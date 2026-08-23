variable "cluster_name" {
  description = "EKS cluster name. Used for role naming and to scope autoscaling permissions."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN of the cluster"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL of the cluster, without the https:// scheme"
  type        = string
}

variable "enable_aws_load_balancer_controller" {
  description = "Create the IRSA role for the AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "enable_external_dns" {
  description = "Create the IRSA role for external-dns"
  type        = bool
  default     = false
}

variable "enable_cluster_autoscaler" {
  description = "Create the IRSA role for the Kubernetes cluster autoscaler"
  type        = bool
  default     = true
}

variable "enable_external_secrets" {
  description = "Create the IRSA role for External Secrets Operator"
  type        = bool
  default     = false
}

variable "enable_cert_manager" {
  description = "Create the IRSA role for cert-manager with Route 53 DNS-01 permissions"
  type        = bool
  default     = false
}

variable "route53_hosted_zone_arns" {
  description = <<-EOT
    Route 53 hosted zone ARNs that external-dns and cert-manager may write to.
    Defaults to every zone, which is convenient in a lab and too broad for
    production. Scope it to the zones the cluster actually owns.
  EOT
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}

variable "secretsmanager_secret_arns" {
  description = "Secrets Manager secret ARNs readable by External Secrets Operator"
  type        = list(string)
  default     = []
}

variable "ssm_parameter_arns" {
  description = "SSM Parameter Store ARNs readable by External Secrets Operator"
  type        = list(string)
  default     = []
}

variable "service_account_namespace" {
  description = "Namespace the platform controllers run in"
  type        = string
  default     = "kube-system"
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary applied to every role created here"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every role"
  type        = map(string)
  default     = {}
}
