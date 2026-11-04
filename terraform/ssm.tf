# Parametros lidos pelos outros repositorios (ADR-F4-14, tabela 3.1 do plano da F2).
# Todos String/StringList com insecure_value: nenhum segredo vai para o SSM, e o plano
# mostra os valores.

resource "aws_ssm_parameter" "vpc_id" {
  name           = "/mecanica/k8s/vpc-id"
  type           = "String"
  insecure_value = data.aws_vpc.default.id
}

resource "aws_ssm_parameter" "subnet_ids" {
  name           = "/mecanica/k8s/subnet-ids"
  type           = "StringList"
  insecure_value = join(",", local.subnet_ids)
}

# SG do cluster, que o EKS aplica aos nodes: o RDS de cada servico libera a 5432 para ele.
resource "aws_ssm_parameter" "node_security_group_id" {
  name           = "/mecanica/k8s/node-security-group-id"
  type           = "String"
  insecure_value = local.cluster_security_group_id
}

resource "aws_ssm_parameter" "nlb_dns" {
  name           = "/mecanica/k8s/nlb-dns"
  type           = "String"
  insecure_value = aws_lb.this.dns_name
}

# Sinal de "ambiente ligado" para os porteiros dos CDs: criado por ultimo no apply.
resource "aws_ssm_parameter" "cluster_name" {
  name           = "/mecanica/k8s/cluster-name"
  type           = "String"
  insecure_value = aws_eks_cluster.this.name

  depends_on = [
    helm_release.traefik,
    helm_release.opentelemetry_operator,
    aws_autoscaling_attachment.traefik,
  ]
}
