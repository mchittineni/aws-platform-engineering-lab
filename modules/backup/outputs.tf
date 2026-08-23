output "vault_name" {
  description = "Backup vault name"
  value       = aws_backup_vault.this.name
}

output "vault_arn" {
  description = "Backup vault ARN. Pass this as copy_destination_vault_arn from another region."
  value       = aws_backup_vault.this.arn
}

output "plan_id" {
  description = "Backup plan ID"
  value       = aws_backup_plan.this.id
}

output "plan_arn" {
  description = "Backup plan ARN"
  value       = aws_backup_plan.this.arn
}

output "kms_key_arn" {
  description = "KMS key encrypting the recovery points"
  value       = local.kms_key_arn
}

output "role_arn" {
  description = "Service role AWS Backup assumes"
  value       = aws_iam_role.backup.arn
}

output "notification_topic_arn" {
  description = "SNS topic receiving backup job events"
  value       = local.notification_topic_arn
}

output "selection_tags" {
  description = "Tags a resource must carry to be included in the plan"
  value       = var.selection_tags
}
