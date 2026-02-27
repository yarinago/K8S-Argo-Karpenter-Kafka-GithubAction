# GitOps Event Platform on Kubernetes (Kafka + Argo CD + Karpenter + Observability + GitHub Actions)

## Prerequisite 
* Linux terminal
* `sudo` command - to install `helm` command

## How to Run
Provide execute commands to the script
```sh
chmod +x Environment/local/cluster_creation.sh
```

Execute the script
```sh
./Environment/local/cluster_creation.sh

# You could also change all/some of the default values set in the script like this
CLUSTER_NAME=[SET_CLUSTER_NAME] \
SERVERS=[SET_SERVERS_AMOUNT] \
AGENTS=[SET_AGENTS_AMOUNT] \
K3S_IMAGE=[SET_IMAGE] \
RECREATE=[SET_TRUE] \
./Environment/local/cluster_creation.sh
```

### Commands to help manage the cluster in local configuration
```sh
k3d cluster stop gitops-ha  # stop the cluster
k3d cluster start gitops-ha # start it again after being stopped
k3d cluster delete gitops-ha # remove all resources of the cluster 
```

## Architecture Decision Records
### Why k3d:
In the local infrasturcure, due to CPU and Memory constrains, I wanted to use a a light know alternative to k8s without hinder the gain in understanding k8s.
I choose that specific rancher image since it was the latest stable image. <br />
The recommended way to create a k3d cluster for GitOps HA setup is using 3 servers and 3 agents. Because of CPU and Memory constrains in my local machine, I have decided to create a cluster with 3 servers and 2 agents.