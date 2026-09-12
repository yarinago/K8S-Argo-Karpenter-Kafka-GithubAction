output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
