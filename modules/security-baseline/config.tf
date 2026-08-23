# ---------------------------------------------------------------------------
# AWS Config
#
# CloudTrail records the API call. Config records the resulting state, which
# is what answers "was this security group ever open?" months later.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "config_assume_role" {
  count = var.enable_config ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0

  name               = "${var.name_prefix}-config-recorder"
  description        = "Recording role for AWS Config"
  assume_role_policy = data.aws_iam_policy_document.config_assume_role[0].json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  count = var.enable_config ? 1 : 0

  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "config_delivery" {
  count = var.enable_config ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/config/AWSLogs/${local.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.audit.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.audit.arn]
  }
}

resource "aws_iam_role_policy" "config_delivery" {
  count = var.enable_config ? 1 : 0

  name   = "deliver-to-audit-bucket"
  role   = aws_iam_role.config[0].id
  policy = data.aws_iam_policy_document.config_delivery[0].json
}

resource "aws_config_configuration_recorder" "this" {
  count = var.enable_config ? 1 : 0

  name     = "${var.name_prefix}-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  count = var.enable_config ? 1 : 0

  name           = "${var.name_prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "config"
  s3_kms_key_arn = aws_kms_key.audit.arn

  snapshot_delivery_properties {
    delivery_frequency = var.config_snapshot_frequency
  }

  depends_on = [
    aws_config_configuration_recorder.this,
    aws_s3_bucket_policy.audit,
    aws_iam_role_policy.config_delivery,
  ]
}

# The recorder is created stopped. Nothing is recorded until this resource
# turns it on, and it cannot be turned on before the delivery channel exists.
resource "aws_config_configuration_recorder_status" "this" {
  # The recorder sets all_supported and include_global_resource_types.
  #checkov:skip=CKV2_AWS_45:The recorder records all supported resources
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

# ---------------------------------------------------------------------------
# Config rules
#
# A deliberately short list. Every rule here maps to a control this repository
# actually claims to enforce, so a NON_COMPLIANT result is a real regression
# rather than noise somebody learns to ignore.
# ---------------------------------------------------------------------------

locals {
  config_rules = var.enable_config ? {
    s3-bucket-public-read-prohibited   = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    s3-bucket-public-write-prohibited  = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
    s3-bucket-ssl-requests-only        = "S3_BUCKET_SSL_REQUESTS_ONLY"
    s3-bucket-versioning-enabled       = "S3_BUCKET_VERSIONING_ENABLED"
    encrypted-volumes                  = "ENCRYPTED_VOLUMES"
    ec2-imdsv2-check                   = "EC2_IMDSV2_CHECK"
    eks-endpoint-no-public-access      = "EKS_ENDPOINT_NO_PUBLIC_ACCESS"
    eks-secrets-encrypted              = "EKS_SECRETS_ENCRYPTED"
    ecr-private-image-scanning         = "ECR_PRIVATE_IMAGE_SCANNING_ENABLED"
    ecr-private-tag-immutability       = "ECR_PRIVATE_TAG_IMMUTABILITY_ENABLED"
    cloudtrail-enabled                 = "CLOUD_TRAIL_ENABLED"
    cloudtrail-encryption-enabled      = "CLOUD_TRAIL_ENCRYPTION_ENABLED"
    cloudtrail-log-validation          = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
    iam-user-mfa-enabled               = "IAM_USER_MFA_ENABLED"
    iam-root-access-key-check          = "IAM_ROOT_ACCESS_KEY_CHECK"
    kms-cmk-not-scheduled-for-deletion = "KMS_CMK_NOT_SCHEDULED_FOR_DELETION"
    vpc-default-security-group-closed  = "VPC_DEFAULT_SECURITY_GROUP_CLOSED"
    vpc-flow-logs-enabled              = "VPC_FLOW_LOGS_ENABLED"
  } : {}
}

resource "aws_config_config_rule" "this" {
  for_each = local.config_rules

  name = "${var.name_prefix}-${each.key}"

  source {
    owner             = "AWS"
    source_identifier = each.value
  }

  tags = var.tags

  depends_on = [aws_config_configuration_recorder_status.this]
}
