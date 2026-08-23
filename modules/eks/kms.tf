# ---------------------------------------------------------------------------
# Envelope encryption key for Kubernetes Secrets
#
# Without this, Secrets are only encrypted with the EKS managed key. With it,
# etcd Secret material is encrypted by a customer managed key that can be
# audited and revoked independently of the cluster.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_iam_policy_document" "secrets_kms" {
  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowEksControlPlane"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "secrets" {
  description             = "Envelope encryption key for ${var.cluster_name} Kubernetes Secrets"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.secrets_kms.json

  tags = merge(var.tags, { Name = "${var.cluster_name}-secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ---------------------------------------------------------------------------
# Control plane log encryption
# ---------------------------------------------------------------------------

resource "aws_kms_key" "logs" {
  description             = "Encrypts ${var.cluster_name} control plane logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/cluster"
          }
        }
      },
    ]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-logs" })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.cluster_name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}
