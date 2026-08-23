output "topic_arn" {
  description = "SNS topic budgets and anomaly detection publish to"
  value       = try(aws_sns_topic.cost[0].arn, null)
}

output "budget_names" {
  description = "Budget names created by this module"
  value = sort(concat(
    [for b in aws_budgets_budget.account : b.name],
    [for b in aws_budgets_budget.environment : b.name],
  ))
}

output "anomaly_monitor_arn" {
  description = "Cost Anomaly Detection monitor ARN"
  value       = try(aws_ce_anomaly_monitor.service[0].arn, null)
}
