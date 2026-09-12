variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "node_iam_role_arn" {
  description = "The bootstrap/Karpenter node IAM role ARN — Karpenter's controller needs iam:PassRole on this to launch nodes with it."
  type        = string
}

variable "secrets_path_prefix" {
  description = "Secrets Manager path prefix this cluster's External Secrets Operator may read, e.g. \"splitwise/dev/\". Scoped per-cluster on purpose — the dev cluster's role cannot resolve to a prod ARN and vice versa."
  type        = string
}

variable "hosted_zone_arn" {
  description = "The Route53 hosted zone ARN external-dns is allowed to modify (from global/dns's hosted_zone_id output, arn:aws:route53:::hostedzone/<id>)."
  type        = string
}
