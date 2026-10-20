package packages

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBundledRollbackKeepsOriginalBytesAfterBaseChanges(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	source := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(source, "AppRun"), []byte("original frontend"), 0755))
	require.NoError(t, m.installer.SeedBundled(t.Context(), source))
	require.NoError(t, os.WriteFile(filepath.Join(source, "AppRun"), []byte("different base image frontend"), 0755))
	require.NoError(t, m.installer.SeedBundled(t.Context(), source))
	saved, err := os.ReadFile(filepath.Join(m.root, string(EmuDeck), BundledFrontend, "AppRun"))
	require.NoError(t, err)
	require.Equal(t, "original frontend", string(saved))
}

func TestExistingBundledSelectionMigratesToPreservedPackage(t *testing.T) {
	root := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(root, "state.json"), []byte(`{"components":{"emudeck":{"active":"bundled-3.5.0","previous":["bundled-3.5.0"],"queued":"bundled-3.5.0"},"kytyps5":{}}}`), 0644))
	m, err := New(root, Sources{}, Installer{}, func(context.Context) (int, error) { return 0, nil })
	require.NoError(t, err)
	s := snapshot(t, m).Components[EmuDeck]
	require.Equal(t, BundledFrontend, s.Active)
	require.Equal(t, BundledFrontend, s.Queued)
	require.Equal(t, []string{BundledFrontend}, s.Previous)
}
