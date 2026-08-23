output "account_id" {
  description = "AWS account the backend and CI roles were created in"
  value       = data.aws_caller_identity.current.account_id
}

output "state_bucket_name" {
  description = "Terraform state bucket name. Put this in every backend.hcl."
  value       = module.state_backend.bucket_name
}

output "state_kms_key_arn" {
  description = "KMS key encrypting Terraform state"
  value       = module.state_backend.kms_key_arn
}

output "backend_hcl" {
  description = "Ready to paste backend.hcl contents"
  value       = <<-EOT
    bucket     = "${module.state_backend.bucket_name}"
    region     = "${var.region}"
    kms_key_id = "${module.state_backend.kms_key_arn}"
  EOT
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = module.github_oidc.oidc_provider_arn
}

output "ci_role_arns" {
  description = "CI role ARNs. Set these as the AWS_*_ROLE_ARN repository variables."
  value       = module.github_oidc.role_arns
}

# ---------------------------------------------------------------------------
# Security baseline
# ---------------------------------------------------------------------------

output "audit_bucket_name" {
  description = "Bucket holding CloudTrail and AWS Config records"
  value       = module.security_baseline.audit_bucket_name
}

output "cloudtrail_arn" {
  description = "Management event trail ARN"
  value       = module.security_baseline.cloudtrail_arn
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID"
  value       = module.security_baseline.guardduty_detector_id
}

output "security_alert_topic_arn" {
  description = "SNS topic receiving security alarms and GuardDuty findings"
  value       = aws_sns_topic.security_alerts.arn
}

output "config_rule_names" {
  description = "AWS Config rules enforcing the controls this repository claims"
  value       = module.security_baseline.config_rule_names
}

# ---------------------------------------------------------------------------
# Cost controls
# ---------------------------------------------------------------------------

output "cost_alert_topic_arn" {
  description = "SNS topic receiving budget and cost anomaly notifications"
  value       = module.cost_controls.topic_arn
}

output "budget_names" {
  description = "Budgets created for the account and each environment"
  value       = module.cost_controls.budget_names
}
