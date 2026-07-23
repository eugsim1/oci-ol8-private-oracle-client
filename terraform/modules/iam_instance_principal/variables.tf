variable "tenancy_id" {
  type        = string
  description = "Root tenancy OCID. OCI requires dynamic groups to be created at this level."

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_id))
    error_message = "tenancy_id must be an OCI tenancy OCID."
  }
}

variable "compute_compartment_id" {
  type        = string
  description = "Compartment containing the Compute instance."

  validation {
    condition     = can(regex("^ocid1\\.(compartment|tenancy)\\.", var.compute_compartment_id))
    error_message = "compute_compartment_id must be an OCI compartment or tenancy OCID."
  }
}

variable "policy_compartment_id" {
  type        = string
  description = "Compartment where the IAM policy is attached."

  validation {
    condition     = can(regex("^ocid1\\.(compartment|tenancy)\\.", var.policy_compartment_id))
    error_message = "policy_compartment_id must be an OCI compartment or tenancy OCID."
  }
}

variable "instance_id" {
  type        = string
  description = "OCID of the Compute instance admitted to the dynamic group."

  validation {
    condition     = can(regex("^ocid1\\.instance\\.", var.instance_id))
    error_message = "instance_id must be an OCI Compute instance OCID."
  }
}

variable "dynamic_group_name" {
  type        = string
  description = "Tenancy-unique dynamic-group name."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_-]{0,99}$", var.dynamic_group_name))
    error_message = "dynamic_group_name must start with a letter, contain only letters, numbers, underscores, or hyphens, and be at most 100 characters."
  }
}

variable "dynamic_group_description" {
  type        = string
  description = "Description for the dynamic group."
}

variable "policy_name" {
  type        = string
  description = "IAM policy name."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_-]{0,99}$", var.policy_name))
    error_message = "policy_name must start with a letter, contain only letters, numbers, underscores, or hyphens, and be at most 100 characters."
  }
}

variable "policy_description" {
  type        = string
  description = "Description for the IAM policy."
}

variable "match_all_instances_in_compartment" {
  type        = bool
  default     = false
  description = "When false, match only instance_id. When true, admit every Compute instance in compute_compartment_id."
}

variable "compartment_permissions" {
  type        = list(string)
  description = "Permission fragments used after 'to' in policy statements, for example 'read autonomous-database-family'."

  validation {
    condition = length(var.compartment_permissions) > 0 && alltrue([
      for permission in var.compartment_permissions :
      length(trimspace(permission)) > 0 &&
      !startswith(lower(trimspace(permission)), "allow ") &&
      !strcontains(lower(permission), " in tenancy") &&
      !strcontains(lower(permission), " in compartment")
    ])
    error_message = "Each permission must be a non-empty policy fragment such as 'read autonomous-database-family', without Allow or a location clause."
  }
}
