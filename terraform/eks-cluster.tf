resource "aws_eks_cluster" "this" {
  name     = var.project
  role_arn = local.lab_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = local.subnet_ids
  }

  # Quem cria o cluster e a role voclabs (sessao do Learner Lab). O bootstrap
  # ja concede admin a ela; um access entry explicito duplicaria e falha com 409.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }
}

# O SG que o EKS cria automaticamente para o cluster as vezes vem so com a
# regra de saida auto-referenciada (trafego entre control plane e nodes),
# sem a regra geral 0.0.0.0/0. Sem ela os nodes nao alcancam EC2/EKS/ECR
# durante o bootstrap e o node group falha com "failed to join the cluster".
resource "aws_vpc_security_group_egress_rule" "cluster_all_egress" {
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Egress geral necessario para os nodes completarem o bootstrap (EC2/EKS/ECR)."
}
