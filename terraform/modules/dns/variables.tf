variable "domain_name" {
  description = "Apex domain, e.g. neuralnexus.site."
  type        = string
}

variable "hostnames" {
  description = "Subdomain labels served by the ALB. The first becomes the certificate's primary domain."
  type        = list(string)
  default     = ["api", "checkout-api"]
}

variable "create_hosted_zone" {
  description = "Create a Route 53 hosted zone and manage records here (Option A). False keeps DNS at Cloudflare and only issues the certificate (Option B) -- see docs/dns-cutover.md."
  type        = bool
  default     = true
}

variable "alb_dns_name" {
  description = "ALB hostname from the Ingress status. Empty on the first apply, before the Helm releases exist; set it on a second apply to create the alias records."
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = "Hosted zone id of the ALB, needed for an alias record."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
