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

const BundledFrontend = "bundled-3.5.0-8cfe7a2"

func (i Installer) SeedBundled(ctx context.Context, source string) (err error) {
	stateData, err := os.ReadFile(filepath.Join(i.Root, "state.json"))
	if err == nil {
		var state State
		if err := json.Unmarshal(stateData, &state); err != nil {
			return fmt.Errorf("read bootstrap state: %w", err)
		}
		s := state.Components[EmuDeck]
		versions := append(slices.Clone(s.Previous), s.Active, s.Queued)
		if !slices.Contains(versions, BundledFrontend) && !slices.Contains(versions, "bundled-3.5.0") {
			return nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("open bootstrap state: %w", err)
	}
	parent := filepath.Join(i.Root, string(EmuDeck))
	final := filepath.Join(parent, BundledFrontend)
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
	if err := i.Probe(ctx, EmuDeck, content); err != nil {
		return fmt.Errorf("verify bundled frontend: %w", err)
	}
	app, err := os.ReadFile(filepath.Join(content, "AppRun"))
	if err != nil {
		return fmt.Errorf("read bundled executable: %w", err)
	}
	digest := sha256.Sum256(app)
	if err := os.WriteFile(filepath.Join(content, ".verified"), []byte(hex.EncodeToString(digest[:])), 0644); err != nil {
		return fmt.Errorf("record bundled executable: %w", err)
	}
	if err := os.Rename(content, final); err != nil {
		return fmt.Errorf("preserve bundled frontend: %w", err)
	}
	return nil
}
