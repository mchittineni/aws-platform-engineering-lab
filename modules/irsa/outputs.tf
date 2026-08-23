output "role_arn" {
  description = "IAM role ARN. Annotate the service account with eks.amazonaws.com/role-arn set to this value."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "IAM role name"
  value       = aws_iam_role.this.name
}

output "service_account_annotation" {
  description = "Ready to use service account annotation map"
  value       = { "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn }
}
