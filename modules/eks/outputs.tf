output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane"
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group created and managed by EKS for control plane to node traffic"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "additional_security_group_id" {
  description = "Additional security group attached to the control plane ENIs"
  value       = aws_security_group.cluster.id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN, required to build IRSA trust policies"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL without the scheme"
  value       = local.oidc_issuer_host
}

output "cluster_iam_role_arn" {
  description = "Control plane IAM role ARN"
  value       = aws_iam_role.cluster.arn
}

output "node_iam_role_arn" {
  description = "Node group instance IAM role ARN"
  value       = aws_iam_role.node.arn
}

output "node_iam_role_name" {
  description = "Node group instance IAM role name"
  value       = aws_iam_role.node.name
}

output "node_groups" {
  description = "Managed node group names keyed by node group key"
  value       = { for k, v in aws_eks_node_group.this : k => v.node_group_name }
}

output "secrets_kms_key_arn" {
  description = "KMS key used for Kubernetes Secret envelope encryption"
  value       = aws_kms_key.secrets.arn
}

output "ebs_kms_key_arn" {
  description = "KMS key used to encrypt EBS volumes provisioned by the CSI driver"
  value       = try(aws_kms_key.ebs[0].arn, null)
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster"
  value       = "aws eks update-kubeconfig --region ${data.aws_region.current.region} --name ${aws_eks_cluster.this.name}"
}

output "cluster_log_group_name" {
  description = "CloudWatch log group holding the control plane logs. Pass this to modules/observability so its metric filters cannot be created before the log group exists."
  value       = aws_cloudwatch_log_group.cluster.name
}
