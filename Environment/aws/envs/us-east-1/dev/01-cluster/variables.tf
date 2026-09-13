variable "splitwise_app_config" {
  description = "Real values for the Splitwise app's config + credentials on this environment, merged into one JSON blob stored as Secrets Manager's splitwise/dev/app-config. Supply via a gitignored terraform.tfvars or TF_VAR_splitwise_app_config at apply time — never commit real values, never hardcode them here. Left empty (default), only the empty Secrets Manager container is created; supplying this later and re-applying populates it. Keys must match exactly what the app repo's k8s/overlays/aws-dev/external-secret.yaml expects: SPLITWISE_GROUP_ID, SPLITWISE_MEMBERS, SPLITWISE_FIRST_MONTH, SPLITWISE_EXCLUDE_MONTHS, SPLITWISE_EXCLUDE_DESCRIPTIONS, SPLITWISE_REFRESH_SECONDS, SPLITWISE_DEBT_DIRECTION, SPLITWISE_PERSON_OWES_DIRECTION, SPLITWISE_RECENT_EXPENSES_LIMIT, SPLITWISE_TABLE_LIMIT, SPLITWISE_CLIENT_ID, SPLITWISE_CLIENT_SECRET, SPLITWISE_ACCESS_TOKEN_JSON."
  type        = map(string)
  sensitive   = true
  default     = {}
}
