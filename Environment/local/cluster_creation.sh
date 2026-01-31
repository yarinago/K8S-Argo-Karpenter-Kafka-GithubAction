#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-gitops-ha}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.31.5-k3s1}"
SERVERS="${SERVERS:-3}"
AGENTS="${AGENTS:-2}"
RECREATE="${RECREATE:-false}" # set RECREATE=true ./bootstrap/local.sh to rebuild


# Check and install if missing dependencies: docker, k3d, kubectl
install_dependencies() {
    # Install docker
    if ! docker --version &> /dev/null; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        docker --version
    fi

    # Install k3d
    if ! k3d version &> /dev/null; then
        log "Installing k3d..."
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
}

# Check the first line of the 'list' output for the cluster name
cluster_exists() {
  k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"
}

# Wait for all nodes to be in 'Ready' state. Max wait time is 5 minutes.
wait_for_nodes_ready() {
  log "Waiting for all nodes to be Ready..."
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


main() {
  install_dependencies

  if cluster_exists; then
    if [ "$RECREATE" = true ]; then
      log "Recreating existing k3d cluster: $CLUSTER_NAME"
      k3d cluster delete "$CLUSTER_NAME" # The command will wait until deletion is complete
      create_cluster

    else
      log "k3d cluster '$CLUSTER_NAME' already exists. Skipping creation."
      exit 0
    fi
  fi

  log "k3d cluster '$CLUSTER_NAME' created successfully."
}