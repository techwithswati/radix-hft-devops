variable "name_prefix" {
  type = string
}
variable "environment" {
  type = string
}
variable "vpc_id" {
  type = string
}
variable "subnet_ids" {
  type = list(string)
}
variable "allowed_security_groups" {
  type = list(string)
  default = []
}
variable "engine" {
  type = string
  default = "aurora-postgresql"
}
variable "engine_version" {
  type = string
  default = "16.2"
}
variable "instance_class" {
  type = string
  default = "db.r7g.large"
}
variable "cluster_size" {
  type = number
  default = 2
}
variable "use_serverless_v2" {
  type = bool
  default = false
}
variable "database_name" {
  type = string
  default = "radix_hft"
}
variable "master_username" {
  type = string
  default = "radix_admin"
}
variable "master_password" {
  type = string
  sensitive = true
}
variable "deletion_protection" {
  type = bool
  default = false
}
variable "backup_retention_period" {
  type = number
  default = 7
}
variable "preferred_backup_window" {
  type = string
  default = "02:00-03:00"
}
variable "storage_encrypted" {
  type = bool
  default = true
}
variable "performance_insights_enabled" {
  type = bool
  default = true
}
variable "performance_insights_retention_period" {
  type = number
  default = 7
}
variable "enabled_cloudwatch_logs_exports" {
  type = list(string)
  default = ["postgresql"]
}
variable "sns_alarm_arn" {
  type = string
  default = ""
}
variable "tags" {
  type = map(string)
  default = {}
}

variable "parameters" {
  description = "Additional cluster parameter overrides"
  type = map(string)
  default = {}
}
