output "region" {
  description = "AWS region this environment lives in"
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Egress IP addresses of the cluster, one per availability zone"
  value       = module.vpc.nat_gateway_public_ips
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "platform_controller_role_arns" {
  description = "IRSA role ARNs to annotate the platform controller service accounts with"
  value       = module.platform_iam.role_arns
}

output "ebs_kms_key_arn" {
  description = "KMS key for EBS volumes, referenced by the gp3 StorageClass"
  value       = module.eks.ebs_kms_key_arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.ecr.repository_urls
}

output "kubeconfig_command" {
  description = "Command that adds this cluster to the local kubeconfig"
  value       = module.eks.kubeconfig_command
}

output "alert_topic_arn" {
  description = "SNS topic the platform alarms publish to"
  value       = module.observability.topic_arn
}

output "platform_degraded_alarm" {
  description = "The single composite alarm covering the paging-worthy conditions"
  value       = module.observability.composite_alarm_name
}

output "platform_dashboard_name" {
  description = "CloudWatch dashboard giving the first sixty seconds of an incident"
  value       = module.observability.dashboard_name
}

output "backup_vault_name" {
  description = "AWS Backup vault used to rehearse the restore procedure"
  value       = module.backup.vault_name
}
