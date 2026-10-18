package moonlight

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
)

func submitPIN(server *RESTServer, secret, pin string) *httptest.ResponseRecorder {
	body, err := json.Marshal(map[string]string{"secret": secret, "pin": pin})
	if err != nil {
		panic(err)
	}
	result := httptest.NewRecorder()
	server.router.ServeHTTP(result, httptest.NewRequest(http.MethodPost, "/pin/", strings.NewReader(string(body))))
	return result
}

func TestPairingStalePINReturnsGone(t *testing.T) {
	server, _ := pairingFixture(t)
	response := submitPIN(server, "expired", "1234")
	require.Equal(t, http.StatusGone, response.Code)
	require.NotEmpty(t, response.Body.String())
}

func TestPairingPINRequiresFourASCIIDigits(t *testing.T) {
	server, _ := pairingFixture(t)
	for _, pin := range []string{"", "123", "12345", "abcd", "12 4", "１２３４"} {
		t.Run(pin, func(t *testing.T) {
			require.Equal(t, http.StatusBadRequest, submitPIN(server, "expired", pin).Code)
		})
	}
}

func TestPairingPagesPreventCaching(t *testing.T) {
	server, _ := pairingFixture(t)
	for _, path := range []string{"/", "/dashboard", "/pin/", "/pairing/pending"} {
		t.Run(path, func(t *testing.T) {
			response := httptest.NewRecorder()
			server.router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
			require.Equal(t, "no-store", response.Header().Get("Cache-Control"))
		})
	}
}

func TestPairingConcurrentPINAcceptedOnce(t *testing.T) {
	server, path := pairingFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := startPairing(server, ctx, path)
	secret := awaitSecret(t, server.manager, "")
	const submissions = 32
	responses := make(chan *httptest.ResponseRecorder, submissions)
	start := make(chan struct{})
	var group sync.WaitGroup
	for range submissions {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			responses <- submitPIN(server, secret, "1234")
		}()
	}
	close(start)
	group.Wait()
	close(responses)
	accepted := 0
	for response := range responses {
		if response.Code == http.StatusOK {
			accepted++
			require.Equal(t, "OK", response.Body.String())
		} else {
			require.Equal(t, http.StatusGone, response.Code)
		}
	}
	require.Equal(t, 1, accepted)
	require.Equal(t, 1, awaitPairing(t, done).Paired)
	require.Empty(t, server.manager.GetPendingSecrets())
}

func TestPairingMalformedPhase1ReturnsFailure(t *testing.T) {
	server, path := pairingFixture(t)
	for _, field := range []string{"clientcert", "salt"} {
		t.Run(field, func(t *testing.T) {
			requestURL, err := url.Parse(path)
			require.NoError(t, err)
			query := requestURL.Query()
			query.Set(field, hex.EncodeToString([]byte("bad")))
			requestURL.RawQuery = query.Encode()
			response := httptest.NewRecorder()

			server.router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, requestURL.String(), nil))

			var result PairingResponse
			require.NoError(t, xml.Unmarshal(response.Body.Bytes(), &result))
			require.Zero(t, result.Paired)
			require.Equal(t, http.StatusBadRequest, result.StatusCode)
			require.Empty(t, server.manager.GetPendingSecrets())
		})
	}
}

func TestPairingMissingCachedCertificateReturnsFailure(t *testing.T) {
	server, _ := pairingFixture(t)
	server.manager.PairingCache.Store("test-client@192.0.2.1", pendingPairCacheEntry{LastPhase: "SERVERCHALLENGERESP"})
	path := "/pair?uniqueid=test-client&clientpairingsecret=" + strings.Repeat("00", 272)
	response := httptest.NewRecorder()

	server.router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))

	var result PairingResponse
	require.NoError(t, xml.Unmarshal(response.Body.Bytes(), &result))
	require.Zero(t, result.Paired)
	require.Equal(t, http.StatusBadRequest, result.StatusCode)
}
