##############################################################
# Dev Environment — Terraform Configuration
# Cost-optimised: serverless Aurora, single NAT, small Redis
##############################################################

terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket         = "radix-hft-terraform-state-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "radix-hft-terraform-locks"
    encrypt        = true
  }

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.50" }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = "dev"
      Project     = "radix-hft"
      ManagedBy    = "Terraform"
      Owner       = "platform-engineering"
    }
  } 
}

locals {
  region      = "us-east-1"
  environment = "dev"
  name_prefix = "radix-hft"
}

##############################################################
# VPC - 2 AZs, single NAT (cost saving)
##############################################################
module "vpc" {
  source = "../../modules/vpc"

  name_prefix = local.name_prefix
  environment = local.environment
  region      = local.region
  vpc_cidr    = "10.10.0.0/16"

  availability_zones = ["us-east-1a", "us-east-1b"]

  private_subnet_cidrs  = ["10.10.0.0/19", "10.10.32.0/19"]
  public_subnet_cidrs   = ["10.10.64.0/20", "10.10.80.0/20"]
  database_subnet_cidrs = ["10.10.96.0/21", "10.10.104.0/21"]

  enable_nat_gateway = true
  single_nat_gateway = true   # Cost saving: single NAT in dev
  enable_flow_logs   = false  # Skip in dev
}

##############################################################
# EKS Cluster - small node groups
##############################################################
module "eks" {
  source = "../../modules/eks"

  name_prefix        = local.name_prefix
  environment        = local.environment
  kubernetes_version = "1.30"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  allowed_cidr_blocks = ["0.0.0.0/0"]  # Public endpoint OK in dev

  trading_critical_desired = 2
  trading_critical_min     = 1
  trading_critical_max     = 4

  log_retention_days = 7
}

##############################################################
# Aurora - Serverless v2, single instance
##############################################################
module "aurora" {
  source = "../../modules/rds"

  name_prefix = local.name_prefix
  environment = local.environment

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.database_subnet_ids

  allowed_security_groups = [module.eks.node_security_group_id]

  engine_version    = "16.2"
  cluster_size      = 1
  use_serverless_v2 = true

  database_name   = "radix_hft_dev"
  master_username = "radix_admin"
  master_password = var.db_password

  deletion_protection     = false
  backup_retention_period = 1

  performance_insights_enabled = false
}

##############################################################
# Redis - single shard, no replicas
##############################################################
module "redis" {
  source = "../../modules/redis"

  name_prefix = local.name_prefix
  environment = local.environment

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  allowed_security_groups = [module.eks.node_security_group_id]

  engine_version     = "7.1"
  node_type          = "cache.t4g.micro"
  num_shards         = 1
  replicas_per_shard = 0

  snapshot_retention_limit = 0
}

##############################################################
# Outputs
##############################################################
output "cluster_name" {
  value = module.eks.cluster_id
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "aurora_endpoint" {
  value     = module.aurora.cluster_endpoint
  sensitive = true
}

output "redis_endpoint" {
  value     = module.redis.primary_endpoint
  sensitive = true
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_id}"
}
