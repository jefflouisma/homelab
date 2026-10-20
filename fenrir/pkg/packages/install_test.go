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
