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
8. Child app `infra` that points to:
   - Helm chart: `Environment/local/charts/infra`
   - External values file (via Argo CD multi-source): `Environment/local/argocd/values/infra-values.yaml`
9. Child app that installs Traefik from the official Helm chart
10. Child app that publishes the local ingress route for Argo CD
11. Splitwise Argo resources grouped under `Environment/local/argocd/apps/splitwise`
    using an `AppProject` plus an `ApplicationSet` that generates the dev and prod apps

`infra` is a placeholder infra app (Namespace + ConfigMap) so the GitOps loop is demonstrated immediately.
SOPS+age support is app-agnostic and can be reused by any app repo synced by this Argo CD instance.

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
kubectl -n argocd get secret sops-age
kubectl -n argocd get deploy argocd-repo-server
kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.containers[?(@.name=="repo-server")].env[?(@.name=="SOPS_AGE_KEY_FILE")].value}'; echo
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}'; echo
kubectl -n argocd logs deploy/argocd-repo-server -c install-sops-and-ksops --tail=100
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
