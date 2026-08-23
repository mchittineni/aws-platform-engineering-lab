locals {
  repositories = { for name in var.repositories : name => "${var.name_prefix}${name}" }

  create_kms_key = var.kms_key_arn == null
  kms_key_arn    = local.create_kms_key ? aws_kms_key.ecr[0].arn : var.kms_key_arn
}

resource "aws_kms_key" "ecr" {
  #checkov:skip=CKV2_AWS_64:Access is governed by IAM; default key policy is deliberate
  count = local.create_kms_key ? 1 : 0

  description             = "Encrypts container images in ECR"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = "ecr" })
}

resource "aws_kms_alias" "ecr" {
  count = local.create_kms_key ? 1 : 0

  name          = "alias/${var.name_prefix == "" ? "ecr" : trimsuffix(var.name_prefix, "/")}"
  target_key_id = aws_kms_key.ecr[0].key_id
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name                 = each.value
  image_tag_mutability = var.image_tag_mutability
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = local.kms_key_arn
  }

  tags = merge(var.tags, { Name = each.value })
}

# ---------------------------------------------------------------------------
# Lifecycle policy
#
# Untagged layers accumulate on every rebuild, and old release images are the
# single largest ECR cost line in a busy repository.
# ---------------------------------------------------------------------------

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain the most recent ${var.max_tagged_images} release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.release_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.max_tagged_images
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after ${var.untagged_image_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiry_days
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Repository policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "pull" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each = length(var.pull_principal_arns) > 0 ? aws_ecr_repository.this : {}

  repository = each.value.name
  policy     = data.aws_iam_policy_document.pull[0].json
}

# ---------------------------------------------------------------------------
# Registry wide scanning configuration
# ---------------------------------------------------------------------------

resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.enable_registry_enhanced_scanning ? 1 : 0

  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}
