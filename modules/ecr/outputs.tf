output "repository_urls" {
  description = "Repository URLs keyed by the input repository name"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Repository ARNs keyed by the input repository name"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

output "kms_key_arn" {
  description = "KMS key encrypting the repositories"
  value       = local.kms_key_arn
}
