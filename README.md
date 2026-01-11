# Grafana Deployment Scripts

Scripts for deploying and managing Grafana on Kubernetes using the official Helm chart.

## Target Deployment Environment

This deployment is designed for a local development environment using the following infrastructure:

### Infrastructure Stack

- **Multipass VM**: Ubuntu 24.04 virtual machine managed by Multipass
- **Kubernetes Distribution**: MicroK8s running inside the Multipass VM
- **Database**: PostgreSQL deployed as a Helm chart within the MicroK8s cluster
- **Container Runtime**: Containerd (MicroK8s default)

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Host Machine (Ubuntu)                    │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │              Multipass VM (Ubuntu 24.04)              │ │
│  │                                                        │ │
│  │  ┌──────────────────────────────────────────────────┐  │ │
│  │  │         MicroK8s Cluster (Kubernetes)          │  │ │
│  │  │                                                  │  │ │
│  │  │  ┌──────────────────────────────────────────┐  │  │ │
│  │  │  │  PostgreSQL Namespace                    │  │  │ │
│  │  │  │  - PostgreSQL Pod                        │  │  │ │
│  │  │  │  - PostgreSQL Service                    │  │  │ │
│  │  │  │  - PostgreSQL PVC                        │  │  │ │
│  │  │  └──────────────────────────────────────────┘  │  │ │
│  │  │                                                  │  │ │
│  │  │  ┌──────────────────────────────────────────┐  │  │ │
│  │  │  │  Grafana Namespace                      │  │  │ │
│  │  │  │  - Grafana Pod                           │  │  │ │
│  │  │  │  - Grafana Service                       │  │  │ │
│  │  │  │  - Grafana Ingress                       │  │  │ │
│  │  │  │  - Grafana PVC                            │  │  │ │
│  │  │  └──────────────────────────────────────────┘  │  │ │
│  │  │                                                  │  │ │
│  │  │  ┌──────────────────────────────────────────┐  │  │ │
│  │  │  │  Ingress Namespace                       │  │  │ │
│  │  │  │  - NGINX Ingress Controller              │  │  │ │
│  │  │  └──────────────────────────────────────────┘  │  │ │
│  │  └──────────────────────────────────────────────────┘  │ │
│  │                                                        │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Network Configuration

- **VM IP**: 10.110.40.193 (accessible from host)
- **Grafana Service**: ClusterIP (internal) + NodePort (30030)
- **Ingress Controller**: NGINX Ingress Controller
- **Ingress Class**: `nginx` / `public`
- **Ingress Host**: `grafana.local` (requires `/etc/hosts` entry)

### Access Methods

1. **Ingress (Primary)**: `http://grafana.local` - Requires adding `10.110.40.193 grafana.local` to `/etc/hosts`
2. **NodePort (Fallback)**: `http://10.110.40.193:30030` - Direct access to the service

## Helm Chart

This deployment uses the **official Grafana Helm Chart** maintained by the Grafana community:

- **Chart Name**: `grafana`
- **Repository**: https://grafana.github.io/helm-charts
- **Documentation**: https://github.com/grafana/helm-charts/tree/main/charts/grafana
- **Chart Version**: `latest` (pulled from repository)
- **Supported Grafana Version**: v10.0+

### Chart Features

The official Grafana Helm chart provides:
- Automated deployment and upgrades
- Persistent storage configuration
- Ingress integration
- Database configuration (PostgreSQL, MySQL, SQLite)
- Security context and RBAC
- Resource limits and requests
- Health checks and probes
- Custom configuration via values files
- Plugin management
- Dashboard and datasource provisioning

### Values Files

This deployment uses two values files:

1. **[`helm-values/official-grafana.yaml`](helm-values/official-grafana.yaml)** - Main Grafana chart configuration
2. **[`helm-values/common-config.yaml`](helm-values/common-config.yaml)** - Common settings shared across components

## Quick Start

```bash
# Deploy Grafana with default settings
./scripts/deploy.sh
```

## Scripts

### deploy.sh
Deploy Grafana using the official Helm chart.

```bash
# Deploy with all features enabled
./scripts/deploy.sh

# Deploy without database fixes
./scripts/deploy.sh --disable-db-fix

# Deploy without ingress (NodePort only)
./scripts/deploy.sh --disable-ingress

# Deploy with custom ingress settings
./scripts/deploy.sh --ingress-class nginx --ingress-host grafana.example.com
```

**Options:**
- `--disable-db-fix` - Skip database permission fixes
- `--disable-ingress` - Deploy without Ingress
- `--ingress-class CLASS` - Specify Ingress class (default: public)
- `--ingress-host HOST` - Specify Ingress host (default: grafana.local)
- `-n, --namespace NAME` - Kubernetes namespace (default: grafana)
- `-r, --release-name NAME` - Helm release name (default: grafana)

### cleanup.sh
Remove Grafana deployment from Kubernetes.

```bash
# Basic cleanup (keep data and namespace)
./scripts/cleanup.sh

# Remove everything including data
./scripts/cleanup.sh --remove-pvc

# Remove entire namespace
./scripts/cleanup.sh --remove-namespace
```

### verify.sh
Verify Grafana deployment is working correctly.

```bash
# Run full verification
./scripts/verify.sh

# Quick verification (skip web tests)
./scripts/verify.sh -q
```

### delete_schema.sh
Delete all Grafana tables from PostgreSQL database.

> **WARNING:** This permanently deletes ALL Grafana data. Use with caution!

```bash
# Delete with confirmation
./scripts/delete_schema.sh

# Delete without confirmation (dangerous!)
./scripts/delete_schema.sh --no-confirm

# Delete from custom database/user
./scripts/delete_schema.sh -d mydb -u myuser
```

### test-ingress.sh
Test Ingress configuration.

```bash
# Run all ingress tests
./scripts/test-ingress.sh

# Quick tests only
./scripts/test-ingress.sh -q
```

## Access Information

**Ingress URL:** `http://grafana.local/login`
**NodePort URL:** `http://10.110.40.193:30030/login`

### 🔐 Grafana Admin Credentials

The Grafana Helm chart automatically generates a random admin password and stores it in a Kubernetes secret.

**Username:** `admin`

**Password:** Auto-generated (stored in Kubernetes secret)

### How to Retrieve Admin Password

The admin password is stored in the `grafana` secret in the `grafana` namespace. To retrieve it:

```bash
kubectl get secret grafana -n grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

**Example output:**
```bash
$ kubectl get secret grafana -n grafana -o jsonpath='{.data.admin-password}' | base64 -d
ul0QN8mvr827FHR4EzA0KCAamGGWmpLnrXH2Ddrw
```

**Important Notes:**
- The password is auto-generated by Helm during installation
- The password is stored in a Kubernetes secret named `grafana`
- The secret contains two keys: `admin-user` and `admin-password`
- Use `base64 -d` to decode the password from the secret
- The password will be displayed prominently after running `./scripts/deploy.sh`
- You will be prompted to change the password on first login

> **Note:** Add `10.110.40.193 grafana.local` to `/etc/hosts` for ingress access.

## Configuration

Edit [`.env`](.env) to customize deployment settings:

### Core Settings
- `GRAFANA_NAMESPACE` - Kubernetes namespace (default: grafana)
- `HELM_RELEASE_NAME` - Helm release name (default: grafana)
- `DEBUG_MODE` - Enable debug logging (default: false)

### Database Settings
- `DB_HOST` - PostgreSQL host (default: postgres-postgresql.postgres.svc.cluster.local)
- `DB_PORT` - PostgreSQL port (default: 5432)
- `DB_NAME` - Grafana database name (default: grafana)
- `DB_USER` - Grafana database user (default: grafana)
- `DB_PASSWORD` - Grafana database password (default: grafana_password123)

### Ingress Settings
- `ENABLE_INGRESS` - Enable/disable ingress (default: true)
- `INGRESS_CLASS` - Ingress class name (default: public)
- `INGRESS_HOST` - Ingress hostname (default: grafana.local)

## File Structure

```
.
├── README.md
├── .env
├── ingress.yaml
├── scripts/
│   ├── deploy.sh
│   ├── cleanup.sh
│   ├── verify.sh
│   ├── test-ingress.sh
│   ├── delete_schema.sh
│   └── utils.sh
└── helm-values/
    ├── official-grafana.yaml
    └── common-config.yaml
```
