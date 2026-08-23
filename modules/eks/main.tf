locals {
  all_subnet_ids = concat(var.private_subnet_ids, var.public_subnet_ids)
}

# ---------------------------------------------------------------------------
# Control plane logs
#
# Created ahead of the cluster so that retention and encryption are under our
# control rather than defaulting to never expire and the AWS owned key.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Additional cluster security group
#
# The EKS managed cluster security group already allows node to control plane
# traffic. This group exists so that other stacks (bastions, VPN, peered VPCs)
# can be granted API access without editing an AWS managed resource.
# ---------------------------------------------------------------------------

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-additional"
  description = "Additional security group attached to the ${var.cluster_name} control plane ENIs"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster-additional" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids              = local.all_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  upgrade_policy {
    support_type = var.upgrade_policy_support_type
  }

  tags = merge(var.tags, { Name = var.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------------------
# Access entries
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  kubernetes_groups = each.value.kubernetes_groups

  tags = var.tags
}

locals {
  # Flatten access entry policies so that one entry can carry several policies.
  access_policy_associations = merge([
    for entry_key, entry in var.access_entries : {
      for policy_arn in entry.policy_arns :
      "${entry_key}/${basename(policy_arn)}" => {
        principal_arn = entry.principal_arn
        policy_arn    = policy_arn
        scope_type    = entry.access_scope_type
        namespaces    = entry.namespaces
      }
    }
  ]...)
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access_policy_associations

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.scope_type
    namespaces = each.value.scope_type == "namespace" ? each.value.namespaces : null
  }

  depends_on = [aws_eks_access_entry.this]
}
