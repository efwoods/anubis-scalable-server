# Route 53 hosted zone (optional) and the ACM certificate the ALB terminates TLS with.
#
# Two supported paths, per docs/dns-cutover.md §1:
#
#   Option A -- create_hosted_zone = true. Terraform owns the zone, creates the ACM
#     validation records, and waits for issuance. The registrar's name servers must be
#     repointed at the outputs of this module. One authority for everything.
#
#   Option B -- create_hosted_zone = false. DNS stays at Cloudflare. Terraform creates
#     only the certificate and outputs the validation records to add by hand as
#     DNS-only (grey cloud) entries. The apply pauses at validation until they exist.
#
# Under Option B the two application records must also be DNS-only. Cloudflare's proxy
# buffers responses and enforces its own ~100 s timeout, which is incompatible with the
# /message SSE stream and the /mcp/relay WebSocket that the ALB carries a 3600 s idle
# timeout to support.

resource "aws_route53_zone" "main" {
  count = var.create_hosted_zone ? 1 : 0

  name    = var.domain_name
  comment = "Neural Nexus -- managed by anubis-scalable-server"

  tags = merge(var.tags, { Name = var.domain_name })
}

locals {
  subject_alternative_names = [for host in var.hostnames : "${host}.${var.domain_name}"]
  primary_domain            = local.subject_alternative_names[0]
}

resource "aws_acm_certificate" "main" {
  domain_name               = local.primary_domain
  subject_alternative_names = slice(local.subject_alternative_names, 1, length(local.subject_alternative_names))
  validation_method         = "DNS"

  tags = merge(var.tags, { Name = "${var.domain_name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = var.create_hosted_zone ? {
    for option in aws_acm_certificate.main.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  } : {}

  zone_id         = aws_route53_zone.main[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn

  # Under Option B there are no Terraform-managed validation records; the apply waits
  # here until the operator adds them at Cloudflare.
  validation_record_fqdns = var.create_hosted_zone ? [for record in aws_route53_record.validation : record.fqdn] : null

  timeouts {
    create = "60m"
  }
}

# --------------------------------------------------------------------------------------
# Application records
#
# Created only under Option A, and only once the ALB exists -- alb_dns_name and
# alb_zone_id come from the Ingress the AWS Load Balancer Controller provisions, so this
# is a second apply after the Helm releases are installed. Leave alb_dns_name empty on
# the first apply.
# --------------------------------------------------------------------------------------

resource "aws_route53_record" "application" {
  for_each = (var.create_hosted_zone && var.alb_dns_name != "") ? toset(var.hostnames) : toset([])

  zone_id = aws_route53_zone.main[0].zone_id
  name    = "${each.value}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
