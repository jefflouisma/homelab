package packages

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBundledRollbackKeepsOriginalBytesAfterBaseChanges(t *testing.T) {
	m := newManager(t, func(context.Context) (int, error) { return 0, nil })
	source := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(source, "AppRun"), []byte("original frontend"), 0755))
	require.NoError(t, m.installer.SeedBundled(t.Context(), EmuDeck, source))
	require.NoError(t, os.WriteFile(filepath.Join(source, "AppRun"), []byte("different base image frontend"), 0755))
	require.NoError(t, m.installer.SeedBundled(t.Context(), EmuDeck, source))
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

func TestBundledShadPS4IsSeededForStateThatPredatesIt(t *testing.T) {
	root := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(root, "state.json"), []byte(`{"components":{"emudeck":{"active":"v1","previous":[]},"kytyps5":{},"ps5plus":{}}}`), 0644))
	source := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(source, "usr/bin"), 0755))
	require.NoError(t, os.WriteFile(filepath.Join(source, "usr/bin/shadps4"), []byte("image shadPS4"), 0755))
	installer := Installer{Root: root, Probe: func(context.Context, Component, string) error { return nil }}
	require.NoError(t, installer.SeedBundled(t.Context(), ShadPS4, source))
	require.FileExists(t, filepath.Join(root, string(ShadPS4), BundledShadPS4, ".verified"))
	m, err := New(root, Sources{}, installer, func(context.Context) (int, error) { return 0, nil })
	require.NoError(t, err)
	require.Equal(t, Status{Active: BundledShadPS4, Previous: []string{}}, snapshot(t, m).Components[ShadPS4])
	require.Equal(t, "v1", snapshot(t, m).Components[EmuDeck].Active)
}

func TestBundledShadPS4IsNotRestoredAfterItLeavesRetention(t *testing.T) {
	root := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(root, "state.json"), []byte(`{"components":{"shadps4":{"active":"v.0.24.0","previous":["v.0.23.0"]}}}`), 0644))
	installer := Installer{Root: root, Probe: func(context.Context, Component, string) error { return errors.New("must not probe") }}
	require.NoError(t, installer.SeedBundled(t.Context(), ShadPS4, t.TempDir()))
	require.NoDirExists(t, filepath.Join(root, string(ShadPS4)))
	require.ErrorContains(t, installer.SeedBundled(t.Context(), Kyty, t.TempDir()), "no bundled package")
}

func TestBundledRPCS3IsSeededForStateThatPredatesIt(t *testing.T) {
	root := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(root, "state.json"), []byte(`{"components":{"shadps4":{"active":"v.0.21.0","previous":[]}}}`), 0644))
	source := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(source, "usr/bin"), 0755))
	require.NoError(t, os.WriteFile(filepath.Join(source, "usr/bin/rpcs3"), []byte("image RPCS3"), 0755))
	installer := Installer{Root: root, Probe: func(context.Context, Component, string) error { return nil }}
	require.NoError(t, installer.SeedBundled(t.Context(), RPCS3, source))
	require.FileExists(t, filepath.Join(root, string(RPCS3), BundledRPCS3, "usr/bin/rpcs3"))
	require.ErrorContains(t, installer.SeedBundled(t.Context(), Eden, t.TempDir()), "no bundled package")
}
