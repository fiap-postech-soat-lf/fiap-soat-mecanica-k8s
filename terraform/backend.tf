# Configurado pelo workflow com -backend-config (bucket mecanica-tfstate-<accountId>,
# key fiap-soat-mecanica-k8s/terraform.tfstate, region us-east-1, use_lockfile=true).
terraform {
  backend "s3" {}
}
