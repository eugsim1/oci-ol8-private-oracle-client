variable "enabled" {
  type        = bool
  default     = true
  description = "Create the OCI Database Tools private endpoint and Autonomous Database connection."
}

variable "compartment_id" { type = string }
variable "vcn_id" { type = string }
variable "subnet_id" { type = string }
variable "network_security_group_id" { type = string }
variable "autonomous_database_id" { type = string }
variable "autonomous_database_display_name" { type = string }
variable "autonomous_database_mtls_required" { type = bool }
variable "connection_string" { type = string }
variable "database_user_name" {
  type    = string
  default = "ADMIN"
}
variable "database_user_password" {
  type      = string
  sensitive = true
}

variable "connection_display_name" {
  type     = string
  default  = null
  nullable = true
}
variable "private_endpoint_display_name" {
  type     = string
  default  = null
  nullable = true
}
variable "endpoint_service_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional Database Tools endpoint-service OCID. When null, Terraform discovers the active service in the compartment."
}
variable "password_secret_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional existing Vault secret OCID containing the database password. When null, this module creates a Vault, key, and secret."
}
variable "vault_dns_wait_duration" {
  type        = string
  default     = "120s"
  description = "Wait after creating a Vault before calling its unique KMS management hostname, allowing OCI DNS propagation to complete."

  validation {
    condition     = can(regex("^[1-9][0-9]*(ms|s|m|h)$", var.vault_dns_wait_duration))
    error_message = "vault_dns_wait_duration must be a positive duration such as 120s or 5m."
  }
}
variable "runtime_identity" {
  type        = string
  default     = "AUTHENTICATED_PRINCIPAL"
  description = "Identity used by Database Tools to retrieve the password secret at runtime."

  validation {
    condition     = contains(["AUTHENTICATED_PRINCIPAL", "RESOURCE_PRINCIPAL"], var.runtime_identity)
    error_message = "runtime_identity must be AUTHENTICATED_PRINCIPAL or RESOURCE_PRINCIPAL."
  }
}
