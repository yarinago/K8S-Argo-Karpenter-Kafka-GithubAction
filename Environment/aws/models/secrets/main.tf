# Creates the Secrets Manager containers. Values are optional — see
# secret_values in variables.tf — and when supplied, are managed as a
# real aws_secretsmanager_secret_version below. That's a deliberate
# tradeoff, not an oversight: managing values through Terraform means the
# resolved value ends up in Terraform state (mitigated by the state
# bucket being private/encrypted/versioned, not eliminated), in exchange
# for `terraform apply` being able to fully provision a working secret in
# one step rather than requiring a separate manual
# `aws secretsmanager put-secret-value` afterward.
#
# recovery_window_in_days = 0 is deliberate, not a security shortcut: this
# project destroys and recreates environments repeatedly for testing.
# Secrets Manager's default 7-30 day recovery window would block
# `terraform apply` from recreating a secret of the same name shortly after
# a destroy ("still scheduled for deletion") — exactly the failure mode a
# fast destroy/recreate loop would hit constantly.
resource "aws_secretsmanager_secret" "this" {
  for_each                = toset(var.secret_names)
  name                     = "${var.path_prefix}/${each.value}"
  recovery_window_in_days  = 0
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each      = var.secret_values
  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = each.value
}
