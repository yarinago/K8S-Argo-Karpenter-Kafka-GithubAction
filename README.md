chmod +x cluster_creation.sh

k3d cluster stop gitops-ha

k3d cluster start gitops-ha

k3d cluster delete gitops-ha
