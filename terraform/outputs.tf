output "instance_id" { value = module.compute.instance_id }
output "instance_name" { value = module.compute.instance_name }
output "target_compartment_id" {
  description = "The compartment OCID supplied through terraform.tfvars and used by every created resource."
  value       = local.target_compartment_id
}
output "resource_compartment_ids" {
  description = "Distinct compartment OCIDs reported by compartment-scoped resources; this must contain only target_compartment_id. The tenancy-level dynamic group is excluded."
  value       = local.created_resource_compartment_ids
}
output "iam_instance_principal_enabled" {
  value = var.iam_instance_principal_enabled
}
output "iam_dynamic_group_id" {
  value = try(module.iam_instance_principal[0].dynamic_group_id, null)
}
output "iam_dynamic_group_name" {
  value = try(module.iam_instance_principal[0].dynamic_group_name, null)
}
output "iam_dynamic_group_matching_rule" {
  value = try(module.iam_instance_principal[0].dynamic_group_matching_rule, null)
}
output "iam_dynamic_group_compartment_id" {
  description = "Root tenancy OCID when instance principal IAM is enabled."
  value       = try(module.iam_instance_principal[0].dynamic_group_compartment_id, null)
}
output "iam_policy_id" {
  value = try(module.iam_instance_principal[0].policy_id, null)
}
output "iam_policy_name" {
  value = try(module.iam_instance_principal[0].policy_name, null)
}
output "iam_policy_statements" {
  value = try(module.iam_instance_principal[0].policy_statements, [])
}
output "iam_policy_compartment_id" {
  description = "The Compute compartment OCID when instance principal IAM is enabled."
  value       = try(module.iam_instance_principal[0].policy_compartment_id, null)
}
output "terraform_workspace" { value = terraform.workspace }
output "immutable_name_suffix" { value = local.immutable_name_suffix }
output "effective_bastion_name" { value = module.bastion.bastion_name }
output "effective_autonomous_database_name" { value = module.autonomous_database.db_name }
output "available_availability_domains" { value = local.availability_domain_names }
output "selected_availability_domain" { value = local.selected_availability_domain }
output "private_ip" { value = module.compute.private_ip }
output "public_ip" { value = module.compute.public_ip }
output "bastion_id" { value = module.bastion.bastion_id }
output "bastion_session_enabled" { value = module.bastion.session_enabled }
output "bastion_session_public_key_path" { value = local.bastion_session_public_key_path }
output "bastion_session_id" { value = module.bastion.session_id }
output "bastion_session_state" { value = module.bastion.session_state }
output "bastion_ssh_command" { value = module.bastion.ssh_command }
output "bastion_plugin_status" { value = module.bastion.plugin_status }
output "bastion_plugin_message" { value = module.bastion.plugin_message }
output "region" { value = var.region }
output "shape" { value = var.shape }
output "memory_in_gbs" { value = var.memory_in_gbs }
output "boot_volume_size_in_gbs" { value = var.boot_volume_size_in_gbs }
output "autonomous_database_id" { value = module.autonomous_database.id }
output "autonomous_database_name" { value = module.autonomous_database.db_name }
output "autonomous_database_state" { value = module.autonomous_database.state }
output "autonomous_database_private_endpoint" { value = module.autonomous_database.private_endpoint }
output "autonomous_database_private_ip" { value = module.autonomous_database.private_endpoint_ip }
output "autonomous_database_tls_high_connection_string" { value = module.autonomous_database.tls_high_connection_string }
output "database_tools_enabled" { value = var.database_tools_enabled }
output "database_tools_connection_id" { value = module.database_tools.connection_id }
output "database_tools_connection_state" { value = module.database_tools.connection_state }
output "database_tools_connection_string" { value = module.database_tools.connection_string }
output "database_tools_runtime_endpoint" { value = module.database_tools.runtime_endpoint }
output "database_tools_private_endpoint_id" { value = module.database_tools.private_endpoint_id }
output "database_tools_private_endpoint_state" { value = module.database_tools.private_endpoint_state }
output "database_tools_private_endpoint_ip" { value = module.database_tools.private_endpoint_ip }
output "database_tools_private_endpoint_fqdn" { value = module.database_tools.private_endpoint_fqdn }
output "database_tools_network_security_group_id" { value = module.database_tools.network_security_group_id }
output "database_tools_password_secret_id" { value = module.database_tools.password_secret_id }
output "database_tools_vault_id" { value = module.database_tools.vault_id }
output "database_tools_key_id" { value = module.database_tools.key_id }
output "terraform_csv_report" { value = local_file.infrastructure_report.filename }
