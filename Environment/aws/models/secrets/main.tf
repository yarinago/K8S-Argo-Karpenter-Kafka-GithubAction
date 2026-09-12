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

# for_each can't take var.secret_values directly: Terraform hard-blocks a
# sensitive-marked value as a for_each set, since resource instance keys
# aren't redacted in plan/state output the way values are — and the whole
# variable's sensitivity taints everything derived from it, keys() included,
# even though the keys themselves (just secret names like "app-config") are
# not sensitive at all. nonsensitive() strips that taint from the key set
# only; secret_string below still reads the real value straight out of the
# still-sensitive var.secret_values, so the actual credential material
# stays fully tracked as sensitive throughout.
resource "aws_secretsmanager_secret_version" "this" {
  for_each      = toset(nonsensitive(keys(var.secret_values)))
  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = var.secret_values[each.key]
}
