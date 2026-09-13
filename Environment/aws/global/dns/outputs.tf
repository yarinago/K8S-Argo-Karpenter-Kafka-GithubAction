output "hosted_zone_id" {
  value = data.aws_route53_zone.root.zone_id
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.wildcard.certificate_arn
}
