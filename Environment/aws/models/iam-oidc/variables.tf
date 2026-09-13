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

variable "secrets_kms_key_arn" {
  description = "The customer-managed KMS key the secrets above are encrypted with (envs/*/01-cluster's aws_kms_key.secrets). Unlike the AWS-managed default key, a customer-managed key doesn't implicitly grant decrypt access to anyone with secretsmanager:GetSecretValue -- external-secrets needs kms:Decrypt on this exact key explicitly, or ExternalSecret syncs start failing with AccessDenied despite the Secrets Manager permissions alone being correct."
  type        = string
}

variable "hosted_zone_arn" {
  description = "The Route53 hosted zone ARN external-dns is allowed to modify (from global/dns's hosted_zone_id output, arn:aws:route53:::hostedzone/<id>)."
  type        = string
}
