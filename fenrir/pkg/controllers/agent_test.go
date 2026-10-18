package controllers_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"games-on-whales.github.io/direwolf/pkg/controllers"
	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	"github.com/stretchr/testify/require"
)

func TestAgentReturnsSubscriptionFailure(t *testing.T) {
	// Given
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	agent := controllers.NewAgent(wolfapi.NewClient(server.URL, server.Client()))
	// When
	err := agent.Run(ctx)
	// Then
	require.Error(t, err)
	require.False(t, agent.Ready())
}

func TestAgentWaitsForEventsAndStopsPausedSession(t *testing.T) {
	// Given
	stopped := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/events":
			w.Header().Set("Content-Type", "text/event-stream")
			_, err := io.WriteString(w, "event: wolf::core::events::PauseStreamEvent\ndata: {\"session_id\":\"session-42\"}\n\n")
			if err != nil {
				t.Error(err)
			}
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		case "/api/v1/sessions/stop":
			var body struct {
				SessionID string `json:"session_id"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			stopped <- body.SessionID
			_, err := io.WriteString(w, `{"success":true}`)
			if err != nil {
				t.Error(err)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	agent := controllers.NewAgent(wolfapi.NewClient(server.URL, server.Client()))
	done := make(chan error, 1)
	// When
	go func() { done <- agent.Run(ctx) }()
	// Then
	select {
	case id := <-stopped:
		require.Equal(t, "session-42", id)
	case err := <-done:
		t.Fatalf("Run returned before processing the event: %v", err)
	case <-ctx.Done():
		t.Fatal("pause event did not stop the session")
	}
	select {
	case err := <-done:
		t.Fatalf("Run returned while the stream remained open: %v", err)
	default:
	}
	require.True(t, agent.Ready())
	cancel()
	select {
	case err := <-done:
		require.ErrorIs(t, err, context.Canceled)
	case <-time.After(time.Second):
		t.Fatal("Run did not stop on cancellation")
	}
	require.False(t, agent.Ready())
}

func TestAgentReturnsErrorOnStreamClosure(t *testing.T) {
	// Given
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	agent := controllers.NewAgent(wolfapi.NewClient(server.URL, server.Client()))
	// When
	err := agent.Run(ctx)
	// Then
	require.Error(t, err)
	require.NoError(t, ctx.Err(), "stream closure must be detected before the deadline")
	require.False(t, agent.Ready())
}

func TestAgentClosesStreamWhenSessionCleanupFails(t *testing.T) {
	// Given
	disconnected := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/events" {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, err := io.WriteString(w, "event: wolf::core::events::PauseStreamEvent\ndata: {\"session_id\":\"session-42\"}\n\n")
		if err != nil {
			t.Error(err)
		}
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(disconnected)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	agent := controllers.NewAgent(wolfapi.NewClient(server.URL, server.Client()))
	// When
	err := agent.Run(ctx)
	// Then
	var statusError *wolfapi.HTTPStatusError
	require.ErrorAs(t, err, &statusError)
	require.Equal(t, http.StatusServiceUnavailable, statusError.StatusCode)
	require.False(t, agent.Ready())
	select {
	case <-disconnected:
	case <-ctx.Done():
		t.Fatal("failed run leaked its event stream")
	}
}
