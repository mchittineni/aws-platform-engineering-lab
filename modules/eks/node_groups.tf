# ---------------------------------------------------------------------------
# Launch template
#
# Managed node groups can run without a launch template, but then IMDSv2 is
# optional, the root volume is unencrypted gp2 and there is no way to force
# instance metadata hardening. One template per node group keeps those
# guarantees while still letting EKS own the AMI and the rolling upgrade.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  for_each = var.node_groups

  name        = "${var.cluster_name}-${each.key}"
  description = "Launch template for the ${each.key} node group of ${var.cluster_name}"

  update_default_version = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = each.value.disk_size
      volume_type           = each.value.disk_type
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 only, and a hop limit of 2 so that pods on the host network cannot
  # reach the credentials of the node role through the metadata endpoint.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-${each.key}"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-${each.key}"
    })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = var.tags
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Managed node groups
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = coalesce(each.value.subnet_ids, var.private_subnet_ids)

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  ami_type       = each.value.ami_type

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config {
    max_unavailable_percentage = each.value.max_unavailable_percentage
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  labels = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })

  # desired_size is owned by the cluster autoscaler or Karpenter once the
  # cluster is live. Terraform sets the initial value and then stops fighting.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
