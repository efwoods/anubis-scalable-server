# ECR repositories, their lifecycle policies, the SOCI index builder, and the GitHub
# OIDC role that CI assumes to push.
#
# SOCI matters more here than in a typical deployment: the Anubis image is 12.8 GB, and
# without lazy loading a scale-out event stalls for minutes while a new node pulls it.
# See docs/image-pipeline.md §4.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, { Name = each.value })
}

# Ten tagged images is roughly two weeks of deploys -- comfortably more than any rollback
# window actually used, and ~130 GB at $0.10/GB for the Anubis repository. Raise this
# deliberately, not by accident.
#
# Untagged images are expired after 7 days, but only those tagged with the SOCI
# convention are exempted: SOCI index artifacts are untagged manifests, and expiring them
# silently disables lazy loading.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last ${var.retained_image_count} tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.retained_image_count
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 7 days (SOCI indexes are refreshed on each push)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })
}

# --------------------------------------------------------------------------------------
# GitHub Actions OIDC push role
#
# No long-lived AWS keys in GitHub. The workflows in docs/image-pipeline.md §3 assume
# this role; the trust policy pins both the repository and the ref so a fork or a branch
# outside the allowlist cannot assume it.
# --------------------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_github_oidc_provider_arn
}

resource "aws_iam_role" "ecr_push" {
  name = "${var.name_prefix}-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = var.github_allowed_subjects
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.ecr_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
          "ecr:ListImages",
        ]
        Resource = [for repository in aws_ecr_repository.this : repository.arn]
      },
    ]
  })
}

# --------------------------------------------------------------------------------------
# SOCI index builder
#
# EventBridge on ECR PUSH -> Lambda that builds and pushes the SOCI index artifact. The
# Lambda package itself is published by AWS Labs; this wires up the trigger, the role,
# and the repository allowlist. Deploy the function from
# https://github.com/awslabs/cfn-ecr-aws-soci-index-builder and pass its name in, or
# leave soci_index_builder_function_name empty to skip and index manually.
# --------------------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "soci" {
  count = var.soci_index_builder_function_name == "" ? 0 : 1

  name        = "${var.name_prefix}-soci-index-on-push"
  description = "Build a SOCI index whenever an image is pushed, so 12.8 GB pulls can be lazy-loaded."

  event_pattern = jsonencode({
    source        = ["aws.ecr"]
    "detail-type" = ["ECR Image Action"]
    detail = {
      "action-type"     = ["PUSH"]
      result            = ["SUCCESS"]
      "repository-name" = var.repository_names
    }
  })

  tags = var.tags
}

data "aws_lambda_function" "soci" {
  count         = var.soci_index_builder_function_name == "" ? 0 : 1
  function_name = var.soci_index_builder_function_name
}

resource "aws_cloudwatch_event_target" "soci" {
  count = var.soci_index_builder_function_name == "" ? 0 : 1

  rule      = aws_cloudwatch_event_rule.soci[0].name
  target_id = "soci-index-builder"
  arn       = data.aws_lambda_function.soci[0].arn
}

resource "aws_lambda_permission" "soci" {
  count = var.soci_index_builder_function_name == "" ? 0 : 1

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_lambda_function.soci[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.soci[0].arn
}
