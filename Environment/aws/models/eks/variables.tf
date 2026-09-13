variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  description = "Verified live against AWS (aws eks describe-addon-versions) rather than assumed — EKS ships a new minor version roughly every ~3 months, so any hardcoded default here goes stale fast. Check current support status before relying on this default long-term; older versions eventually roll off standard support into a paid \"extended support\" tier."
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "admin_principal_arn" {
  description = "IAM principal (user or role ARN) granted cluster-admin via an EKS access entry — e.g. the terraform-bootstrap user for now, the github-actions-terraform role for CI."
  type        = list(string)
}

variable "bootstrap_instance_type" {
  description = "Single managed-node-group instance for system pods that must exist before Karpenter can run anything: coredns, kube-proxy, aws-node, ebs-csi, the Karpenter controller itself, Argo CD, aws-load-balancer-controller, external-secrets. None of these individually need much, but together they need somewhere to live that isn't Karpenter (Karpenter can't provision a node to run its own controller)."
  type        = string
  default     = "t3.large"
}
