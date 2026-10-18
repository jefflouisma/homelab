package wolfapi_test

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	"github.com/stretchr/testify/require"
)

var requests = map[string]func(context.Context, wolfapi.Client) error{
	"add": func(ctx context.Context, c wolfapi.Client) error {
		_, err := c.AddSession(ctx, wolfapi.Session{})
		return err
	},
	"stop":     func(ctx context.Context, c wolfapi.Client) error { return c.StopSession(ctx, "session-1") },
	"sessions": func(ctx context.Context, c wolfapi.Client) error { _, err := c.ListSessions(ctx); return err },
	"apps":     func(ctx context.Context, c wolfapi.Client) error { _, err := c.ListApps(ctx); return err },
	"clients":  func(ctx context.Context, c wolfapi.Client) error { _, err := c.ListClients(ctx); return err },
}

func TestRequestsRejectHTTPFailure(t *testing.T) {
	// Given a failure status carrying an otherwise successful JSON response.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, err := io.WriteString(w, `{"success":true,"session_id":"session-1"}`)
		if err != nil {
			t.Error(err)
		}
	}))
	defer server.Close()
	for name, request := range requests {
		t.Run(name, func(t *testing.T) {
			// When
			err := request(context.Background(), wolfapi.NewClient(server.URL, server.Client()))
			// Then
			var statusError *wolfapi.HTTPStatusError
			require.ErrorAs(t, err, &statusError)
			require.Equal(t, http.StatusServiceUnavailable, statusError.StatusCode)
		})
	}
}

func TestRequestsHonorCancellation(t *testing.T) {
	for name, request := range requests {
		t.Run(name, func(t *testing.T) {
			// Given an in-flight request whose server waits for cancellation.
			started := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, err := io.Copy(io.Discard, r.Body)
				if err != nil {
					t.Error(err)
				}
				close(started)
				<-r.Context().Done()
			}))
			defer server.Close()
			httpClient := server.Client()
			httpClient.Timeout = time.Second
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			// When
			go func() { done <- request(ctx, wolfapi.NewClient(server.URL, httpClient)) }()
			<-started
			cancel()
			// Then
			require.ErrorIs(t, <-done, context.Canceled)
		})
	}
}

func TestSubscribeRejectsHTTPFailure(t *testing.T) {
	// Given
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	// When
	events, err := wolfapi.NewClient(server.URL, server.Client()).SubscribeToEvents(ctx)
	// Then
	require.Error(t, err)
	require.Nil(t, events)
	require.False(t, errors.Is(err, context.DeadlineExceeded), "HTTP failure should be returned immediately")
}

func TestSubscribeDeliversEventsAndClosesOnEOF(t *testing.T) {
	// Given a CRLF stream with multiline data and a heartbeat.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, err := io.WriteString(w, ": heartbeat\r\n\r\nid: 7\r\nevent: pause\r\ndata: first\r\ndata: second\r\n\r\n")
		if err != nil {
			t.Error(err)
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	// When
	events, err := wolfapi.NewClient(server.URL, server.Client()).SubscribeToEvents(ctx)
	// Then
	require.NoError(t, err)
	select {
	case event := <-events:
		require.NotNil(t, event)
		require.Equal(t, "pause", string(event.Event))
		require.Equal(t, "7", string(event.ID))
		require.Equal(t, "first\nsecond", string(event.Data))
	case <-ctx.Done():
		t.Fatal("event was not delivered")
	}
	select {
	case _, open := <-events:
		require.False(t, open)
	case <-ctx.Done():
		t.Fatal("event channel stayed open after EOF")
	}
}

func TestSubscribeClosesOnCancellation(t *testing.T) {
	for _, payload := range []string{"", "event: pause\ndata: {}\n\n"} {
		t.Run(payload, func(t *testing.T) {
			// Given an idle stream or a blocked consumer.
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				_, err := io.WriteString(w, payload)
				if err != nil {
					t.Error(err)
				}
				w.(http.Flusher).Flush()
				<-r.Context().Done()
			}))
			defer server.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			events, err := wolfapi.NewClient(server.URL, server.Client()).SubscribeToEvents(ctx)
			require.NoError(t, err)
			// When
			cancel()
			// Then
			timer := time.NewTimer(time.Second)
			defer timer.Stop()
			for {
				select {
				case _, open := <-events:
					if !open {
						return
					}
				case <-timer.C:
					t.Fatal("event channel stayed open after cancellation")
				}
			}
		})
	}
}
