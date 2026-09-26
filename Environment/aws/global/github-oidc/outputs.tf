output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_terraform.arn
  description = "Set this as the AWS_ROLE_ARN repo variable/secret for the Terraform CI workflows."
}
