##############################################################
# Production Environment - Terraform Configuration
# Radix HFT Trading Platform
##############################################################

terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket         = "radix-hft-terraform-state-prod"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "radix-hft-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/radix-hft-terraform-state"
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = local.region

  default_tags {
    tags = {
      Environment = "prod"
      Project     = "radix-hft"
      ManagedBy   = "Terraform"
      Owner       = "platform-engineering"
    }
  }
}

locals {
  region      = "us-east-1"
  environment = "prod"
  name_prefix = "radix-hft"
}

##############################################################
# VPC Module
##############################################################
module "vpc" {
  source = "../../modules/vpc"

  name_prefix = local.name_prefix
  environment = local.environment
  region = local.region
  vpc_cidr = "10.0.0.0/16"

  # 3 AZs for high availability
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

  private_subnet_cidrs = [
    "10.0.0.0/19",
    "10.0.32.0/19",
    "10.0.64.0/19",
  ]

  public_subnet_cidrs = [
    "10.0.128.0/20",
    "10.0.144.0/20",
    "10.0.160.0/20",
  ]

  database_subnet_cidrs = [
    "10.0.176.0/21",
    "10.0.184.0/21",
    "10.0.192.0/21",
  ]

  enable_nat_gateway  = true
  single_nat_gateway  = false # HA NAT in prod
  enable_vpn_gateway  = false
  enable_flow_logs    = true
  flow_logs_retention = 30
}

##############################################################
# EKS Cluster
##############################################################
module "eks" {
  source = "../../modules/eks"

  name_prefix        = local.name_prefix
  environment        = local.environment
  kubernetes_version = "1.30"

  vpc_id = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  # Prod: Private-only API endpoint
  allowed_cidr_blocks = var.vpn_cidr_blocks

  trading_critical_desired = 6
  trading_critical_min     = 4
  trading_critical_max     = 16

  log_retention_days = 90
  
  tags = {
    CostCenter = "trading-prod"
    DataClass  = "confidential"
    Compliance = "pci-dss,sox"
  }
}

##############################################################
# IAM (IRSA roles)
##############################################################
module "iam" {
  source = "../../modules/iam"

  name_prefix       = local.name_prefix
  environment       = local.environment
  region            = local.region
  account_id        = data.aws_caller_identity.current.account_id
  oidc_provider_url = module.eks.cluster_oidc_issuer_url
  oidc_provider_arn = module.eks.oidc_provider_arn
  kms_key_arn       = module.aurora.kms_key_arn
  msk_cluster_name  = module.msk.cluster_name
}

data "aws_caller_identity" "current" {}

##############################################################
# Aurora PostgreSQL (Trade Ledger)
##############################################################
module "aurora" {
  source = "../../modules/rds"

  name_prefix       = local.name_prefix
  environment       = local.environment
  engine            = "aurora-postgresql"
  engine_version    = "16.2"
  instance_class    = "db.r7g.2xlarge"
  cluster_size      = 3

  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.database_subnet_ids
  allowed_security_groups = [module.eks.node_security_group_id]

  database_name   = "radix_hft"
  master_username = "radix_admin"
  master_password = var.db_password

  deletion_protection     = true
  backup_retention_period = 35
  preferred_backup_window = "02:00-03:00"
  storage_encrypted       = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 31

  enabled_cloudwatch_logs_exports = ["postgresql"]
}

##############################################################
# ElastiCache (Redis - Order State & Session)
##############################################################
module "redis" {
  source = "../../modules/redis"

  name_prefix        = local.name_prefix
  environment        = local.environment
  engine_version     = "7.1"
  node_type          = "cache.r7g.xlarge"
  num_shards         = 3
  replicas_per_shard = 2

  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnet_ids
  allowed_security_groups = [module.eks.node_security_group_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  snapshot_retention_limit = 7
  snapshot_window          = "03:00-05:00"
}

##############################################################
# MSK Kafka (Market Data Feed)
##############################################################
module "msk" {
  source = "../../modules/msk"

  name_prefix   = local.name_prefix
  environment   = local.environment
  kafka_version = "3.7.0"
  instance_type = "kafka.m5.4xlarge"
  broker_count  = 3

  vpc_id         = module.vpc.vpc_id
  client_subnets = module.vpc.private_subnet_ids
  
  allowed_security_groups = [module.eks.node_security_group_id]

  volume_size = 2000 # GB per broker

  encryption_in_transit_client_broker = "TLS"
  encryption_in_transit_in_cluster    = true

  configuration = {
    "auto.create.topics.enable"  = "false"
    "log.retention.hours"        = "168"
    "log.retention.bytes"        = "107374182400" # 100 GB
    "num.partitions"             = "12"
    "default.replication.factor" = "3"
    "min.insync.replicas"        = "2"
    "compression.type"           = "lz4"
  }
}

##############################################################
# Monitoring Infrastructure
##############################################################
module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix  = local.name_prefix
  environment  = local.environment
  cluster_name = module.eks.cluster_id

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # AMP (Amazon Managed Prometheus)
  enable_amp    = true
  amp_retention = "400d"

  # AMG (Amazon Managed Grafana)
  enable_amg = true

  # S3 for long-term metrics storage (Thanos)
  enable_thanos_s3 = true

  pagerduty_routing_key = var.pagerduty_routing_key
  slack_webhook_url     = var.slack_webhook_url
  alert_email           = var.alert_email
}

##############################################################
# Outputs
##############################################################
output "cluster_name" {
  value = module.eks.cluster_id
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "aurora_endpoint" {
  value     = module.aurora.cluster_endpoint
  sensitive = true
}

output "redis_primary_endpoint" {
  value     = module.redis.primary_endpoint
  sensitive = true
}

output "msk_brokers" {
  value     = module.msk.bootstrap_brokers_tls
  sensitive = true
}

output "amp_endpoint" {
  value = module.monitoring.amp_workspace_endpoint
}

output "grafana_url" {
  value = module.monitoring.grafana_workspace_url
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_id}"
}
