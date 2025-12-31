# Barleta Applications

ArgoCD-managed applications for the Barleta environment on Harvester native RKE2.

## Structure

```
apps/
├── argocd-root.yaml       # Root application (app-of-apps)
├── namespaces.yaml        # Namespace definitions
├── platform/              # Core platform services
│   ├── argocd/
│   ├── cert-manager/
│   └── traefik/
└── identity/              # Identity stack (fresh deployments)
    ├── postgresql/
    ├── keycloak/
    └── midpoint/
```

## Deployment Order

1. **Platform Services**
   - cert-manager (certificates)
   - Traefik (ingress)
   - ArgoCD (self-managed after bootstrap)

2. **Identity Stack**
   - PostgreSQL (database)
   - FreeIPA VM (deployed via Terraform, not ArgoCD)
   - Keycloak (SSO)
   - MidPoint (IGA)

## Fresh Deployment Notes

All identity components are **fresh deployments** - no data migration from HomePractice.

- FreeIPA: New realm `barleta.local`
- Keycloak: New realm, new users
- MidPoint: Fresh connectors to FreeIPA
- PostgreSQL: Fresh databases
