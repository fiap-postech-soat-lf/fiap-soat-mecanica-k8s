# Launch template explicito (F2-h): IMDSv2 com hop limit 2 para os pods alcancarem o
# IMDS e usarem a LabRole do node pela cadeia padrao do SDK. Sem security groups aqui,
# para o EKS continuar aplicando o SG do cluster aos nodes.
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.project}-nodes-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # pods alcançam o IMDS (credenciais da LabRole)
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # As default_tags do provider nao chegam as instancias criadas pelo ASG.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.project}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = local.lab_role_arn
  subnet_ids      = local.subnet_ids
  instance_types  = [var.node_instance_type]

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [terraform_data.cluster_all_egress]
}
