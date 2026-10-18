package wolfapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"

	"github.com/r3labs/sse/v2"
)

type ClientInfo struct {
	ID       string `json:"client_id"`
	AppState string `json:"app_state_folder,omitempty"`
}

type ClientsResponse struct {
	Response `json:",inline"`
	Clients  []ClientInfo `json:"clients"`
}

type Session struct {
	AppID             string         `json:"app_id"`
	AudioChannelCount int            `json:"audio_channel_count"`
	ClientID          string         `json:"client_id"`
	ClientIP          string         `json:"client_ip"`
	ClientSettings    ClientSettings `json:"client_settings"`
	VideoHeight       int            `json:"video_height"`
	VideoRefreshRate  int            `json:"video_refresh_rate"`
	VideoWidth        int            `json:"video_width"`

	AESKey string `json:"aes_key"`
	AESIV  string `json:"aes_iv"`

	// Required by Wolf API for RTSP streaming
	RTSPFakeIP string `json:"rtsp_fake_ip"`
}

type ClientSettings struct {
	ControllersOverride []string `json:"controllers_override"`
	//!TODO Float is lossy type. Possible to use decimal?
	HScrollAcceleration float64 `json:"h_scroll_acceleration"`
	MouseAcceleration   float64 `json:"mouse_acceleration"`
	RunGID              int     `json:"run_gid"`
	RunUID              int     `json:"run_uid"`
	VScrollAcceleration float64 `json:"v_scroll_acceleration"`
}

// App represents a Wolf application
type App struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

type Client interface {
	AddSession(ctx context.Context, session Session) (string, error)
	StopSession(ctx context.Context, sessionID string) error
	ListSessions(ctx context.Context) ([]Session, error)
	ListApps(ctx context.Context) ([]App, error)
	ListClients(ctx context.Context) ([]ClientInfo, error)
	SubscribeToEvents(ctx context.Context) (<-chan *sse.Event, error)
}

type client struct {
	apiURL     string
	httpClient *http.Client
}

func NewClient(
	apiURL string,
	httpClient *http.Client,
) Client {
	return &client{
		apiURL:     apiURL,
		httpClient: httpClient,
	}
}

// POST /api/v1/sessions/add
func (c *client) AddSession(
	ctx context.Context,
	session Session,
) (string, error) {
	u, err := url.JoinPath(c.apiURL, "/api/v1/sessions/add")
	if err != nil {
		return "", err
	}

	encodedSession, err := json.Marshal(session)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", u, bytes.NewBuffer(encodedSession))
	if err != nil {
		return "", err
	}

	// FORCE HTTP/1.0 (this disables chunked encoding automatically)
	req.Proto = "HTTP/1.0"
	req.ProtoMajor = 1
	req.ProtoMinor = 0
	req.TransferEncoding = []string{"identity"}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var addSessionResp AddSessionResponse
	if err := json.NewDecoder(resp.Body).Decode(&addSessionResp); err != nil {
		return "", err
	}

	if !addSessionResp.Success {
		return "", fmt.Errorf("failed to add session: %s", addSessionResp.Error)
	}

	return addSessionResp.SessionID, nil
}

// GET /api/v1/sessions
func (c *client) ListSessions(ctx context.Context) ([]Session, error) {
	u, err := url.JoinPath(c.apiURL, "/api/v1/sessions")
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, err
	}

	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var sessionsResp SessionsResponse
	if err := json.NewDecoder(resp.Body).Decode(&sessionsResp); err != nil {
		return nil, err
	}

	if !sessionsResp.Success {
		return nil, fmt.Errorf("failed to list sessions: %s", sessionsResp.Error)
	}

	return sessionsResp.Sessions, nil
}

// GET /api/v1/apps
func (c *client) ListApps(ctx context.Context) ([]App, error) {
	u, err := url.JoinPath(c.apiURL, "/api/v1/apps")
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, err
	}

	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var appsResp AppsResponse
	if err := json.NewDecoder(resp.Body).Decode(&appsResp); err != nil {
		return nil, err
	}

	if !appsResp.Success {
		return nil, fmt.Errorf("failed to list apps: %s", appsResp.Error)
	}

	return appsResp.Apps, nil
}

// GET /api/v1/clients
func (c *client) ListClients(ctx context.Context) ([]ClientInfo, error) {
	u, err := url.JoinPath(c.apiURL, "/api/v1/clients")
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, err
	}

	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var clientsResp ClientsResponse
	if err := json.NewDecoder(resp.Body).Decode(&clientsResp); err != nil {
		return nil, err
	}

	if !clientsResp.Success {
		return nil, fmt.Errorf("failed to list clients: %s", clientsResp.Error)
	}

	return clientsResp.Clients, nil
}

func (c *client) StopSession(ctx context.Context, sessionID string) error {
	type StopSessionRequest struct {
		SessionID string `json:"session_id"`
	}
	u, err := url.JoinPath(c.apiURL, "/api/v1/sessions/stop")
	if err != nil {
		return err
	}

	stopSessionReq := StopSessionRequest{
		SessionID: sessionID,
	}
	encodedStopSessionReq, err := json.Marshal(stopSessionReq)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", u, bytes.NewBuffer(encodedStopSessionReq))
	if err != nil {
		return err
	}

	req.Header.Set("Content-Type", "application/json")
	resp, err := c.do(req)
	if err != nil {
		return err
	}

	defer resp.Body.Close()
	var stopSessionResp Response
	if err := json.NewDecoder(resp.Body).Decode(&stopSessionResp); err != nil {
		return err
	} else if !stopSessionResp.Success {
		return fmt.Errorf("failed to stop session: %s", stopSessionResp.Error)
	}

	return nil
}

type HTTPStatusError struct {
	Method     string
	URL        string
	StatusCode int
}

func (e *HTTPStatusError) Error() string {
	return fmt.Sprintf("%s %s: HTTP %d", e.Method, e.URL, e.StatusCode)
}

func (c *client) do(req *http.Request) (*http.Response, error) {
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("wolf request: %w", err)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		resp.Body.Close()
		return nil, &HTTPStatusError{Method: req.Method, URL: req.URL.String(), StatusCode: resp.StatusCode}
	}
	return resp, nil
}

func (c *client) SubscribeToEvents(ctx context.Context) (<-chan *sse.Event, error) {
	u, err := url.JoinPath(c.apiURL, "/api/v1/events")
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "text/event-stream")
	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}

	events := make(chan *sse.Event)
	go func() {
		defer close(events)
		defer resp.Body.Close()
		reader := sse.NewEventStreamReader(resp.Body, 1<<16)
		var lastID []byte
		for {
			data, err := reader.ReadEvent()
			if err != nil {
				return
			}
			event := &sse.Event{ID: lastID}
			for _, line := range bytes.FieldsFunc(data, func(r rune) bool { return r == '\r' || r == '\n' }) {
				field, value, _ := bytes.Cut(line, []byte(":"))
				value = bytes.TrimPrefix(value, []byte(" "))
				switch string(field) {
				case "id":
					event.ID = bytes.Clone(value)
					lastID = event.ID
				case "event":
					event.Event = bytes.Clone(value)
				case "data":
					event.Data = append(event.Data, value...)
					event.Data = append(event.Data, '\n')
				case "retry":
					event.Retry = bytes.Clone(value)
				}
			}
			if len(event.Data) == 0 {
				continue
			}
			event.Data = bytes.TrimSuffix(event.Data, []byte("\n"))
			select {
			case events <- event:
			case <-ctx.Done():
				return
			}
		}
	}()
	return events, nil
}

type Response struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
}

type SessionsResponse struct {
	Response `json:",inline"`
	Sessions []Session `json:"sessions"`
}

type AppsResponse struct {
	Response `json:",inline"`
	Apps     []App `json:"apps"`
}

type AddSessionResponse struct {
	Response  `json:",inline"`
	SessionID string `json:"session_id"`
}

type WolfEventType string

const (
	PauseStreamEventType  WolfEventType = "wolf::core::events::PauseStreamEvent"
	PlugDeviceEventType   WolfEventType = "wolf::core::events::PlugDeviceEvent"
	UnplugDeviceEventType WolfEventType = "wolf::core::events::UnplugDeviceEvent"
)

type PauseStreamEvent struct {
	SessionID string `json:"session_id"`
}

// PlugDeviceEvent matches Wolf's C++ PlugDeviceEvent struct.
// Wolf broadcasts this via SSE when a virtual input device (joypad, mouse, keyboard)
// is created via uinput. Each udev_events entry contains DEVNAME, MAJOR, MINOR, etc.
type PlugDeviceEvent struct {
	SessionID  string              `json:"session_id"`
	UdevEvents []map[string]string `json:"udev_events"`
	// udev_hw_db_entries is a C++ vector<pair<string, vector<string>>> which
	// serializes as [[key, [values...]], ...]. We don't need it for mknod,
	// so we skip parsing it.
	UdevHwDbEntries json.RawMessage `json:"udev_hw_db_entries"`
}
