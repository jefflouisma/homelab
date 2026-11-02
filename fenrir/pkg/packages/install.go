package packages

import (
	"context"
	"crypto/sha1"
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
	checksum, err := release.checksum()
	if err != nil {
		return err
	}
	parent := filepath.Join(i.Root, string(component))
	if err := os.MkdirAll(parent, 0755); err != nil {
		return fmt.Errorf("create package directory: %w", err)
	}
	final := filepath.Join(parent, release.Version)
	if recorded, err := os.ReadFile(filepath.Join(final, ".verified")); err == nil {
		if string(recorded) != checksum {
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
	case Kyty, PS5Plus:
		if err := os.Mkdir(content, 0755); err != nil {
			return fmt.Errorf("create extraction directory: %w", err)
		}
		if err := run(ctx, "tar", "-xzf", archive, "--no-same-owner", "-C", content); err != nil {
			return err
		}
	case EmuDeck, RPCS3, Eden, Eglantine:
		if err := run(ctx, "extract-appimage", archive, content); err != nil {
			return err
		}
	case ShadPS4:
		unpacked := filepath.Join(tmp, "zip")
		if err := run(ctx, "unzip", "-q", archive, "-d", unpacked); err != nil {
			return err
		}
		if err := run(ctx, "extract-appimage", filepath.Join(unpacked, "Shadps4-sdl.AppImage"), content); err != nil {
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
	if err := os.WriteFile(filepath.Join(content, ".verified"), []byte(checksum), 0644); err != nil {
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
	sum256, sum1 := sha256.New(), sha1.New()
	n, err := io.Copy(io.MultiWriter(file, sum256, sum1), io.LimitReader(resp.Body, (1<<30)+1))
	if err != nil {
		return fmt.Errorf("save download: %w", err)
	}
	if n > 1<<30 {
		return fmt.Errorf("release exceeds 1 GiB download limit")
	}
	if release.SHA256 != "" {
		if hex.EncodeToString(sum256.Sum(nil)) != release.SHA256 {
			return fmt.Errorf("SHA-256 verification failed")
		}
	} else if hex.EncodeToString(sum1.Sum(nil)) != release.SHA1 {
		return fmt.Errorf("SHA-1 verification failed")
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

func Probe(ctx context.Context, component Component, directory string) (err error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	// Emulators create their user directories even for --help, and some fail without parents.
	home, err := os.MkdirTemp("", "package-probe-")
	if err != nil {
		return fmt.Errorf("create probe home: %w", err)
	}
	defer func() { err = errors.Join(err, os.RemoveAll(home)) }()
	for _, path := range []string{".local/share", ".config"} {
		if err := os.MkdirAll(filepath.Join(home, path), 0755); err != nil {
			return fmt.Errorf("create probe home: %w", err)
		}
	}
	var cmd *exec.Cmd
	libraries := filepath.Join(directory, "usr/lib")
	switch component {
	case Kyty, PS5Plus:
		cmd = exec.CommandContext(ctx, filepath.Join(directory, "kyty_emulator"), "--help")
		libraries = filepath.Join(directory, "lib")
	case EmuDeck:
		cmd = exec.CommandContext(ctx, "/lib64/ld-linux-x86-64.so.2", "--library-path", filepath.Join(directory, "usr/lib"), filepath.Join(directory, "AppRun"), "--help")
	case ShadPS4:
		cmd = exec.CommandContext(ctx, filepath.Join(directory, "usr/bin/shadps4"), "--help")
	case RPCS3:
		// Headless mode needs no display; the AppImage bundles only the Wayland and X11 Qt platforms.
		cmd = exec.CommandContext(ctx, filepath.Join(directory, "AppRun"), "--headless", "--help")
	case Eden:
		// The Qt frontend opens its window even for --help; eden-cli shares its arguments and binary.
		if _, err := os.Stat(filepath.Join(directory, "bin/eden")); err != nil {
			return fmt.Errorf("Eden Qt frontend: %w", err)
		}
		cmd = exec.CommandContext(ctx, filepath.Join(directory, "AppRun"), "eden-cli", "--help")
	case Eglantine:
		cmd = exec.CommandContext(ctx, filepath.Join(directory, "usr/bin/eden-cli"), "--help")
	default:
		return fmt.Errorf("unsupported component %q", component)
	}
	cmd.Dir = directory
	cmd.Env = append(os.Environ(), "QT_QPA_PLATFORM=offscreen", "SDL_VIDEODRIVER=dummy", "LD_LIBRARY_PATH="+libraries, "HOME="+home)
	output, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	// Eglantine's eden-cli prints its usage, then exits 1 because no game was given.
	if component == Eglantine && errors.As(err, &exit) && strings.Contains(string(output), "Usage:") {
		err = nil
	}
	if err != nil {
		return fmt.Errorf("executable probe: %w: %.2000s", err, output)
	}
	contract := map[Component][]string{
		Kyty:    {"--game", "--fullscreen", "--screen-width", "--screen-height"},
		PS5Plus: {"--game", "--fullscreen", "--screen-width", "--screen-height"},
		// ES-DE launches PS4 games with -g <eboot.bin> -f true.
		ShadPS4: {"--game", "--fullscreen"},
		// ES-DE boots PS3 games with --no-gui --fullscreen; prepare-ps3-firmware uses --installfw.
		RPCS3:     {"--no-gui", "--fullscreen", "--installfw"},
		Eden:      {"--game", "--fullscreen"},
		Eglantine: {"--game", "--fullscreen"},
	}
	for _, flag := range contract[component] {
		if !strings.Contains(string(output), flag) {
			return fmt.Errorf("%s CLI contract is missing %s", component, flag)
		}
	}
	return nil
}
