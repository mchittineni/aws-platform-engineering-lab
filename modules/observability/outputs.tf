output "topic_arn" {
  description = "SNS topic the alarms publish to"
  value       = try(aws_sns_topic.alerts[0].arn, null)
}

output "alarm_names" {
  description = "Every metric alarm created by this module"
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.api_server_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.nat_port_allocation_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.nat_packets_dropped : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.container_insights : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.audit : a.alarm_name],
  ))
}

output "composite_alarm_name" {
  description = "The single alarm on-call should subscribe to"
  value       = try(aws_cloudwatch_composite_alarm.platform_degraded[0].alarm_name, null)
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = try(aws_cloudwatch_dashboard.platform[0].dashboard_name, null)
}
