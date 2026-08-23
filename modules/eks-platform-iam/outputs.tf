output "aws_load_balancer_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller"
  value       = try(module.aws_load_balancer_controller[0].role_arn, null)
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for external-dns"
  value       = try(module.external_dns[0].role_arn, null)
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for the cluster autoscaler"
  value       = try(module.cluster_autoscaler[0].role_arn, null)
}

output "external_secrets_role_arn" {
  description = "IRSA role ARN for External Secrets Operator"
  value       = try(module.external_secrets[0].role_arn, null)
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager"
  value       = try(module.cert_manager[0].role_arn, null)
}

output "role_arns" {
  description = "All platform controller role ARNs, keyed by controller name. Nulls are omitted."
  value = { for k, v in {
    "aws-load-balancer-controller" = try(module.aws_load_balancer_controller[0].role_arn, null)
    "external-dns"                 = try(module.external_dns[0].role_arn, null)
    "cluster-autoscaler"           = try(module.cluster_autoscaler[0].role_arn, null)
    "external-secrets"             = try(module.external_secrets[0].role_arn, null)
    "cert-manager"                 = try(module.cert_manager[0].role_arn, null)
  } : k => v if v != null }
}
