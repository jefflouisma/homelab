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

func TestRollbackRetainsThreeVersionsAndNeverPrunesActive(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
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
	require.Equal(t, "bundled-3.5.0", snapshot(t, m).Components[EmuDeck].Active)
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
