output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = local.provider_arn
}

output "role_arns" {
  description = "Role ARNs keyed by role name. Pass these to aws-actions/configure-aws-credentials as role-to-assume."
  value       = { for k, v in aws_iam_role.this : k => v.arn }
}
