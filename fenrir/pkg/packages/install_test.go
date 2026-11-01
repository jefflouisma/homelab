package packages

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
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
