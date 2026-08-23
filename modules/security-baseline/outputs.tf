output "audit_bucket_name" {
  description = "Bucket holding CloudTrail and AWS Config records"
  value       = aws_s3_bucket.audit.id
}

output "audit_bucket_arn" {
  description = "ARN of the audit bucket"
  value       = aws_s3_bucket.audit.arn
}

output "audit_kms_key_arn" {
  description = "KMS key encrypting the audit records"
  value       = aws_kms_key.audit.arn
}

output "cloudtrail_arn" {
  description = "ARN of the management event trail"
  value       = try(aws_cloudtrail.this[0].arn, null)
}

output "cloudtrail_log_group_name" {
  description = "CloudWatch log group the trail is mirrored into, and the source of the security alarms"
  value       = try(aws_cloudwatch_log_group.cloudtrail[0].name, null)
}

output "security_log_kms_key_arn" {
  description = "KMS key encrypting the CloudWatch log groups created here"
  value       = aws_kms_key.logs.arn
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID"
  value       = try(aws_guardduty_detector.this[0].id, null)
}

output "config_recorder_name" {
  description = "AWS Config recorder name"
  value       = try(aws_config_configuration_recorder.this[0].name, null)
}

output "config_rule_names" {
  description = "Config rule names created by this module"
  value       = sort([for r in aws_config_config_rule.this : r.name])
}

output "security_alarm_names" {
  description = "CloudWatch alarm names created from the CloudTrail metric filters"
  value       = sort([for a in aws_cloudwatch_metric_alarm.this : a.alarm_name])
}
