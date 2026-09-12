module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # API auth mode, not the legacy aws-auth ConfigMap — access entries below
  # are the modern, Terraform-native way to grant cluster access.
  authentication_mode = "API_AND_CONFIG_MAP"

  cluster_endpoint_public_access = true

  enable_irsa = true

  # Karpenter's EC2NodeClass discovers this security group by tag, the
  # same karpenter.sh/discovery pattern already used for subnets in
  # models/vpc — Karpenter-provisioned nodes join the cluster through it.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  cluster_addons = {
    vpc-cni = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    bootstrap = {
      instance_types = [var.bootstrap_instance_type]
      min_size       = 1
      max_size       = 1
      desired_size   = 1

      labels = {
        role = "bootstrap"
      }

      # No taint here on purpose — this was tried and broke the cluster:
      # coredns and aws-ebs-csi-driver are core EKS addons that must run
      # somewhere, and this node is the only one that exists before
      # Karpenter itself is even running. They don't tolerate an arbitrary
      # custom taint, so with one applied both got stuck permanently
      # DEGRADED ("untolerated taint {node-role: bootstrap}") and timed
      # out. A stray small app pod occasionally landing here before
      # Karpenter scales up is a minor, harmless cost — nowhere near as bad
      # as core system addons being unable to schedule at all.
    }
  }

  access_entries = {
    for arn in var.admin_principal_arn : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
