# Identity Stack Implementation Plan

## Overview

This document outlines the implementation plan for deploying an enterprise-grade identity stack on the **HomePractice K3s cluster**. The stack provides centralized authentication, identity governance, and directory services.

### Components

| Component | Purpose | Version | UI Access |
|-----------|---------|---------|-----------|
| **Keycloak** | SSO / Identity Broker (OIDC/SAML) | 26.x | `https://keycloak.practice.local` |
| **MidPoint** | Identity Governance & Administration | 4.8.x | `https://midpoint.practice.local` |
| **FreeIPA** | LDAP Directory + Kerberos KDC (VM) | Fedora 41 | `https://ipa.practice.local` |

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          192.168.1.0/24 (Home Network)                       │
│                                                                             │
│  ┌─────────────┐                                                            │
│  │ Workstation │ ──────────┐                                                │
│  └─────────────┘           │                                                │
│                            ▼                                                │
│                   ┌────────────────┐                                        │
│                   │   OPNsense     │  Port Forwards:                        │
│                   │  192.168.1.40  │  - 8443 → Keycloak (10.10.10.210:443)  │
│                   │   (WAN)        │  - 8444 → MidPoint (10.10.10.211:443)  │
│                   │  10.10.10.1    │  - 8445 → FreeIPA  (10.10.10.212:443)  │
│                   │   (LAN)        │                                        │
│                   └───────┬────────┘                                        │
│                           │                                                 │
└───────────────────────────┼─────────────────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────────────────┐
│                           ▼                                                 │
│              10.10.10.0/24 (HomePractice LAN)                               │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    K3s Cluster (10.10.10.10)                          │   │
│  │                                                                       │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │   │
│  │  │    Keycloak     │  │    MidPoint     │  ┌─────────────────┐       │   │
│  │  │  10.10.10.210   │  │  10.10.10.211   │  │     PostgreSQL  │       │   │
│  │  │  (LoadBalancer) │  │  (LoadBalancer) │  │   10.10.10.213  │       │   │
│  │  └────────┬────────┘  └────────┬────────┘  └─────────────────┘       │   │
│  │           │                    │                                     │   │
│  │           └────────────────────┘                                     │   │
│  │                                                                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    FreeIPA VM (10.10.10.212)                          │   │
│  │                                                                       │   │
│  │  - Fedora 41 VM deployed via Terraform                               │   │
│  │  - FreeIPA server installed via Ansible                              │   │
│  │  - LDAP (389/636), Kerberos (88/464), HTTPS (443)                    │   │
│  │  - Requires systemd (cannot run in K8s containers)                   │   │
│  │                                                                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Integration Flow

```
                    ┌──────────────┐
                    │   End User   │
                    └──────┬───────┘
                           │ OIDC/SAML
                           ▼
                    ┌──────────────┐
                    │   Keycloak   │ ◄─── SSO for all applications
                    │   (IdP/SP)   │
                    └──────┬───────┘
                           │ LDAP Federation
                           ▼
                    ┌──────────────┐
                    │   FreeIPA    │ ◄─── User Directory (Source of Truth)
                    │ (LDAP/KDC)   │      Groups, Policies, Kerberos
                    └──────┬───────┘
                           │ Connector
                           ▼
                    ┌──────────────┐
                    │   MidPoint   │ ◄─── Identity Governance
                    │    (IGA)     │      Provisioning, Roles, Compliance
                    └──────────────┘
```

---

## Phase 1: Infrastructure Prerequisites

### 1.1 Network Configuration

Update OPNsense to create port forwards for external access from `192.168.1.0/24`:

**File:** `homepractice/ansible/playbooks/opnsense-configure.yml`

Add these port forward rules via API:

| External Port | Internal IP | Internal Port | Service |
|--------------|-------------|---------------|---------|
| 8443 | 10.10.10.210 | 443 | Keycloak |
| 8444 | 10.10.10.211 | 443 | MidPoint |
| 8445 | 10.10.10.212 | 443 | FreeIPA |

### 1.2 DNS Configuration

Add DNS entries to OPNsense Unbound:

| Hostname | IP |
|----------|-----|
| `keycloak.practice.local` | 10.10.10.210 |
| `midpoint.practice.local` | 10.10.10.211 |
| `ipa.practice.local` | 10.10.10.212 |
| `postgres.practice.local` | 10.10.10.213 |

### 1.3 MetalLB IP Allocation

Reserve IPs from the existing MetalLB pool (`10.10.10.200-10.10.10.250`):

| Service | Reserved IP |
|---------|-------------|
| Keycloak | 10.10.10.210 |
| MidPoint | 10.10.10.211 |
| FreeIPA | 10.10.10.212 |
| PostgreSQL | 10.10.10.213 |

---

## Phase 2: Shared PostgreSQL Database

Deploy a shared PostgreSQL instance for Keycloak and MidPoint.

### 2.1 Create ArgoCD Application

**File:** `homepractice/apps/identity-postgres.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: identity-postgres
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: "16.4.1"
    helm:
      values: |
        global:
          postgresql:
            auth:
              postgresPassword: ""
              existingSecret: identity-postgres-secret
              secretKeys:
                adminPasswordKey: postgres-password

        primary:
          persistence:
            enabled: true
            storageClass: local-path
            size: 20Gi
          
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi

          initdb:
            scripts:
              create-databases.sql: |
                CREATE DATABASE keycloak;
                CREATE DATABASE midpoint;
                CREATE USER keycloak WITH ENCRYPTED PASSWORD 'keycloak-db-pass';
                CREATE USER midpoint WITH ENCRYPTED PASSWORD 'midpoint-db-pass';
                GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
                GRANT ALL PRIVILEGES ON DATABASE midpoint TO midpoint;

        service:
          type: LoadBalancer
          loadBalancerIP: 10.10.10.213

        metrics:
          enabled: true

  destination:
    server: https://kubernetes.default.svc
    namespace: identity
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 2.2 Database Secrets (Sealed)

**File:** `homepractice/apps/identity/postgres-secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: identity-postgres-secret
  namespace: identity
type: Opaque
stringData:
  postgres-password: "CHANGE_ME_postgres_admin"
  keycloak-password: "CHANGE_ME_keycloak_db"
  midpoint-password: "CHANGE_ME_midpoint_db"
```

> **Note:** Use SealedSecrets or External Secrets Operator in production.

---

## Phase 3: FreeIPA Deployment

FreeIPA provides the LDAP directory and Kerberos KDC. Deploy first as other components depend on it.

### 3.1 ArgoCD Application

**File:** `homepractice/apps/freeipa.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: freeipa
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:jefflouisma/homelab.git
    targetRevision: HEAD
    path: homepractice/apps/identity/freeipa
  destination:
    server: https://kubernetes.default.svc
    namespace: identity
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 3.2 FreeIPA Manifests

**File:** `homepractice/apps/identity/freeipa/configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: freeipa-env
  namespace: identity
data:
  IPA_SERVER_HOSTNAME: "ipa.practice.local"
  IPA_SERVER_INSTALL_OPTIONS: >-
    --realm=PRACTICE.LOCAL
    --domain=practice.local
    --ds-password=DirectoryP@ssw0rd
    --admin-password=AdminP@ssw0rd
    --unattended
    --no-ntp
    --no-ui-redirect
    --setup-dns
    --forwarder=10.10.10.1
    --no-dnssec-validation
```

**File:** `homepractice/apps/identity/freeipa/statefulset.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: freeipa
  namespace: identity
spec:
  type: LoadBalancer
  loadBalancerIP: 10.10.10.212
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
    - name: ldap
      port: 389
      targetPort: 389
    - name: ldaps
      port: 636
      targetPort: 636
    - name: kerberos-udp
      port: 88
      targetPort: 88
      protocol: UDP
    - name: kerberos-tcp
      port: 88
      targetPort: 88
      protocol: TCP
    - name: kpasswd-udp
      port: 464
      targetPort: 464
      protocol: UDP
    - name: kpasswd-tcp
      port: 464
      targetPort: 464
      protocol: TCP
  selector:
    app: freeipa
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: freeipa
  namespace: identity
spec:
  serviceName: freeipa
  replicas: 1
  selector:
    matchLabels:
      app: freeipa
  template:
    metadata:
      labels:
        app: freeipa
    spec:
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      containers:
        - name: freeipa
          image: freeipa/freeipa-server:rocky-9
          imagePullPolicy: IfNotPresent
          envFrom:
            - configMapRef:
                name: freeipa-env
          startupProbe:
            httpGet:
              path: /ipa/ui/
              port: 80
              scheme: HTTP
            failureThreshold: 60
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /ipa/ui/
              port: 80
            initialDelaySeconds: 60
            periodSeconds: 15
            failureThreshold: 10
          resources:
            requests:
              cpu: "500m"
              memory: "2Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
          volumeMounts:
            - name: data
              mountPath: /data
          securityContext:
            privileged: true
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 20Gi
```

### 3.3 Post-Deployment Configuration (CaC via Ansible)

**File:** `homepractice/ansible/playbooks/freeipa-configure.yml`

```yaml
---
- name: Configure FreeIPA Users and Groups
  hosts: localhost
  gather_facts: false
  vars:
    ipa_host: "ipa.practice.local"
    ipa_admin_password: "{{ lookup('env', 'IPA_ADMIN_PASSWORD') }}"
  
  tasks:
    - name: Create service accounts
      community.general.ipa_user:
        ipa_host: "{{ ipa_host }}"
        ipa_user: admin
        ipa_pass: "{{ ipa_admin_password }}"
        name: "{{ item.name }}"
        givenname: "{{ item.givenname }}"
        sn: "{{ item.sn }}"
        password: "{{ item.password }}"
        state: present
      loop:
        - { name: keycloak-ldap, givenname: Keycloak, sn: LDAP, password: "{{ lookup('env', 'KEYCLOAK_LDAP_PASSWORD') }}" }
        - { name: midpoint-ldap, givenname: MidPoint, sn: LDAP, password: "{{ lookup('env', 'MIDPOINT_LDAP_PASSWORD') }}" }

    - name: Create groups
      community.general.ipa_group:
        ipa_host: "{{ ipa_host }}"
        ipa_user: admin
        ipa_pass: "{{ ipa_admin_password }}"
        name: "{{ item }}"
        state: present
      loop:
        - idm-admins
        - idm-operators
        - application-users
```

---

## Phase 4: Keycloak Deployment

### 4.1 ArgoCD Application

**File:** `homepractice/apps/keycloak.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: keycloak
    targetRevision: "24.0.5"
    helm:
      values: |
        auth:
          adminUser: admin
          existingSecret: keycloak-admin-secret
          secretKeys:
            adminPasswordKey: admin-password

        proxy: edge
        httpRelativePath: /

        service:
          type: LoadBalancer
          loadBalancerIP: 10.10.10.210
          ports:
            http: 80
            https: 443

        postgresql:
          enabled: false

        externalDatabase:
          host: identity-postgres-postgresql.identity.svc.cluster.local
          port: 5432
          user: keycloak
          database: keycloak
          existingSecret: identity-postgres-secret
          existingSecretPasswordKey: keycloak-password

        replicaCount: 1

        persistence:
          enabled: false

        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 2Gi

        extraEnvVars:
          - name: KC_PROXY
            value: "edge"
          - name: KC_HOSTNAME_STRICT
            value: "false"
          - name: KC_HTTP_ENABLED
            value: "true"
          - name: KC_HEALTH_ENABLED
            value: "true"
          - name: KC_METRICS_ENABLED
            value: "true"

        extraVolumes:
          - name: realm-import
            configMap:
              name: keycloak-realm-config

        extraVolumeMounts:
          - name: realm-import
            mountPath: /opt/bitnami/keycloak/data/import
            readOnly: true

        args:
          - start
          - --import-realm

  destination:
    server: https://kubernetes.default.svc
    namespace: identity
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 4.2 Realm Configuration (GitOps)

**File:** `homepractice/apps/identity/keycloak/realm-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-realm-config
  namespace: identity
data:
  homelab-realm.json: |
    {
      "realm": "homelab",
      "enabled": true,
      "displayName": "HomeLab Identity",
      "sslRequired": "external",
      "registrationAllowed": false,
      "loginWithEmailAllowed": true,
      "duplicateEmailsAllowed": false,
      "resetPasswordAllowed": true,
      "editUsernameAllowed": false,
      "bruteForceProtected": true,
      "permanentLockout": false,
      "maxFailureWaitSeconds": 900,
      "minimumQuickLoginWaitSeconds": 60,
      "waitIncrementSeconds": 60,
      "quickLoginCheckMilliSeconds": 1000,
      "maxDeltaTimeSeconds": 43200,
      "failureFactor": 5,
      "components": {
        "org.keycloak.storage.UserStorageProvider": [
          {
            "name": "freeipa-ldap",
            "providerId": "ldap",
            "config": {
              "enabled": ["true"],
              "priority": ["0"],
              "importEnabled": ["true"],
              "editMode": ["READ_ONLY"],
              "vendor": ["rhds"],
              "connectionUrl": ["ldaps://freeipa.identity.svc.cluster.local:636"],
              "bindDn": ["uid=keycloak-ldap,cn=users,cn=accounts,dc=practice,dc=local"],
              "bindCredential": ["${KEYCLOAK_LDAP_BIND_CREDENTIAL}"],
              "usersDn": ["cn=users,cn=accounts,dc=practice,dc=local"],
              "usernameLDAPAttribute": ["uid"],
              "rdnLDAPAttribute": ["uid"],
              "uuidLDAPAttribute": ["ipaUniqueID"],
              "userObjectClasses": ["inetOrgPerson, organizationalPerson"],
              "trustEmail": ["true"],
              "pagination": ["true"],
              "fullSyncPeriod": ["-1"],
              "changedSyncPeriod": ["86400"],
              "useTruststoreSpi": ["ldapsOnly"]
            }
          }
        ]
      },
      "clients": [
        {
          "clientId": "midpoint",
          "name": "MidPoint IGA",
          "enabled": true,
          "protocol": "openid-connect",
          "publicClient": false,
          "standardFlowEnabled": true,
          "directAccessGrantsEnabled": true,
          "serviceAccountsEnabled": true,
          "redirectUris": ["https://midpoint.practice.local/*"],
          "webOrigins": ["https://midpoint.practice.local"]
        },
        {
          "clientId": "argocd",
          "name": "ArgoCD",
          "enabled": true,
          "protocol": "openid-connect",
          "publicClient": false,
          "standardFlowEnabled": true,
          "redirectUris": ["https://10.10.10.200/*"],
          "webOrigins": ["https://10.10.10.200"]
        }
      ]
    }
```

### 4.3 Keycloak Secrets

**File:** `homepractice/apps/identity/keycloak/secrets.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin-secret
  namespace: identity
type: Opaque
stringData:
  admin-password: "CHANGE_ME_keycloak_admin"
---
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-ldap-secret
  namespace: identity
type: Opaque
stringData:
  bind-credential: "CHANGE_ME_ldap_bind_password"
```

---

## Phase 5: MidPoint Deployment

### 5.1 ArgoCD Application

**File:** `homepractice/apps/midpoint.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: midpoint
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:jefflouisma/homelab.git
    targetRevision: HEAD
    path: homepractice/apps/identity/midpoint
  destination:
    server: https://kubernetes.default.svc
    namespace: identity
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 5.2 MidPoint Manifests

**File:** `homepractice/apps/identity/midpoint/deployment.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: midpoint-config
  namespace: identity
data:
  config.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <configuration>
      <midpoint>
        <repository>
          <type>native</type>
          <jdbcUrl>jdbc:postgresql://identity-postgres-postgresql.identity.svc.cluster.local:5432/midpoint</jdbcUrl>
          <jdbcUsername>midpoint</jdbcUsername>
        </repository>
        <audit>
          <auditService>
            <auditServiceFactoryClass>com.evolveum.midpoint.audit.impl.LoggerAuditServiceFactory</auditServiceFactoryClass>
          </auditService>
        </audit>
      </midpoint>
    </configuration>
---
apiVersion: v1
kind: Service
metadata:
  name: midpoint
  namespace: identity
spec:
  type: LoadBalancer
  loadBalancerIP: 10.10.10.211
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: https
      port: 443
      targetPort: 8443
  selector:
    app: midpoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: midpoint
  namespace: identity
spec:
  replicas: 1
  selector:
    matchLabels:
      app: midpoint
  template:
    metadata:
      labels:
        app: midpoint
    spec:
      containers:
        - name: midpoint
          image: evolveum/midpoint:4.8.4-alpine
          ports:
            - containerPort: 8080
            - containerPort: 8443
          env:
            - name: MP_SET_midpoint_repository_jdbcUrl
              value: "jdbc:postgresql://identity-postgres-postgresql.identity.svc.cluster.local:5432/midpoint"
            - name: MP_SET_midpoint_repository_jdbcUsername
              value: "midpoint"
            - name: MP_SET_midpoint_repository_jdbcPassword
              valueFrom:
                secretKeyRef:
                  name: identity-postgres-secret
                  key: midpoint-password
            - name: MP_ENTRY_POINT
              value: "/opt/midpoint/bin/midpoint.sh"
          volumeMounts:
            - name: midpoint-home
              mountPath: /opt/midpoint/var
            - name: config
              mountPath: /opt/midpoint/var/config.xml
              subPath: config.xml
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              cpu: "2"
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /midpoint/actuator/health
              port: 8080
            initialDelaySeconds: 120
            periodSeconds: 15
          livenessProbe:
            httpGet:
              path: /midpoint/actuator/health
              port: 8080
            initialDelaySeconds: 300
            periodSeconds: 30
      volumes:
        - name: midpoint-home
          persistentVolumeClaim:
            claimName: midpoint-pvc
        - name: config
          configMap:
            name: midpoint-config
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: midpoint-pvc
  namespace: identity
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
```

### 5.3 MidPoint Resources (CaC)

**File:** `homepractice/apps/identity/midpoint/resources/freeipa-connector.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<resource xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3"
          oid="10000000-0000-0000-0000-000000000001">
    <name>FreeIPA Directory</name>
    <description>FreeIPA LDAP connector for user provisioning</description>
    <connectorRef type="ConnectorType">
        <filter>
            <q:equal>
                <q:path>connectorType</q:path>
                <q:value>com.evolveum.polygon.connector.ldap.LdapConnector</q:value>
            </q:equal>
        </filter>
    </connectorRef>
    <connectorConfiguration>
        <configurationProperties>
            <host>freeipa.identity.svc.cluster.local</host>
            <port>636</port>
            <connectionSecurity>ssl</connectionSecurity>
            <bindDn>uid=midpoint-ldap,cn=users,cn=accounts,dc=practice,dc=local</bindDn>
            <bindPassword>
                <clearValue>MIDPOINT_LDAP_PASSWORD</clearValue>
            </bindPassword>
            <baseContext>dc=practice,dc=local</baseContext>
        </configurationProperties>
    </connectorConfiguration>
    <schemaHandling>
        <objectType>
            <kind>account</kind>
            <default>true</default>
            <objectClass>ri:inetOrgPerson</objectClass>
        </objectType>
    </schemaHandling>
</resource>
```

---

## Phase 6: Service Integrations (CAC - Configuration as Code)

All identity services are integrated using GitOps manifests stored in `homepractice/apps/identity/integration/`.

### 6.1 Integration Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Identity Service Integration                      │
│                                                                         │
│  ┌──────────────┐         LDAP Federation          ┌──────────────┐    │
│  │   Keycloak   │ ◄─────────────────────────────── │   FreeIPA    │    │
│  │  (practice   │   uid=keycloak-service           │ (LDAP/KDC)   │    │
│  │   realm)     │   cn=users,cn=accounts           │              │    │
│  └──────┬───────┘   dc=practice,dc=local           └──────┬───────┘    │
│         │                                                  │            │
│         │ OIDC/REST                                       │ LDAP       │
│         │ midpoint-admin client                            │            │
│         ▼                                                  ▼            │
│  ┌──────────────┐         LDAP Provisioning        ┌──────────────┐    │
│  │   MidPoint   │ ─────────────────────────────────│   FreeIPA    │    │
│  │    (IGA)     │   uid=midpoint-service           │              │    │
│  │              │   Sync users/groups              │              │    │
│  └──────────────┘                                  └──────────────┘    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.2 GitOps Integration Files

```
homepractice/apps/identity/integration/
├── kustomization.yaml                  # Kustomize bundle
├── keycloak-realm-config.yaml          # Practice realm with LDAP federation
├── keycloak-realm-import-job.yaml      # Auto-imports realm on deploy
├── midpoint-resources-configmap.yaml   # FreeIPA & Keycloak connectors
├── midpoint-resources-import-job.yaml  # Auto-imports resources
└── freeipa-setup-job.yaml              # Creates service accounts
```

### 6.3 Keycloak Practice Realm Configuration

The `practice` realm is configured with:
- **LDAP User Federation** to FreeIPA at `ldaps://ipa.practice.local:636`
- **Service account**: `uid=keycloak-service,cn=users,cn=accounts,dc=practice,dc=local`
- **Attribute mappers**: username, email, firstName, lastName, groups
- **Clients**: `midpoint` (for SSO), `midpoint-admin` (for REST API)

### 6.4 MidPoint Resource Connectors

**FreeIPA LDAP Resource** (`oid: 00000000-0000-0000-0000-000000000100`):
- Connects to `ldaps://ipa.practice.local:636`
- Service account: `uid=midpoint-service`
- Provisions: users (inetOrgPerson), groups (groupOfNames)
- Sync: bidirectional with correlation on `uid` → `name`

**Keycloak REST Resource** (`oid: 00000000-0000-0000-0000-000000000200`):
- Connects to `http://keycloak.identity.svc.cluster.local`
- Realm: `practice`
- Manages: users, realm roles
- Uses `midpoint-admin` client with service account

### 6.5 Credentials (Stored in Secrets)

| Service Account | Purpose | Secret |
|-----------------|---------|--------|
| `keycloak-service` | Keycloak → FreeIPA LDAP bind | `freeipa-admin-secret.keycloak-ldap-password` |
| `midpoint-service` | MidPoint → FreeIPA LDAP bind | `freeipa-admin-secret.midpoint-ldap-password` |
| `midpoint-admin` | MidPoint → Keycloak REST API | `MidPointAdminAPI2024!` |

### 6.6 Deploy Integrations

```bash
# Apply integration manifests
kubectl apply -f homepractice/apps/identity/secrets/freeipa-admin-secret.yaml
kubectl apply -f homepractice/apps/identity/integration/

# Verify jobs completed
kubectl get jobs -n identity
```

---

## Phase 7: OPNsense Network Configuration

Update Ansible playbook to configure port forwarding for external access.

### 6.1 Port Forward Rules

**Add to:** `homepractice/ansible/playbooks/opnsense-configure.yml`

```yaml
    - name: Create port forward for Keycloak
      ansible.builtin.uri:
        url: "https://{{ opn_host }}/api/firewall/nat/addRule"
        method: POST
        user: "{{ opn_api_key }}"
        password: "{{ opn_api_secret }}"
        force_basic_auth: true
        validate_certs: false
        body_format: json
        body:
          rule:
            enabled: "1"
            interface: "wan"
            protocol: "tcp"
            source: { net: "any" }
            destination: { port: "8443" }
            target: "10.10.10.210"
            local-port: "443"
            descr: "Keycloak HTTPS"

    - name: Create port forward for MidPoint
      ansible.builtin.uri:
        url: "https://{{ opn_host }}/api/firewall/nat/addRule"
        method: POST
        user: "{{ opn_api_key }}"
        password: "{{ opn_api_secret }}"
        force_basic_auth: true
        validate_certs: false
        body_format: json
        body:
          rule:
            enabled: "1"
            interface: "wan"
            protocol: "tcp"
            source: { net: "any" }
            destination: { port: "8444" }
            target: "10.10.10.211"
            local-port: "443"
            descr: "MidPoint HTTPS"

    - name: Create port forward for FreeIPA
      ansible.builtin.uri:
        url: "https://{{ opn_host }}/api/firewall/nat/addRule"
        method: POST
        user: "{{ opn_api_key }}"
        password: "{{ opn_api_secret }}"
        force_basic_auth: true
        validate_certs: false
        body_format: json
        body:
          rule:
            enabled: "1"
            interface: "wan"
            protocol: "tcp"
            source: { net: "any" }
            destination: { port: "8445" }
            target: "10.10.10.212"
            local-port: "443"
            descr: "FreeIPA HTTPS"
```

---

## Implementation Order

### Deployment Sequence

```
1. Prerequisites
   └── Create namespace: identity
   └── Create secrets (postgres, keycloak, freeipa)
   └── Update OPNsense port forwards
   
2. PostgreSQL
   └── Deploy shared PostgreSQL instance
   └── Wait for readiness
   └── Verify databases created
   
3. FreeIPA (20-30 min install)
   └── Deploy StatefulSet
   └── Wait for initial install to complete
   └── Run Ansible to create service accounts
   
4. Keycloak
   └── Deploy with Helm
   └── Import realm configuration
   └── Configure LDAP federation to FreeIPA
   └── Test authentication
   
5. MidPoint
   └── Deploy application
   └── Configure FreeIPA connector
   └── Import roles and policies
   └── Test provisioning
```

### Estimated Timeline

| Phase | Duration | Notes |
|-------|----------|-------|
| Prerequisites | 30 min | Secrets, network config |
| PostgreSQL | 10 min | Quick Helm deploy |
| FreeIPA | 30-45 min | Long initial install |
| Keycloak | 15 min | Helm + realm import |
| MidPoint | 20 min | Deploy + connector config |
| Integration Testing | 1-2 hr | End-to-end validation |

---

## Resource Requirements

### Cluster Resources Needed

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|-----------|-------------|-----------|----------------|--------------|---------|
| PostgreSQL | 250m | 1 | 512Mi | 1Gi | 20Gi |
| FreeIPA | 500m | 2 | 2Gi | 4Gi | 20Gi |
| Keycloak | 500m | 2 | 1Gi | 2Gi | - |
| MidPoint | 500m | 2 | 2Gi | 4Gi | 10Gi |
| **Total** | **1.75 cores** | **7 cores** | **5.5Gi** | **11Gi** | **50Gi** |

### K3s Node Requirements

Current HomePractice K3s node: **4 vCPU, 32GB RAM**

- Available after system overhead: ~3.5 vCPU, ~28GB RAM
- Identity stack needs: 1.75 vCPU request, 5.5GB RAM request
- **Verdict:** ✅ Sufficient resources

---

## Access URLs (from 192.168.1.X network)

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| **Keycloak** | `https://192.168.1.40:8443` | admin / (from secret) |
| **MidPoint** | `https://192.168.1.40:8444/midpoint` | administrator / 5ecr3t |
| **FreeIPA** | `https://192.168.1.40:8445/ipa/ui` | admin / (from install) |

---

## GitOps File Structure

```
homepractice/
├── apps/
│   ├── identity-postgres.yaml      # ArgoCD App for PostgreSQL
│   ├── freeipa.yaml                # ArgoCD App for FreeIPA
│   ├── keycloak.yaml               # ArgoCD App for Keycloak
│   ├── midpoint.yaml               # ArgoCD App for MidPoint
│   └── identity/
│       ├── namespace.yaml
│       ├── secrets/                # SealedSecrets
│       │   ├── postgres-secret.yaml
│       │   ├── keycloak-secrets.yaml
│       │   └── freeipa-secrets.yaml
│       ├── freeipa/
│       │   ├── configmap.yaml
│       │   └── statefulset.yaml
│       ├── keycloak/
│       │   ├── realm-configmap.yaml
│       │   └── ldap-federation.yaml
│       └── midpoint/
│           ├── deployment.yaml
│           └── resources/
│               ├── freeipa-connector.xml
│               └── roles/
├── ansible/
│   └── playbooks/
│       ├── opnsense-configure.yml  # Updated with port forwards
│       └── freeipa-configure.yml   # Post-deploy user/group setup
```

---

## Next Steps

1. **Create the directory structure** under `homepractice/apps/identity/`
2. **Generate secrets** and consider SealedSecrets for GitOps
3. **Deploy PostgreSQL** first and verify connectivity
4. **Deploy FreeIPA** and wait for install completion (~30 min)
5. **Deploy Keycloak** and configure LDAP federation
6. **Deploy MidPoint** and configure FreeIPA connector
7. **Update OPNsense** with port forward rules
8. **Test end-to-end** authentication flow

---

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [MidPoint Documentation](https://docs.evolveum.com/midpoint/)
- [FreeIPA Container](https://github.com/freeipa/freeipa-container)
- [Bitnami Keycloak Helm Chart](https://github.com/bitnami/charts/tree/main/bitnami/keycloak)
- [MidPoint Kubernetes](https://github.com/Evolveum/midpoint-kubernetes)
