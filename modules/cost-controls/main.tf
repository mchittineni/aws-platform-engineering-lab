# ---------------------------------------------------------------------------
# Cost controls
#
# A Kubernetes platform can quietly triple its bill: an autoscaler that never
# scales down, a forgotten NAT gateway per zone, an ALB per Ingress. Budgets
# catch the slow drift, anomaly detection catches the step change.
#
# Budgets and Cost Anomaly Detection are global services that only answer in
# us-east-1, so this module is called with an aliased provider.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  notification_emails = var.notification_emails
}

# ---------------------------------------------------------------------------
# Notification topic
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Notification key
#
# The AWS managed alias/aws/sns key cannot be audited, rotated or revoked
# independently of the account, so the topic gets its own customer managed key.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "cost" {
  count = var.sns_kms_key_id == null ? 1 : 0

  description             = "Encrypts messages published to the ${var.name_prefix} cost alert topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cost_kms[0].json

  tags = merge(var.tags, { Name = "${var.name_prefix}-cost-alerts" })
}

resource "aws_kms_alias" "cost" {
  count = var.sns_kms_key_id == null ? 1 : 0

  name          = "alias/${var.name_prefix}-cost-alerts"
  target_key_id = aws_kms_key.cost[0].key_id
}

data "aws_iam_policy_document" "cost_kms" {
  count = var.sns_kms_key_id == null ? 1 : 0

  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  # Without this the publishing service can reach the topic but cannot
  # encrypt the message, and the publish fails with KMSAccessDenied.
  statement {
    sid       = "AllowPublishingServices"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

locals {
  cost_kms_key_id = var.sns_kms_key_id != null ? var.sns_kms_key_id : aws_kms_key.cost[0].arn
}

resource "aws_sns_topic" "cost" {
  count = var.create_sns_topic ? 1 : 0

  name              = "${var.name_prefix}-cost-alerts"
  kms_master_key_id = local.cost_kms_key_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-cost-alerts" })
}

data "aws_iam_policy_document" "cost_topic" {
  count = var.create_sns_topic ? 1 : 0

  statement {
    sid       = "AllowBudgetsAndAnomalyDetection"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.cost[0].arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "cost" {
  count = var.create_sns_topic ? 1 : 0

  arn    = aws_sns_topic.cost[0].arn
  policy = data.aws_iam_policy_document.cost_topic[0].json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = var.create_sns_topic ? toset(local.notification_emails) : toset([])

  topic_arn = aws_sns_topic.cost[0].arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  topic_arns = var.create_sns_topic ? concat([aws_sns_topic.cost[0].arn], var.additional_topic_arns) : var.additional_topic_arns
}

# ---------------------------------------------------------------------------
# Account budget
#
# Two thresholds on actual spend and one on the forecast. The forecast alarm
# is the one that gives you time to act.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "account" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit             = false
    include_refund             = false
    include_subscription       = true
    include_tax                = true
    include_upfront            = true
    include_recurring          = true
    include_other_subscription = true
    include_support            = true
    include_discount           = true
    use_amortized              = true
    use_blended                = false
  }

  dynamic "notification" {
    for_each = var.actual_spend_thresholds

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = local.topic_arns
      subscriber_email_addresses = local.notification_emails
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.forecast_threshold
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = local.topic_arns
    subscriber_email_addresses = local.notification_emails
  }
}

# ---------------------------------------------------------------------------
# Per environment budgets
#
# Scoped by the Environment tag every stack applies through default_tags, so
# a dev cluster left running over a weekend is visible on its own line.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "environment" {
  for_each = var.environment_budgets_usd

  name         = "${var.name_prefix}-${each.key}"
  budget_type  = "COST"
  limit_amount = tostring(each.value)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # The Budgets tag filter format is user:<TagKey>$<TagValue>, so the dollar
  # is a literal separator rather than an interpolation.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Environment$%s", each.key)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = local.topic_arns
    subscriber_email_addresses = local.notification_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.forecast_threshold
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = local.topic_arns
    subscriber_email_addresses = local.notification_emails
  }
}

# ---------------------------------------------------------------------------
# Cost anomaly detection
#
# Machine learning on the spend curve per service. Catches the "somebody
# enabled enhanced scanning on a 400 image registry" class of surprise that a
# monthly budget only reveals three weeks later.
# ---------------------------------------------------------------------------

resource "aws_ce_anomaly_monitor" "service" {
  count = var.enable_anomaly_detection ? 1 : 0

  name              = "${var.name_prefix}-per-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = var.tags
}

resource "aws_ce_anomaly_subscription" "service" {
  count = var.enable_anomaly_detection ? 1 : 0

  name      = "${var.name_prefix}-anomalies"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.service[0].arn]

  subscriber {
    type    = "SNS"
    address = local.topic_arns[0]
  }

  # Alert only when the anomaly is worth somebody's morning.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_impact_threshold_usd)]
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = length(local.topic_arns) > 0
      error_message = "enable_anomaly_detection needs a topic: either create_sns_topic must be true or additional_topic_arns must be set."
    }
  }

  depends_on = [aws_sns_topic_policy.cost]
}
