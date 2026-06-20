##############################################################
# Radix HFT — Monitoring Infrastructure Module
# Amazon Managed Prometheus (AMP) + Managed Grafana (AMG)
# SNS for alert routing to PagerDuty + Slack
##############################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.50" }
  }
}

locals {
  identifier = "${var.name_prefix}-${var.environment}"
  common_tags = merge(var.tags, {
    ManagedBy   = "Terraform"
    Environment = var.environment
    Project     = "radix-hft"
  })
}

data "aws_caller_identity" "current" {}

##############################################################
# SNS Topics for alerts
##############################################################
resource "aws_kms_key" "sns" {
  description             = "SNS encryption key - ${local.identifier}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_sns_topic" "p0_alerts" {
  name              = "${local.identifier}-p0-alerts"
  kms_master_key_id = aws_kms_key.sns.id
  tags              = merge(local.common_tags, { Severity = "P0" })
}

resource "aws_sns_topic" "p1_alerts" {
  name              = "${local.identifier}-p1-alerts"
  kms_master_key_id = aws_kms_key.sns.id
  tags              = merge(local.common_tags, { Severity = "P1" })
}

resource "aws_sns_topic" "p2_alerts" {
  name              = "${local.identifier}-p2-alerts"
  kms_master_key_id = aws_kms_key.sns.id
  tags              = merge(local.common_tags, { Severity = "P2" })
}

# PagerDuty HTTPS subscription for P0/P1
resource "aws_sns_topic_subscription" "pagerduty_p0" {
  count     = var.pagerduty_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.p0_alerts.arn
  protocol  = "https"
  endpoint  = var.pagerduty_endpoint
}

resource "aws_sns_topic_subscription" "pagerduty_p1" {
  count     = var.pagerduty_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.p1_alerts.arn
  protocol  = "https"
  endpoint  = var.pagerduty_endpoint
}

# Email subscription for P2
resource "aws_sns_topic_subscription" "email_p2" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.p2_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

##############################################################
# Amazon Managed Prometheus (AMP)
##############################################################
resource "aws_prometheus_workspace" "main" {
  count = var.enable_amp ? 1 : 0

  alias = "${local.identifier}-prometheus"

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp[0].arn}:*"
  }

  tags = local.common_tags
}

resource "aws_prometheus_alert_manager_definition" "main" {
  count        = var.enable_amp ? 1 : 0
  workspace_id = aws_prometheus_workspace.main[0].id

  definition = <<-EOT
    alertmanager_config: |
      global:
        resolve_timeout: 5m
        slack_api_url: '${var.slack_webhook_url}'

      route:
        group_by: ['alertname', 'service', 'severity']
        group_wait: 10s
        group_interval: 5m
        repeat_interval: 4h
        receiver: 'default'
        routes:
          - match:
              severity: critical
            receiver: pagerduty
            repeat_interval: 1h
          - match:
              severity: warning
            receiver: slack-warnings
            repeat_interval: 6h

      receivers:
        - name: 'default'
          slack_configs:
            - channel: '#trading-alerts'
              title: '{{ template "slack.title" . }}'
              text: '{{ template "slack.text" . }}'
              send_resolved: true

        - name: 'pagerduty'
          pagerduty_configs:
            - routing_key: '${var.pagerduty_routing_key}'
              severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
              description: '{{ .CommonAnnotations.summary }}'
              client: 'Radix HFT Prometheus'
              client_url: 'https://grafana.${var.environment}.radix-hft.com'
          slack_configs:
            - channel: '#trading-p0'
              title: '🚨 P0 ALERT: {{ .CommonAnnotations.summary }}'
              text: '{{ .CommonAnnotations.description }}'
              
        - name: 'slack-warnings'
          slack_configs:
            - channel: '#trading-alerts'
              title: '⚠️ {{ .CommonAnnotations.summary }}'
              text: '{{ .CommonAnnotations.description }}'
              send_resolved: true
  EOT
}

resource "aws_prometheus_rule_group_namespace" "trading" {
  count        = var.enable_amp ? 1 : 0
  name         = "trading-platform"
  workspace_id = aws_prometheus_workspace.main[0].id

  data = file("${path.module}/../../../monitoring/prometheus/alerts.yaml")
}

resource "aws_cloudwatch_log_group" "amp" {
  count             = var.enable_amp ? 1 : 0
  name              = "/aws/prometheus/${local.identifier}"
  retention_in_days = 30
  tags              = local.common_tags
}

##############################################################
# Amazon Managed Grafana (AMG)
##############################################################
resource "aws_grafana_workspace" "main" {
  count = var.enable_amg ? 1 : 0

  name                      = "${local.identifier}-grafana"
  description               = "Radix HFT Grafana - ${var.environment}"
  account_access_type       = "CURRENT_ACCOUNT"
  authentication_providers  = ["AWS_SSO"]
  permission_type           = "SERVICE_MANAGED"
  role_arn                  = aws_iam_role.grafana[0].arn

  data_sources              = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]
  notification_destinations = ["SNS"]

  vpc_configuration {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.grafana[0].id]
  }

  tags = local.common_tags
}

resource "aws_grafana_workspace_api_key" "admin" {
  count           = var.enable_amg ? 1 : 0
  key_name        = "terraform-admin"
  key_role        = "ADMIN"
  seconds_to_live = 2592000  # 30 days
  workspace_id    = aws_grafana_workspace.main[0].id
}

resource "aws_iam_role" "grafana" {
  count = var.enable_amg ? 1 : 0
  name  = "${local.identifier}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "grafana_prometheus" {
  count      = var.enable_amg ? 1 : 0
  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  count      = var.enable_amg ? 1 : 0
  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_security_group" "grafana" {
  count       = var.enable_amg ? 1 : 0
  name        = "${local.identifier}-grafana-sg"
  description = "Security group for Amazon Managed Grafana"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

##############################################################
# Thanos S3 bucket (long-term metrics storage)
##############################################################
resource "aws_s3_bucket" "thanos" {
  count         = var.enable_thanos_s3 ? 1 : 0
  bucket        = "${var.name_prefix}-thanos-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  tags          = merge(local.common_tags, { Purpose = "long-term-metrics" })
}

resource "aws_s3_bucket_versioning" "thanos" {
  count  = var.enable_thanos_s3 ? 1 : 0
  bucket = aws_s3_bucket.thanos[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "thanos" {
  count  = var.enable_thanos_s3 ? 1 : 0
  bucket = aws_s3_bucket.thanos[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "thanos" {
  count  = var.enable_thanos_s3 ? 1 : 0
  bucket = aws_s3_bucket.thanos[0].id

  rule {
    id     = "thanos-tiering"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration {
      days = var.amp_retention_days
    }
  }
}

resource "aws_s3_bucket_public_access_block" "thanos" {
  count                   = var.enable_thanos_s3 ? 1 : 0
  bucket                  = aws_s3_bucket.thanos[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##############################################################
# Outputs
##############################################################
output "amp_workspace_id" {
  value = var.enable_amp ? aws_prometheus_workspace.main[0].id : ""
}

output "amp_workspace_endpoint" {
  value = var.enable_amp ? aws_prometheus_workspace.main[0].prometheus_endpoint : ""
}

output "grafana_workspace_url" {
  value = var.enable_amg ? aws_grafana_workspace.main[0].endpoint : ""
}

output "p0_sns_topic_arn" {
  value = aws_sns_topic.p0_alerts.arn
}

output "p1_sns_topic_arn" {
  value = aws_sns_topic.p1_alerts.arn
}

output "p2_sns_topic_arn" {
  value = aws_sns_topic.p2_alerts.arn
}

output "thanos_bucket_id" {
  value = var.enable_thanos_s3 ? aws_s3_bucket.thanos[0].id : ""
}