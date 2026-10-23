package packages

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func newManager(t *testing.T, sessions func(context.Context) (int, error)) *Manager {
	t.Helper()
	root := t.TempDir()
	m, err := New(root, Sources{}, Installer{Root: root, Probe: func(context.Context, Component, string) error { return nil }}, sessions)
	require.NoError(t, err)
	return m
}

func snapshot(t *testing.T, m *Manager) State {
	t.Helper()
	data, err := m.Snapshot()
	require.NoError(t, err)
	var state State
	require.NoError(t, json.Unmarshal(data, &state))
	return state
}

func TestActivationWaitsForSessionsAndSurvivesRestart(t *testing.T) {
	running := 1
	m := newManager(t, func(context.Context) (int, error) { return running, nil })
	s := m.state.Components[Kyty]
	s.Staged = &Release{Version: "v1"}
	m.state.Components[Kyty] = s
	require.NoError(t, m.Queue(Kyty, ""))
	require.NoError(t, m.Activate(t.Context()))
	require.Empty(t, snapshot(t, m).Components[Kyty].Active)
	require.Equal(t, "v1", snapshot(t, m).Components[Kyty].Queued)
	restarted, err := New(m.root, Sources{}, m.installer, m.activeSessions)
	require.NoError(t, err)
	running = 0
	require.NoError(t, restarted.Activate(t.Context()))
	require.Equal(t, "v1", snapshot(t, restarted).Components[Kyty].Active)
	require.Empty(t, snapshot(t, restarted).Components[Kyty].Queued)
}

func TestActivationFailsClosedWhenSessionLookupFails(t *testing.T) {
	lookupErr := errors.New("API unavailable")
	m := newManager(t, func(context.Context) (int, error) { return 0, lookupErr })
	s := m.state.Components[Kyty]
	s.Staged = &Release{Version: "v1"}
	m.state.Components[Kyty] = s
	require.NoError(t, m.Queue(Kyty, ""))
	err := m.Activate(t.Context())
	require.ErrorIs(t, err, lookupErr)
	require.Empty(t, snapshot(t, m).Components[Kyty].Active)
}

func TestActivationWaitsForSessionStartingDuringProbe(t *testing.T) {
	lookups := 0
	m := newManager(t, func(context.Context) (int, error) {
		lookups++
		if lookups == 1 {
			return 0, nil
		}
		return 1, nil
	})
	s := m.state.Components[Kyty]
	s.Staged = &Release{Version: "v1"}
	m.state.Components[Kyty] = s
	require.NoError(t, m.Queue(Kyty, ""))
	require.NoError(t, m.Activate(t.Context()))
	require.Empty(t, snapshot(t, m).Components[Kyty].Active)
	require.Equal(t, "v1", snapshot(t, m).Components[Kyty].Queued)
}

func TestCancelRemovesPendingActivation(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	s := m.state.Components[Kyty]
	s.Staged = &Release{Version: "v1"}
	m.state.Components[Kyty] = s
	require.NoError(t, m.Queue(Kyty, ""))
	require.NoError(t, m.Cancel(Kyty))
	require.NoError(t, m.Activate(t.Context()))
	require.Empty(t, snapshot(t, m).Components[Kyty].Active)
	require.Empty(t, snapshot(t, m).Components[Kyty].Queued)
}

func TestStatusRemainsReadableDuringActivationProbe(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	s := m.state.Components[Kyty]
	s.Staged = &Release{Version: "v1"}
	m.state.Components[Kyty] = s
	require.NoError(t, m.Queue(Kyty, ""))
	m.installer.Probe = func(ctx context.Context, _ Component, _ string) error {
		read := make(chan error, 1)
		go func() { _, err := m.Snapshot(); read <- err }()
		select {
		case err := <-read:
			return err
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	require.NoError(t, m.Activate(ctx))
}

func TestNewStagingPrunesSupersededBuildsButKeepsQueuedVersion(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 1, nil })
	checksum := strings.Repeat("a", 64)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"tag_name": "new", "assets": []map[string]string{{"name": "new-Linux-x86_64.tar.gz", "browser_download_url": "https://github.com/new", "digest": "sha256:" + checksum}}})
	}))
	defer server.Close()
	m.sources = Sources{Client: server.Client(), GitHub: server.URL}
	s := m.state.Components[Kyty]
	s.Active = "active"
	s.Queued = "queued"
	s.Previous = []string{"previous"}
	s.Staged = &Release{Version: "obsolete"}
	m.state.Components[Kyty] = s
	for _, v := range []string{"active", "queued", "previous", "obsolete", "new"} {
		path := filepath.Join(m.root, string(Kyty), v)
		require.NoError(t, os.MkdirAll(path, 0755))
		require.NoError(t, os.WriteFile(filepath.Join(path, ".verified"), []byte(checksum), 0644))
	}
	m.stage(t.Context(), Kyty)
	require.NoDirExists(t, filepath.Join(m.root, string(Kyty), "obsolete"))
	for _, v := range []string{"active", "queued", "previous", "new"} {
		require.DirExists(t, filepath.Join(m.root, string(Kyty), v))
	}
}

func TestRollbackRetainsThreeVersionsAndNeverPrunesActive(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	frontendBefore := snapshot(t, m).Components[EmuDeck]
	for n := 1; n <= 5; n++ {
		version := fmt.Sprintf("v%d", n)
		dir := filepath.Join(m.root, string(Kyty), version)
		require.NoError(t, os.MkdirAll(dir, 0755))
		require.NoError(t, os.WriteFile(filepath.Join(dir, "save-sentinel"), []byte(version), 0644))
		s := m.state.Components[Kyty]
		s.Staged = &Release{Version: version}
		m.state.Components[Kyty] = s
		require.NoError(t, m.Queue(Kyty, ""))
		require.NoError(t, m.Activate(t.Context()))
	}
	require.Equal(t, []string{"v4", "v3", "v2"}, snapshot(t, m).Components[Kyty].Previous)
	require.NoDirExists(t, filepath.Join(m.root, string(Kyty), "v1"))
	require.NoError(t, m.Queue(Kyty, "v3"))
	require.NoError(t, m.Activate(t.Context()))
	require.Equal(t, "v3", snapshot(t, m).Components[Kyty].Active)
	require.FileExists(t, filepath.Join(m.root, string(Kyty), "v3", "save-sentinel"))
	require.Equal(t, frontendBefore, snapshot(t, m).Components[EmuDeck])
}

func TestHTTPRejectsUnknownAndUnretainedVersions(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	for _, tc := range []struct {
		path, body string
		status     int
	}{
		{"/api/updates/unknown/check", "{}", 400},
		{"/api/updates/kytyps5/apply", "{}", 409},
		{"/api/updates/kytyps5/rollback", `{"version":"../../other"}`, 409},
		{"/api/updates/kytyps5/rollback", `{"version":""}`, 400},
		{"/api/updates/kytyps5/rollback", `{"version":`, 409},
		{"/api/updates/ps5plus/apply", "{}", 409},
	} {
		t.Run(tc.path+tc.body, func(t *testing.T) {
			rec := httptest.NewRecorder()
			m.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(tc.body)))
			require.Equal(t, tc.status, rec.Code)
		})
	}
}

func TestFailedProbeDoesNotReplaceWorkingPackage(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	s := m.state.Components[Kyty]
	s.Active = "old"
	s.Staged = &Release{Version: "new"}
	m.state.Components[Kyty] = s
	require.NoError(t, m.Queue(Kyty, ""))
	m.installer.Probe = func(context.Context, Component, string) error { return errors.New("loader failure") }
	require.Error(t, m.Activate(t.Context()))
	require.Equal(t, "old", snapshot(t, m).Components[Kyty].Active)
}

func TestStateFromBeforePS5PlusGainsAnEmptyComponent(t *testing.T) {
	root := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(root, "state.json"), []byte(`{"components":{"emudeck":{"active":"v1","previous":[]},"kytyps5":{"active":"k1","previous":["k0"]}}}`), 0644))
	m, err := New(root, Sources{}, Installer{Root: root}, nil)
	require.NoError(t, err)
	state := snapshot(t, m)
	require.Equal(t, "k1", state.Components[Kyty].Active)
	require.Equal(t, []string{"k0"}, state.Components[Kyty].Previous)
	require.Equal(t, Status{Previous: []string{}}, state.Components[PS5Plus])
	require.NoError(t, os.WriteFile(filepath.Join(root, "state.json"), []byte(`{"components":{"other":{}}}`), 0644))
	_, err = New(root, Sources{}, Installer{Root: root}, nil)
	require.ErrorContains(t, err, "unknown component")
}

func TestEveryComponentCanBeQueuedForCheckAtOnce(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	for _, id := range Components {
		require.NoError(t, m.Check(id))
	}
}
