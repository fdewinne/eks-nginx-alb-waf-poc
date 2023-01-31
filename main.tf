terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.44"
    }
  }

  required_version = ">= 1.3.6"

  backend "s3" {
    bucket = "fdewinne-eks-nginx-alb-waf"
    key    = "dev"
    region = "eu-west-1"
  }
}

provider "aws" {
  region = "eu-west-1"
}

provider "aws" {
  region = "us-east-1"
  alias  = "global"
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", local.cluster_name]
  }
}

locals {
  cluster_name = module.eks_blueprints.eks_cluster_id
  eks_oidc_issuer_url  = replace(data.aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer, "https://", "")
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", local.cluster_name]
    }
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_blueprints.eks_cluster_id
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "eks-ngninx-alb-waf-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b"]
  public_subnets  = ["10.0.10.0/24", "10.0.20.0/24"]

  enable_nat_gateway = false
  enable_vpn_gateway = false

  tags = {
    Environment = "dev"
  }
  public_subnet_tags = {
    "kubernetes.io/cluster/eks-ngninx-alb-waf" = "shared"
    "kubernetes.io/role/elb"              = 1
  }
}

module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints"

  # EKS CLUSTER
  cluster_name = "eks-ngninx-alb-waf"
  cluster_version = "1.24"
  vpc_id = module.vpc.vpc_id
  enable_irsa = true
  private_subnet_ids = module.vpc.public_subnets

  map_roles = var.map_roles

  # EKS MANAGED NODE GROUPS
  managed_node_groups = {
    default = {
      node_group_name = "default"
      enable_node_group_prefix = true
      min_size = 2
      max_size = 4
      desired_size = 2
      instance_types = ["m5.large"]
      capacity_type = "SPOT"
      subnet_ids = module.vpc.public_subnets
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "time_sleep" "dataplane" {
  create_duration = "10s"

  triggers = {
    eks_cluster_id      = module.eks_blueprints.eks_cluster_id # this ties it to downstream resources
  }
}

data "aws_eks_cluster" "eks_cluster" {
  # this makes downstream resources wait for data plane to be ready
  name = time_sleep.dataplane.triggers["eks_cluster_id"]
}

module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints/modules/kubernetes-addons"

  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_id       = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint = module.eks_blueprints.eks_cluster_endpoint
  eks_cluster_version  = module.eks_blueprints.eks_cluster_version
  eks_cluster_domain   = var.domain_name

  # EKS Addons
  enable_amazon_eks_aws_ebs_csi_driver = true
  enable_amazon_eks_coredns = true
  enable_amazon_eks_kube_proxy = true
  amazon_eks_kube_proxy_config = {
    most_recent = true
  }
  enable_amazon_eks_vpc_cni = true
  amazon_eks_vpc_cni_config = {
    most_recent = true
  }
  enable_aws_load_balancer_controller      = true
  # Limit controller scope to ALB ingress class to avoid load balancer creation for nginx
  aws_load_balancer_controller_helm_config = {
    set = [
      {
        name  = "scope.ingressClass",
        value = "alb"
      }
    ]
  }
  enable_metrics_server                    = true
  enable_cluster_autoscaler                = true
  enable_external_dns                      = true
  # Limit external dns scope to ALB ingress class to avoid creation of dns entry for nginx ingresses
  external_dns_helm_config = {
    set = [
      {
        name  = "extraArgs.annotation-filter"
        value = "kubernetes.io/ingress.class in (alb)"
      }
    ]
  }
  enable_cert_manager                      = true
  cert_manager_install_letsencrypt_issuers = true
  cert_manager_domain_names                = [
    var.domain_name
  ]

  #K8s Add-ons
  enable_argocd = true
  argocd_helm_config = {
    namespace = "argocd"
    version = "5.16.7"
    values = [templatefile("${path.module}/helm-configs/argocd-values.yaml", {
      clusterDomain = var.domain_name
    })]
  }
}

module "nginx_addon" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints/modules/kubernetes-addons/helm-addon"
  
  helm_config = {
    namespace   = "kube-system"
    name        = "ingress-nginx"
    chart       = "ingress-nginx"
    repository  = "https://kubernetes.github.io/ingress-nginx"
    version     = "4.4.0"
    values      = [templatefile("${path.module}/helm-configs/ingress-nginx-values.yaml", {})]
  }
  
  addon_context = {
    aws_caller_identity_account_id = data.aws_caller_identity.current.account_id
    aws_caller_identity_arn        = data.aws_caller_identity.current.arn
    aws_eks_cluster_endpoint       = module.eks_blueprints.eks_cluster_endpoint
    aws_partition_id               = data.aws_partition.current.partition
    aws_region_name                = data.aws_region.current.name
    eks_cluster_id                 = data.aws_eks_cluster.eks_cluster.id
    eks_oidc_issuer_url            = local.eks_oidc_issuer_url
    eks_oidc_provider_arn          = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.eks_oidc_issuer_url}"
    tags                           = {}
  }
}

module "alb_ingress_addon" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints/modules/kubernetes-addons/helm-addon"
  
  helm_config = {
    namespace   = "kube-system"
    name        = "alb-ingress"
    chart       = "${path.module}/alb-ingress"
    values      = [templatefile("${path.module}/helm-configs/alb-ingress-values.yaml", {
      certificate_arn = "arn:aws:acm:eu-west-1:395097224046:certificate/0188407c-98b2-4435-a9b1-3dd22db32cc4"
      subnets = join(",", module.vpc.public_subnets)
      base_domain = var.domain_name
      waf_arn = aws_wafv2_web_acl.waf.arn
    })]
  }
  
  addon_context = {
    aws_caller_identity_account_id = data.aws_caller_identity.current.account_id
    aws_caller_identity_arn        = data.aws_caller_identity.current.arn
    aws_eks_cluster_endpoint       = module.eks_blueprints.eks_cluster_endpoint
    aws_partition_id               = data.aws_partition.current.partition
    aws_region_name                = data.aws_region.current.name
    eks_cluster_id                 = data.aws_eks_cluster.eks_cluster.id
    eks_oidc_issuer_url            = local.eks_oidc_issuer_url
    eks_oidc_provider_arn          = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.eks_oidc_issuer_url}"
    tags                           = {}
  }
}