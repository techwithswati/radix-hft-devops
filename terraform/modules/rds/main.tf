##############################################################
# Radix HFT — Aurora PostgreSQL Module
# Multi-AZ Aurora cluster for trade ledger & audit log
# Enhanced monitoring, Performance Insights, auto-scaling
##############################################################

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.50" }
    random = { source = "hashicorp/random", version = "~> 3.6"  }
  }
}

locals {
  identifier  = "${var.name_prefix}-${var.environment}-aurora"
  port        = 5432
  common_tags = merge(var.tags, { ManagedBy = "Terraform", Environment = var.environment })
}

##############################################################
# Subnet Group
##############################################################
resource "aws_db_subnet_group" "main" {
  name        = "${local.identifier}-subnet-group"
  description = "Aurora PostgreSQL subnet group - ${var.environment}"
  subnet_ids  = var.subnet_ids
  tags        = local.common_tags
}

##############################################################
# Parameter Groups
##############################################################
resource "aws_rds_cluster_parameter_group" "main" {
  name        = "${local.identifier}-cluster-pg"
  family      = "aurora-postgresql16"
  description = "Radix HFT Aurora cluster parameters"

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements,auto_explain,pg_cron"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
  parameter {
    name  = "auto_explain.log_min_duration"
    value = "500"
  }
  parameter {
    name  = "auto_explain.log_analyze"
    value = "1"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }
  parameter {
    name  = "deadlock_timeout"
    value = "1000"
  }
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "30000"  # 30s - prevent long idle transactions
  }
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  tags = local.common_tags
}

resource "aws_db_parameter_group" "main" {
  name        = "${local.identifier}-instance-pg"
  family      = "aurora-postgresql16"
  description = "Radix HFT Aurora instance parameters"

  parameter {
    name  = "log_temp_files"
    value = "0"
  }

  tags = local.common_tags
}

##############################################################
# KMS Key for encryption at rest
##############################################################
resource "aws_kms_key" "aurora" {
  description             = "Aurora encryption key - ${local.identifier}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "aurora" {
  name          = "alias/${local.identifier}"
  target_key_id = aws_kms_key.aurora.key_id
}

##############################################################
# Security Group
##############################################################
resource "aws_security_group" "aurora" {
  name        = "${local.identifier}-sg"
  description = "Security group for Aurora PostgreSQL cluster"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = local.port
    to_port         = local.port
    protocol        = "tcp"
    security_groups = var.allowed_security_groups
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.identifier}-sg" })
}

##############################################################
# IAM Role for Enhanced Monitoring
##############################################################
resource "aws_iam_role" "monitoring" {
  name = "${local.identifier}-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

##############################################################
# Aurora Cluster
##############################################################
resource "aws_rds_cluster" "main" {
  cluster_identifier = local.identifier
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version
  database_name      = var.database_name
  master_username    = var.master_username
  master_password    = var.master_password
  port               = local.port

  db_subnet_group_name            = aws_db_subnet_group.main.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]

  # Encryption
  storage_encrypted = true
  kms_key_id        = aws_kms_key.aurora.arn

  # Backup
  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = "sun:04:00-sun:05:00"
  copy_tags_to_snapshot        = true
  skip_final_snapshot          = var.environment != "prod"
  final_snapshot_identifier    = var.environment == "prod" ? "${local.identifier}-final-${formatdate("YYYY-MM-DD", timestamp())}" : null

  # High Availability
  deletion_protection = var.deletion_protection

  # Logging
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  # Performance Insights
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? aws_kms_key.aurora.arn : null
  performance_insights_retention_period = var.performance_insights_retention_period

  # Serverless v2 scaling (optional - use for dev/staging)
  dynamic "serverlessv2_scaling_configuration" {
    for_each = var.use_serverless_v2 ? [1] : []
    content {
      min_capacity = 0.5
      max_capacity = 64
    }
  }

  apply_immediately = var.environment != "prod"

  lifecycle {
    ignore_changes = [master_password]
  }

  tags = local.common_tags
}

##############################################################
# Aurora Cluster Instances
##############################################################
resource "aws_rds_cluster_instance" "main" {
  count = var.cluster_size

  identifier              = "${local.identifier}-${count.index + 1}"
  cluster_identifier      = aws_rds_cluster.main.id
  engine                  = aws_rds_cluster.main.engine
  engine_version          = aws_rds_cluster.main.engine_version
  instance_class          = var.use_serverless_v2 ? "db.serverless" : var.instance_class
  db_parameter_group_name = aws_db_parameter_group.main.name

  # Primary instance gets more frequent monitoring
  monitoring_interval = count.index == 0 ? 15 : 60
  monitoring_role_arn = aws_iam_role.monitoring.arn

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? aws_kms_key.aurora.arn : null
  performance_insights_retention_period = var.performance_insights_retention_period

  auto_minor_version_upgrade = true
  apply_immediately          = var.environment != "prod"

  tags = merge(local.common_tags, {
    Name = "${local.identifier}-${count.index == 0 ? "writer" : "reader-${count.index}"}"
    Role = count.index == 0 ? "writer" : "reader"
  })
}

##############################################################
# Auto Scaling for read replicas
##############################################################
resource "aws_appautoscaling_target" "aurora_read_replicas" {
  count              = var.environment == "prod" ? 1 : 0
  max_capacity       = 5
  min_capacity       = 1
  resource_id        = "cluster:${aws_rds_cluster.main.id}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  service_namespace  = "rds"
}

resource "aws_appautoscaling_policy" "aurora_read_replicas" {
  count              = var.environment == "prod" ? 1 : 0
  name               = "${local.identifier}-read-replica-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.aurora_read_replicas[0].resource_id
  scalable_dimension = aws_appautoscaling_target.aurora_read_replicas[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.aurora_read_replicas[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "RDSReaderAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 300
    scale_out_cooldown = 30
  }
}

##############################################################
# CloudWatch Alarms
##############################################################
resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  alarm_name          = "${local.identifier}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Aurora CPU exceeds 80%"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.id
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "aurora_freeable_memory" {
  alarm_name          = "${local.identifier}-low-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 536870912  # 512 MB
  alarm_description   = "Aurora freeable memory < 512MB"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.id
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "aurora_replica_lag" {
  alarm_name          = "${local.identifier}-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 100  # 100ms
  alarm_description   = "Aurora replica lag > 100ms"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.id
  }

  tags = local.common_tags
}

##############################################################
# Outputs
##############################################################
output "cluster_endpoint" {
  value     = aws_rds_cluster.main.endpoint
  sensitive = true
}
output "reader_endpoint" {
  value     = aws_rds_cluster.main.reader_endpoint
  sensitive = true
}
output "cluster_identifier" {
  value = aws_rds_cluster.main.id
}
output "cluster_arn" {
  value = aws_rds_cluster.main.arn
}
output "port" {
  value = aws_rds_cluster.main.port
}
output "database_name" {
  value = aws_rds_cluster.main.database_name
}
output "security_group_id" {
  value = aws_security_group.aurora.id
}
output "kms_key_arn" {
  value = aws_kms_key.aurora.arn
}
