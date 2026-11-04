provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Conecta o provider Helm no cluster recem-criado nesta mesma apply, usando
# um token de curta duracao (aws eks get-token) em vez de credenciais estaticas.
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
    }
  }
}
