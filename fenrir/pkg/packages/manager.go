package packages

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

type Status struct {
	Active    string    `json:"active"`
	Available *Release  `json:"available,omitempty"`
	Staged    *Release  `json:"staged,omitempty"`
	Queued    string    `json:"queued,omitempty"`
	Previous  []string  `json:"previous"`
	Checked   time.Time `json:"checked"`
	Error     string    `json:"error,omitempty"`
	Busy      bool      `json:"busy"`
}

type State struct {
	Components      map[Component]Status `json:"components"`
	ActivationError string               `json:"activation_error,omitempty"`
}

type Manager struct {
	mu             sync.Mutex
	state          State
	root           string
	sources        Sources
	installer      Installer
	activeSessions func(context.Context) (int, error)
	now            func() time.Time
	checks         chan Component
}

func (m *Manager) Check(id Component) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.state.Components[id]
	if s.Busy {
		return fmt.Errorf("a check is already running")
	}
	s.Busy = true
	s.Error = ""
	m.state.Components[id] = s
	select {
	case m.checks <- id:
		return nil
	default:
		s.Busy = false
		m.state.Components[id] = s
		return fmt.Errorf("check queue is full")
	}
}

func (m *Manager) stage(ctx context.Context, id Component) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	release, err := m.sources.Latest(ctx, id)
	if err == nil {
		m.mu.Lock()
		s := m.state.Components[id]
		s.Available = &release
		m.state.Components[id] = s
		m.mu.Unlock()
		err = m.installer.Install(ctx, id, release)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.state.Components[id]
	s.Busy = false
	s.Checked = m.now()
	if err != nil {
		s.Error = err.Error()
		slog.ErrorContext(ctx, "package staging failed", "component", id, "error", err)
	} else {
		s.Staged = &release
		s.Error = ""
	}
	m.state.Components[id] = s
	if err := m.saveLocked(); err != nil {
		slog.ErrorContext(ctx, "persist staging result", "error", err)
		s.Error = err.Error()
		m.state.Components[id] = s
	}
}

func (m *Manager) Queue(id Component, version string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.state.Components[id]
	if version == "" {
		if s.Staged == nil {
			return fmt.Errorf("no verified update is staged")
		}
		version = s.Staged.Version
	}
	if version != s.Active && !slices.Contains(s.Previous, version) && (s.Staged == nil || s.Staged.Version != version) {
		return fmt.Errorf("version is not staged or retained")
	}
	if s.Active == version {
		return fmt.Errorf("version is already active")
	}
	before := s
	s.Queued = version
	s.Error = ""
	m.state.Components[id] = s
	if err := m.saveLocked(); err != nil {
		m.state.Components[id] = before
		return err
	}
	return nil
}

func (m *Manager) Cancel(id Component) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	before := m.state.Components[id]
	s := before
	s.Queued = ""
	s.Error = ""
	m.state.Components[id] = s
	if err := m.saveLocked(); err != nil {
		m.state.Components[id] = before
		return err
	}
	return nil
}

func (m *Manager) Activate(ctx context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	queued := false
	for _, s := range m.state.Components {
		queued = queued || s.Queued != ""
	}
	if !queued {
		return nil
	}
	n, err := m.activeSessions(ctx)
	if err != nil {
		return fmt.Errorf("check running sessions: %w", err)
	}
	if n > 0 {
		return nil
	}
	for _, id := range []Component{EmuDeck, Kyty} {
		s := m.state.Components[id]
		if s.Queued == "" {
			continue
		}
		if s.Queued != "bundled-3.5.0" {
			if err := m.installer.Probe(ctx, id, filepath.Join(m.root, string(id), s.Queued)); err != nil {
				return fmt.Errorf("activation check: %w", err)
			}
		}
		before := s
		previous := []string{}
		if s.Active != "" {
			previous = append(previous, s.Active)
		}
		for _, v := range s.Previous {
			if v != s.Queued && !slices.Contains(previous, v) && len(previous) < 3 {
				previous = append(previous, v)
			}
		}
		s.Active = s.Queued
		s.Queued = ""
		s.Previous = previous
		s.Error = ""
		m.state.Components[id] = s
		if err := m.saveLocked(); err != nil {
			m.state.Components[id] = before
			return err
		}
		if err := m.pruneLocked(id, s); err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) pruneLocked(id Component, s Status) error {
	entries, err := os.ReadDir(filepath.Join(m.root, string(id)))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("list retained packages: %w", err)
	}
	keep := append(slices.Clone(s.Previous), s.Active, s.Queued)
	if s.Staged != nil {
		keep = append(keep, s.Staged.Version)
	}
	for _, entry := range entries {
		if entry.IsDir() && versionPattern.MatchString(entry.Name()) && !slices.Contains(keep, entry.Name()) {
			if err := os.RemoveAll(filepath.Join(m.root, string(id), entry.Name())); err != nil {
				return fmt.Errorf("prune package: %w", err)
			}
		}
	}
	return nil
}

func (m *Manager) Run(ctx context.Context) {
	checkTicker := time.NewTicker(6 * time.Hour)
	defer checkTicker.Stop()
	activationTicker := time.NewTicker(5 * time.Second)
	defer activationTicker.Stop()
	for _, id := range []Component{EmuDeck, Kyty} {
		if err := m.Check(id); err != nil {
			slog.ErrorContext(ctx, "schedule initial check", "error", err)
		}
	}
	for {
		select {
		case <-ctx.Done():
			return
		case id := <-m.checks:
			m.stage(ctx, id)
		case <-checkTicker.C:
			for _, id := range []Component{EmuDeck, Kyty} {
				if err := m.Check(id); err != nil {
					slog.WarnContext(ctx, "schedule release check", "error", err)
				}
			}
		case <-activationTicker.C:
			err := m.Activate(ctx)
			m.mu.Lock()
			if err != nil {
				m.state.ActivationError = err.Error()
			} else {
				m.state.ActivationError = ""
			}
			m.mu.Unlock()
			if err != nil {
				slog.ErrorContext(ctx, "activate queued package", "error", err)
			}
		}
	}
}
