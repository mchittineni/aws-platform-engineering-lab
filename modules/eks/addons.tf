locals {
  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ---------------------------------------------------------------------------
# IRSA role for the VPC CNI
#
# The node role also carries AmazonEKS_CNI_Policy so that the CNI works before
# the add-on is reconciled. Once this role is in place the add-on uses it, and
# the node role attachment can be removed in a hardening pass.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "vpc_cni_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.cluster_name}-vpc-cni"
  description        = "IRSA role for the VPC CNI add-on on ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ---------------------------------------------------------------------------
# IRSA role for the EBS CSI driver
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  name               = "${var.cluster_name}-ebs-csi"
  description        = "IRSA role for the EBS CSI driver on ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role[0].json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Lets the driver create volumes encrypted with the cluster KMS key.
data "aws_iam_policy_document" "ebs_csi_kms" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RevokeGrant",
    ]
    resources = [aws_kms_key.ebs[0].arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.ebs[0].arn]
  }
}

resource "aws_iam_role_policy" "ebs_csi_kms" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  name   = "ebs-kms"
  role   = aws_iam_role.ebs_csi[0].id
  policy = data.aws_iam_policy_document.ebs_csi_kms[0].json
}

resource "aws_kms_key" "ebs" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  description             = "Encrypts EBS volumes provisioned by the ${var.cluster_name} CSI driver"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-ebs" })
}

resource "aws_kms_alias" "ebs" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  name          = "alias/${var.cluster_name}-ebs"
  target_key_id = aws_kms_key.ebs[0].key_id
}

# ---------------------------------------------------------------------------
# Add-ons
#
# vpc-cni, kube-proxy and the pod identity agent come up before the nodes.
# coredns and the CSI driver need a node to schedule on, so they wait.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = lookup(var.addon_versions, "vpc-cni", null)

  service_account_role_arn = aws_iam_role.vpc_cni.arn

  # Without enableNetworkPolicy the API server happily accepts every
  # NetworkPolicy object and enforces none of them, which is the worst
  # possible outcome: a policy that looks applied and is not.
  configuration_values = jsonencode({
    enableNetworkPolicy = var.enable_network_policy ? "true" : "false"

    env = merge(
      {
        # Pods land on the node's own ENIs, so this is what decides how many
        # pods a node can hold before the CNI runs out of addresses.
        ENABLE_PREFIX_DELEGATION = var.enable_prefix_delegation ? "true" : "false"
      },
      var.vpc_cni_env,
    )
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = lookup(var.addon_versions, "kube-proxy", null)

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags
}

resource "aws_eks_addon" "pod_identity_agent" {
  count = var.enable_pod_identity_agent ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = lookup(var.addon_versions, "eks-pod-identity-agent", null)

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = lookup(var.addon_versions, "coredns", null)

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = lookup(var.addon_versions, "aws-ebs-csi-driver", null)

  service_account_role_arn = aws_iam_role.ebs_csi[0].arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  depends_on = [aws_eks_node_group.this]
}


# ---------------------------------------------------------------------------
# CloudWatch observability add-on
#
# Ships Container Insights metrics and container logs to CloudWatch. This is
# what makes the node level alarms in modules/observability real rather than
# permanently INSUFFICIENT_DATA.
#
# It is also the most expensive add-on here: log ingestion is charged per GB,
# so `container_log_retention_days` matters.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cloudwatch_observability_assume_role" {
  count = var.enable_cloudwatch_observability ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_observability" {
  count = var.enable_cloudwatch_observability ? 1 : 0

  name               = "${var.cluster_name}-cloudwatch-agent"
  description        = "IRSA role for the CloudWatch observability add-on on ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_observability_assume_role[0].json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability" {
  count = var.enable_cloudwatch_observability ? 1 : 0

  role       = aws_iam_role.cloudwatch_observability[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count = var.enable_cloudwatch_observability ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = lookup(var.addon_versions, "amazon-cloudwatch-observability", null)

  service_account_role_arn = aws_iam_role.cloudwatch_observability[0].arn

  configuration_values = jsonencode({
    agent = {
      config = {
        logs = {
          metrics_collected = {
            kubernetes = {
              enhanced_container_insights = var.enable_enhanced_container_insights
            }
          }
        }
      }
    }
    containerLogs = {
      enabled = var.enable_container_logs
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  depends_on = [aws_eks_node_group.this]
}
