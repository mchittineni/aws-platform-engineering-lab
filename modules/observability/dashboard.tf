# ---------------------------------------------------------------------------
# Dashboard
#
# Deliberately small. The purpose is the first sixty seconds of an incident:
# is the control plane answering, are nodes leaving, is egress saturated. The
# deep dive happens in Grafana.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "platform" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "${var.cluster_name}-platform"

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 2
          properties = {
            markdown = join("\n", [
              "# ${var.cluster_name}",
              "Control plane, egress and node health. Application and Kubernetes internals live in Grafana.",
              "Runbook: `docs/operations.md` — incident response: `docs/disaster-recovery.md`",
            ])
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "API server requests"
            region = local.region
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              ["AWS/EKS", "cluster_request_total", "ClusterName", var.cluster_name, { label = "Total" }],
              ["AWS/EKS", "cluster_failed_request_count", "ClusterName", var.cluster_name, { label = "Failed" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "NAT gateway egress"
            region = local.region
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = length(var.nat_gateway_ids) > 0 ? [
              for id in var.nat_gateway_ids :
              ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", id, { label = id }]
            ] : [["AWS/NATGateway", "BytesOutToDestination"]]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "NAT port allocation errors and dropped packets"
            region = local.region
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = length(var.nat_gateway_ids) > 0 ? flatten([
              for id in var.nat_gateway_ids : [
                ["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", id, { label = "${id} port errors" }],
                ["AWS/NATGateway", "PacketsDropCount", "NatGatewayId", id, { label = "${id} drops" }],
              ]
            ]) : [["AWS/NATGateway", "ErrorPortAllocation"]]
          }
        },
      ],
      var.enable_container_insights_alarms ? [
        {
          type   = "metric"
          x      = 12
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "Node health"
            region = local.region
            view   = "timeSeries"
            period = 300
            metrics = [
              ["ContainerInsights", "cluster_failed_node_count", "ClusterName", var.cluster_name, { stat = "Maximum", label = "NotReady nodes" }],
              ["ContainerInsights", "cluster_node_count", "ClusterName", var.cluster_name, { stat = "Maximum", label = "Nodes" }],
              ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name, { stat = "Average", label = "CPU %" }],
              ["ContainerInsights", "node_memory_utilization", "ClusterName", var.cluster_name, { stat = "Average", label = "Memory %" }],
            ]
          }
        },
      ] : [],
      var.enable_audit_log_alarms ? [
        {
          type   = "metric"
          x      = 0
          y      = 14
          width  = 24
          height = 6
          properties = {
            title  = "Audit log detections"
            region = local.region
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              for k in keys(local.audit_filters) :
              [var.audit_metric_namespace, "${var.cluster_name}-${k}", { label = replace(k, "_", " ") }]
            ]
          }
        },
      ] : [],
    )
  })
}
