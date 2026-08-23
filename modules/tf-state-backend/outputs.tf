output "bucket_name" {
  description = "State bucket name"
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "State bucket ARN"
  value       = aws_s3_bucket.state.arn
}

output "access_log_bucket_name" {
  description = "Bucket holding S3 server access logs for the state bucket"
  value       = try(aws_s3_bucket.access_logs[0].id, null)
}

output "kms_key_arn" {
  description = "KMS key encrypting the state bucket"
  value       = aws_kms_key.state.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB lock table name, when created"
  value       = try(aws_dynamodb_table.lock[0].name, null)
}

output "backend_configuration" {
  description = "Copy this into the backend block of an environment"
  value = {
    bucket       = aws_s3_bucket.state.id
    kms_key_id   = aws_kms_key.state.arn
    encrypt      = true
    use_lockfile = !var.enable_dynamodb_lock_table
  }
}
