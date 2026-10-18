package moonlight

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"encoding/xml"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	api "games-on-whales.github.io/direwolf/pkg/api/v1alpha1"
	"games-on-whales.github.io/direwolf/pkg/generic"
	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/cache"
)

func attachResumeAgent(t *testing.T, s *RESTServer, status int, live []wolfapi.Session) {
	t.Helper()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "GET", r.Method)
		require.Equal(t, "/api/v1/sessions", r.URL.Path)
		require.Equal(t, "stream.house.svc:8443", r.Host)
		w.WriteHeader(status)
		require.NoError(t, json.NewEncoder(w).Encode(map[string]any{"success": true, "sessions": live}))
	}))
	t.Cleanup(server.Close)
	transport := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}}
	t.Cleanup(transport.CloseIdleConnections)
	s.wolfHTTPClient = &http.Client{Transport: transport, Timeout: time.Second}
}

func TestResumeRequiresLiveWolfSessionAndMatchingKeys(t *testing.T) {
	for _, tc := range []struct {
		name, key, iv    string
		status, expected int
		live             []wolfapi.Session
	}{
		{"live", "key", "iv", 200, 200, []wolfapi.Session{{ClientID: "wolf-1", AESKey: "key", AESIV: "iv"}}},
		{"stopped", "key", "iv", 200, 409, nil},
		{"stale_id", "key", "iv", 200, 409, []wolfapi.Session{{ClientID: "another-session", AESKey: "key", AESIV: "iv"}}},
		{"stale_keys", "key", "iv", 200, 409, []wolfapi.Session{{ClientID: "wolf-1", AESKey: "old-key", AESIV: "iv"}}},
		{"new_key", "new-key", "iv", 200, 409, []wolfapi.Session{{ClientID: "wolf-1", AESKey: "key", AESIV: "iv"}}},
		{"new_iv", "key", "new-iv", 200, 409, []wolfapi.Session{{ClientID: "wolf-1", AESKey: "key", AESIV: "iv"}}},
		{"upstream_error", "key", "iv", 503, 503, []wolfapi.Session{{ClientID: "wolf-1", AESKey: "key", AESIV: "iv"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, client, ctx := resolutionRESTFixture(t)
			session := &api.Session{ObjectMeta: metav1.ObjectMeta{Name: "active", Namespace: "house", Labels: map[string]string{"direwolf/user": "jeff"}}, Spec: api.SessionSpec{Config: api.SessionInfo{AESKey: "key", AESIV: "iv", VideoWidth: 1920, VideoHeight: 1080, VideoRefreshRate: 60}}, Status: api.SessionStatus{ServiceName: "stream", WolfSessionID: "wolf-1", StreamURL: "rtsp://192.168.1.221:48010"}}
			indexer := cache.NewIndexer(cache.MetaNamespaceKeyFunc, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
			require.NoError(t, indexer.Add(session))
			s.SessionLister = generic.NewLister[*api.Session](indexer).Namespaced("house")
			attachResumeAgent(t, s, tc.status, tc.live)
			response := httptest.NewRecorder()
			s.resumeHandler(response, httptest.NewRequest("GET", "/resume?mode=1920x1080x60&rikey="+tc.key+"&rikeyid="+tc.iv, nil).WithContext(ctx))
			require.Equal(t, tc.expected, response.Code)
			var result ResumeResponse
			require.NoError(t, xml.Unmarshal(response.Body.Bytes(), &result))
			require.Equal(t, tc.expected, result.StatusCode)
			if tc.expected == 200 {
				require.Equal(t, 1, result.Resume)
				require.Equal(t, session.Status.StreamURL, result.RTSPSessionURL)
			} else {
				require.Zero(t, result.Resume)
				require.Empty(t, result.RTSPSessionURL)
			}
			require.Empty(t, client.Actions())
		})
	}
}
