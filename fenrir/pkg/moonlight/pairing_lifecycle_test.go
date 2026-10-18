package moonlight

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"encoding/xml"
	"net/http/httptest"
	"net/url"
	"runtime"
	"testing"
	"time"

	"games-on-whales.github.io/direwolf/pkg/util"
	"github.com/stretchr/testify/require"
)

func pairingFixture(t *testing.T) (*RESTServer, string) {
	t.Helper()
	certPEM, keyPEM, err := util.GenerateEphemeralCert("ECC")
	require.NoError(t, err)
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	require.NoError(t, err)
	server := NewRESTServer(NewPairingManager(cert, nil), nil, nil, nil, nil, nil, nil, RESTServerOptions{})
	query := url.Values{"uniqueid": {"test-client"}, "salt": {"00112233445566778899aabbccddeeff"}, "clientcert": {hex.EncodeToString(certPEM)}}
	return server, "/pair?" + query.Encode()
}

func startPairing(s *RESTServer, ctx context.Context, path string) <-chan *httptest.ResponseRecorder {
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		recorder := httptest.NewRecorder()
		s.router.ServeHTTP(recorder, httptest.NewRequest("GET", path, nil).WithContext(ctx))
		done <- recorder
	}()
	return done
}

func awaitSecret(t *testing.T, m *PairingManager, previous string) string {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		for _, secret := range m.GetPendingSecrets() {
			if secret != previous {
				return secret
			}
		}
		select {
		case <-deadline:
			t.Fatal("new pending PIN was not published")
		default:
			runtime.Gosched()
		}
	}
}

func awaitPairing(t *testing.T, done <-chan *httptest.ResponseRecorder) PairingResponse {
	t.Helper()
	select {
	case response := <-done:
		var result PairingResponse
		require.NoError(t, xml.Unmarshal(response.Body.Bytes(), &result))
		return result
	case <-time.After(time.Second):
		t.Fatal("pair request did not finish")
		return PairingResponse{}
	}
}

func TestPairingCancelRemovesPendingPIN(t *testing.T) {
	server, path := pairingFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := startPairing(server, ctx, path)
	secret := awaitSecret(t, server.manager, "")
	t.Cleanup(func() { server.manager.PostPin(secret, "1234") })

	cancel()

	require.Zero(t, awaitPairing(t, done).Paired)
	require.Empty(t, server.manager.GetPendingSecrets())
	require.Error(t, server.manager.PostPin(secret, "1234"))
}

func TestPairingDeadlineStopsWaiting(t *testing.T) {
	server, path := pairingFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	done := startPairing(server, ctx, path)

	<-ctx.Done()

	require.Zero(t, awaitPairing(t, done).Paired)
	require.Empty(t, server.manager.GetPendingSecrets())
}

func TestPairingRetryReplacesWaitingRequest(t *testing.T) {
	server, path := pairingFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first := startPairing(server, ctx, path)
	oldSecret := awaitSecret(t, server.manager, "")
	t.Cleanup(func() { server.manager.PostPin(oldSecret, "1234") })

	second := startPairing(server, ctx, path)
	secret := awaitSecret(t, server.manager, oldSecret)
	t.Cleanup(func() { server.manager.PostPin(secret, "1234") })

	require.Equal(t, []string{secret}, server.manager.GetPendingSecrets())
	require.Zero(t, awaitPairing(t, first).Paired)
	require.Error(t, server.manager.PostPin(oldSecret, "1234"))
	require.NoError(t, server.manager.PostPin(secret, "1234"))
	require.Equal(t, 1, awaitPairing(t, second).Paired)
}

func TestPairingRetryReplacesIncompleteHandshake(t *testing.T) {
	server, path := pairingFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first := startPairing(server, ctx, path)
	secret := awaitSecret(t, server.manager, "")
	require.NoError(t, server.manager.PostPin(secret, "1234"))
	require.Equal(t, 1, awaitPairing(t, first).Paired)

	second := startPairing(server, ctx, path)
	newSecret := awaitSecret(t, server.manager, secret)
	require.NoError(t, server.manager.PostPin(newSecret, "5678"))

	require.Equal(t, 1, awaitPairing(t, second).Paired)
}
