##############################################################
# Radix HFT — MSK (Managed Streaming for Kafka) Module
# High-throughput Kafka cluster for:
#   - Market data feed distribution (1M+ msg/s)
#   - Order event streaming (orders, executions, risk-events)
#   - Audit log (immutable append-only)
##############################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.50" }
  }
}

locals {
  identifier  = "${var.name_prefix}-${var.environment}-kafka"
  common_tags = merge(var.tags, {
    ManagedBy   = "Terraform"
    Environment = var.environment
    Project     = "radix-hft"
  })
}

data "aws_caller_identity" "current" {}

##############################################################
# KMS Key
##############################################################
resource "aws_kms_key" "msk" {
  description             = "MSK encryption key - ${local.identifier}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "msk" {
  name          = "alias/${local.identifier}"
  target_key_id = aws_kms_key.msk.key_id
}

##############################################################
# Security Group
##############################################################
resource "aws_security_group" "msk" {
  name        = "${local.identifier}-sg"
  description = "Security group for MSK Kafka cluster"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Kafka TLS from EKS nodes"
    from_port       = 9094
    to_port         = 9094
    protocol        = "tcp"
    security_groups = var.allowed_security_groups
  }

  ingress {
    description     = "Kafka IAM auth from EKS nodes"
    from_port       = 9098
    to_port         = 9098
    protocol        = "tcp"
    security_groups = var.allowed_security_groups
  }

  ingress {
    description = "ZooKeeper (internal)"
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    self        = true
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
# MSK Configuration
##############################################################
resource "aws_msk_configuration" "main" {
  kafka_versions = [var.kafka_version]
  name           = "${local.identifier}-config"
  description    = "Radix HFT Kafka configuration"

  server_properties = <<-EOT
    # Topic defaults
    auto.create.topics.enable=false
    num.partitions=${lookup(var.configuration, "num.partitions", "12")}
    default.replication.factor=${lookup(var.configuration, "default.replication.factor", "3")}
    min.insync.replicas=${lookup(var.configuration, "min.insync.replicas", "2")}

    # Retention
    log.retention.hours=${lookup(var.configuration, "log.retention.hours", "168")}
    log.retention.bytes=${lookup(var.configuration, "log.retention.bytes", "107374182400")}
    log.segment.bytes=1073741824
    log.cleanup.policy=delete

    # Performance
    compression.type=${lookup(var.configuration, "compression.type", "lz4")}
    num.io.threads=8
    num.network.threads=5
    num.replica.fetchers=4
    socket.send.buffer.bytes=102400
    socket.receive.buffer.bytes=102400
    socket.request.max.bytes=104857600

    # Durability
    unclean.leader.election.enable=false
    log.flush.interval.messages=10000
    log.flush.interval.ms=1000

    # Consumer groups
    group.initial.rebalance.delay.ms=3000
    offsets.retention.minutes=10080

    # Security
    allow.everyone.if.no.acl.found=false
  EOT
}

##############################################################
# MSK Cluster
##############################################################
resource "aws_msk_cluster" "main" {
  cluster_name           = local.identifier
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.broker_count

  broker_node_group_info {
    instance_type   = var.instance_type
    client_subnets  = var.client_subnets
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.volume_size
        provisioned_throughput {
          enabled           = true
          volume_throughput = 250
        }
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  # Encryption
  encryption_info {
    encryption_in_transit {
      client_broker = var.encryption_in_transit_client_broker
      in_cluster    = var.encryption_in_transit_in_cluster  
    }
    encryption_at_rest_kms_key_arn = aws_kms_key.msk.arn
  }

  # Authentication - IAM + TLS
  client_authentication {
    sasl {
      iam   = true
      scram = false
    }
    tls {
      certificate_authority_arns = []
    }
    unauthenticated = false
  }

  # Logging
  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
      s3 {
        enabled = true
        bucket  = aws_s3_bucket.msk_logs.id
        prefix  = "kafka-logs/"
      }
    }
  }

  # Monitoring
  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = true
      }
      node_exporter {
        enabled_in_broker = true
      }
    }
  }

  enhanced_monitoring = "PER_TOPIC_PER_PARTITION"

  tags = local.common_tags
}

##############################################################
# S3 Bucket for MSK broker logs
##############################################################
resource "aws_s3_bucket" "msk_logs" {
  bucket        = "${var.name_prefix}-msk-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.environment != "prod"
  tags          = local.common_tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.msk.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "msk_logs" {
  bucket                  = aws_s3_bucket.msk_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##############################################################
# CloudWatch Log Group
##############################################################
resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${local.identifier}/brokers"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.msk.arn
  tags              = local.common_tags
}

##############################################################
# CloudWatch Alarms
##############################################################
resource "aws_cloudwatch_metric_alarm" "kafka_under_replicated" {
  alarm_name          = "${local.identifier}-under-replicated-partitions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnderReplicatedPartitions"
  namespace           = "AWS/Kafka"
  period              = 60
  statistic          = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "MSK has under-replicated partitions - durability risk"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    "Cluster Name" = aws_msk_cluster.main.cluster_name
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "kafka_disk_usage" {
  alarm_name          = "${local.identifier}-disk-usage-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "KafkaDataLogsDiskUsed"
  namespace           = "AWS/Kafka"
  period              = 300
  statistic          = "Average"
  threshold           = 80
  alarm_description   = "MSK broker disk usage > 80%"
  alarm_actions       = var.sns_alarm_arn != "" ? [var.sns_alarm_arn] : []

  dimensions = {
    "Cluster Name" = aws_msk_cluster.main.cluster_name
  }

  tags = local.common_tags
}

##############################################################
# Outputs
##############################################################
output "bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers string"
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
  sensitive   = true
}

output "bootstrap_brokers_sasl_iam" {
  description = "IAM SASL bootstrap brokers"
  value       = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
  sensitive   = true
}

output "cluster_arn" {
  value = aws_msk_cluster.main.arn
}

output "cluster_name" {
  value = aws_msk_cluster.main.cluster_name
}

output "zookeeper_connection_string" {
  value = aws_msk_cluster.main.zookeeper_connect_string
  sensitive = true
}

output "security_group_id" {
  value = aws_security_group.msk.id
}
