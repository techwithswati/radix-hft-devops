##############################################################
# Staging Environment - Terraform Configuration
# Mirrors prod topology at reduced scale; used for blues/green
# deploys, integration tests, and k6 load testing
##############################################################

terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket         = "radix-hft-terraform-state-staging"
    key            = "staging/terraform.tfstate"
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
      Environment = "staging"
      Project     = "radix-hft"
      ManagedBy   = "Terraform"
      Owner       = "platform-engineering"
    }
  }
}

locals {
  region      = "us-east-1"
  environment = "staging"
  name_prefix = "radix-hft"
}

##############################################################
# VPC - 3 AZs, HA NAT (mirrors prod)
##############################################################
module "vpc" {
  source = "../../modules/vpc"

  name_prefix = local.name_prefix
  environment = local.environment
  region      = local.region
  vpc_cidr    = "10.20.0.0/16"

  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

  private_subnet_cidrs = [
    "10.20.0.0/19",
    "10.20.32.0/19",
    "10.20.64.0/19",
  ]

  public_subnet_cidrs = [
    "10.20.128.0/20",
    "10.20.144.0/20",
    "10.20.160.0/20",
  ]

  database_subnet_cidrs = [
    "10.20.176.0/21",
    "10.20.184.0/21",
    "10.20.192.0/21",
  ]

  enable_nat_gateway  = true
  single_nat_gateway  = false
  enable_flow_logs    = true
  flow_logs_retention = 7
}

##############################################################
# EKS Cluster
##############################################################
module "eks" {
  source = "../../modules/eks"

  name_prefix        = local.name_prefix
  environment        = local.environment
  kubernetes_version = "1.30"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  allowed_cidr_blocks = var.vpn_cidr_blocks

  trading_critical_desired = 3
  trading_critical_min     = 2
  trading_critical_max     = 8

  log_retention_days = 14
}

##############################################################
# Aurora - 2-node cluster (writer + reader)
##############################################################
module "aurora" {
  source = "../../modules/rds"

  name_prefix = local.name_prefix
  environment = local.environment

  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.database_subnet_ids

  allowed_security_groups = [module.eks.node_security_group_id]

  engine_version = "16.2"
  instance_class = "db.r7g.large"
  cluster_size   = 2

  database_name   = "radix_hft_staging"
  master_username = "radix_admin"
  master_password = var.db_password

  deletion_protection     = false
  backup_retention_period = 7

  performance_insights_enabled = true
}

##############################################################
# Redis - 2 shards, 1 replica each
##############################################################
module "redis" {
  source = "../../modules/redis"

  name_prefix = local.name_prefix
  environment = local.environment

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  allowed_security_groups = [module.eks.node_security_group_id]

  engine_version     = "7.1"
  node_type          = "cache.r7g.large"
  num_shards         = 2
  replicas_per_shard = 1

  snapshot_retention_limit = 3
}

##############################################################
# MSK - 3 brokers, smaller instance class than prod
##############################################################
module "msk" {
  source = "../../modules/msk"

  name_prefix = local.name_prefix
  environment = local.environment

  vpc_id         = module.vpc.vpc_id
  client_subnets = module.vpc.private_subnet_ids

  allowed_security_groups = [module.eks.node_security_group_id]

  kafka_version = "3.7.0"
  instance_type = "kafka.m5.xlarge"
  broker_count  = 3
  volume_size   = 500

  configuration = {
    "num.partitions"             = "6"
    "default.replication.factor" = "3"
    "min.insync.replicas"        = "2"
    "log.retention.hours"        = "72"
  }
}

##############################################################
# Monitoring - AMP enabled, AMG optional
##############################################################
module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix  = local.name_prefix
  environment  = local.environment
  cluster_name = module.eks.cluster_id

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  enable_amp       = true
  amp_retention    = "15d"
  enable_amg       = false
  enable_thanos_s3 = false

  alert_email           = var.alert_email
  pagerduty_routing_key = var.pagerduty_routing_key
  slack_webhook_url     = var.slack_webhook_url
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

output "msk_brokers" {
  value     = module.msk.bootstrap_brokers_tls
  sensitive = true
}

output "amp_workspace_endpoint" {
  value = module.monitoring.amp_workspace_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_id}"
}
