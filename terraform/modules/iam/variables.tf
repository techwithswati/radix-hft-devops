variable "name_prefix" {
  type = string
}
variable "environment" {
  type = string
}
variable "region" {
  type = string
}
variable "account_id" {
  type = string
}
variable "oidc_provider_url" {
  type = string
}
variable "oidc_provider_arn" {
  type = string
}
variable "kms_key_arn" {
  type = string
}
variable "msk_cluster_name" {
  type = string
  default = ""
}
variable "tags" {
  type = map(string)
  default = {}
}

variable "service_accounts" {
  description = "Map of service account names to namespace/name for IRSA"
  type = map(object({
    namespace = string
    name      = string
  }))
  default = {
    "order-service" = {
      namespace = "trading"
      name      = "order-service"
    }
    "market-data-service" = {
      namespace = "trading"
      name      = "market-data-service"
    }
    "risk-engine" = {
      namespace = "trading"
      name      = "risk-engine"
    }
    "api-gateway" = {
      namespace = "trading"
      name      = "api-gateway"
    }
    "external-secrets" = {
      namespace = "external-secrets"
      name      = "external-secrets"
    }
    "karpenter" = {
      namespace = "karpenter"
      name      = "karpenter"
    }
  }
}