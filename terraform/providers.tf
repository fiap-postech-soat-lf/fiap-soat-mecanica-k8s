# Na F1 so o provider aws. Os providers helm/kubernetes entram na F2, junto com o
# aws_eks_cluster que eles referenciam.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project    = "mecanica"
      ManagedBy  = "terraform"
      Repository = "fiap-soat-mecanica-k8s"
    }
  }
}
