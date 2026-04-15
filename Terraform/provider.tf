terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # profile can be optionally set with AWS_PROFILE
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.q0.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.q0.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.q0.token
}
