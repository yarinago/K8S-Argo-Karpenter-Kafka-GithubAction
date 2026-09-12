variable "domain_name" {
  type    = string
  default = "splitwise.click"
}

variable "infra_repo_url" {
  type    = string
  default = "https://github.com/yarinago/K8S-Argo-Karpenter-Kafka-GithubAction.git"
}

variable "gitops_revision" {
  description = "Branch this environment's Argo CD root app tracks — dev follows develop, matching the convention already used locally and in the Splitwise ApplicationSet."
  type        = string
  default     = "develop"
}

variable "root_app_path" {
  description = "Path inside infra_repo_url the root Application points at. Doesn't exist yet as real content — see envs/us-east-1/dev/02-platform/README.md."
  type        = string
  default     = "Environment/aws/argocd/apps/dev"
}

# Capacity profiles per Milestone 6's "at least two capacity profiles"
# requirement: general (everyday workloads) and batch (compute-heavy,
# sized for splitwise-loadgen). Sizing derived from the local environment's
# measured combined footprint (~10.7GB for a full dev+prod+Kafka+
# monitoring stack) — see the AWS planning notes; these are starting
# guardrails against runaway spend, not tuned limits.
variable "general_nodepool_cpu_limit" {
  type    = string
  default = "8"
}

variable "general_nodepool_memory_limit" {
  type    = string
  default = "16Gi"
}

variable "batch_nodepool_cpu_limit" {
  type    = string
  default = "4"
}

variable "batch_nodepool_memory_limit" {
  type    = string
  default = "8Gi"
}

# Chart versions intentionally left unpinned (null) below rather than
# guessed — pin these once you've confirmed current versions
# (helm search repo / the chart's own release page) rather than trust a
# hardcoded number that may not exist by apply time.
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
