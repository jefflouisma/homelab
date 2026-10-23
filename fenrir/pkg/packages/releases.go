package packages

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

type Component string

const (
	EmuDeck Component = "emudeck"
	Kyty    Component = "kytyps5"
	PS5Plus Component = "ps5plus"
)

// Components lists every managed package in check and activation order.
var Components = []Component{EmuDeck, Kyty, PS5Plus}

// gitHubRepositories publish Linux tarballs that share the KytyPS5 package layout.
var gitHubRepositories = map[Component]string{Kyty: "KytyPS5/KytyPS5", PS5Plus: "jefflouisma/PS5Plus"}

type Release struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
}

var versionPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$`)

func ParseComponent(value string) (Component, error) {
	switch Component(value) {
	case EmuDeck, Kyty, PS5Plus:
		return Component(value), nil
	default:
		return "", fmt.Errorf("unknown component %q", value)
	}
}

type Sources struct {
	Client *http.Client
	GitHub string
	GitLab string
}

func (s Sources) get(ctx context.Context, address string, target any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return fmt.Errorf("release request: %w", err)
	}
	req.Header.Set("User-Agent", "Fenrir-package-manager")
	resp, err := s.Client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch release: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("release API returned HTTP %d", resp.StatusCode)
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 4<<20)).Decode(target); err != nil {
		return fmt.Errorf("decode release: %w", err)
	}
	return nil
}

func (s Sources) latestGitHub(ctx context.Context, repository string) (Release, error) {
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
		if asset.Name == release.Tag+"-Linux-x86_64.tar.gz" {
			return Release{Version: release.Tag, URL: asset.URL, SHA256: strings.TrimPrefix(asset.Digest, "sha256:")}, nil
		}
	}
	return Release{}, nil
}

func (s Sources) Latest(ctx context.Context, component Component) (Release, error) {
	var result Release
	switch component {
	case Kyty, PS5Plus:
		var err error
		if result, err = s.latestGitHub(ctx, gitHubRepositories[component]); err != nil {
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
	if !versionPattern.MatchString(result.Version) || len(result.SHA256) != 64 || result.URL == "" {
		return Release{}, fmt.Errorf("release is incomplete or has no SHA-256 digest")
	}
	return result, nil
}
