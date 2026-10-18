# Argo CD applications

The deployed cluster is Ubuntu/k3s on g913. Start with the root [README](../../README.md) and [operations guide](../../docs/operations.md).

The single root application is `../bootstrap/argocd-root.yaml`. This directory's `kustomization.yaml` explicitly includes child Applications and namespace definitions. Bootstrap manifests stay outside this source directory to avoid self-management and duplicate ownership.

| Source | Contents |
| --- | --- |
| `house/` | Fenrir, media, Home Assistant, and active GPU device initialization |
| `identity/` | PostgreSQL/Keycloak and ingress resources |
| `analytics/` | Explicit Kustomization for analytics services and manual ingestion CronJobs |
| `analytics-helm-apps.yaml` | Airflow and DataHub Helm Applications, including their existing settings |
| `platform/` | cert-manager, issuers, and MetalLB pool configuration |

Traefik belongs to the k3s packaged installation. Gateway API CRDs belong to `gateway-api-crds`; Envoy's Helm source skips duplicate CRD installation. Server-side apply handles large CRD schemas. Narrow Argo differences for PVC template type fields and the injected MetalLB CA bundle are declared in their application definitions.

Validate with `make validate`. Commit changes to `main`; image workflows publish SHA-tagged images and update manifests. Argo reconciles them. Use the root Kustomization when applying this directory.
