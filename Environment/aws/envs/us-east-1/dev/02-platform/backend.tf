terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket       = "splitwise-tfstate-398915901412"
    key          = "envs/us-east-1/dev/02-platform/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# This stage needs a live cluster to point the Kubernetes/Helm/kubectl
# providers at — that's why it's a separate root from 01-cluster rather
# than one flat apply: Terraform can't configure a provider against a
# cluster that doesn't exist yet in the same plan. Reading 01-cluster's
# state here (rather than re-declaring cluster_name etc. as variables)
# means this root can never drift out of sync with what 01-cluster
# actually created.
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "splitwise-tfstate-398915901412"
    key    = "envs/us-east-1/dev/01-cluster/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  cluster_name     = data.terraform_remote_state.cluster.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca       = data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data
}

# `exec`-based auth (not a static token) — spawns the AWS CLI fresh for
# each API call rather than embedding one short-lived token at provider
# configuration time. Requires the AWS CLI to be on PATH wherever this is
# applied from (already true here — see the WSL2 setup earlier).
locals {
  eks_auth_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "us-east-1"]
  }
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  exec {
    api_version = local.eks_auth_exec.api_version
    command     = local.eks_auth_exec.command
    args        = local.eks_auth_exec.args
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca)
    exec {
      api_version = local.eks_auth_exec.api_version
      command     = local.eks_auth_exec.command
      args        = local.eks_auth_exec.args
    }
  }
}

provider "kubectl" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  load_config_file       = false
  exec {
    api_version = local.eks_auth_exec.api_version
    command     = local.eks_auth_exec.command
    args        = local.eks_auth_exec.args
  }
}
