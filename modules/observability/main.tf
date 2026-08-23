# ---------------------------------------------------------------------------
# Platform observability
#
# Prometheus and Grafana run inside the cluster, which is exactly why they
# cannot be the whole answer: they go down with it. These alarms live in
# CloudWatch and watch the things that break underneath Kubernetes — the
# control plane, NAT egress, node health — so an outage still reaches somebody.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Supplied by the caller so that Terraform knows the log group exists before
  # a metric filter is created against it. Deriving the name from the cluster
  # name instead builds no dependency edge, and the first apply then races the
  # eks module.
  cluster_log_group = coalesce(var.cluster_log_group_name, "/aws/eks/${var.cluster_name}/cluster")
}

# ---------------------------------------------------------------------------
# Alert routing
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Notification key
#
# The AWS managed alias/aws/sns key cannot be audited, rotated or revoked
# independently of the account, so the topic gets its own customer managed key.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "alerts" {
  count = var.sns_kms_key_id == null ? 1 : 0

  description             = "Encrypts messages published to the ${var.cluster_name} platform alert topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.alerts_kms[0].json

  tags = merge(var.tags, { Name = "${var.cluster_name}-platform-alerts" })
}

resource "aws_kms_alias" "alerts" {
  count = var.sns_kms_key_id == null ? 1 : 0

  name          = "alias/${var.cluster_name}-platform-alerts"
  target_key_id = aws_kms_key.alerts[0].key_id
}

data "aws_iam_policy_document" "alerts_kms" {
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
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

locals {
  alerts_kms_key_id = var.sns_kms_key_id != null ? var.sns_kms_key_id : aws_kms_key.alerts[0].arn
}

resource "aws_sns_topic" "alerts" {
  count = var.create_sns_topic ? 1 : 0

  name              = "${var.cluster_name}-platform-alerts"
  kms_master_key_id = local.alerts_kms_key_id

  tags = merge(var.tags, { Name = "${var.cluster_name}-platform-alerts" })
}

data "aws_iam_policy_document" "alerts" {
  count = var.create_sns_topic ? 1 : 0

  statement {
    sid       = "AllowCloudWatchAlarms"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts[0].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  count = var.create_sns_topic ? 1 : 0

  arn    = aws_sns_topic.alerts[0].arn
  policy = data.aws_iam_policy_document.alerts[0].json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = var.create_sns_topic ? toset(var.notification_emails) : toset([])

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  alarm_actions = concat(
    var.create_sns_topic ? [aws_sns_topic.alerts[0].arn] : [],
    var.additional_topic_arns,
  )
}

# ---------------------------------------------------------------------------
# Control plane
#
# EKS publishes request metrics for the managed API server. A sustained
# failure rate here means kubectl, the controllers and the autoscaler are all
# degraded at once.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_server_errors" {
  count = var.enable_control_plane_alarms ? 1 : 0

  alarm_name        = "${var.cluster_name}-api-server-5xx"
  alarm_description = "The EKS API server is returning server side errors"

  namespace   = "AWS/EKS"
  metric_name = "cluster_failed_request_count"
  dimensions  = { ClusterName = var.cluster_name }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.api_server_error_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

# ---------------------------------------------------------------------------
# NAT gateway
#
# ErrorPortAllocation is the alarm nobody sets until the first time it fires.
# A NAT gateway runs out of source ports at roughly 55,000 concurrent
# connections to a single destination, and the symptom inside the cluster is
# random connection timeouts that look like an application bug.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "nat_port_allocation_errors" {
  for_each = var.enable_nat_alarms ? toset(var.nat_gateway_ids) : toset([])

  alarm_name        = "${var.cluster_name}-nat-${each.value}-port-allocation-errors"
  alarm_description = "NAT gateway ${each.value} could not allocate a source port. Egress connections are being dropped."

  namespace   = "AWS/NATGateway"
  metric_name = "ErrorPortAllocation"
  dimensions  = { NatGatewayId = each.value }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "nat_packets_dropped" {
  for_each = var.enable_nat_alarms ? toset(var.nat_gateway_ids) : toset([])

  alarm_name        = "${var.cluster_name}-nat-${each.value}-packets-dropped"
  alarm_description = "NAT gateway ${each.value} is dropping packets"

  namespace   = "AWS/NATGateway"
  metric_name = "PacketsDropCount"
  dimensions  = { NatGatewayId = each.value }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.nat_packet_drop_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Node and pod health
#
# These metrics only exist once Container Insights is collecting them, which
# needs the amazon-cloudwatch-observability add-on in the cluster. Enabling
# the alarms without the agent produces alarms stuck in INSUFFICIENT_DATA,
# so they are gated on their own flag.
# ---------------------------------------------------------------------------

locals {
  container_insights_alarms = var.enable_container_insights_alarms ? {
    failed_nodes = {
      metric_name         = "cluster_failed_node_count"
      description         = "One or more nodes are NotReady"
      statistic           = "Maximum"
      threshold           = 0
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
    }
    node_cpu = {
      metric_name         = "node_cpu_utilization"
      description         = "Node CPU utilisation is sustained high enough that scheduling will start failing"
      statistic           = "Average"
      threshold           = var.node_cpu_threshold
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
    }
    node_memory = {
      metric_name         = "node_memory_utilization"
      description         = "Node memory utilisation is high enough to risk kubelet eviction"
      statistic           = "Average"
      threshold           = var.node_memory_threshold
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 3
    }
    node_filesystem = {
      metric_name         = "node_filesystem_utilization"
      description         = "Node disk utilisation is approaching the kubelet image garbage collection threshold"
      statistic           = "Average"
      threshold           = var.node_disk_threshold
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
    }
  } : {}
}

resource "aws_cloudwatch_metric_alarm" "container_insights" {
  for_each = local.container_insights_alarms

  alarm_name        = "${var.cluster_name}-${replace(each.key, "_", "-")}"
  alarm_description = each.value.description

  namespace   = "ContainerInsights"
  metric_name = each.value.metric_name
  dimensions  = { ClusterName = var.cluster_name }

  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.evaluation_periods
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison_operator
  treat_missing_data  = "missing"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Audit log detections
#
# The control plane audit log is already being shipped to CloudWatch by the
# eks module. These filters turn it into three specific questions rather than
# a log nobody reads.
# ---------------------------------------------------------------------------

locals {
  audit_filters = var.enable_audit_log_alarms ? {
    anonymous_api_access = {
      description = "The API server served a request for system:anonymous"
      pattern     = "{ ($.user.username = \"system:anonymous\") && ($.responseStatus.code < 400) }"
      threshold   = 1
    }
    forbidden_responses = {
      description = "A burst of 403 responses, which is what a probing credential looks like"
      pattern     = "{ $.responseStatus.code = 403 }"
      threshold   = var.forbidden_response_threshold
    }
    exec_into_pod = {
      description = "Somebody opened a shell in a running pod"
      pattern     = "{ ($.objectRef.subresource = \"exec\") && ($.verb = \"create\") }"
      threshold   = 1
    }
    secret_enumeration = {
      description = "A principal listed Secrets across namespaces"
      pattern     = "{ ($.objectRef.resource = \"secrets\") && ($.verb = \"list\") && ($.responseStatus.code = 200) }"
      threshold   = var.secret_list_threshold
    }
  } : {}
}

resource "aws_cloudwatch_log_metric_filter" "audit" {
  for_each = local.audit_filters

  name           = "${var.cluster_name}-${replace(each.key, "_", "-")}"
  log_group_name = local.cluster_log_group
  pattern        = each.value.pattern

  metric_transformation {
    name          = "${var.cluster_name}-${each.key}"
    namespace     = var.audit_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "audit" {
  for_each = local.audit_filters

  alarm_name        = "${var.cluster_name}-audit-${replace(each.key, "_", "-")}"
  alarm_description = each.value.description

  namespace   = var.audit_metric_namespace
  metric_name = "${var.cluster_name}-${each.key}"

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = var.tags

  depends_on = [aws_cloudwatch_log_metric_filter.audit]
}

# ---------------------------------------------------------------------------
# One alarm to page on
#
# A composite alarm so on-call has a single subscription that means "the
# platform is degraded", instead of twelve independent pagers.
# ---------------------------------------------------------------------------

locals {
  paging_alarm_names = concat(
    var.enable_control_plane_alarms ? [aws_cloudwatch_metric_alarm.api_server_errors[0].alarm_name] : [],
    [for a in aws_cloudwatch_metric_alarm.nat_port_allocation_errors : a.alarm_name],
    [for k, a in aws_cloudwatch_metric_alarm.container_insights : a.alarm_name if k == "failed_nodes"],
  )
}

resource "aws_cloudwatch_composite_alarm" "platform_degraded" {
  count = var.enable_composite_alarm && length(local.paging_alarm_names) > 0 ? 1 : 0

  alarm_name        = "${var.cluster_name}-platform-degraded"
  alarm_description = "At least one component the cluster depends on is unhealthy. Start at docs/operations.md."

  alarm_rule = join(" OR ", [for name in local.paging_alarm_names : "ALARM(\"${name}\")"])

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}
