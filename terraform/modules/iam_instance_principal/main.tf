locals {
  matching_rule = var.match_all_instances_in_compartment ? (
    "instance.compartment.id = '${var.compute_compartment_id}'"
    ) : (
    "instance.id = '${var.instance_id}'"
  )

  policy_statements = [
    for permission in var.compartment_permissions :
    "Allow dynamic-group ${var.dynamic_group_name} to ${permission} in compartment id ${var.policy_compartment_id}"
  ]
}

# OCI dynamic groups are tenancy-level IAM resources. OCI requires the root
# tenancy OCID here; they cannot be created inside the Compute compartment.
resource "oci_identity_dynamic_group" "compute" {
  compartment_id = var.tenancy_id
  name           = var.dynamic_group_name
  description    = var.dynamic_group_description
  matching_rule  = local.matching_rule
}

# A policy can be attached to the Compute compartment. Because its attachment
# point is that compartment, it grants access only there and in its descendants.
resource "oci_identity_policy" "compute" {
  compartment_id = var.policy_compartment_id
  name           = var.policy_name
  description    = var.policy_description
  statements     = local.policy_statements

  depends_on = [oci_identity_dynamic_group.compute]
}
