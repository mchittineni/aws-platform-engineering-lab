# ---------------------------------------------------------------------------
# Control plane role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name                  = "${var.cluster_name}-cluster"
  description           = "EKS control plane role for ${var.cluster_name}"
  assume_role_policy    = data.aws_iam_policy_document.cluster_assume_role.json
  force_detach_policies = true

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# Node instance role
#
# SSM is attached instead of opening SSH. Nodes are reachable through Session
# Manager, so no bastion host and no inbound port 22 anywhere.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name                  = "${var.cluster_name}-node"
  description           = "EKS managed node group instance role for ${var.cluster_name}"
  assume_role_policy    = data.aws_iam_policy_document.node_assume_role.json
  force_detach_policies = true

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset(concat([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ], var.node_extra_policy_arns))

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# IRSA: OIDC provider
#
# This is what lets a Kubernetes ServiceAccount assume an IAM role without any
# long lived credentials on the node.
# ---------------------------------------------------------------------------

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, { Name = "${var.cluster_name}-irsa" })
}
