##############################################################
# Radix HFT — ElastiCache Redis Module
# Cluster-mode Redis for order state, session cache, and
# rate-limiting counters. mTLS auth, encryption at rest.
##############################################################

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.50" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

locals {
  identifier = "${var.name_prefix}-${var.environment}-redis"
  common_tags = merge(var.tags, {
    ManagedBy   = "Terraform"
    Environment = var.environment
    Project     = "radix-hft"
  })
}

##############################################################
# KMS Key
##############################################################
resource "aws_kms_key" "redis" {
  description             = "ElastiCache Redis encryption key - ${local.identifier}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "redis" {
  name          = "alias/${local.identifier}"
  target_key_id = aws_kms_key.redis.key_id
}

##############################################################
# Security Group
##############################################################
resource "aws_security_group" "redis" {
  name        = "${local.identifier}-sg"
  description = "Security group for ElastiCache Redis cluster"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = var.allowed_security_groups
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.identifier}-sg" })
}

##############################################################
# Subnet Group
##############################################################
resource "aws_elasticache_subnet_group" "main" {
  name        = "${local.identifier}-subnet-group"
  description = "Redis subnet group - ${var.environment}"
  subnet_ids  = var.subnet_ids
  tags        = local.common_tags
}

##############################################################
# Parameter Group
##############################################################
resource "aws_elasticache_parameter_group" "main" {
  name        = "${local.identifier}-params"
  family      = "redis7"
  description = "Radix HFT Redis parameters"

  # Optimized for low-latency trading workloads
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"           # Evict LRU keys when memory full
  }
  parameter {
    name  = "activerehashing"
    value = "yes"
  }
  parameter {
    name  = "lazyfree-lazy-eviction"
    value = "yes"           # Non-blocking eviction
  }
  parameter {
    name  = "lazyfree-lazy-expire"
    value = "yes"
  }
  parameter {
    name  = "tcp-keepalive"
    value = "60"
  }
  parameter {
    name  = "timeout"
    value = "300"
  }
  parameter {
    name  = "slowlog-log-slower-than"
    value = "1000"           # Log commands > 1ms
  }
  parameter {
    name  = "latency-tracking"
    value = "yes"
  }

  tags = local.common_tags
}

##############################################################
# Random auth token (if not provided)
##############################################################
resource "random_password" "auth_token" {
  count   = var.auth_token == "" ? 1 : 0
  length  = 64
  special = false  # Redis token cannot contain spaces or @ # "
}

locals {
  auth_token = var.auth_token != "" ? var.auth_token : random_password.auth_token[0].result
}

##############################################################
# Replication Group (Cluster Mode Enabled)
##############################################################
resource "aws_elasticache_replication_group" "main" {
  replication_group_id = local.identifier
  description          = "Radix HFT Redis - ${var.environment}"

  engine_version       = var.engine_version
  node_type            = var.node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.main.name

  # Cluster mode
  num_node_groups            = var.num_shards
  replicas_per_node_group    = var.replicas_per_shard
  automatic_failover_enabled = true
  multi_az_enabled           = var.environment == "prod"

  # Networking
  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  # Encryption
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = aws_kms_key.redis.arn
  auth_token                 = local.auth_token

  # Snapshots
  snapshot_retention_limit  = var.snapshot_retention_limit
  snapshot_window           = var.snapshot_window
  final_snapshot_identifier = var.environment == "prod" ? "${local.identifier}-final" : null

  # Maintenance
  maintenance_window         = "sun:05:00-sun:06:00"
  auto_minor_version_upgrade = true

  # Logging
  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_engine.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "engine-log"
  }

  apply_immediately = var.environment != "prod"

  tags = local.common_tags

  lifecycle {
    ignore_changes = [auth_token]
  }
}

##############################################################
# CloudWatch Log Groups
##############################################################
resource "aws_cloudwatch_log_group" "redis_slow" {
  name              = "/aws/elasticache/${local.identifier}/slow-log"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "redis_engine" {
  name              = "/aws/elasticache/${local.identifier}/engine-log"
  retention_in_days = 7
  tags              = local.common_tags
}

##############################################################
# CloudWatch Alarms
##############################################################
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "${local.identifier}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "EngineCPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Redis engine CPU > 70%"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.main.id
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${local.identifier}-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Redis memory usage > 80%"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.main.id
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "redis_connections" {
  alarm_name          = "${local.identifier}-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CurrConnections"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Average"
  threshold           = 5000
  alarm_description   = "Redis connections > 5000"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.main.id
  }

  tags = local.common_tags
}

##############################################################
# Store auth token in Secrets Manager
##############################################################
resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "${var.environment}/radix-hft/redis-auth-token"
  description             = "Redis AUTH token for ${local.identifier}"
  kms_key_id              = var.secrets_kms_key_arn != "" ? var.secrets_kms_key_arn : null
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id                = aws_secretsmanager_secret.redis_auth.id
  secret_string            = jsonencode({
    auth_token             = local.auth_token
    configuration_endpoint = aws_elasticache_replication_group.main.configuration_endpoint_address
    port                   = 6379
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

##############################################################
# Outputs
##############################################################
output "primary_endpoint" {
  description = "Redis primary endpoint (cluster mode)"
  value       = aws_elasticache_replication_group.main.configuration_endpoint_address
  sensitive   = true
}

output "replication_group_id" {
  value = aws_elasticache_replication_group.main.id
}
output "security_group_id" {
  value = aws_security_group.redis.id
}
output "auth_secret_arn" {
  value     = aws_secretsmanager_secret.redis_auth.arn
  sensitive = true
}
output "port" {
  value = 6379
}
