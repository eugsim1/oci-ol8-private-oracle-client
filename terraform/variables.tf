variable "region" { type = string }
variable "compartment_id" { type = string }
variable "availability_domain_index" {
  type        = number
  default     = 0
  description = "Zero-based index into the sorted availability-domain names returned by OCI."
  validation {
    condition     = var.availability_domain_index >= 0 && floor(var.availability_domain_index) == var.availability_domain_index
    error_message = "availability_domain_index must be a non-negative whole number."
  }
}
variable "ssh_public_key_path" {
  type        = string
  description = "Filesystem path to the OpenSSH public key installed for opc and oracle."
}
variable "create_bastion_session" {
  type        = bool
  default     = true
  description = "Create a temporary managed SSH session from OCI Bastion to the private compute node."
}
variable "bastion_session_public_key_path" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional local OpenSSH public-key path for the Bastion session. When null, ssh_public_key_path is used."

  validation {
    condition     = var.bastion_session_public_key_path == null ? true : length(trimspace(var.bastion_session_public_key_path)) > 0
    error_message = "bastion_session_public_key_path must be null or a non-empty filesystem path."
  }
}
variable "controller_public_cidr" {
  type        = string
  description = "Public CIDR of the Ansible controller allowed to open OCI Bastion sessions."
  validation {
    condition     = var.controller_public_cidr != "0.0.0.0/0" || var.allow_open_bastion_cidr
    error_message = "Use a restricted controller CIDR, or explicitly set allow_open_bastion_cidr = true to permit 0.0.0.0/0."
  }
}
variable "allow_open_bastion_cidr" {
  type        = bool
  default     = false
  description = "Explicit security override allowing controller_public_cidr to be 0.0.0.0/0."
}
variable "compute_node_name" {
  type        = string
  default     = "ol8-private-oracle-client"
  description = "OCI display name for the Oracle Linux compute instance and prefix for related resources."
  validation {
    condition     = length(trimspace(var.compute_node_name)) > 0
    error_message = "compute_node_name must not be empty."
  }
}
variable "shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}
variable "ocpus" {
  type    = number
  default = 1
}
variable "memory_in_gbs" {
  type    = number
  default = 16
}
variable "boot_volume_size_in_gbs" {
  type    = number
  default = 100
}
variable "vcn_cidr" {
  type    = string
  default = "10.30.0.0/16"
}
variable "private_subnet_cidr" {
  type    = string
  default = "10.30.1.0/24"
}
variable "bastion_session_ttl_seconds" {
  type    = number
  default = 10800
}
variable "bastion_plugin_wait_duration" {
  type        = string
  default     = "600s"
  description = "Delay before testing whether the instance Bastion plugin is RUNNING."

  validation {
    condition     = can(regex("^[1-9][0-9]*(ms|s|m|h)$", var.bastion_plugin_wait_duration))
    error_message = "bastion_plugin_wait_duration must be a positive duration such as 600s or 15m."
  }
}
variable "adb_admin_password" {
  type        = string
  sensitive   = true
  description = "Autonomous Database ADMIN password. Supply through TF_VAR_adb_admin_password."
  validation {
    condition     = length(var.adb_admin_password) >= 12 && length(var.adb_admin_password) <= 30
    error_message = "The ADB ADMIN password must contain between 12 and 30 characters."
  }
}
variable "adb_db_name" {
  type    = string
  default = "ORAPRIV"
}
variable "adb_display_name" {
  type    = string
  default = "Private Autonomous Database"
}
variable "adb_workload" {
  type    = string
  default = "OLTP"
  validation {
    condition     = contains(["OLTP", "DW", "AJD", "APEX"], var.adb_workload)
    error_message = "adb_workload must be OLTP, DW, AJD, or APEX."
  }
}
variable "adb_compute_count" {
  type    = number
  default = 2
}
variable "adb_storage_size_in_tbs" {
  type    = number
  default = 1
}
variable "adb_license_model" {
  type    = string
  default = "LICENSE_INCLUDED"
}
variable "adb_private_endpoint_label" {
  type    = string
  default = "oraprivadb"
}
variable "adb_is_mtls_connection_required" {
  type        = bool
  default     = false
  description = "When false, ADB permits both TLS and mTLS. OCI Database Tools uses TLS; downloaded-wallet clients may continue using mTLS."
}
variable "adb_private_endpoint_detach_wait_duration" {
  type        = string
  default     = "300s"
  description = "Destroy-time wait for the Autonomous Database private-endpoint VNIC to detach from its NSG."

  validation {
    condition     = can(regex("^[1-9][0-9]*(ms|s|m|h)$", var.adb_private_endpoint_detach_wait_duration))
    error_message = "adb_private_endpoint_detach_wait_duration must be a positive duration such as 300s or 10m."
  }
}

variable "database_tools_enabled" {
  type        = bool
  default     = true
  description = "Create an OCI Database Tools private endpoint and connection for the Terraform-created Autonomous Database."
}
variable "database_tools_connection_display_name" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional Database Tools connection display name. Null derives the name from adb_display_name."
}
variable "database_tools_private_endpoint_display_name" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional Database Tools private-endpoint display name. Null derives the name from adb_display_name."
}
variable "database_tools_endpoint_service_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional Database Tools endpoint-service OCID. Null discovers the active endpoint service in the compartment."

  validation {
    condition     = var.database_tools_endpoint_service_id == null ? true : can(regex("^ocid1\\.databasetoolsendpointservice\\.", var.database_tools_endpoint_service_id))
    error_message = "database_tools_endpoint_service_id must be null or a Database Tools endpoint-service OCID."
  }
}
variable "database_tools_password_secret_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional existing Vault secret OCID containing the ADMIN password. Null creates a dedicated Vault, key, and secret."

  validation {
    condition     = var.database_tools_password_secret_id == null ? true : can(regex("^ocid1\\.vaultsecret\\.", var.database_tools_password_secret_id))
    error_message = "database_tools_password_secret_id must be null or a Vault secret OCID."
  }
}
variable "database_tools_vault_dns_wait_duration" {
  type        = string
  default     = "120s"
  description = "Wait after Vault creation before creating its KMS key, allowing the unique management hostname to propagate in DNS."

  validation {
    condition     = can(regex("^[1-9][0-9]*(ms|s|m|h)$", var.database_tools_vault_dns_wait_duration))
    error_message = "database_tools_vault_dns_wait_duration must be a positive duration such as 120s or 5m."
  }
}
variable "database_tools_runtime_identity" {
  type        = string
  default     = "AUTHENTICATED_PRINCIPAL"
  description = "Identity Database Tools uses to retrieve its Vault secret. RESOURCE_PRINCIPAL requires the corresponding OCI dynamic-group and policy."

  validation {
    condition     = contains(["AUTHENTICATED_PRINCIPAL", "RESOURCE_PRINCIPAL"], var.database_tools_runtime_identity)
    error_message = "database_tools_runtime_identity must be AUTHENTICATED_PRINCIPAL or RESOURCE_PRINCIPAL."
  }
}
