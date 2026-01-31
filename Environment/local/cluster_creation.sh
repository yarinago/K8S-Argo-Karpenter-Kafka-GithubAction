#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-gitops-ha}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.31.5-k3s1}"
SERVERS="${SERVERS:-3}"
AGENTS="${AGENTS:-2}"
RECREATE="${RECREATE:-false}" # set RECREATE=true ./bootstrap/local.sh to rebuild

# Argo CD
ARGOCD_NAMESPACE="argocd"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.6.12}"  # pin for reproducibility (update intentionally)
ARGOCD_RELEASE_NAME="${ARGOCD_RELEASE_NAME:-argocd}"


# Check and install if missing dependencies: docker, k3d, kubectl
install_dependencies() {
    # Install docker
    if ! docker --version &> /dev/null; then
        echo "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        docker --version
    fi

    # Install k3d
    if ! k3d version &> /dev/null; then
        echo "Installing k3d..."
        curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        k3d version
    fi

    # Install kubectl
    if ! kubectl version --client &> /dev/null; then
        curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
        kubectl version --client
    fi

    #install helm
    if ! helm version &> /dev/null; then
        echo "Installing Helm..."
        tmp="$(mktemp -d)"
        curl -fsSL https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz -o "${tmp}/helm.tgz"
        tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
        mv "${tmp}/linux-amd64/helm" /usr/local/bin/helm
        chmod +x /usr/local/bin/helm
        rm -rf "${tmp}"
        helm version --short
    fi
}

# Check the first line of the 'list' output for the cluster name
cluster_exists() {
  k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"
}

# Wait for all nodes to be in 'Ready' state. Max wait time is 5 minutes.
wait_for_nodes_ready() {
  echo "Waiting for all nodes to be Ready..."
  kubectl wait --for=condition=Ready node --all --timeout=300s
  kubectl get nodes -o wide
}

# Cluster creation function
: ' The recommended way to create a k3d cluster for GitOps HA setup is using 3 servers and 3 agents.
    However, for local development and testing purposes, we will create a cluster with 3 servers and 2 agents.

    --disable=traefik: Prevents the automatic installation of the Traefik Ingress Controller. Will be managed by Argo CD.
    --disable=servicelb: Prevents the installation of the default service load balancer. MetalLB will be used instead.
    --disable=metrics-server: Disables the metrics server, will be installed by Argo CD for versioning/config consistent and auditable
    --secrets-encryption: Enables encryption of Kubernetes secrets at rest for enhanced security.
    --node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule: Taints the control plane nodes to prevent regular workloads from being scheduled on them.
'
create_cluster() {
    k3d cluster create "$CLUSTER_NAME" \
      --servers "$SERVERS" \
      --agents "$AGENTS" \
      --image "$K3S_IMAGE" \
      --api-port 127.0.0.1:6445 \
      --port "8080:80@loadbalancer" \
      --port "8443:443@loadbalancer" \
      --k3s-arg "--disable=traefik@server:*" \
      --k3s-arg "--disable=servicelb@server:*" \
      --k3s-arg "--disable=metrics-server@server:*" \
      --k3s-arg "--secrets-encryption@server:*" \
      --k3s-arg "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule@server:*"

    wait_for_nodes_ready
}

# Create necessary namespaces and install Argo CD
install_argo_cd() {
  # Argo CD depends on a namespaced called 'argocd' to be present
  if ! kubectl get namespace ${ARGOCD_NAMESPACE} &> /dev/null; then
    echo "Creating '${ARGOCD_NAMESPACE}' namespace..."
    kubectl create namespace ${ARGOCD_NAMESPACE}
  else
    echo "Namespace '${ARGOCD_NAMESPACE}' already exists. Skipping namespace creation."
  fi

  # Add repo (idempotent)
  if ! helm repo list | awk '{print $1}' | grep -qx "argo"; then
    echo "Adding argo-helm repo..."
    helm repo add argo https://argoproj.github.io/argo-helm
  fi
  helm repo update >/dev/null

  # Install/upgrade Argo CD.
  # Key production-like setting for Ingress TLS termination:
  # server.insecure=true (Argo runs HTTP behind ingress that terminates TLS)
  echo "Installing/upgrading Argo CD via Helm (chart version ${ARGOCD_CHART_VERSION})..."

  helm upgrade --install "${ARGOCD_RELEASE_NAME}" argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --version "${ARGOCD_CHART_VERSION}" \
    --set configs.params."server\.insecure"="true" \
    --set server.service.type="ClusterIP" \
    --wait --timeout 10m

  echo "Waiting for Argo CD deployments to be Ready..."
  kubectl wait deployment -n ${ARGOCD_NAMESPACE} argocd-server argocd-repo-server argocd-application-controller --for=condition=Available=True --timeout=300s
  kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s # Needed when Argo CD is applied and we immediately try to create an Application - common in automation and C
}


main() {
  install_dependencies

  if cluster_exists; then
    if [ "$RECREATE" = true ]; then
      echo "Recreating existing k3d cluster: $CLUSTER_NAME"
      k3d cluster delete "$CLUSTER_NAME" # The command will wait until deletion is complete
      create_cluster

    else
      echo "k3d cluster '$CLUSTER_NAME' already exists. Skipping creation."
      exit 0
    fi
  else
    create_cluster
    echo "k3d cluster '$CLUSTER_NAME' created successfully."
  fi  

  install_argo_cd
}

main "$@"