package controllers

import (
	"encoding/json"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"sync"

	"games-on-whales.github.io/direwolf/pkg/wolfapi"
)

// InputDevice is a device announced by this pod's private Wolf event stream.
// Never enumerate host-wide devices: other Wolf pods use identical pad names.
type InputDevice struct {
	SessionID  string `json:"session_id"`
	Path       string `json:"path"`
	Major      uint32 `json:"major"`
	Minor      uint32 `json:"minor"`
	Generation uint64 `json:"generation"`
}

type inputDevices struct {
	mu         sync.Mutex
	devices    map[string]InputDevice
	generation uint64
}

var inputEventPath = regexp.MustCompile(`^/dev/input/event[0-9]+$`)

func (a *Agent) updateInputDevices(event wolfapi.PlugDeviceEvent, plug bool) {
	a.input.mu.Lock()
	defer a.input.mu.Unlock()
	if event.SessionID == "" {
		return
	}
	if a.input.devices == nil {
		a.input.devices = make(map[string]InputDevice)
	}
	for _, properties := range event.UdevEvents {
		path := properties["DEVNAME"]
		if !inputEventPath.MatchString(path) {
			continue
		}
		if !plug {
			if device, ok := a.input.devices[path]; ok && device.SessionID == event.SessionID {
				delete(a.input.devices, path)
			}
			continue
		}
		major, majorErr := strconv.ParseUint(properties["MAJOR"], 10, 32)
		minor, minorErr := strconv.ParseUint(properties["MINOR"], 10, 32)
		if majorErr != nil || minorErr != nil || major != 13 {
			continue
		}
		a.input.generation++
		a.input.devices[path] = InputDevice{SessionID: event.SessionID, Path: path,
			Major: uint32(major), Minor: uint32(minor), Generation: a.input.generation}
	}
}

func (a *Agent) removeSessionDevices(sessionID string) {
	a.input.mu.Lock()
	defer a.input.mu.Unlock()
	for path, device := range a.input.devices {
		if device.SessionID == sessionID {
			delete(a.input.devices, path)
		}
	}
}

func (a *Agent) clearInputDevices() {
	a.input.mu.Lock()
	defer a.input.mu.Unlock()
	clear(a.input.devices)
}

// ServeInputDevices exposes only ownership metadata; no stream encryption keys.
// The existing ready gate establishes the subscription before clients can stream.
func (a *Agent) ServeInputDevices(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !a.Ready() {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	a.input.mu.Lock()
	devices := make([]InputDevice, 0, len(a.input.devices))
	for _, device := range a.input.devices {
		devices = append(devices, device)
	}
	a.input.mu.Unlock()
	sort.Slice(devices, func(i, j int) bool { return devices[i].Path < devices[j].Path })
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(struct {
		Devices []InputDevice `json:"devices"`
	}{devices})
}
