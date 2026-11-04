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

# O SG que o EKS cria para o cluster as vezes vem so com a regra de saida
# auto-referenciada, sem a regra geral 0.0.0.0/0 (visto pelo grupo em 2026-09-15,
# logo apos um reset da conta). Sem ela os nodes nao alcancam EC2/EKS/ECR no
# bootstrap e o node group falha com "failed to join the cluster". Outras vezes a
# regra ja vem criada, e um aws_vpc_security_group_egress_rule falha com
# InvalidPermission.Duplicate (janela do D7, 2026-11-04). Por isso a regra e
# garantida de forma idempotente pela CLI, e nao declarada como recurso: o SG e do
# EKS e e apagado junto com o cluster, entao nao ha nada a desfazer no destroy.
resource "terraform_data" "cluster_all_egress" {
  triggers_replace = [local.cluster_security_group_id]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      SG = local.cluster_security_group_id
    }
    command = <<-EOT
      set -euo pipefail
      regra='[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"Egress geral para o bootstrap dos nodes"}]}]'
      if saida=$(aws ec2 authorize-security-group-egress --group-id "$SG" --ip-permissions "$regra" 2>&1); then
        echo "Egress 0.0.0.0/0 criado no $SG"
      elif grep -q 'InvalidPermission.Duplicate' <<< "$saida"; then
        echo "Egress 0.0.0.0/0 ja existia no $SG"
      else
        echo "$saida" >&2
        exit 1
      fi
    EOT
  }
}
