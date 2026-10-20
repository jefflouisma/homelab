package packages

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestOfficialReleaseResolutionSelectsLinuxAndMatchingChecksum(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/KytyPS5/KytyPS5/releases/latest":
			json.NewEncoder(w).Encode(map[string]any{"tag_name": "daily-123", "assets": []map[string]string{{"name": "daily-123-Windows-x64.zip", "digest": "sha256:" + string(make([]byte, 64))}, {"name": "daily-123-Linux-x86_64.tar.gz", "browser_download_url": "https://github.com/linux", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}})
		case "/projects/18817634/releases/permalink/latest":
			w.Write([]byte(`{"tag_name":"v4.0.0","assets":{"links":[{"name":"ES-DE_x64_SteamDeck.AppImage","url":"https://wrong"},{"name":"ES-DE_x64.AppImage","url":"https://gitlab.com/files/999/download"}]}}`))
		case "/projects/18817634/packages":
			w.Write([]byte(`[{"id":42,"version":"4.0.0"}]`))
		case "/projects/18817634/packages/42/package_files":
			w.Write([]byte(`[{"id":999,"file_name":"ES-DE_x64.AppImage","file_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	sources := Sources{Client: server.Client(), GitHub: server.URL, GitLab: server.URL}
	kyty, err := sources.Latest(t.Context(), Kyty)
	require.NoError(t, err)
	require.Equal(t, "https://github.com/linux", kyty.URL)
	esde, err := sources.Latest(t.Context(), EmuDeck)
	require.NoError(t, err)
	require.Equal(t, "v4.0.0", esde.Version)
	require.Equal(t, "https://gitlab.com/files/999/download", esde.URL)
}

func TestIncompleteReleaseIsNotStaged(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"tag_name":"daily","assets":[]}`)) }))
	defer server.Close()
	s := Sources{Client: server.Client(), GitHub: server.URL}
	_, err := s.Latest(t.Context(), Kyty)
	require.Error(t, err)
}
