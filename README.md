# Barleta homelab

Barleta runs on **Ubuntu 24.04 and a single-node k3s cluster** on `g913` (`192.168.1.10`). Argo CD reconciles the application manifests from this repository's `main` branch.

## Repository map

| Path | Responsibility |
| --- | --- |
| `barleta/bootstrap/` | Host prerequisites and the Argo root application, applied deliberately |
| `barleta/apps/kustomization.yaml` | Explicit list of root resources and child applications |
| `barleta/apps/house/` | Fenrir, media, home automation, and GPU device initialization |
| `barleta/apps/identity/` | PostgreSQL, Keycloak, and ingress definitions |
| `barleta/apps/analytics/` | Analytics services and the tested UCI ingestion image |
| `fenrir/cmd/`, `fenrir/pkg/` | Go operator, Moonlight proxy, and Wolf sidecar |
| `fenrir/images/wolf/` | Wolf source and its compatible, pinned image build |
| `moonlight-mcp/` | Protocol diagnostics and acknowledged native input adapter |
| `scripts/native-moonlight/` | Real Moonlight client and SDL controller test helper |
| `.github/workflows/` | Project validation and image publication |

See [operations](docs/operations.md), [house services](barleta/house.md), [analytics](barleta/analytics.md), and [Fenrir deployment](barleta/apps/house/fenrir/README.md).

## Apple TV

Add **`192.168.1.221`** in Moonlight. Start pairing on the Apple TV, then open **<http://192.168.1.221:47989/>** on another device and enter the displayed PIN. Select EmuDeck or RetroArch after pairing.

The October 2026 reliability update replaces the proxy's temporary server identity with a persistent Secret. Existing clients need one pairing after this transition; if the client retains the old server certificate, remove the saved host and add it again. Subsequent proxy rollouts retain the same identity.

## Development

All task-generated files, downloads, logs, screenshots, caches, and build output belong under **`/Volumes/4TB_Drive/tmp/`**. Set `TMPDIR` before running tools. Keep generated binaries and tool state out of Git.

```sh
export TMPDIR=/Volumes/4TB_Drive/tmp/
make validate
make test
make build
```

Go, Rust, kubectl, Python 3.11+, and PyYAML are required for the complete local checks. The loader's PostgreSQL integration test is described in the [analytics guide](barleta/analytics.md). Native controller testing requires an Apple Silicon Mac with Moonlight and Command Line Tools; follow its [test guide](scripts/native-moonlight/README.md).

## Releases

GitHub Actions builds images and commits their source SHA tags into the manifests. Argo CD deploys those manifest changes. Go components, Wolf, and the UCI loader require the reusable project checks before publication. Publication retries reapply their own tag updates to the current `main` and fail if all pushes fail.

EmuDeck and RetroArch builds fetch upstream emulator releases and cores when their image workflows run. Their `UPSTREAM_REFRESH` build argument prevents an old download layer from silently supplying stale upstream builds. Wolf's platform/toolchain inputs remain pinned because its GPU compositor has compatibility requirements.

Obsolete Harvester/Terraform, undeployed NixOS configuration, provider caches, compiled binaries, unused templates, and broken gitlinks are retired from the active tree after validation. Historical source remains available in Git; operational state and live PVCs are separate from those files.
