package packages

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const DefaultRoot = "/Volumes/4TB_Drive/tmp/fenrir-packages"

type Installer struct {
	Root   string
	Client *http.Client
	Probe  func(context.Context, Component, string) error
}

func (i Installer) Install(ctx context.Context, component Component, release Release) (err error) {
	if !versionPattern.MatchString(release.Version) {
		return fmt.Errorf("invalid release version")
	}
	if _, err := hex.DecodeString(release.SHA256); err != nil || len(release.SHA256) != 64 {
		return fmt.Errorf("invalid release checksum")
	}
	parent := filepath.Join(i.Root, string(component))
	if err := os.MkdirAll(parent, 0755); err != nil {
		return fmt.Errorf("create package directory: %w", err)
	}
	final := filepath.Join(parent, release.Version)
	if checksum, err := os.ReadFile(filepath.Join(final, ".verified")); err == nil {
		if string(checksum) != release.SHA256 {
			return fmt.Errorf("retained package checksum differs from the upstream release")
		}
		return i.Probe(ctx, component, final)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect package: %w", err)
	}
	tmp, err := os.MkdirTemp(parent, ".stage-")
	if err != nil {
		return fmt.Errorf("create staging directory: %w", err)
	}
	defer func() { err = errors.Join(err, os.RemoveAll(tmp)) }()
	archive := filepath.Join(tmp, "download")
	if err := i.download(ctx, release, archive); err != nil {
		return err
	}
	content := filepath.Join(tmp, "content")
	switch component {
	case Kyty:
		if err := os.Mkdir(content, 0755); err != nil {
			return fmt.Errorf("create extraction directory: %w", err)
		}
		if err := run(ctx, "tar", "-xzf", archive, "--no-same-owner", "-C", content); err != nil {
			return err
		}
	case EmuDeck:
		if err := run(ctx, "extract-appimage", archive, content); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unsupported component %q", component)
	}
	if err := run(ctx, "chmod", "-R", "a+rX", content); err != nil {
		return err
	}
	if err := i.Probe(ctx, component, content); err != nil {
		return fmt.Errorf("package launch check failed: %w", err)
	}
	if err := os.WriteFile(filepath.Join(content, ".verified"), []byte(release.SHA256), 0644); err != nil {
		return fmt.Errorf("record checksum: %w", err)
	}
	if err := os.Rename(content, final); err != nil {
		return fmt.Errorf("publish package: %w", err)
	}
	return nil
}

func (i Installer) download(ctx context.Context, release Release, path string) (err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, release.URL, nil)
	if err != nil {
		return fmt.Errorf("download request: %w", err)
	}
	resp, err := i.Client.Do(req)
	if err != nil {
		return fmt.Errorf("download release: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download returned HTTP %d", resp.StatusCode)
	}
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create download: %w", err)
	}
	defer func() { err = errors.Join(err, file.Close()) }()
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(file, hash), io.LimitReader(resp.Body, (1<<30)+1))
	if err != nil {
		return fmt.Errorf("save download: %w", err)
	}
	if n > 1<<30 {
		return fmt.Errorf("release exceeds 1 GiB download limit")
	}
	if hex.EncodeToString(hash.Sum(nil)) != release.SHA256 {
		return fmt.Errorf("SHA-256 verification failed")
	}
	return nil
}

func run(ctx context.Context, name string, args ...string) error {
	output, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s failed: %w: %.2000s", name, err, output)
	}
	return nil
}

func Probe(ctx context.Context, component Component, directory string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var cmd *exec.Cmd
	switch component {
	case Kyty:
		cmd = exec.CommandContext(ctx, filepath.Join(directory, "kyty_emulator"), "--help")
	case EmuDeck:
		cmd = exec.CommandContext(ctx, "/lib64/ld-linux-x86-64.so.2", "--library-path", filepath.Join(directory, "usr/lib"), filepath.Join(directory, "AppRun"), "--help")
	default:
		return fmt.Errorf("unsupported component %q", component)
	}
	cmd.Dir = directory
	cmd.Env = append(os.Environ(), "QT_QPA_PLATFORM=offscreen", "SDL_VIDEODRIVER=dummy", "LD_LIBRARY_PATH="+filepath.Join(directory, "lib"), "HOME="+os.TempDir())
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("executable probe: %w: %.2000s", err, output)
	}
	if component == Kyty {
		for _, flag := range []string{"--game", "--fullscreen", "--screen-width", "--screen-height"} {
			if !strings.Contains(string(output), flag) {
				return fmt.Errorf("Kyty CLI contract is missing %s", flag)
			}
		}
	}
	return nil
}
