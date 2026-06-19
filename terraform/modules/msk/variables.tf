variable "name_prefix" {
  type = string
}
variable "environment" {
  type = string
}
variable "vpc_id" {
  type = string
}
variable "client_subnets" {
  type = list(string)
}
variable "allowed_security_groups" {
  type    = list(string)
  default = []
}
variable "kafka_version" {
  type    = string
  default = "3.7.0"
}
variable "instance_type" {
  type    = string
  default = "kafka.m5.2xlarge"
}
variable "broker_count" {
  type    = number
  default = 3
}
variable "volume_size" {
  type    = number
  default = 1000
}
variable "encryption_in_transit_client_broker" {
  type    = string
  default = "TLS"
}
variable "encryption_in_transit_in_cluster" {
  type    = bool
  default = true
}
variable "sns_alarm_arn" {
  type    = string
  default = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "configuration" {
  description = "Kafka broker configuration key-value pairs"
  type        = map(string)
  default     = {}
}
