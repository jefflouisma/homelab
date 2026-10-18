# Operations

## Ownership and bootstrap

`barleta/bootstrap/argocd-root.yaml` is the single root Application. Its source is the explicit Kustomization in `barleta/apps/`. It does not render itself or another root application. Analytics has its own explicit Kustomization; its Helm applications are declared alongside the other child applications.

Argo CD itself is an existing cluster prerequisite. Traefik is the k3s-managed installation in `kube-system`; do not install a second Traefik Helm release. MetalLB owns LoadBalancer addresses from `192.168.1.220-230`. k3s ServiceLB must remain disabled.

The host configuration is recorded in `barleta/bootstrap/k3s-config.yaml`. The only active network interface is `enx4cea416e3264`; preserve its `node-ip`, `advertise-address`, and `flannel-iface` settings when changing k3s configuration. Apply a reviewed host configuration to `/etc/rancher/k3s/config.yaml` and restart k3s during maintenance. Do not run an old Harvester or NixOS installer against this host.

The NVIDIA driver and Container Toolkit are installed on Ubuntu. `scripts/fenrir-modules.conf`, the NVIDIA RuntimeClass, and `barleta/apps/house/nvidia-device-init.yaml` support the containers. Streaming pods require their current GPU/device mounts, capabilities, supplementary input group, and socket permissions. Changes to these require a real video/controller regression test.

Before the first Moonlight proxy deployment, provision the existing `moonlight-tls` certificate, then run:

```sh
scripts/bootstrap-moonlight-identity.sh house
kubectl apply -f barleta/bootstrap/argocd-root.yaml
```

The helper copies the existing TLS material into `moonlight-server-identity` only if that Secret is absent. Preserve and back up that Secret with the cluster. It is deliberately independent of certificate renewal: Moonlight clients pin the server certificate, and changing it requires pairing again. Private keys belong in cluster/backup storage, never in Git.

Start each new pairing from Moonlight, then open `http://192.168.1.221:47989/` and choose the current request. A `/pin/#...` link belongs to one attempt; do not bookmark it. Requests disappear when the client disconnects, retries, or waits three minutes. An inactive PIN page offers a link back to the dashboard so you can select the new attempt. A proxy restart also ends pending attempts; existing completed pairings remain valid.

`platform/cluster-issuer.yaml` contains the pre-existing issuer definitions. The optional CA issuer requires `barleta-ca-secret`; it is not part of the root Kustomization. Do not enable an unconfigured issuer as a prerequisite for unrelated applications.

## Health checks

On g913, use `sudo k3s kubectl` where the examples below say `kubectl`. From a configured workstation:

```sh
make status
kubectl get applications.argoproj.io -n argocd
kubectl get pods -A
kubectl get pvc -A
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

Application sync health does not replace an HTTP or game test. Argo and Keycloak use HTTPS ingress; an HTTP request to their TLS-only route may return 404. Other declared house and analytics routes use HTTP.

| Endpoint | Expected behavior |
| --- | --- |
| `https://argocd.barleta.local` | Argo CD UI |
| `https://keycloak.barleta.local` | Keycloak redirect/UI on service port 8080 |
| `http://homeassistant.barleta.local` | Home Assistant redirect/UI through Traefik |
| `http://192.168.1.221:47989/serverinfo` | Moonlight server information |
| Wolf sidecar `/livez` | Process responds |
| Wolf sidecar `/readyz` | A live Wolf event subscription exists |

For a failing application, inspect its sync operation and resource diff before forcing a sync:

```sh
kubectl describe application.argoproj.io APPLICATION -n argocd
kubectl get events -n NAMESPACE --sort-by=.lastTimestamp
kubectl logs -n NAMESPACE POD -c CONTAINER --since=10m
kubectl logs -n NAMESPACE POD -c CONTAINER --previous
```

The Go sidecar retries failed subscriptions and becomes unready after event-stream loss. Wolf HTTP failures propagate to callers. Session Services explicitly request the proxy's IP; pending allocation and stream errors are requeued, and a different address is never published as ready. Do not treat successful command submission, an RTSP URL, or an SDL acknowledgement as proof that video and controller input work in a game.

If an established Session loses `status.wolfSessionID`, the operator matches its encryption key/IV against Wolf's live session list and restores the ID exposed there as `client_id`. A live `streamURL` prevents the five-minute startup timeout from deleting that session during recovery. Status conflicts return to the work queue for retry. After a controller rollout, test reconnection and a stream lasting more than five minutes.

When migrating from k3s ServiceLB to MetalLB, disabling ServiceLB does not clear its old Service finalizers. A deleting session Service can retain the streaming ports and block the next session. After confirming ServiceLB is disabled, no svclb pods remain, and MetalLB owns allocation, remove only the obsolete `service.kubernetes.io/load-balancer-cleanup` finalizer from affected Services. Preserve other finalizers and wait for the old Service to disappear before retrying a stream.

Home Assistant uses `Recreate` because two instances cannot share its configuration database/lock. Its init container seeds the declared proxy stanza only when no `http` section exists. It preserves existing configuration and leaves a user-defined HTTP section under user control.

EmuDeck fills missing RPCS3 dialog settings after firmware preparation. A partial INI containing only display settings must not block a controller-only game launch at the welcome dialog. Existing explicit dialog preferences remain unchanged. `make validate` includes regression tests for fresh, partial, and customized profiles.

## Emulator regression test

Use an isolated test pairing/profile when possible. Record the original pairing and PVC inventory before runtime changes. After updating a streaming component:

1. Pair or reconnect a native Moonlight client and confirm decoded video.
2. Navigate ES-DE with both buttons and directional input.
3. Launch RPCS3 Street Fighter, enter gameplay, and open the pause menu with Start.
4. Launch shadPS4 Dead or Alive 5 and verify selection changes from controller input.
5. Open standalone RetroArch and verify menu movement/confirmation.
6. Check Wolf, sidecar, emulator, and operator logs for new failures.
7. Disconnect the owned client and remove only the test session/pairing. Verify original PVC identities and pairings remain.

Keep screenshots and logs under the required temporary root. The [native helper guide](../scripts/native-moonlight/README.md) explains how MCP gamepad input reaches the real client. Its provider supports gamepads; keyboard/mouse and raw ENet verification report unsupported errors.

The tested Wolf compositor logs a GBM allocation fallback and uses default DMA formats without zero-copy. Streaming and controller input passed with this fallback. Treat zero-copy optimization as separate GPU compatibility work; changing container privileges is not a demonstrated fix for this warning.

Wolf is pinned to `546a17d` and digest `86159679457592b8fd2d10d4af34e5df961f9bbd87c2ae45f838c50f45e19d03`. Candidate `8306c4d` built successfully and passed RetroArch/PPSSPP video and input, but RPCS3 ignored game buttons. The same updated RPCS3/profile accepted input with the deployed Wolf image. Direct SDL polling in the candidate container received Start/A correctly, so the precise compositor/RPCS3 interaction remains unresolved. Do not promote that candidate. Wolf CI publishes candidates without changing `WOLF_IMAGE`; promote a tested digest in Git after the full native regression list passes.

## Rollback and retirement

Revert the manifest/image change in Git and let Argo reconcile. Preserve `moonlight-server-identity`, Pairing resources, and PVCs. Reverting a container image cannot restore a certificate that existed only in a deleted container.

Legacy deployment files can be recovered from commit `5a22b7a` with `git show` or `git archive`. Removing those repository files does not run Terraform destroy, uninstall a host driver, or remove application volumes. Never use a source cleanup as a reason to delete PVCs or bootstrap a different operating system.
