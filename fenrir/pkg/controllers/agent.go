package controllers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync/atomic"

	"games-on-whales.github.io/direwolf/pkg/wolfapi"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/klog/v2"
)

var ErrEventStreamClosed = errors.New("wolf event stream closed")

type Agent struct {
	WolfClient wolfapi.Client
	ready      atomic.Bool
	input      inputDevices
}

func NewAgent(wolfClient wolfapi.Client) *Agent {
	return &Agent{WolfClient: wolfClient}
}

func (a *Agent) Ready() bool {
	return a.ready.Load()
}

func (a *Agent) Run(ctx context.Context) error {
	klog.Info("Starting Agent")
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer a.ready.Store(false)
	defer a.clearInputDevices()

	ch, err := a.WolfClient.SubscribeToEvents(ctx)
	if err != nil {
		return fmt.Errorf("subscribe to wolf events: %w", err)
	}
	a.ready.Store(true)
	klog.Info("Agent started")

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-ch:
			if !ok || ev == nil {
				if err := ctx.Err(); err != nil {
					return err
				}
				return ErrEventStreamClosed
			}
			switch wolfapi.WolfEventType(ev.Event) {
			case wolfapi.PlugDeviceEventType, wolfapi.UnplugDeviceEventType:
				var deviceEvent wolfapi.PlugDeviceEvent
				if err := json.Unmarshal(ev.Data, &deviceEvent); err != nil {
					utilruntime.HandleError(fmt.Errorf("failed to unmarshal input device event: %w", err))
					continue
				}
				a.updateInputDevices(deviceEvent, wolfapi.WolfEventType(ev.Event) == wolfapi.PlugDeviceEventType)
			case wolfapi.PauseStreamEventType:
				var pauseEvent wolfapi.PauseStreamEvent
				if err := json.Unmarshal(ev.Data, &pauseEvent); err != nil {
					utilruntime.HandleError(fmt.Errorf("failed to unmarshal pause stream event: %w", err))
					continue
				}
				if err := a.WolfClient.StopSession(ctx, pauseEvent.SessionID); err != nil {
					return fmt.Errorf("stop paused session: %w", err)
				}
				a.removeSessionDevices(pauseEvent.SessionID)
			}
		}
	}
}
