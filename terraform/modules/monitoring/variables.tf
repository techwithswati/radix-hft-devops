variable "name_prefix" {
  type = string
}
variable "environment" {
  type = string
}
variable "cluster_name" {
  type = string
}
variable "vpc_id" {
  type    = string
  default = ""
}
variable "private_subnet_ids" {
  type    = list(string)
  default = []
}
variable "enable_amp" {
  type    = bool
  default = true
}
variable "enable_amg" {
  type    = bool
  default = true
}
variable "enable_thanos_s3" {
  type    = bool
  default = false
}
variable "amp_retention" {
  type    = string
  default = "30d"
}
variable "amp_retention_days" {
  type    = number
  default = 400
}
variable "pagerduty_endpoint" {
  type    = string
  default = ""
}
variable "pagerduty_routing_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "slack_webhook_url" {
  type    = string
  default = ""
  sensitive = true
}
variable "alert_email" {
  type    = string
  default = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}