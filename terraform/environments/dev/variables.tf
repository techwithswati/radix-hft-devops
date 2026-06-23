variable "db_password" {
  description = "Aurora master password — sourced from AWS Secrets Manager in CI"
  type        = string
  sensitive   = true
}