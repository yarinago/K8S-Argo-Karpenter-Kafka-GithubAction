variable "role_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  description = "Without the leading https://, e.g. \"oidc.eks.us-east-1.amazonaws.com/id/XXXX\"."
  type        = string
}

variable "namespace" {
  type = string
}

variable "service_account" {
  type = string
}

variable "policy_json" {
  description = "IAM policy document JSON to attach. Required (not optional) — an optional/null variant was tried and removed: it makes the aws_iam_role_policy resource's `count` depend on a value that's unknown at plan time whenever the policy JSON references another resource being created in the same apply (e.g. karpenter_irsa's policy references module.karpenter's not-yet-created role ARN), which Terraform can't evaluate (\"Invalid count argument\"). Every actual caller in this codebase always passes a real policy, so this is a required argument, not a conditional."
  type        = string
}
