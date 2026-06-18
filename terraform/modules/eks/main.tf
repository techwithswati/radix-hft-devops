##############################################################
# Radix HFT - EKS Cluster Module
# Provisions a hardened EKS 1.30 cluster with:
#  - Multi-AZ node groups (on-demand + spot)
#  - Managed add-ons (CoreDNS, kube-proxy, VPC CNI)
#  - OIDC provider for IRSA
#  - CIS Benchmark hardening
##############################################################

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cluster_name    = "${var.name_prefix}-${var.environment}"
  account_id      = data.aws_caller_identity.current.account_id
  region          = data.aws_region.current.name
  oidc_issuer_url = aws_eks_cluster.main.identity[0].oidc[0].issuer
  oidc_provider   = replace(local.oidc_issuer_url, "https://", "")

  common_tags = merge(var.tags, {
    ManagedBy   = "Terraform"
    Environment = var.environment
    Project     = "radix-hft"
    CostCenter  = "trading-infrastructure"
  })
}

##############################################################
# EKS Cluster
##############################################################
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.environment == "prod" ? false : true
    public_access_cidrs     = var.allowed_cidr_blocks
    security_group_ids      = [aws_security_group.cluster.id]
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.service_cidr
    ip_family         = "ipv4"
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy {
    support_type = "EXTENDED"
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_cloudwatch_log_group.eks,
  ]
}

##############################################################
# KMS Key for Secret Encryption
##############################################################
resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption Key - ${local.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key.json
  tags                    = local.common_tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

data "aws_iam_policy_document" "kms_key" {
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowEKSToUseKey"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions   = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}

##############################################################
# OIDC Provider (required for IRSA)
##############################################################
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  tags            = local.common_tags
}

##############################################################
# Node Groups
##############################################################

# On-Demand: Trading Critical (order-service, risk-engine)
resource "aws_eks_node_group" "trading_critical" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "trading-critical"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2_x86_64"
  capacity_type   = "ON_DEMAND"
  instance_types  = ["c6i.4xlarge"]
  disk_size       = 100

  scaling_config {
    desired_size = var.trading_critical_desired
    max_size     = var.trading_critical_max
    min_size     = var.trading_critical_min
  }

  update_config {
    max_unavailable_percentage = 25
  }

  labels = {
    role       = "trading-critical"
    environment = var.environment
    workload   = "latency-sensitive"
  }

  taint {
    key    = "workload"
    value  = "trading-critical"
    effect = "NO_SCHEDULE"
  }

  launch_template {
    id      = aws_launch_template.trading_critical.id
    version = "$Latest"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [ scaling_config[0].desired_size ]
  }
}

# On-Demand: Market Data (high-memory, high-throughput)
resource "aws_eks_node_group" "market_data" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "market-data"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2_x86_64"
  capacity_type   = "ON_DEMAND"
  instance_types  = ["r6i.2xlarge"]
  disk_size       = 200

  scaling_config {
    desired_size = 4
    max_size     = 12
    min_size     = 2
  }

  labels = {
    role       = "market-data"
    workload   = "data-intensive"
  }

  launch_template {
    id      = aws_launch_template.market_data.id
    version = "$Latest"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [ scaling_config[0].desired_size ]
  }
}

# Spot: System workloads (ArgoCD, monitoring)
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2_x86_64"
  capacity_type   = var.environment == "prod" ? "ON_DEMAND" : "SPOT"
  instance_types  = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge"]

  scaling_config {
    desired_size = 3
    max_size     = 6
    min_size     = 2
  }

  labels = {
    role = "system"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [ scaling_config[0].desired_size ]
  }
}

##############################################################
# Launch Templates (Nitro + CPU pinning for ultra-low latency)
##############################################################
resource "aws_launch_template" "trading_critical" {
  name_prefix   = "${local.cluster_name}-trading-critical-"
  image_id      = data.aws_ami.eks_optimized.id
  instance_type = "c6i.4xlarge"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }

  # CPU pinning + huge pages for ultra-low latency
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    set -ex
    cat <<'KUBELET_EOF' >> /etc/kubernetes/kubelet/kubelet-config.json
    {
      "cpuManagerPolicy": "static",
      "topologyManagerPolicy": "single-numa-node",
      "reservedSystemCPUs": "0-1"
    }
    KUBELET_EOF
    echo "vm.nr_hugepages=512" >> /etc/sysctl.conf
    sysctl -p
    /etc/eks/bootstrap.sh ${local.cluster_name} \
      --kubelet-extra-args '--node-labels=workload=trading-critical,role=order-service'
    USERDATA 
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.cluster_name}-trading-critical"
    })
  }
}

resource "aws_launch_template" "market_data" {
  name_prefix   = "${local.cluster_name}-market-data-"
  image_id      = data.aws_ami.eks_optimized.id
  instance_type = "r6i.2xlarge"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 200
      volume_type           = "gp3"
      iops                  = 6000
      throughput            = 250
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.cluster_name}-market-data"
    })
  }
}

##############################################################
# EKS Managed Add-ons
##############################################################
resource "aws_eks_addon" "coredns" {
    cluster_name                = aws_eks_cluster.main.name
    addon_name                  = "coredns"
    addon_version               = "v1.11.1-eksbuild.8"
    resolve_conflicts_on_update = "PRESERVE"

    configuration_values = jsonencode({
      replicaCount = var.environment == "prod" ? 3 : 2
      resources = {
        limits = {
          cpu    = "200m",
          memory = "200Mi"
        }
        requests = {
          cpu    = "100m",
          memory = "128Mi"
        }
      }
    })

    tags = local.common_tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = "v1.30.0-eksbuild.3"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = "v1.18.1-eksbuild.3"
  service_account_role_arn    = aws_iam_role.vpc_cni.arn
  resolve_conflicts_on_update = "OVERWRITE"
  
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET = "1"
    }
  })

  tags = local.common_tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.31.0-eksbuild.1"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  tags                        = local.common_tags
}

##############################################################
# CloudWatch Log Group
##############################################################
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.eks.arn
  tags              = local.common_tags
}

##############################################################
# Data Sources
##############################################################
data "aws_ami" "eks_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-${var.kubernetes_version}-v*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

##############################################################
# Outputs
##############################################################
output "cluster_id" {
  description = "EKS Cluster ID"
  value       = aws_eks_cluster.main.id
}

output "cluster_endpoint" {
  description = "EKS Cluster endpoint"
  value       = aws_eks_cluster.main.endpoint
  sensitive   = true
}

output "cluster_certificate_authority" {
  description = "EKS Cluster CA data"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA"
  value       = local.oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_security_group_id" {
  value = aws_security_group.nodes.id
}

output "node_group_arns" {
  description = "ARNs of managed node groups"
  value = {
    trading_critical = aws_eks_node_group.trading_critical.arn
    market_data      = aws_eks_node_group.market_data.arn
    system           = aws_eks_node_group.system.arn
  }
}
