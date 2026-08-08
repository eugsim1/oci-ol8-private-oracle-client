variable "compartment_id" { type = string }
variable "vcn_id" { type = string }
variable "subnet_id" { type = string }
variable "client_cidr" { type = string }
variable "db_name" { type = string }
variable "display_name" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "db_version" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional Oracle AI Database version. Set 19c or 26ai; null lets OCI select the current regional default."

  validation {
    condition     = var.db_version == null ? true : contains(["19c", "26ai"], var.db_version)
    error_message = "db_version must be null, 19c, or 26ai."
  }
}
variable "db_workload" { type = string }
variable "compute_count" { type = number }
variable "data_storage_size_in_tbs" { type = number }
variable "license_model" { type = string }
variable "private_endpoint_label" { type = string }
variable "is_mtls_connection_required" {
  type        = bool
  default     = false
  description = "When false, ADB accepts both one-way TLS and mTLS. Database Tools uses the one-way TLS profile; wallet clients can continue using mTLS."
}
variable "private_endpoint_detach_wait_duration" {
  type        = string
  default     = "300s"
  description = "Destroy-time delay after Autonomous Database deletion so OCI can detach its private-endpoint VNIC before deleting the NSG."

  validation {
    condition     = can(regex("^[1-9][0-9]*(ms|s|m|h)$", var.private_endpoint_detach_wait_duration))
    error_message = "private_endpoint_detach_wait_duration must be a positive duration such as 300s or 10m."
  }
}
