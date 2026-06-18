##############################################################
# Radix HFT — IAM Roles Module
# IRSA (IAM Roles for Service Accounts) for all services
# Follows least-privilege principle per service
##############################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.50" }
  }
}

locals {
  oidc_provider = replace(var.oidc_provider_url, "https://", "")
  common_tags   = merge(var.tags, { ManagedBy = "Terraform", Environment = var. environment })
}

# Helper: trust policy for IRSA
data "aws_iam_policy_document" "irsa_trust" {
  for_each = var.service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["sts.amazonaws.com"]
    }
  }
}

##############################################################
# Order Service - Secrets Manager + MSK
##############################################################
resource "aws_iam_role" "order_service" {
  name               = "${var.name_prefix}-${var.environment}-order-service"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["order-service"].json
  tags               = merge(local.common_tags, { Service = "order-service" })
}

resource "aws_iam_policy" "order_service" {
  name        = "${var.name_prefix}-${var.environment}-order-service-policy"
  description = "Order service: Secrets Manager + MSK IAM auth"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid     = "ReadSecrets"
        Effects = "Allow"
        Action  = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.environment}/radix-hft/order-service/*"
        ]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.kms_key_arn]
      },
      {
        Sid     = "MSKConnect"
        Effects = "Allow"
        Action  = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
        ]
        Resource = [
          "arn:aws:kafka:${var.region}:${var.account_id}:cluster/${var.msk_cluster_name}/*",
          "arn:aws:kafka:${var.region}:${var.account_id}:topic/${var.msk_cluster_name}/*",
        ]
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "RadixHFT/OrderService"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "order_service" {
  role       = aws_iam_role.order_service.name
  policy_arn = aws_iam_policy.order_service.arn
}

##############################################################
# Market Data Service - MSK + S3 (snapshot storage)
##############################################################
resource "aws_iam_role" "market_data_service" {
  name               = "${var.name_prefix}-${var.environment}-market-data-service"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["market-data-service"].json
  tags               = merge(local.common_tags, { Service = "market-data-service" })
}

resource "aws_iam_policy" "market_data_service" {
  name        = "${var.name_prefix}-${var.environment}-market-data-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid     = "ReadSecrets"
        Effects = "Allow"
        Action  = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.environment}/radix-hft/market-data/*"
        ]
      },
      {
        Sid     = "MSKReadWrite"
        Effects = "Allow"
        Action  = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup",
        ]
        Resource = "*"
      },
      {
        Sid      = "S3Snapshots"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-market-data-snapshots-${var.environment}",
          "arn:aws:s3:::${var.name_prefix}-market-data-snapshots-${var.environment}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "market_data_service" {
  role       = aws_iam_role.market_data_service.name
  policy_arn = aws_iam_policy.market_data_service.arn
}

##############################################################
# Risk Engine - Secrets Manager only (no external data access)
##############################################################
resource "aws_iam_role" "risk_engine" {
  name               = "${var.name_prefix}-${var.environment}-risk-engine"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["risk-engine"].json
  tags               = merge(local.common_tags, { Service = "risk-engine" })
}

resource "aws_iam_policy" "risk_engine" {
  name        = "${var.name_prefix}-${var.environment}-risk-engine-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid     = "ReadSecrets"
        Effects = "Allow"
        Action  = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.environment}/radix-hft/risk-engine/*"
        ]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.kms_key_arn]
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "RadixHFT/RiakEngine"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "risk_engine" {
  role       = aws_iam_role.risk_engine.name
  policy_arn = aws_iam_policy.risk_engine.arn
}

##############################################################
# API Gateway - Secrets Manager only
##############################################################
resource "aws_iam_role" "api_gateway" {
  name               = "${var.name_prefix}-${var.environment}-api-gateway"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["api-gateway"].json
  tags               = merge(local.common_tags, { Service = "api-gateway" })
}

resource "aws_iam_policy" "api_gateway" {
  name        = "${var.name_prefix}-${var.environment}-api-gateway-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid     = "ReadSecrets"
        Effects = "Allow"
        Action  = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.environment}/radix-hft/api-gateway/*"
        ]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway" {
  role       = aws_iam_role.api_gateway.name
  policy_arn = aws_iam_policy.api_gateway.arn
}

##############################################################
# External Secrets Operator - Read all environment secrets
##############################################################
resource "aws_iam_role" "external_secrets" {
  name               = "${var.name_prefix}-${var.environment}-external_secrets"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["external_secrets"].json
  tags               = merge(local.common_tags, { Service = "external_secrets" })
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.name_prefix}-${var.environment}-external_secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid     = "ReadEnvironmentSecrets"
        Effects = "Allow"
        Action  = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.environment}/radix-hft/*"
        ]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

##############################################################
# Karpenter Node Role
##############################################################
resource "aws_iam_role" "karpenter_node" {
  name = "${var.name_prefix}-${var.environment}-karpenter_node"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])


  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.name_prefix}-${var.environment}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
  tags = local.common_tags
}

##############################################################
# Karpenter Controller Role (IRSA)
##############################################################
resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.name_prefix}-${var.environment}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["karpenter"].json
  tags               = local.common_tags
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "${var.name_prefix}-${var.environment}-karpenter-controller-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid     = "AllowScopedEC2InstanceActions"
        Effects = "Allow"
        Action  = [
          "ec2:RunInstances",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
        ]
        Resource = [
          "arn:aws:ec2:${var.region}::image/*",
          "arn:aws:ec2:${var.region}:${var.account_id}:instance/*",
          "arn:aws:ec2:${var.region}:${var.account_id}:spot-instance-request/*",
          "arn:aws:ec2:${var.region}:${var.account_id}:security-group/*",
          "arn:aws:ec2:${var.region}:${var.account_id}:subnet/*",
          "arn:aws:ec2:${var.region}:${var.account_id}:launch-template/*",
        ]
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Resource = ["arn:aws:ec2:${var.region}:${var.account_id}:instance/*",]
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid = "AllowInstanceProfilePassRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [aws_iam_role.karpenter_node.arn]
      },
      {
        Sid = "AllowDescribeActions"
        Effect= "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "pricing:GetProducts",
          "ssm:GetParameter"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

##############################################################
# Outputs
##############################################################
output "order_service_role_arn" {
  value = aws_iam_role.order_service.arn
}
output "market_data_role_arn" {
  value = aws_iam_role.market_data_service.arn
}
output "risk_engine_role_arn" {
  value = aws_iam_role.risk_engine.arn
}
output "api_gateway_role_arn" {
  value = aws_iam_role.api_gateway.arn
}
output "external_secrets_role_arn" {
  value = aws_iam_role.external_secrets.arn
}
output "karpenter_controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}
output "karpenter_node_role_arn" {
  value = aws_iam_role.karpenter_node.arn
}
output "karpenter_node_instance_profile" {
  value = aws_iam_instance_profile.karpenter_node.name 
}
