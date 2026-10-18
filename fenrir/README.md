# Fenrir

Fenrir coordinates Wolf game-streaming sessions on Kubernetes. Moonlight connects to the proxy, which associates a paired client with a User and creates a Session for the selected App.

## Components

| Source | Responsibility |
| --- | --- |
| `cmd/moonlight-proxy` | Pairing page, Moonlight endpoints, app lists, session launch/resume |
| `cmd/operator` | Reconcile Users, Apps, Sessions, profile PVCs, streaming Deployments and Services |
| `cmd/wolf-agent` | Forward the local Wolf API and monitor session events |
| `pkg/wolfapi` | Context-aware Wolf requests and event-stream decoding |
| `images/wolf` | Wolf compositor/encoder source and compatible image build |

A streaming pod contains the application, Wolf, the agent, PulseAudio and the input-device helper. Shared runtime sockets connect those containers. The application waits for Wayland before launch. Device mounts, the NVIDIA runtime and host input group allow video encoding and controllers; preserve these when changing pod templates.

## Networking and lifecycle

The deployed stack uses MetalLB. Session Services share the proxy's address using the same sharing key and an explicit `metallb.io/loadBalancerIPs` annotation. The operator publishes an RTSP endpoint only after that exact address is assigned. Pending allocation and stream errors return to the work queue for retry.

The sidecar remains subscribed to Wolf events. Readiness requires a live subscription; disconnects make it unready until reconnection. A paused stream stops its Wolf session. HTTP failures are returned to callers rather than treated as success.

The proxy receives explicit TLS file arguments and mounts `moonlight-server-identity`. Preserve that Secret across rollouts because Moonlight pins the server certificate. Pairing records alone cannot replace a lost server identity.

## Development and deployment

From the repository root:

```sh
export TMPDIR=/Volumes/4TB_Drive/tmp/
make validate
make test-go
make build
```

Build output and caches stay on the external drive. CI publishes commit-tagged images after validation; Argo CD reconciles the declared tags.

See the [deployment guide](../barleta/apps/house/fenrir/README.md), [operations guide](../docs/operations.md), and [native controller test guide](../scripts/native-moonlight/README.md). The current deployment is a single-host installation; simultaneous multi-host or multi-session compatibility has not been verified.
