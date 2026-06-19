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
  type    = list(string)
  default = []
}
variable "engine_version" {
  type    = string
  default = "7.1"
}
variable "node_type" {
  type    = string
  default = "cache.r7g.large"
}
variable "num_shards" {
  type    = number
  default = 2
}
variable "replicas_per_shard" {
  type    = number
  default = 1
}
variable "auth_token" {
  type      = string
  default   = ""
  sensitive = true
}
variable "at_rest_encryption_enabled" {
  type    = bool
  default = true
}
variable "transit_encryption_enabled" {
  type    = bool
  default = true
}
variable "snapshot_retention_limit" {
  type    = number
  default = 3
}
variable "snapshot_window" {
  type    = string
  default = "03:00-05:00"
}
variable "sns_alarm_arn" {
  type    = string
  default = ""
}
variable "secrets_kms_key_arn" {
  type    = string
  default = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}