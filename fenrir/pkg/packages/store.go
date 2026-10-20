package packages

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"time"
)

func New(root string, sources Sources, installer Installer, sessions func(context.Context) (int, error)) (*Manager, error) {
	if err := os.MkdirAll(root, 0755); err != nil {
		return nil, fmt.Errorf("create package root: %w", err)
	}
	for _, pattern := range []string{".state-*", "emudeck/.stage-*", "kytyps5/.stage-*"} {
		paths, err := filepath.Glob(filepath.Join(root, pattern))
		if err != nil {
			return nil, fmt.Errorf("find interrupted staging: %w", err)
		}
		for _, path := range paths {
			if err := os.RemoveAll(path); err != nil {
				return nil, fmt.Errorf("clean interrupted staging: %w", err)
			}
		}
	}
	m := &Manager{root: root, sources: sources, installer: installer, activeSessions: sessions, now: time.Now, checks: make(chan Component, 2), state: State{Components: map[Component]Status{EmuDeck: {Active: "bundled-3.5.0", Previous: []string{}}, Kyty: {Previous: []string{}}}}}
	data, err := os.ReadFile(filepath.Join(root, "state.json"))
	if err == nil {
		if err := json.Unmarshal(data, &m.state); err != nil {
			return nil, fmt.Errorf("read package state: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("open package state: %w", err)
	}
	if len(m.state.Components) != 2 {
		return nil, fmt.Errorf("package state must contain both components")
	}
	for _, id := range []Component{EmuDeck, Kyty} {
		s, ok := m.state.Components[id]
		if !ok {
			return nil, fmt.Errorf("missing component %s", id)
		}
		for _, v := range append(slices.Clone(s.Previous), s.Active, s.Queued) {
			if v != "" && !versionPattern.MatchString(v) {
				return nil, fmt.Errorf("invalid stored version")
			}
		}
		s.Busy = false
		m.state.Components[id] = s
	}
	if err := m.saveLocked(); err != nil {
		return nil, err
	}
	return m, nil
}

func (m *Manager) saveLocked() error {
	data, err := json.MarshalIndent(m.state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode package state: %w", err)
	}
	f, err := os.CreateTemp(m.root, ".state-")
	if err != nil {
		return fmt.Errorf("create state transaction: %w", err)
	}
	name := f.Name()
	defer os.Remove(name)
	_, writeErr := f.Write(data)
	err = errors.Join(writeErr, f.Chmod(0644), f.Sync(), f.Close())
	if err != nil {
		return fmt.Errorf("persist package state: %w", err)
	}
	if err := os.Rename(name, filepath.Join(m.root, "state.json")); err != nil {
		return fmt.Errorf("commit package state: %w", err)
	}
	return nil
}

func (m *Manager) Snapshot() ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return json.Marshal(m.state)
}
