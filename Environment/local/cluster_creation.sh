#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# K3S Cluster
CLUSTER_NAME="${CLUSTER_NAME:-gitops-ha}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.31.5-k3s1}"
SERVERS="${SERVERS:-3}"
AGENTS="${AGENTS:-2}"
RECREATE="${RECREATE:-false}" # set RECREATE=true ./Environment/local/cluster_creation.sh to rebuild

# Argo CD
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-9.4.2}"
ARGOCD_RELEASE_NAME="${ARGOCD_RELEASE_NAME:-argocd}"
ARGOCD_SERVER_PORT="${ARGOCD_SERVER_PORT:-31002}"

# SOPS + age
SOPS_AGE_SECRET_NAME="${SOPS_AGE_SECRET_NAME:-sops-age}"
SOPS_AGE_KEY_FILE_LOCAL="${SOPS_AGE_KEY_FILE_LOCAL:-${HOME}/.config/sops/age/keys.txt}"
SOPS_VERSION="${SOPS_VERSION:-v3.9.4}"
KSOPS_VERSION="${KSOPS_VERSION:-v4.4.0}"
AGE_VERSION="${AGE_VERSION:-v1.2.1}"

# App-of-apps bootstrap
GITOPS_REPO_URL="${GITOPS_REPO_URL:-}"
GITOPS_REPO_REVISION="${GITOPS_REPO_REVISION:-}"
ARGOCD_ROOT_APP_NAME="${ARGOCD_ROOT_APP_NAME:-platform-root}"
ARGOCD_ROOT_APP_PATH="${ARGOCD_ROOT_APP_PATH:-Environment/local/argocd/apps}"

# Install required local dependencies only when missing.
install_dependencies() {
    if ! docker --version &>/dev/null; then
        echo "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        docker --version
    fi

    if ! k3d version &>/dev/null; then
        echo "Installing k3d..."
        curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        k3d version
    fi

    if ! kubectl version --client &>/dev/null; then
        curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
        kubectl version --client
    fi

    if ! helm version &>/dev/null; then
        echo "Installing Helm..."
        tmp="$(mktemp -d)"
        curl -fsSL https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz -o "${tmp}/helm.tgz"
        tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
        sudo mkdir -p /usr/local/bin
        sudo mv "${tmp}/linux-amd64/helm" /usr/local/bin/helm
        chmod +x /usr/local/bin/helm
        rm -rf "${tmp}"
        helm version --short
    fi

    if ! age-keygen --version &>/dev/null; then
        echo "Installing age..."
        tmp="$(mktemp -d)"
        curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" -o "${tmp}/age.tgz"
        tar -xzf "${tmp}/age.tgz" -C "${tmp}"
        sudo mkdir -p /usr/local/bin
        sudo mv "${tmp}/age/age" /usr/local/bin/age
        sudo mv "${tmp}/age/age-keygen" /usr/local/bin/age-keygen
        sudo chmod +x /usr/local/bin/age /usr/local/bin/age-keygen
        rm -rf "${tmp}"
        age-keygen --version
    fi
}

# Check whether the target k3d cluster already exists.
cluster_exists() {
    k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"
}

# Wait until all Kubernetes nodes report Ready.
wait_for_nodes_ready() {
    echo "Waiting for all nodes to be Ready..."
    kubectl wait --for=condition=Ready node --all --timeout=300s
    kubectl get nodes -o wide
}

# Wait for Argo CD workloads without blocking on completed Job pods.
wait_for_argocd_workloads() {
    local workloads
    mapfile -t workloads < <(kubectl -n "${ARGOCD_NAMESPACE}" get deployment,statefulset \
      -l app.kubernetes.io/part-of=argocd -o name 2>/dev/null || true)

    if [[ "${#workloads[@]}" -eq 0 ]]; then
        echo "No Argo CD workloads found to wait for."
        return 0
    fi

    local workload
    for workload in "${workloads[@]}"; do
        echo "Waiting for ${workload} rollout..."
        if ! kubectl -n "${ARGOCD_NAMESPACE}" rollout status "${workload}" --timeout=600s; then
            echo "Rollout timed out for ${workload}. Collecting diagnostics..."
            kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/part-of=argocd -o wide || true
            kubectl -n "${ARGOCD_NAMESPACE}" describe "${workload}" || true
            return 1
        fi
    done
}

# Create the k3d cluster with the configured topology and ports.
create_cluster() {
    k3d cluster create "${CLUSTER_NAME}" \
      --servers "${SERVERS}" \
      --agents "${AGENTS}" \
      --image "${K3S_IMAGE}" \
      --api-port 127.0.0.1:6445 \
      --port "8080:80@loadbalancer" \
      --port "8443:443@loadbalancer" \
      --port "${ARGOCD_SERVER_PORT}:${ARGOCD_SERVER_PORT}@loadbalancer" \
      --k3s-arg "--disable=traefik@server:*" \
      --k3s-arg "--disable=servicelb@server:*" \
      --k3s-arg "--disable=metrics-server@server:*" \
      --k3s-arg "--secrets-encryption@server:*" \
      --k3s-arg "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule@server:*"

    wait_for_nodes_ready
}

# Normalize SSH GitHub URLs to HTTPS so Argo CD can pull without SSH setup.
normalize_repo_url_for_argocd() {
    local url="$1"
    if [[ "${url}" =~ ^git@github\.com:(.+)\.git$ ]]; then
        echo "https://github.com/${BASH_REMATCH[1]}.git"
    else
        echo "${url}"
    fi
}

# Resolve the GitOps repo URL from env var or current git remote.
resolve_repo_url() {
    local candidate="${GITOPS_REPO_URL}"
    if [[ -z "${candidate}" ]]; then
        candidate="$(git -C "${REPO_ROOT}" config --get remote.origin.url || true)"
    fi

    candidate="$(normalize_repo_url_for_argocd "${candidate}")"
    if [[ -z "${candidate}" ]]; then
        echo "Could not resolve repo URL. Set GITOPS_REPO_URL explicitly." >&2
        exit 1
    fi
    echo "${candidate}"
}

# Resolve the GitOps revision from env var or current branch, with main as fallback.
resolve_repo_revision() {
    if [[ -n "${GITOPS_REPO_REVISION}" ]]; then
        echo "${GITOPS_REPO_REVISION}"
        return
    fi

    local candidate
    candidate="$(git -C "${REPO_ROOT}" branch --show-current 2>/dev/null || true)"
    if [[ -z "${candidate}" ]]; then
        candidate="main"
    fi
    echo "${candidate}"
}

# Ensure a persistent local age key exists for SOPS decryption.
ensure_local_sops_age_key() {
    local key_dir
    key_dir="$(dirname "${SOPS_AGE_KEY_FILE_LOCAL}")"
    mkdir -p "${key_dir}"

    if [[ ! -s "${SOPS_AGE_KEY_FILE_LOCAL}" ]]; then
        echo "Generating age key at '${SOPS_AGE_KEY_FILE_LOCAL}'..."
        age-keygen -o "${SOPS_AGE_KEY_FILE_LOCAL}"
    else
        echo "Reusing existing age key at '${SOPS_AGE_KEY_FILE_LOCAL}'."
    fi

    if ! grep -q '^AGE-SECRET-KEY-' "${SOPS_AGE_KEY_FILE_LOCAL}"; then
        echo "Invalid age key file: ${SOPS_AGE_KEY_FILE_LOCAL}" >&2
        exit 1
    fi

    chmod 600 "${SOPS_AGE_KEY_FILE_LOCAL}"
}

# Create or update the in-cluster secret that repo-server uses for age decryption.
sync_sops_age_secret() {
    echo "Syncing '${SOPS_AGE_SECRET_NAME}' secret in namespace '${ARGOCD_NAMESPACE}'..."
    kubectl -n "${ARGOCD_NAMESPACE}" create secret generic "${SOPS_AGE_SECRET_NAME}" \
      --from-file=keys.txt="${SOPS_AGE_KEY_FILE_LOCAL}" \
      --dry-run=client -o yaml | kubectl apply -f -
}

# Patch repo-server to support KSOPS with SOPS+age for Kustomize apps.
configure_repo_server_sops() {
    local patch_file
    patch_file="$(mktemp)"

    cat > "${patch_file}" <<EOF
spec:
  template:
    spec:
      volumes:
        - name: custom-tools
          emptyDir: {}
        - name: ksops-plugin
          emptyDir: {}
        - name: sops-age
          secret:
            secretName: ${SOPS_AGE_SECRET_NAME}
      initContainers:
        - name: install-sops-and-ksops
          image: alpine:3.20
          command: ["/bin/sh", "-ec"]
          args:
            - |
              set -euo pipefail
              apk add --no-cache curl tar
              KSOPS_VERSION="v${KSOPS_VERSION#v}"
              SOPS_VERSION="v${SOPS_VERSION#v}"
              mkdir -p /custom-tools /ksops-plugin/viaduct.ai/v1/ksops /tmp/ksops
              curl -fsSL "https://github.com/viaduct-ai/kustomize-sops/releases/download/\${KSOPS_VERSION}/ksops_\${KSOPS_VERSION#v}_Linux_x86_64.tar.gz" -o /tmp/ksops.tgz
              tar -xzf /tmp/ksops.tgz -C /tmp/ksops
              mv /tmp/ksops/ksops /ksops-plugin/viaduct.ai/v1/ksops/ksops
              chmod +x /ksops-plugin/viaduct.ai/v1/ksops/ksops
              curl -fsSL -o /custom-tools/sops "https://github.com/getsops/sops/releases/download/\${SOPS_VERSION}/sops-\${SOPS_VERSION}.linux.amd64"
              chmod +x /custom-tools/sops
          volumeMounts:
            - name: custom-tools
              mountPath: /custom-tools
            - name: ksops-plugin
              mountPath: /ksops-plugin
      containers:
        - name: repo-server
          env:
            - name: XDG_CONFIG_HOME
              value: /home/argocd/.config
            - name: SOPS_AGE_KEY_FILE
              value: /etc/argocd/sops-age/keys.txt
          volumeMounts:
            - name: custom-tools
              mountPath: /usr/local/bin/sops
              subPath: sops
            - name: ksops-plugin
              mountPath: /home/argocd/.config/kustomize/plugin
            - name: sops-age
              mountPath: /etc/argocd/sops-age
              readOnly: true
EOF

    echo "Patching argocd-repo-server for SOPS/KSOPS support..."
    kubectl -n "${ARGOCD_NAMESPACE}" patch deployment argocd-repo-server --type strategic --patch-file "${patch_file}"
    rm -f "${patch_file}"

    echo "Enabling Kustomize exec plugins in argocd-cm..."
    local build_options
    build_options="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}' 2>/dev/null || true)"
    if [[ " ${build_options} " != *" --enable-alpha-plugins "* ]]; then
        build_options="${build_options} --enable-alpha-plugins"
    fi
    if [[ " ${build_options} " != *" --enable-exec "* ]]; then
        build_options="${build_options} --enable-exec"
    fi
    build_options="$(echo "${build_options}" | xargs)"
    kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type merge \
      -p "$(printf '{"data":{"kustomize.buildOptions":"%s"}}' "${build_options}")"

    echo "Restarting argocd-repo-server..."
    kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deployment argocd-repo-server
    if ! kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment argocd-repo-server --timeout=600s; then
        local updated_replicas ready_replicas
        updated_replicas="$(kubectl -n "${ARGOCD_NAMESPACE}" get deployment argocd-repo-server -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)"
        ready_replicas="$(kubectl -n "${ARGOCD_NAMESPACE}" get deployment argocd-repo-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
        updated_replicas="${updated_replicas:-0}"
        ready_replicas="${ready_replicas:-0}"

        echo "argocd-repo-server rollout timed out (updated=${updated_replicas}, ready=${ready_replicas})."
        if [[ "${updated_replicas}" -ge 1 && "${ready_replicas}" -ge 1 ]]; then
            echo "Proceeding: updated and ready replica exists; old replica termination is delayed."
            return 0
        fi

        local latest_repo_server_pod
        echo "Collecting diagnostics..."
        kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-repo-server -o wide || true
        kubectl -n "${ARGOCD_NAMESPACE}" describe deployment argocd-repo-server || true
        latest_repo_server_pod="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-repo-server --sort-by=.metadata.creationTimestamp -o name | tail -n 1 | cut -d/ -f2)"
        if [[ -n "${latest_repo_server_pod}" ]]; then
            kubectl -n "${ARGOCD_NAMESPACE}" describe pod "${latest_repo_server_pod}" || true
            kubectl -n "${ARGOCD_NAMESPACE}" logs "${latest_repo_server_pod}" -c install-sops-and-ksops --tail=200 || true
            kubectl -n "${ARGOCD_NAMESPACE}" logs "${latest_repo_server_pod}" -c repo-server --tail=200 || true
        fi
        return 1
    fi
}

# Print Argo CD UI/login details for local access.
print_argocd_access_info() {
    echo "Argo CD UI (ingress): http://argocd.localtest.me:8080"
    echo "Argo CD UI (fallback NodePort): http://localhost:${ARGOCD_SERVER_PORT}"
    echo "Splitwise UI (dev after app sync): http://splitwise.localtest.me:8080"
    echo "Splitwise UI (prod after app sync): http://splitwise-prod.localtest.me:8080"
    echo "Argo CD username: admin"
    echo "Argo CD initial password is stored in secret: argocd-initial-admin-secret"
    echo "Retrieve it manually with:"
    echo "kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
    echo "Root app: ${ARGOCD_ROOT_APP_NAME}"
}

# Print the public age key that app repositories should use for encryption.
print_age_public_key() {
    local public_key
    public_key="$(age-keygen -y "${SOPS_AGE_KEY_FILE_LOCAL}")"
    echo "SOPS age key file: ${SOPS_AGE_KEY_FILE_LOCAL}"
    echo "SOPS age public key: ${public_key}"
}

# Install or upgrade Argo CD and keep a fallback NodePort for direct access.
install_argo_cd() {
    if ! kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        echo "Creating '${ARGOCD_NAMESPACE}' namespace..."
        kubectl create namespace "${ARGOCD_NAMESPACE}"
    else
        echo "Namespace '${ARGOCD_NAMESPACE}' already exists. Skipping namespace creation."
    fi

    ensure_local_sops_age_key
    sync_sops_age_secret

    if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "argo"; then
        echo "Adding argo-helm repo..."
        helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null
    fi
    helm repo update >/dev/null 2>&1

    echo "Installing/upgrading Argo CD via Helm (chart version ${ARGOCD_CHART_VERSION})..."
    helm upgrade --install "${ARGOCD_RELEASE_NAME}" argo/argo-cd \
      --namespace "${ARGOCD_NAMESPACE}" \
      --version "${ARGOCD_CHART_VERSION}" \
      --set configs.params."server\.insecure"="true" \
      --set server.service.type="ClusterIP" \
      --wait --timeout 10m

    echo "Waiting for Argo CD CRDs and pods..."
    kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
    wait_for_argocd_workloads

    configure_repo_server_sops

    echo "Creating fallback Argo CD NodePort (http://localhost:${ARGOCD_SERVER_PORT})..."
    kubectl apply -f "${SCRIPT_DIR}/argocd-server-service.yml" -n "${ARGOCD_NAMESPACE}"
}

# Create the root Argo CD app that bootstraps child applications.
bootstrap_root_application() {
    local repo_url
    local repo_revision
    repo_url="$(resolve_repo_url)"
    repo_revision="$(resolve_repo_revision)"

    echo "Bootstrapping Argo CD root application '${ARGOCD_ROOT_APP_NAME}'..."
    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_ROOT_APP_NAME}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${repo_url}
    targetRevision: ${repo_revision}
    path: ${ARGOCD_ROOT_APP_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
}

# Orchestrate dependency install, cluster lifecycle, and Argo CD bootstrap.
main() {
    install_dependencies

    if cluster_exists; then
        if [[ "${RECREATE}" == "true" ]]; then
            echo "Recreating existing k3d cluster: ${CLUSTER_NAME}"
            k3d cluster delete "${CLUSTER_NAME}"
            create_cluster
        else
            echo "k3d cluster '${CLUSTER_NAME}' already exists. Skipping creation."
        fi
    else
        create_cluster
        echo "k3d cluster '${CLUSTER_NAME}' created successfully."
    fi

    install_argo_cd
    bootstrap_root_application

    echo "Bootstrap complete."
    print_argocd_access_info
    print_age_public_key
}

main "$@"
