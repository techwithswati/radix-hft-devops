variable "name_prefix" {
  type = string
}
variable "environment" {
  type = string
}
variable "region" {
  type = string
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "availability_zones" {
  type = list(string)
}
variable "public_subnet_cidrs" {
  type = list(string)
}
variable "private_subnet_cidrs" {
  type = list(string)
}
variable "database_subnet_cidrs" {
  type = list(string)
}
variable "enable_nat_gateway" {
  type    = bool
  default = true
}
variable "single_nat_gateway" {
  type    = bool
  default = false
}
variable "enable_vpn_gateway" {
  type    = bool
  default = false
}
variable "enable_flow_logs" {
  type    = bool
  default = true
}
variable "flow_logs_retention" {
  type    = number
  default = 30
}
variable "tags" {
  type    = map(string)
  default = {}
}