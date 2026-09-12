variable "domain_name" {
  type    = string
  default = "splitwise.click"
}

variable "infra_repo_url" {
  type    = string
  default = "https://github.com/yarinago/K8S-Argo-Karpenter-Kafka-GithubAction.git"
}

variable "gitops_revision" {
  description = "Branch this environment's Argo CD root app tracks — prod follows main, matching the convention already used locally and in the Splitwise ApplicationSet."
  type        = string
  default     = "main"
}

variable "root_app_path" {
  description = "Path inside infra_repo_url the root Application points at. Doesn't exist yet as real content — see envs/us-east-1/prod/02-platform/README.md (same status applies here)."
  type        = string
  default     = "Environment/aws/argocd/apps/prod"
}

# Capacity profiles per Milestone 6's "at least two capacity profiles"
# requirement. Prod's general profile gets a bit more headroom than dev's
# (12/24Gi vs 8/16Gi) — see the AWS planning notes; batch stays the same
# size as dev since splitwise-loadgen's demo load doesn't scale by
# environment the way the general profile's steady-state traffic might.
variable "general_nodepool_cpu_limit" {
  type    = string
  default = "12"
}

variable "general_nodepool_memory_limit" {
  type    = string
  default = "24Gi"
}

variable "batch_nodepool_cpu_limit" {
  type    = string
  default = "4"
}

variable "batch_nodepool_memory_limit" {
  type    = string
  default = "8Gi"
}

# Chart versions intentionally left unpinned (null) — pin these once
# you've confirmed current versions rather than trust a hardcoded number
# that may not exist by apply time.
variable "karpenter_chart_version" {
  type    = string
  default = null
}

variable "alb_controller_chart_version" {
  type    = string
  default = null
}

variable "external_dns_chart_version" {
  type    = string
  default = null
}

variable "external_secrets_chart_version" {
  type    = string
  default = null
}

variable "argocd_chart_version" {
  type    = string
  default = null
}
