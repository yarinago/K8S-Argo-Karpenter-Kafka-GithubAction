data "aws_route53_zone" "root" {
  name         = var.domain_name
  private_zone = false
}

# One wildcard cert covers both environments' subdomains
# (splitwise.<domain>, splitwise-dev.<domain>, grafana.<domain>,
# grafana-dev.<domain>, argocd.<domain>, argocd-dev.<domain>, ...) — a cert
# isn't a security boundary between dev and prod the way IAM/secrets are,
# so sharing one here is simpler with no real downside.
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  subject_alternative_names = [var.domain_name]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.root.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
