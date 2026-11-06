# No security groups here on purpose: EKS then attaches the cluster security group, which already
# allows nodes and the control plane to talk to each other.
resource "aws_launch_template" "node" {
  name_prefix            = "${var.name}-node-"
  update_default_version = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 only. A hop limit of 2 lets containers reach the metadata service, as on EKS's own
  # default launch template; some controllers read their region or VPC from it.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name}-node" }
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name           = aws_eks_cluster.this.name
  node_group_name_prefix = "${var.name}-"
  node_role_arn          = aws_iam_role.node.arn
  subnet_ids             = var.subnet_ids
  version                = aws_eks_cluster.this.version

  ami_type       = var.ami_type
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    # Changing instance types replaces the group: bring the new nodes up before removing the old.
    create_before_destroy = true
    # The desired size belongs to whoever scales the group (e.g. Cluster Autoscaler) after creation.
    ignore_changes = [scaling_config[0].desired_size]
  }

  # The role must keep its permissions until the nodes are gone.
  depends_on = [aws_iam_role_policy_attachment.node]
}
