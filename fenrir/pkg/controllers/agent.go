package controllers

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/klog/v2"
)

// Default directory for writing device signal files.
// This is inside the shared /etc/wolf (wolf-cfg emptyDir volume)
// which is accessible by all containers in the pod.
const DefaultDevicesDir = "/etc/wolf/devices"

// Represents the controller that runs inside the Pod itself
type Agent struct {
	WolfClient wolfapi.Client
	DevicesDir string // Directory to write device signal files
}

func NewAgent(
	wolfClient wolfapi.Client,
) *Agent {
	devDir := os.Getenv("WOLF_DEVICES_DIR")
	if devDir == "" {
		devDir = DefaultDevicesDir
	}

	res := &Agent{
		WolfClient: wolfClient,
		DevicesDir: devDir,
	}

	return res
}

func (a *Agent) Run(ctx context.Context) error {
	klog.Infof("Starting Agent")

	// Ensure devices directory exists
	if err := os.MkdirAll(a.DevicesDir, 0755); err != nil {
		klog.Warningf("Failed to create devices dir %s: %v", a.DevicesDir, err)
	}

	if err := a.watchEvents(ctx); err != nil {
		return err
	}

	klog.Infof("Agent started")
	return nil
}

func (a *Agent) watchEvents(ctx context.Context) error {
	ch, err := a.WolfClient.SubscribeToEvents(ctx)
	if err != nil {
		return err
	}

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case ev, ok := <-ch:
				if !ok || ev == nil {
					klog.Infof("Event channel closed")
					return
				}

				klog.Infof("Received event: %s", ev.Event)
				klog.V(4).Infof("Event Data: %s", ev.Data)

				switch wolfapi.WolfEventType(ev.Event) {
				// Wolf handles a moonlight disconnect as a "Pause".
				// When moonlight disconnects from Wolf we should reflect that
				// into the state in Kubernetes so things can be cleaned up.
				case wolfapi.PauseStreamEventType:
					var pauseEvent wolfapi.PauseStreamEvent
					if err := json.Unmarshal(ev.Data, &pauseEvent); err != nil {
						utilruntime.HandleError(fmt.Errorf("failed to unmarshal pause stream event: %w", err))
						continue
					}

					if err := a.WolfClient.StopSession(ctx, pauseEvent.SessionID); err != nil {
						utilruntime.HandleError(fmt.Errorf("failed to stop session: %w", err))
						continue
					}

				// Wolf fires PlugDeviceEvent when a virtual input device is created
				// via uinput (joypad, mouse, keyboard). The event contains device
				// metadata (DEVNAME, MAJOR, MINOR) needed to create the device node
				// in other containers via mknod.
				//
				// In Docker mode, Wolf's DockerRunner processes this by running
				// `docker exec mknod` inside the game container.
				// In K8s mode (ProcessRunner), nothing handles it — so the agent
				// writes the device info to a shared volume file that game containers
				// can read and use to create their own device nodes.
				case wolfapi.PlugDeviceEventType:
					a.handlePlugDeviceEvent(ev.Data)

				default:
					continue
				}
			}
		}
	}()

	return nil
}

// handlePlugDeviceEvent processes a PlugDeviceEvent and writes device metadata
// to the shared devices directory as individual JSON files.
func (a *Agent) handlePlugDeviceEvent(data []byte) {
	var plugEvent wolfapi.PlugDeviceEvent
	if err := json.Unmarshal(data, &plugEvent); err != nil {
		utilruntime.HandleError(fmt.Errorf("failed to unmarshal PlugDeviceEvent: %w", err))
		return
	}

	klog.Infof("Received PlugDeviceEvent for session %s with %d udev events",
		plugEvent.SessionID, len(plugEvent.UdevEvents))

	for i, udevEv := range plugEvent.UdevEvents {
		devName := udevEv["DEVNAME"]
		major := udevEv["MAJOR"]
		minor := udevEv["MINOR"]
		subsystem := udevEv["SUBSYSTEM"]

		if devName == "" || major == "" || minor == "" {
			klog.V(2).Infof("  udev_event[%d]: skipping (missing DEVNAME/MAJOR/MINOR): %v", i, udevEv)
			continue
		}

		klog.Infof("  udev_event[%d]: DEVNAME=%s MAJOR=%s MINOR=%s SUBSYSTEM=%s",
			i, devName, major, minor, subsystem)

		// Write a signal file for each device. filename = sanitized devname
		// e.g., /etc/wolf/devices/dev_input_event14.json
		sanitized := sanitizeDevName(devName)
		signalFile := filepath.Join(a.DevicesDir, sanitized+".json")

		// Include all udev fields in the signal file
		signalData, err := json.MarshalIndent(udevEv, "", "  ")
		if err != nil {
			utilruntime.HandleError(fmt.Errorf("failed to marshal device signal: %w", err))
			continue
		}

		if err := os.WriteFile(signalFile, signalData, 0644); err != nil {
			utilruntime.HandleError(fmt.Errorf("failed to write device signal file %s: %w", signalFile, err))
			continue
		}

		klog.Infof("Wrote device signal: %s", signalFile)
	}
}

// sanitizeDevName converts a device path like "/dev/input/event14" to "dev_input_event14"
func sanitizeDevName(devName string) string {
	result := make([]byte, 0, len(devName))
	for _, c := range []byte(devName) {
		if c == '/' {
			if len(result) > 0 { // skip leading slash
				result = append(result, '_')
			}
		} else {
			result = append(result, c)
		}
	}
	return string(result)
}
