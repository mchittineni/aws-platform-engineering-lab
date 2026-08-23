# ---------------------------------------------------------------------------
# CloudTrail
#
# The management event trail is the record of who changed what. Without log
# file validation and a KMS key under our control, a trail is evidence that
# can be quietly edited.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cloudtrail" {
  #checkov:skip=CKV_AWS_338:Retention is a variable; the audit bucket is the durable copy
  count = var.enable_cloudtrail ? 1 : 0

  name              = "/aws/cloudtrail/${var.name_prefix}"
  retention_in_days = var.cloudtrail_cloudwatch_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = var.tags
}

# A second key, scoped to CloudWatch Logs. The audit key policy grants
# CloudTrail and Config; CloudWatch Logs needs its own encryption context
# condition, and mixing the two makes both grants harder to read.
resource "aws_kms_key" "logs" {
  description             = "Encrypts ${var.name_prefix} CloudWatch log groups created by the security baseline"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"
          }
        }
      },
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-logs" })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name_prefix}-security-logs"
  target_key_id = aws_kms_key.logs.key_id
}

data "aws_iam_policy_document" "cloudtrail_assume_role" {
  count = var.enable_cloudtrail ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  name               = "${var.name_prefix}-cloudtrail-to-cloudwatch"
  description        = "Lets CloudTrail deliver events to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume_role[0].json

  tags = var.tags
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  count = var.enable_cloudtrail ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  name   = "deliver-to-cloudwatch"
  role   = aws_iam_role.cloudtrail[0].id
  policy = data.aws_iam_policy_document.cloudtrail_logs[0].json
}

resource "aws_cloudtrail" "this" {
  # Findings reach SNS through EventBridge rules, which can filter by severity.
  # A trail SNS topic fires on log delivery, not on anything interesting.
  # CloudWatch Logs integration is configured below via cloud_watch_logs_group_arn.
  #checkov:skip=CKV_AWS_252:Alerting is via EventBridge, which can filter by severity
  #checkov:skip=CKV2_AWS_10:CloudWatch Logs integration is configured, count-indexed
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.audit.arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail[0].arn

  # Management events, plus object level access to the audit bucket itself so
  # reading or attempting to delete a record is recorded.
  advanced_event_selector {
    name = "management-events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "audit-bucket-data-events"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.audit.arn}/"]
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-trail" })

  depends_on = [aws_s3_bucket_policy.audit]
}

# ---------------------------------------------------------------------------
# Alarms on the events that matter
#
# GuardDuty and Security Hub are the broad net. These are the handful of
# events that should page somebody the moment they happen.
# ---------------------------------------------------------------------------

locals {
  cloudtrail_metric_filters = var.enable_cloudtrail && var.enable_cloudtrail_alarms ? {
    root_account_usage = {
      description = "Root credentials were used"
      pattern     = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      threshold   = 1
    }
    unauthorized_api_calls = {
      description = "A burst of AccessDenied or UnauthorizedOperation responses"
      pattern     = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"
      threshold   = 25
    }
    iam_policy_changes = {
      description = "An IAM policy, role or user was changed"
      pattern     = "{ ($.eventName = Delete*Policy) || ($.eventName = Create*Policy) || ($.eventName = Attach*Policy) || ($.eventName = Detach*Policy) || ($.eventName = Put*Policy) }"
      threshold   = 1
    }
    cloudtrail_configuration_changes = {
      description = "Somebody changed or stopped the trail"
      pattern     = "{ ($.eventName = CreateTrail) || ($.eventName = UpdateTrail) || ($.eventName = DeleteTrail) || ($.eventName = StopLogging) }"
      threshold   = 1
    }
    kms_key_deletion = {
      description = "A KMS key was scheduled for deletion or disabled"
      pattern     = "{ ($.eventSource = kms.amazonaws.com) && (($.eventName = DisableKey) || ($.eventName = ScheduleKeyDeletion)) }"
      threshold   = 1
    }
    security_group_changes = {
      description = "A security group rule was changed"
      pattern     = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupEgress) }"
      threshold   = 5
    }
  } : {}
}

resource "aws_cloudwatch_log_metric_filter" "this" {
  for_each = local.cloudtrail_metric_filters

  name           = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail[0].name
  pattern        = each.value.pattern

  metric_transformation {
    name          = "${var.name_prefix}-${each.key}"
    namespace     = var.security_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.cloudtrail_metric_filters

  alarm_name          = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  alarm_description   = each.value.description
  namespace           = var.security_metric_namespace
  metric_name         = "${var.name_prefix}-${each.key}"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_topic_arns
  ok_actions    = var.alarm_topic_arns

  tags = var.tags
}
