# step-ca PKI for HomePractice

Private Certificate Authority for issuing trusted TLS certificates to HomePractice services.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     K3s Cluster (10.10.10.10)                   │
│                                                                 │
│  ┌─────────────┐     ACME      ┌─────────────┐                 │
│  │   Traefik   │ ◄───────────► │   step-ca   │                 │
│  │ 10.10.10.230│   auto-renew  │ 10.10.10.232│                 │
│  └─────────────┘               └─────────────┘                 │
│         │                                                       │
│         │ TLS certs for:                                       │
│         ├── keycloak.practice.local                            │
│         ├── testapp.practice.local                             │
│         └── (future services)                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Address | Purpose |
|-----------|---------|---------|
| step-ca | 10.10.10.232:443 | ACME CA server |
| Traefik | 10.10.10.230 | Ingress with ACME client |

## How It Works

1. **step-ca** runs as a private ACME Certificate Authority
2. **Traefik** is configured with `certificatesresolvers.stepca.acme`
3. When an Ingress is created with `certresolver: stepca`, Traefik:
   - Requests a certificate from step-ca via ACME protocol
   - Automatically renews before expiration
4. Certificates are signed by step-ca's root CA

## Device Trust Setup

For WebAuthn/Passkeys to work, devices must trust the step-ca root certificate.

### Export Root CA Certificate

```bash
# From a machine with kubectl access
kubectl exec -n step-ca deploy/step-ca -- step ca root > step-ca-root.crt

# Or via step CLI (after bootstrap)
step ca root step-ca-root.crt
```

### macOS

1. Double-click `step-ca-root.crt`
2. Keychain Access opens → Select "System" keychain
3. Click "Add"
4. Find the certificate, double-click it
5. Expand "Trust" → Set "SSL" to "Always Trust"
6. Close and enter password

Or via command line:
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain step-ca-root.crt
```

### iOS

1. Transfer `step-ca-root.crt` to device (AirDrop, email, or host on web server)
2. Tap the file → "Profile Downloaded" appears
3. Go to **Settings → General → VPN & Device Management**
4. Tap the profile → Install
5. Go to **Settings → General → About → Certificate Trust Settings**
6. Enable full trust for the step-ca root

### Android

1. Transfer `step-ca-root.crt` to device
2. Go to **Settings → Security → Encryption & credentials**
3. Tap **Install a certificate → CA certificate**
4. Select the file and confirm
5. Certificate appears in "User credentials"

## Verification

After trusting the CA, verify by visiting:
- https://keycloak.practice.local
- https://testapp.practice.local

The browser should show a valid certificate with no warnings.

## Troubleshooting

### Check step-ca logs
```bash
kubectl logs -n step-ca deploy/step-ca
```

### Check Traefik ACME status
```bash
kubectl logs -n traefik deploy/traefik | grep -i acme
```

### Verify certificate chain
```bash
openssl s_client -connect keycloak.practice.local:443 -servername keycloak.practice.local
```

## GitOps

All configuration is managed via ArgoCD:
- **Application**: `step-ca`
- **Namespace**: `step-ca`
- **Helm Chart**: `smallstep/step-certificates`
- **Values**: `homepractice/apps/infrastructure/step-ca/values.yaml`
