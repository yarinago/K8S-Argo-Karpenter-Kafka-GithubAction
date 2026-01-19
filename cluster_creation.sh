#!/bin/bash

# Install k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d version

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client

# The recommended way to create a k3d cluster for GitOps HA setup is using 3 servers and 3 agents.
# However, for local development and testing purposes, we will create a cluster with 3 server and 2 agents.
k3d cluster create gitops-ha \
  --servers 3 \
  --agents 2 \
  --image rancher/k3s:v1.34.3-k3s1 \
  --api-port 127.0.0.1:6445 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:*" \
  --k3s-arg "--disable=servicelb@server:*" \
  --k3s-arg "--disable=metrics-server@server:*" \
  --k3s-arg "--secrets-encryption@server:*" \
  --k3s-arg "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule@server:*"