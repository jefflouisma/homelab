package controllers_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"games-on-whales.github.io/direwolf/pkg/controllers"
	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	"github.com/stretchr/testify/require"
)

func TestAgentInputInventoryTracksItsEventStream(t *testing.T) {
	events := make(chan string, 8)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/sessions/stop" {
			_, _ = w.Write([]byte(`{"success":true}`))
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		for {
			select {
			case event := <-events:
				_, _ = fmt.Fprint(w, event)
				w.(http.Flusher).Flush()
			case <-r.Context().Done():
				return
			}
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	agent := controllers.NewAgent(wolfapi.NewClient(server.URL, server.Client()))
	done := make(chan error, 1)
	go func() { done <- agent.Run(ctx) }()
	snapshot := func() []controllers.InputDevice {
		t.Helper()
		w := httptest.NewRecorder()
		agent.ServeInputDevices(w, httptest.NewRequest(http.MethodGet, "/input-devices", nil))
		if w.Code != http.StatusOK {
			return nil
		}
		var result struct {
			Devices []controllers.InputDevice `json:"devices"`
		}
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &result))
		return result.Devices
	}
	send := func(event, session, path, major, minor string) {
		t.Helper()
		body, err := json.Marshal(wolfapi.PlugDeviceEvent{SessionID: session, UdevEvents: []map[string]string{
			{"DEVNAME": path, "MAJOR": major, "MINOR": minor},
		}})
		require.NoError(t, err)
		events <- fmt.Sprintf("event: wolf::core::events::%s\ndata: %s\n\n", event, body)
	}
	require.Eventually(t, agent.Ready, time.Second, time.Millisecond)
	send("PlugDeviceEvent", "session-a", "/dev/input/event42", "13", "106")
	send("PlugDeviceEvent", "session-b", "/dev/input/event43", "13", "107")
	send("PlugDeviceEvent", "session-a", "/dev/input/../event44", "13", "108")
	send("PlugDeviceEvent", "session-a", "/dev/input/event45", "1", "109")
	require.Eventually(t, func() bool { return len(snapshot()) == 2 }, time.Second, time.Millisecond)
	first := snapshot()
	require.Equal(t, "/dev/input/event42", first[0].Path)
	require.Equal(t, "session-a", first[0].SessionID)
	require.Equal(t, uint32(13), first[0].Major)
	send("UnplugDeviceEvent", "session-b", "/dev/input/event42", "13", "106")
	// A new plug acts as an ordering barrier and must get a fresh generation.
	send("PlugDeviceEvent", "session-b", "/dev/input/event43", "13", "107")
	require.Eventually(t, func() bool {
		rows := snapshot()
		return len(rows) == 2 && rows[1].Generation > first[1].Generation
	}, time.Second, time.Millisecond)
	send("UnplugDeviceEvent", "session-a", "/dev/input/event42", "13", "106")
	require.Eventually(t, func() bool {
		rows := snapshot()
		return len(rows) == 1 && rows[0].SessionID == "session-b"
	}, time.Second, time.Millisecond)
	events <- "event: wolf::core::events::PauseStreamEvent\ndata: {\"session_id\":\"session-b\"}\n\n"
	require.Eventually(t, func() bool { return len(snapshot()) == 0 }, time.Second, time.Millisecond)
	cancel()
	require.ErrorIs(t, <-done, context.Canceled)
	w := httptest.NewRecorder()
	agent.ServeInputDevices(w, httptest.NewRequest(http.MethodGet, "/input-devices", nil))
	require.Equal(t, http.StatusServiceUnavailable, w.Code)
	require.NotContains(t, w.Body.String(), "event42")
}

func TestAgentInputInventoryRejectsMutations(t *testing.T) {
	agent := controllers.NewAgent(nil)
	w := httptest.NewRecorder()
	agent.ServeInputDevices(w, httptest.NewRequest(http.MethodPost, "/input-devices", nil))
	require.Equal(t, http.StatusMethodNotAllowed, w.Code)
}
