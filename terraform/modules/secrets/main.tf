# Secrets Manager secrets and the IRSA roles that let External Secrets Operator and the
# Stripe provisioning hook reach them.
#
# One secret per service, holding the entire environment as a single JSON object. The
# Anubis environment is roughly 200 variables (see anubis/.env.example); one secret per
# variable would mean 200 ExternalSecret resources and 200 Secrets Manager API calls per
# refresh, for no isolation benefit -- both tiers read the same environment anyway.
#
# Terraform creates the secrets EMPTY and never holds their values. Populate them per
# docs/runbook.md §1.2. `ignore_changes` on the version keeps a later `terraform apply`
# from reverting a value written by the runbook or by the Stripe provisioning hook.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name        = each.key
  description = each.value.description

  # Zero would delete immediately with no recovery. Seven days is the minimum window
  # that still allows an "undo" after a mistaken destroy.
  recovery_window_in_days = 7

  tags = merge(var.tags, { Name = each.key })
}

resource "aws_secretsmanager_secret_version" "placeholder" {
  for_each = aws_secretsmanager_secret.this

  secret_id     = each.value.id
  secret_string = jsonencode({ PLACEHOLDER = "populate via docs/runbook.md 1.2" })

  lifecycle {
    # The real values are written out of band. Terraform must not revert them.
    ignore_changes = [secret_string]
  }
}

# --------------------------------------------------------------------------------------
# External Secrets Operator
#
# One IRSA role for the ESO controller, scoped to exactly these secrets. ESO reads them
# and projects each into a Kubernetes Secret that the Deployments consume with envFrom.
# --------------------------------------------------------------------------------------

resource "aws_iam_role" "external_secrets" {
  name = "${var.name_prefix}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.external_secrets_namespace}:${var.external_secrets_service_account}"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "read-application-secrets"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [for secret in aws_secretsmanager_secret.this : secret.arn]
    }]
  })
}

# --------------------------------------------------------------------------------------
# Stripe provisioning hook
#
# The Helm pre-install/pre-upgrade hook runs provision_stripe_billing.py and writes the
# resulting billing config back into the Anubis secret, because pods cannot share the
# Docker volume the Compose stack uses for the same handoff. See runbook §4.
#
# This role is write-capable and therefore deliberately separate from the ESO role.
# --------------------------------------------------------------------------------------

resource "aws_iam_role" "stripe_provision" {
  count = var.stripe_provision_secret_name == "" ? 0 : 1

  name = "${var.name_prefix}-stripe-provision"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.application_namespace}:${var.stripe_provision_service_account}"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "stripe_provision" {
  count = var.stripe_provision_secret_name == "" ? 0 : 1

  name = "update-billing-config"
  role = aws_iam_role.stripe_provision[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret",
      ]
      Resource = [aws_secretsmanager_secret.this[var.stripe_provision_secret_name].arn]
    }]
  })
}
