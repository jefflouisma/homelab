package packages

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestOfficialReleaseResolutionSelectsLinuxAndMatchingChecksum(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/KytyPS5/KytyPS5/releases/latest":
			json.NewEncoder(w).Encode(map[string]any{"tag_name": "daily-123", "assets": []map[string]string{{"name": "daily-123-Windows-x64.zip", "digest": "sha256:" + string(make([]byte, 64))}, {"name": "daily-123-Linux-x86_64.tar.gz", "browser_download_url": "https://github.com/linux", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}})
		case "/repos/jefflouisma/PS5Plus/releases/latest":
			json.NewEncoder(w).Encode(map[string]any{"tag_name": "PS5Plus-1", "assets": []map[string]string{{"name": "PS5Plus-1-Linux-x86_64.tar.gz", "browser_download_url": "https://github.com/ps5plus", "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}})
		case "/repos/shadps4-emu/shadPS4/releases/latest":
			json.NewEncoder(w).Encode(map[string]any{"tag_name": "v.0.21.0", "assets": []map[string]string{{"name": "shadps4-macos-sdl-0.21.0.zip", "browser_download_url": "https://github.com/macos", "digest": "sha256:" + strings.Repeat("e", 64)}, {"name": "shadps4-linux-sdl-0.21.0.zip", "browser_download_url": "https://github.com/shadps4", "digest": "sha256:" + strings.Repeat("d", 64)}}})
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
	ps5plus, err := sources.Latest(t.Context(), PS5Plus)
	require.NoError(t, err)
	require.Equal(t, Release{Version: "PS5Plus-1", URL: "https://github.com/ps5plus", SHA256: strings.Repeat("c", 64)}, ps5plus)
	shadps4, err := sources.Latest(t.Context(), ShadPS4)
	require.NoError(t, err)
	require.Equal(t, Release{Version: "v.0.21.0", URL: "https://github.com/shadps4", SHA256: strings.Repeat("d", 64)}, shadps4)
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

func TestRPCS3VersionComesFromItsAppImageName(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/repos/RPCS3/rpcs3-binaries-linux/releases/latest", r.URL.Path)
		json.NewEncoder(w).Encode(map[string]any{"tag_name": "build-" + strings.Repeat("f", 40), "assets": []map[string]string{
			{"name": "rpcs3-v0.0.44-20400-1b336f41_linux64.AppImage.sig", "browser_download_url": "https://github.com/sig"},
			{"name": "rpcs3-v0.0.44-20400-1b336f41_linux64.AppImage", "browser_download_url": "https://github.com/rpcs3", "digest": "sha256:" + strings.Repeat("a", 64)},
		}})
	}))
	defer server.Close()
	release, err := Sources{Client: server.Client(), GitHub: server.URL}.Latest(t.Context(), RPCS3)
	require.NoError(t, err)
	require.Equal(t, Release{Version: "v0.0.44-20400-1b336f41", URL: "https://github.com/rpcs3", SHA256: strings.Repeat("a", 64)}, release)
}

func TestEglantineFollowsNewestBuildOfItsDefaultBranch(t *testing.T) {
	onBranch, experimental := strings.Repeat("1", 40), strings.Repeat("2", 40)
	build := func(tag, target, published string) map[string]any {
		return map[string]any{"tag_name": tag, "target_commitish": target, "published_at": published, "prerelease": true, "assets": []map[string]string{
			{"name": "eglantine-" + target + "-linux-x86_64.AppImage", "browser_download_url": "https://github.com/standard-" + tag, "digest": "sha256:" + strings.Repeat("b", 64)},
			{"name": "eglantine-" + target + "-linux-x86_64-pgo.AppImage", "browser_download_url": "https://github.com/" + tag, "digest": "sha256:" + strings.Repeat("c", 64)},
		}}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/Djihads80/Eglantine/releases":
			// GitHub lists releases out of publication order.
			json.NewEncoder(w).Encode([]map[string]any{
				build("build-90", onBranch, "2026-11-01T10:00:00Z"),
				build("build-116", experimental, "2026-11-02T00:29:46Z"),
				build("build-110", onBranch, "2026-11-01T23:04:38Z"),
			})
		case "/repos/Djihads80/Eglantine/commits":
			require.Equal(t, "nx2", r.URL.Query().Get("sha"))
			json.NewEncoder(w).Encode([]map[string]string{{"sha": onBranch}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	release, err := Sources{Client: server.Client(), GitHub: server.URL}.Latest(t.Context(), Eglantine)
	require.NoError(t, err)
	require.Equal(t, Release{Version: "build-110", URL: "https://github.com/build-110", SHA256: strings.Repeat("c", 64)}, release)
}

func TestEdenIsVerifiedWithTheSHA1FromItsZsyncIndex(t *testing.T) {
	filename := "Eden-Linux-v0.2.1-amd64-clang-pgo.AppImage"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/eden-emu/eden/releases/latest":
			json.NewEncoder(w).Encode(map[string]any{"tag_name": "v0.2.1", "assets": []map[string]string{
				{"name": "Eden-Linux-v0.2.1-amd64-gcc-standard.AppImage", "browser_download_url": "https://stable/gcc"},
				{"name": filename, "browser_download_url": "https://stable/pgo"},
				{"name": "Eden-Linux-amd64-clang-pgo.AppImage.zsync", "browser_download_url": "http://" + r.Host + "/index.zsync"},
			}})
		case "/index.zsync":
			w.Write([]byte("zsync: 0.6.2\nFilename: " + filename + "\nSHA-1: " + strings.Repeat("d", 40) + "\n\n\x00\xffblock checksums"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	release, err := Sources{Client: server.Client(), Eden: server.URL}.Latest(t.Context(), Eden)
	require.NoError(t, err)
	require.Equal(t, Release{Version: "v0.2.1", URL: "https://stable/pgo", SHA1: strings.Repeat("d", 40)}, release)
}
