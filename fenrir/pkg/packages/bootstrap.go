package packages

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

const (
	BundledFrontend = "bundled-3.5.0-8cfe7a2"
	BundledShadPS4  = "bundled-0.20.0-8cfe7a2"
)

// bundled describes a package copied from the pinned bootstrap image so rollback keeps its original bytes.
type bundled struct {
	version    string
	legacy     string
	executable string
}

var bundledPackages = map[Component]bundled{
	EmuDeck: {version: BundledFrontend, legacy: "bundled-3.5.0", executable: "AppRun"},
	ShadPS4: {version: BundledShadPS4, executable: "usr/bin/shadps4"},
}

func (i Installer) SeedBundled(ctx context.Context, component Component, source string) (err error) {
	b, ok := bundledPackages[component]
	if !ok {
		return fmt.Errorf("%s has no bundled package", component)
	}
	stateData, err := os.ReadFile(filepath.Join(i.Root, "state.json"))
	if err == nil {
		var state State
		if err := json.Unmarshal(stateData, &state); err != nil {
			return fmt.Errorf("read bootstrap state: %w", err)
		}
		// A component missing from stored state starts on its bundled package.
		if s, ok := state.Components[component]; ok {
			versions := append(slices.Clone(s.Previous), s.Active, s.Queued)
			if !slices.Contains(versions, b.version) && (b.legacy == "" || !slices.Contains(versions, b.legacy)) {
				return nil
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("open bootstrap state: %w", err)
	}
	parent := filepath.Join(i.Root, string(component))
	final := filepath.Join(parent, b.version)
	if _, err := os.Stat(filepath.Join(final, ".verified")); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect bundled package: %w", err)
	}
	if err := os.MkdirAll(parent, 0755); err != nil {
		return fmt.Errorf("create bootstrap directory: %w", err)
	}
	tmp, err := os.MkdirTemp(parent, ".stage-")
	if err != nil {
		return fmt.Errorf("create bootstrap staging: %w", err)
	}
	defer func() { err = errors.Join(err, os.RemoveAll(tmp)) }()
	content := filepath.Join(tmp, "content")
	if err := run(ctx, "cp", "-a", source, content); err != nil {
		return err
	}
	if err := i.Probe(ctx, component, content); err != nil {
		return fmt.Errorf("verify bundled %s: %w", component, err)
	}
	app, err := os.ReadFile(filepath.Join(content, b.executable))
	if err != nil {
		return fmt.Errorf("read bundled executable: %w", err)
	}
	digest := sha256.Sum256(app)
	if err := os.WriteFile(filepath.Join(content, ".verified"), []byte(hex.EncodeToString(digest[:])), 0644); err != nil {
		return fmt.Errorf("record bundled executable: %w", err)
	}
	if err := os.Rename(content, final); err != nil {
		return fmt.Errorf("preserve bundled %s: %w", component, err)
	}
	return nil
}
