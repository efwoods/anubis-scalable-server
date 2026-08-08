output "acm_certificate_arn" {
  description = "Validated certificate ARN. Referenced by the ALB Ingress annotation."
  value       = aws_acm_certificate_validation.main.certificate_arn
}

output "hosted_zone_id" {
  description = "Route 53 hosted zone id, empty under Option B."
  value       = var.create_hosted_zone ? aws_route53_zone.main[0].zone_id : ""
}

output "name_servers" {
  description = "Name servers to set at the registrar under Option A."
  value       = var.create_hosted_zone ? aws_route53_zone.main[0].name_servers : []
}

output "acm_validation_records" {
  description = "Validation records to add manually under Option B (Cloudflare, DNS-only)."
  value = [
    for option in aws_acm_certificate.main.domain_validation_options : {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  ]
}

output "fully_qualified_hostnames" {
  description = "The hostnames this certificate covers."
  value       = local.subject_alternative_names
}
