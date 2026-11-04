terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # A linha 3.x mudou a sintaxe dos blocos set/kubernetes; fica na 2.x.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
