package packages

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDownloadVerifiesChecksumBeforeExtraction(t *testing.T) {
	var archive bytes.Buffer
	gz := gzip.NewWriter(&archive)
	tw := tar.NewWriter(gz)
	data := []byte("real archive payload")
	require.NoError(t, tw.WriteHeader(&tar.Header{Name: "kyty_emulator", Mode: 0755, Size: int64(len(data))}))
	_, err := tw.Write(data)
	require.NoError(t, err)
	require.NoError(t, tw.Close())
	require.NoError(t, gz.Close())
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(archive.Bytes()) }))
	defer server.Close()
	root := t.TempDir()
	installer := Installer{Root: root, Client: server.Client(), Probe: func(_ context.Context, _ Component, dir string) error {
		_, err := os.ReadFile(filepath.Join(dir, "kyty_emulator"))
		return err
	}}
	checksum := sha256.Sum256(archive.Bytes())
	release := Release{Version: "daily", URL: server.URL, SHA256: hex.EncodeToString(checksum[:])}
	require.NoError(t, installer.Install(t.Context(), Kyty, release))
	require.FileExists(t, filepath.Join(root, string(Kyty), "daily", ".verified"))
	release.Version = "corrupt"
	release.SHA256 = strings.Repeat("0", 64)
	require.ErrorContains(t, installer.Install(t.Context(), Kyty, release), "SHA-256")
	require.NoDirExists(t, filepath.Join(root, string(Kyty), "corrupt"))
}

func TestShadPS4ProbeProvidesUserDirectoryAndChecksLaunchFlags(t *testing.T) {
	scratch := t.TempDir()
	t.Setenv("TMPDIR", scratch)
	for _, tc := range []struct {
		help, err string
	}{
		{"-g,     --game TEXT\n-f,     --fullscreen TEXT", ""},
		{"-g,     --game TEXT", "missing --fullscreen"},
	} {
		dir := t.TempDir()
		require.NoError(t, os.MkdirAll(filepath.Join(dir, "usr/bin"), 0755))
		// Like shadPS4, fail when ~/.local/share is missing.
		script := "#!/bin/sh\nmkdir \"$HOME/.local/share/shadPS4\" || exit 1\nprintf '%s\\n' '" + tc.help + "'\n"
		require.NoError(t, os.WriteFile(filepath.Join(dir, "usr/bin/shadps4"), []byte(script), 0755))
		err := Probe(t.Context(), ShadPS4, dir)
		if tc.err == "" {
			require.NoError(t, err)
		} else {
			require.ErrorContains(t, err, tc.err)
		}
		leftovers, err := os.ReadDir(scratch)
		require.NoError(t, err)
		require.Empty(t, leftovers)
	}
}

func TestSHA1OnlyReleaseIsVerifiedAndRecorded(t *testing.T) {
	payload := []byte("eden appimage")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(payload) }))
	defer server.Close()
	root := t.TempDir()
	stub := t.TempDir()
	// Stand in for extract-appimage, which unpacks the downloaded AppImage.
	require.NoError(t, os.WriteFile(filepath.Join(stub, "extract-appimage"), []byte("#!/bin/sh\nmkdir -p \"$2\" && cp \"$1\" \"$2/AppRun\"\n"), 0755))
	t.Setenv("PATH", stub+string(os.PathListSeparator)+os.Getenv("PATH"))
	installer := Installer{Root: root, Client: server.Client(), Probe: func(context.Context, Component, string) error { return nil }}
	digest := sha1.Sum(payload)
	release := Release{Version: "v0.2.1", URL: server.URL, SHA1: hex.EncodeToString(digest[:])}
	require.NoError(t, installer.Install(t.Context(), Eden, release))
	recorded, err := os.ReadFile(filepath.Join(root, string(Eden), "v0.2.1", ".verified"))
	require.NoError(t, err)
	require.Equal(t, "sha1:"+release.SHA1, string(recorded))
	// A retained package is accepted again only for the same upstream digest.
	require.NoError(t, installer.Install(t.Context(), Eden, release))
	release.SHA1 = strings.Repeat("0", 40)
	require.ErrorContains(t, installer.Install(t.Context(), Eden, release), "differs")
	release.Version = "v0.2.2"
	require.ErrorContains(t, installer.Install(t.Context(), Eden, release), "SHA-1 verification failed")
	require.ErrorContains(t, installer.Install(t.Context(), Eden, Release{Version: "v0.2.3", URL: server.URL}), "invalid release checksum")
}

func TestSwitchProbesCheckLaunchFlags(t *testing.T) {
	usage := "Usage: eden-cli [options] <filename>\n-f, --fullscreen      Start in fullscreen mode\n-g, --game            File path of the game to load"
	for _, tc := range []struct {
		name      string
		component Component
		files     map[string]string
		err       string
	}{
		{"eden", Eden, map[string]string{"AppRun": "[ \"$1 $2\" = 'eden-cli --help' ] && echo '" + usage + "'", "bin/eden": ""}, ""},
		{"eden without Qt frontend", Eden, map[string]string{"AppRun": "echo '" + usage + "'"}, "Qt frontend"},
		// Eglantine prints its usage, then fails because no game was given.
		{"eglantine", Eglantine, map[string]string{"usr/bin/eden-cli": "echo '" + usage + "'; echo 'Failed to load ROM: No ROM specified'; exit 1"}, ""},
		{"eglantine crash", Eglantine, map[string]string{"usr/bin/eden-cli": "exit 1"}, "executable probe"},
		{"rpcs3", RPCS3, map[string]string{"AppRun": "[ \"$1 $2\" = '--headless --help' ] && echo '--no-gui --fullscreen --installfw <path>'"}, ""},
		{"rpcs3 without firmware installer", RPCS3, map[string]string{"AppRun": "echo '--no-gui --fullscreen'"}, "missing --installfw"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			for name, body := range tc.files {
				require.NoError(t, os.MkdirAll(filepath.Dir(filepath.Join(dir, name)), 0755))
				require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0755))
			}
			err := Probe(t.Context(), tc.component, dir)
			if tc.err == "" {
				require.NoError(t, err)
			} else {
				require.ErrorContains(t, err, tc.err)
			}
		})
	}
}
