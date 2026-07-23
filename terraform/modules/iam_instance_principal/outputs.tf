output "dynamic_group_id" {
  value = oci_identity_dynamic_group.compute.id
}

output "dynamic_group_name" {
  value = oci_identity_dynamic_group.compute.name
}

output "dynamic_group_matching_rule" {
  value = oci_identity_dynamic_group.compute.matching_rule
}

output "dynamic_group_compartment_id" {
  description = "Always the root tenancy OCID because OCI dynamic groups are tenancy-level."
  value       = oci_identity_dynamic_group.compute.compartment_id
}

output "policy_id" {
  value = oci_identity_policy.compute.id
}

output "policy_name" {
  value = oci_identity_policy.compute.name
}

output "policy_statements" {
  value = oci_identity_policy.compute.statements
}

output "policy_compartment_id" {
  value = oci_identity_policy.compute.compartment_id
}

output "policy_resource_compartment_ids" {
  description = "Compartment IDs for resources expected to be in the application compartment. The tenancy-level dynamic group is intentionally excluded."
  value       = [oci_identity_policy.compute.compartment_id]
}
