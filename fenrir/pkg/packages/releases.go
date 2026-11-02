package packages

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

type Component string

const (
	EmuDeck Component = "emudeck"
	Kyty    Component = "kytyps5"
	PS5Plus Component = "ps5plus"
	ShadPS4 Component = "shadps4"
	RPCS3   Component = "rpcs3"
	// Eden emulates the Nintendo Switch; Eglantine, an Eden fork, the Nintendo Switch 2.
	Eden      Component = "eden"
	Eglantine Component = "eglantine"
)

// Components lists every managed package in check and activation order.
var Components = []Component{EmuDeck, Kyty, PS5Plus, ShadPS4, RPCS3, Eden, Eglantine}

// gitHubRepositories publish one Linux asset per latest release, selected by gitHubAsset.
var gitHubRepositories = map[Component]string{Kyty: "KytyPS5/KytyPS5", PS5Plus: "jefflouisma/PS5Plus", ShadPS4: "shadps4-emu/shadPS4", RPCS3: "RPCS3/rpcs3-binaries-linux"}

// RPCS3 tags builds by commit; its AppImage name carries the readable version.
var rpcs3Asset = regexp.MustCompile(`^rpcs3-(v[0-9.]+-[0-9]+-[0-9a-f]+)_linux64\.AppImage$`)

// gitHubAsset reports the version an asset provides when it is the component's Linux build.
func gitHubAsset(component Component, tag, name string) (string, bool) {
	switch component {
	case ShadPS4:
		// Tags look like v.0.21.0; the zip holds the SDL AppImage.
		return tag, name == "shadps4-linux-sdl-"+strings.TrimPrefix(tag, "v.")+".zip"
	case RPCS3:
		if match := rpcs3Asset.FindStringSubmatch(name); match != nil {
			return match[1], true
		}
		return "", false
	default:
		// KytyPS5 and its PS5Plus fork share a tarball layout.
		return tag, name == tag+"-Linux-x86_64.tar.gz"
	}
}

const (
	eglantineRepository = "Djihads80/Eglantine"
	// Eglantine also publishes nx2-experimental and manual builds; only its default branch is followed.
	eglantineBranch = "nx2"
)

type Release struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
	// SHA1 is used only for sources that publish no SHA-256 digest.
	SHA1 string `json:"sha1,omitempty"`
}

// checksum is the upstream digest recorded in .verified: SHA-256 hex, or sha1:<hex>.
func (r Release) checksum() (string, error) {
	if r.SHA256 != "" {
		if digest, err := hex.DecodeString(r.SHA256); err != nil || len(digest) != sha256.Size {
			return "", fmt.Errorf("invalid release checksum")
		}
		return r.SHA256, nil
	}
	if digest, err := hex.DecodeString(r.SHA1); err != nil || len(digest) != sha1.Size {
		return "", fmt.Errorf("invalid release checksum")
	}
	return "sha1:" + r.SHA1, nil
}

var versionPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$`)

func ParseComponent(value string) (Component, error) {
	switch Component(value) {
	case EmuDeck, Kyty, PS5Plus, ShadPS4, RPCS3, Eden, Eglantine:
		return Component(value), nil
	default:
		return "", fmt.Errorf("unknown component %q", value)
	}
}

type Sources struct {
	Client *http.Client
	GitHub string
	GitLab string
	// Eden is the Forgejo API hosting Eden's releases.
	Eden string
}

func (s Sources) fetch(ctx context.Context, address string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, fmt.Errorf("release request: %w", err)
	}
	req.Header.Set("User-Agent", "Fenrir-package-manager")
	resp, err := s.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch release: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("release API returned HTTP %d", resp.StatusCode)
	}
	return resp, nil
}

func (s Sources) get(ctx context.Context, address string, target any) error {
	resp, err := s.fetch(ctx, address)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 4<<20)).Decode(target); err != nil {
		return fmt.Errorf("decode release: %w", err)
	}
	return nil
}

func (s Sources) latestGitHub(ctx context.Context, component Component) (Release, error) {
	repository := gitHubRepositories[component]
	var release struct {
		Tag    string `json:"tag_name"`
		Draft  bool   `json:"draft"`
		Assets []struct {
			Name   string `json:"name"`
			URL    string `json:"browser_download_url"`
			Digest string `json:"digest"`
		} `json:"assets"`
	}
	if err := s.get(ctx, s.GitHub+"/repos/"+repository+"/releases/latest", &release); err != nil {
		return Release{}, err
	}
	if release.Draft {
		return Release{}, fmt.Errorf("latest %s release is a draft", repository)
	}
	for _, asset := range release.Assets {
		if version, ok := gitHubAsset(component, release.Tag, asset.Name); ok {
			return Release{Version: version, URL: asset.URL, SHA256: strings.TrimPrefix(asset.Digest, "sha256:")}, nil
		}
	}
	return Release{}, nil
}

// latestEglantine selects the newest pre-release built from eglantineBranch; Eglantine publishes no stable releases.
func (s Sources) latestEglantine(ctx context.Context) (Release, error) {
	type build struct {
		Tag       string    `json:"tag_name"`
		Draft     bool      `json:"draft"`
		Target    string    `json:"target_commitish"`
		Published time.Time `json:"published_at"`
		Assets    []struct {
			Name   string `json:"name"`
			URL    string `json:"browser_download_url"`
			Digest string `json:"digest"`
		} `json:"assets"`
	}
	var builds []build
	if err := s.get(ctx, s.GitHub+"/repos/"+eglantineRepository+"/releases?per_page=50", &builds); err != nil {
		return Release{}, err
	}
	var commits []struct {
		SHA string `json:"sha"`
	}
	if err := s.get(ctx, s.GitHub+"/repos/"+eglantineRepository+"/commits?sha="+eglantineBranch+"&per_page=100", &commits); err != nil {
		return Release{}, err
	}
	onBranch := map[string]bool{}
	for _, commit := range commits {
		onBranch[commit.SHA] = true
	}
	slices.SortFunc(builds, func(a, b build) int { return b.Published.Compare(a.Published) })
	for _, b := range builds {
		if b.Draft || !onBranch[b.Target] {
			continue
		}
		for _, asset := range b.Assets {
			// PGO builds are the same programs with profile-guided optimization.
			if asset.Name == "eglantine-"+b.Target+"-linux-x86_64-pgo.AppImage" {
				return Release{Version: b.Tag, URL: asset.URL, SHA256: strings.TrimPrefix(asset.Digest, "sha256:")}, nil
			}
		}
	}
	return Release{}, fmt.Errorf("no recent Eglantine %s build has a Linux x86_64 AppImage", eglantineBranch)
}

func (s Sources) latestEden(ctx context.Context) (Release, error) {
	var release struct {
		Tag    string `json:"tag_name"`
		Assets []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	// Forgejo's latest release excludes drafts and pre-releases.
	if err := s.get(ctx, s.Eden+"/repos/eden-emu/eden/releases/latest", &release); err != nil {
		return Release{}, err
	}
	name := "Eden-Linux-" + release.Tag + "-amd64-clang-pgo.AppImage"
	var download, index string
	for _, asset := range release.Assets {
		switch asset.Name {
		case name:
			download = asset.URL
		case "Eden-Linux-amd64-clang-pgo.AppImage.zsync":
			index = asset.URL
		}
	}
	if download == "" || index == "" {
		return Release{}, fmt.Errorf("Eden release has no Linux amd64 AppImage")
	}
	// Eden publishes no SHA-256 digest; the zsync index it builds with each AppImage records its SHA-1.
	resp, err := s.fetch(ctx, index)
	if err != nil {
		return Release{}, err
	}
	defer resp.Body.Close()
	header, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return Release{}, fmt.Errorf("read Eden zsync index: %w", err)
	}
	fields := map[string]string{}
	lines := bufio.NewScanner(bytes.NewReader(header))
	for lines.Scan() && lines.Text() != "" {
		if key, value, ok := strings.Cut(lines.Text(), ": "); ok {
			fields[key] = value
		}
	}
	if fields["Filename"] != name {
		return Release{}, fmt.Errorf("Eden zsync index describes %q", fields["Filename"])
	}
	return Release{Version: release.Tag, URL: download, SHA1: fields["SHA-1"]}, nil
}

func (s Sources) Latest(ctx context.Context, component Component) (Release, error) {
	var result Release
	switch component {
	case Kyty, PS5Plus, ShadPS4, RPCS3:
		var err error
		if result, err = s.latestGitHub(ctx, component); err != nil {
			return result, err
		}
	case Eglantine:
		var err error
		if result, err = s.latestEglantine(ctx); err != nil {
			return result, err
		}
	case Eden:
		var err error
		if result, err = s.latestEden(ctx); err != nil {
			return result, err
		}
	case EmuDeck:
		var release struct {
			Tag    string `json:"tag_name"`
			Assets struct {
				Links []struct {
					Name string `json:"name"`
					URL  string `json:"url"`
				} `json:"links"`
			} `json:"assets"`
		}
		if err := s.get(ctx, s.GitLab+"/projects/18817634/releases/permalink/latest", &release); err != nil {
			return result, err
		}
		var download string
		for _, link := range release.Assets.Links {
			if link.Name == "ES-DE_x64.AppImage" {
				download = link.URL
			}
		}
		if download == "" {
			return result, fmt.Errorf("ES-DE release has no x64 AppImage")
		}
		var entries []struct {
			ID      int    `json:"id"`
			Version string `json:"version"`
		}
		endpoint := s.GitLab + "/projects/18817634/packages?package_name=ES-DE_Stable&package_version=" + url.QueryEscape(strings.TrimPrefix(release.Tag, "v")) + "&per_page=100"
		if err := s.get(ctx, endpoint, &entries); err != nil {
			return result, err
		}
		for _, entry := range entries {
			if entry.Version != strings.TrimPrefix(release.Tag, "v") {
				continue
			}
			var files []struct {
				ID   int    `json:"id"`
				Name string `json:"file_name"`
				SHA  string `json:"file_sha256"`
			}
			if err := s.get(ctx, fmt.Sprintf("%s/projects/18817634/packages/%d/package_files?per_page=100", s.GitLab, entry.ID), &files); err != nil {
				return result, err
			}
			for _, file := range files {
				if file.Name == "ES-DE_x64.AppImage" && strings.Contains(download, "/"+strconv.Itoa(file.ID)+"/") {
					result = Release{Version: release.Tag, URL: download, SHA256: file.SHA}
				}
			}
		}
	default:
		return result, fmt.Errorf("unknown component %q", component)
	}
	if _, err := result.checksum(); !versionPattern.MatchString(result.Version) || err != nil || result.URL == "" {
		return Release{}, fmt.Errorf("release is incomplete or has no published digest")
	}
	return result, nil
}
