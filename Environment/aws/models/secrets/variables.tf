variable "path_prefix" {
  description = "e.g. \"splitwise/dev\" or \"splitwise/prod\" — matches the IRSA policy scope in models/iam-oidc."
  type        = string
}

variable "secret_names" {
  description = "Names under path_prefix, e.g. [\"kafka-credentials\", \"app-config\"]."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key these secrets are encrypted with (see envs/*/01-cluster's aws_kms_key.secrets). Required, not optional — a caller that wants the AWS-managed default back should say so explicitly rather than this module silently deciding on its behalf."
  type        = string
}

variable "secret_values" {
  description = "Optional real values to write, keyed by entries in secret_names — only creates an aws_secretsmanager_secret_version for keys present here; any name in secret_names left out just keeps its empty container. Never hardcode real values in .tf files: supply this via a gitignored terraform.tfvars or a TF_VAR_secret_values environment variable at apply time, so managing these stays portable across machines/operators instead of depending on anything local to one person's setup."
  type        = map(string)
  sensitive   = true
  default     = {}
}
