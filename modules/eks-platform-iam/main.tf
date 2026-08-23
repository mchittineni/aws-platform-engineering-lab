# ---------------------------------------------------------------------------
# IRSA roles for the platform controllers that run on every EKS cluster.
#
# Each controller gets its own role with its own policy. One shared "platform"
# role would mean a compromised external-dns pod could also delete load
# balancers.
# ---------------------------------------------------------------------------

data "aws_partition" "current" {}

locals {
  namespace = var.service_account_namespace

  # Default to every zone only when nothing narrower was supplied.
  hosted_zone_arns = length(var.route53_hosted_zone_arns) > 0 ? var.route53_hosted_zone_arns : ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/*"]

  secret_arns = length(var.secretsmanager_secret_arns) > 0 ? var.secretsmanager_secret_arns : ["arn:${data.aws_partition.current.partition}:secretsmanager:*:*:secret:${var.cluster_name}/*"]

  parameter_arns = length(var.ssm_parameter_arns) > 0 ? var.ssm_parameter_arns : ["arn:${data.aws_partition.current.partition}:ssm:*:*:parameter/${var.cluster_name}/*"]
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller
# ---------------------------------------------------------------------------

module "aws_load_balancer_controller" {
  count  = var.enable_aws_load_balancer_controller ? 1 : 0
  source = "../irsa"

  role_name   = "${var.cluster_name}-aws-load-balancer-controller"
  description = "AWS Load Balancer Controller on ${var.cluster_name}"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  service_accounts  = ["${local.namespace}/aws-load-balancer-controller"]

  inline_policies = {
    "aws-load-balancer-controller" = templatefile(
      "${path.module}/policies/aws-load-balancer-controller.json.tftpl",
      { partition = data.aws_partition.current.partition },
    )
  }

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}

# ---------------------------------------------------------------------------
# external-dns
# ---------------------------------------------------------------------------

module "external_dns" {
  count  = var.enable_external_dns ? 1 : 0
  source = "../irsa"

  role_name   = "${var.cluster_name}-external-dns"
  description = "external-dns on ${var.cluster_name}"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  service_accounts  = ["${local.namespace}/external-dns"]

  inline_policies = {
    "external-dns" = templatefile(
      "${path.module}/policies/external-dns.json.tftpl",
      { hosted_zone_arns = jsonencode(local.hosted_zone_arns) },
    )
  }

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}

# ---------------------------------------------------------------------------
# Cluster autoscaler
# ---------------------------------------------------------------------------

module "cluster_autoscaler" {
  count  = var.enable_cluster_autoscaler ? 1 : 0
  source = "../irsa"

  role_name   = "${var.cluster_name}-cluster-autoscaler"
  description = "Kubernetes cluster autoscaler on ${var.cluster_name}"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  service_accounts  = ["${local.namespace}/cluster-autoscaler"]

  inline_policies = {
    "cluster-autoscaler" = templatefile(
      "${path.module}/policies/cluster-autoscaler.json.tftpl",
      { cluster_name = var.cluster_name },
    )
  }

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}

# ---------------------------------------------------------------------------
# External Secrets Operator
# ---------------------------------------------------------------------------

module "external_secrets" {
  count  = var.enable_external_secrets ? 1 : 0
  source = "../irsa"

  role_name   = "${var.cluster_name}-external-secrets"
  description = "External Secrets Operator on ${var.cluster_name}"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  service_accounts  = ["external-secrets/external-secrets"]

  inline_policies = {
    "external-secrets" = templatefile(
      "${path.module}/policies/external-secrets.json.tftpl",
      {
        secret_arns    = jsonencode(local.secret_arns)
        parameter_arns = jsonencode(local.parameter_arns)
      },
    )
  }

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}

# ---------------------------------------------------------------------------
# cert-manager
# ---------------------------------------------------------------------------

module "cert_manager" {
  count  = var.enable_cert_manager ? 1 : 0
  source = "../irsa"

  role_name   = "${var.cluster_name}-cert-manager"
  description = "cert-manager Route 53 DNS-01 solver on ${var.cluster_name}"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  service_accounts  = ["cert-manager/cert-manager"]

  inline_policies = {
    "cert-manager" = templatefile(
      "${path.module}/policies/cert-manager.json.tftpl",
      {
        partition        = data.aws_partition.current.partition
        hosted_zone_arns = jsonencode(local.hosted_zone_arns)
      },
    )
  }

  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}
