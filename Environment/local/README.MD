# Local Bootstrap (k3d + Argo CD + App-of-Apps)

This folder bootstraps a local k3d cluster, installs Argo CD, and creates a root Argo CD Application (app-of-apps pattern).

## What Gets Bootstrapped

1. k3d cluster
2. Argo CD via Helm
3. Managed Traefik ingress on `http://*.localtest.me:8080`
4. Fallback NodePort service for Argo CD UI at `http://localhost:31002`
5. Argo CD repo-server patched for KSOPS/SOPS decryption of Kustomize apps
6. `argocd/sops-age` secret synced from a local age key file
7. Root Argo CD app (`platform-root`) that points to:
   - `Environment/local/argocd/apps`
8. Dedicated Argo CD project `local-platform` for the root app and local platform apps
9. Commented-out placeholder `infra` example kept in the repo for reference only
10. Child app that installs Traefik from the official Helm chart
11. Child app that publishes the local ingress route for Argo CD
12. Child app that installs the Strimzi Cluster Operator
13. Dedicated `monitoring` Argo CD project with one Application per observability
    service — `prometheus-operator` (CRDs + operator), `prometheus`,
    `alertmanager`, `grafana`, and `loki` — each its own Helm release
14. Splitwise Argo resources grouped under `Environment/local/argocd/apps/splitwise`
    using an `AppProject` plus an `ApplicationSet` that generates the dev and prod apps
15. Splitwise dev/prod apps that combine the application repo overlays with a local Kafka runtime layer

The `infra` placeholder example is currently commented out and kept only as a reference.
SOPS+age support is app-agnostic and can be reused by any app repo synced by this Argo CD instance.

## Layout

```text
Environment/local/
  argocd/
    access/argocd/              # Argo CD ingress + NodePort fallback service
    apps/
      infrastructure/            # Local platform project + ingress/kafka/argo-rollouts apps
      monitoring/                # Monitoring AppProject + prometheus-operator/prometheus/alertmanager/grafana/loki apps
      splitwise/                 # Splitwise AppProject + ApplicationSet + Kafka runtime overlays
    charts/infra/               # Commented-out Helm example for the placeholder infra app
    reference/infra-raw/        # Commented-out raw-manifest equivalent of the infra chart
    values/                     # Helm values for local apps/charts
```

## Prerequisites

- Linux terminal
- `sudo` permissions (for dependency installs)

## Run

```sh
chmod +x Environment/local/cluster_creation.sh
./Environment/local/cluster_creation.sh
```

Argo CD syncs from GitHub, not from your local workspace. If you want Argo to see local changes, commit and push the branch first.

## Connect To Argo CD

- Primary UI: `http://argocd.localtest.me:8080`
- Fallback UI: `http://localhost:31002`
- Username: `admin`
- Password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

`localtest.me` resolves to `127.0.0.1`, so no hosts-file change is needed for these local URLs.
The built-in k3s Traefik remains disabled; this repo installs and manages Traefik explicitly through Argo CD.

## Open Splitwise

After Argo CD syncs the root resources and the Splitwise `ApplicationSet`
generates the environment apps, open:

```text
Dev:  http://splitwise-dev.localtest.me:8080
Prod: http://splitwise.localtest.me:8080
```

The Splitwise ingress for these local URLs is owned by the
`splitwise-household-expenses` repo's `k8s/overlays/dev` and
`k8s/overlays/prod` overlays.

## Open Grafana

After the monitoring app syncs, open:

```text
Grafana: http://grafana.localtest.me:8080
```

Grafana is configured for anonymous local read-only access and includes a
`Splitwise Kafka Observability` dashboard.

## SOPS+age First Run

On first run, the script:

1. Generates a local age private key once (if missing): `~/.config/sops/age/keys.txt`
2. Creates or updates `argocd/sops-age` from that key file
3. Patches `argocd-repo-server` to enable KSOPS/SOPS decryption for Kustomize apps

After bootstrap, the script prints your age public key. Share that public key with any app repo that should encrypt secrets for this cluster.

## Re-run / Cluster Recreate

- Re-run without recreation (idempotent):  
  `./Environment/local/cluster_creation.sh`
- Recreate cluster and keep using the same local key:  
  `RECREATE=true ./Environment/local/cluster_creation.sh`

As long as `~/.config/sops/age/keys.txt` remains, reruns reuse the same key and resync `argocd/sops-age`.

No cluster recreate is required for the managed ingress controller itself.
Only recreate the cluster if you manually changed the k3d flags and want to return to the default state in this repo.

## Verification

```sh
# Argo CD secrets and config
kubectl -n argocd get secret sops-age
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}'; echo

# Confirm the repo-server has the KSOPS binary (installed by the Helm-managed init container)
kubectl -n argocd exec deploy/argocd-repo-server -c repo-server -- \
  ls -la /home/argocd/.config/kustomize/plugin/viaduct.ai/v1/ksops/ksops

# Init container logs if the binary is missing
kubectl -n argocd logs deploy/argocd-repo-server -c install-sops-and-ksops --tail=100

# Confirm SOPS_AGE_KEY_FILE env var is set
kubectl -n argocd get deploy argocd-repo-server \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="repo-server")].env[?(@.name=="SOPS_AGE_KEY_FILE")].value}'; echo

# Kafka and monitoring resources
kubectl get kafkatopics -A
kubectl get kafka -A
kubectl get podmonitors -A | grep splitwise
```

## Optional Environment Variables

Cluster:
- `CLUSTER_NAME` (default: `gitops-ha`)
- `K3S_IMAGE` (default: `rancher/k3s:v1.31.5-k3s1`)
- `SERVERS` (default: `3`)
- `AGENTS` (default: `2`)
- `RECREATE` (default: `false`)

Argo CD:
- `ARGOCD_NAMESPACE` (default: `argocd`)
- `ARGOCD_CHART_VERSION` (default: `9.4.2`)
- `ARGOCD_RELEASE_NAME` (default: `argocd`)
- `ARGOCD_SERVER_PORT` (default: `31002`)

SOPS + age:
- `SOPS_AGE_SECRET_NAME` (default: `sops-age`)
- `SOPS_AGE_KEY_FILE_LOCAL` (default: `$HOME/.config/sops/age/keys.txt`)
- `AGE_VERSION` (default: `v1.2.1`)
- `SOPS_VERSION` (default: `v3.9.4`)
- `KSOPS_VERSION` (default: `v4.4.0`)

Root app bootstrap:
- `GITOPS_REPO_URL` (default: detected from git remote)
- `GITOPS_REPO_REVISION` (default: current git branch, fallback `main`)
- `ARGOCD_ROOT_APP_NAME` (default: `platform-root`)
- `ARGOCD_ROOT_APP_PROJECT` (default: `local-platform`)
- `ARGOCD_ROOT_APP_PATH` (default: `Environment/local/argocd/apps`)

Example:

```sh
GITOPS_REPO_REVISION=main \
ARGOCD_ROOT_APP_NAME=my-root \
./Environment/local/cluster_creation.sh
```

## Local Cluster Ops

```sh
k3d cluster stop gitops-ha
k3d cluster start gitops-ha
k3d cluster delete gitops-ha
```

## Public Key Sharing For App Repos

Get the public key from your local private key file:

```sh
age-keygen -y ~/.config/sops/age/keys.txt
```

Share only this public key (`age1...`) with app repos.  
Never share `~/.config/sops/age/keys.txt` (private key).
