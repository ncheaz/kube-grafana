# Grafana Admin Credentials

## Current Deployment Credentials

**Username:** `admin`

**Password:** `ul0QN8mvr827FHR4EzA0KCAamGGWmpLnrXH2Ddrw`

## How to Retrieve Admin Password

The admin password is stored in a Kubernetes secret named `grafana` in the `grafana` namespace.

### Command to Retrieve Password

```bash
kubectl get secret grafana -n grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

### Command to Retrieve Username

```bash
kubectl get secret grafana -n grafana -o jsonpath='{.data.admin-user}' | base64 -d
```

## Important Notes

- The password is **auto-generated** by the Helm chart during installation
- The password is stored in a Kubernetes secret for security
- The secret contains two keys:
  - `admin-user`: The admin username (default: `admin`)
  - `admin-password`: The auto-generated admin password
- The password will be displayed prominently after running `./scripts/deploy.sh`
- You will be prompted to change the password on first login

## Access URLs

- **Ingress URL:** http://grafana.local/login
- **NodePort URL:** http://10.110.40.193:30030/login

> **Note:** Add `10.110.40.193 grafana.local` to `/etc/hosts` for ingress access.

## Troubleshooting

If you cannot retrieve the password:

1. Check if the secret exists:
   ```bash
   kubectl get secret grafana -n grafana
   ```

2. Check if the namespace is correct:
   ```bash
   kubectl get namespaces | grep grafana
   ```

3. View all secrets in the namespace:
   ```bash
   kubectl get secrets -n grafana
   ```

4. View the full secret data:
   ```bash
   kubectl get secret grafana -n grafana -o yaml
   ```

## Documentation

For more information about Grafana deployment and configuration, see:
- [README.md](README.md) - Main documentation
- [helm-values/official-grafana.yaml](helm-values/official-grafana.yaml) - Helm chart values
