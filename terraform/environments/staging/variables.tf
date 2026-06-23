variable "db_password" {
  description = "Aurora master password — sourced from AWS Secrets Manager in CI"
  type        = string
  sensitive   = true
}

variable "vpn_cidr_blocks" {
  description = "CIDR blocks for VPN/bastion access to EKS API endpoint"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "Email address for P2 alert SNS subscriptions"
  type        = string
  default     = ""
}

variable "pagerduty_routing_key" {
  description = "PagerDuty Events API v2 routing key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for Alertmanager"
  type        = string
  sensitive   = true
  default     = ""
}