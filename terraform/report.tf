locals {
  infrastructure_report_rows = [
    { resource_type = "deployment", resource_name = terraform.workspace, attribute = "target_compartment_id", value = local.target_compartment_id },
    { resource_type = "deployment", resource_name = terraform.workspace, attribute = "immutable_name_suffix", value = local.immutable_name_suffix },

    { resource_type = "network", resource_name = "vcn", attribute = "id", value = module.network.vcn_id },
    { resource_type = "network", resource_name = "vcn", attribute = "cidr", value = module.network.vcn_cidr },
    { resource_type = "network", resource_name = "private_subnet", attribute = "id", value = module.network.private_subnet_id },
    { resource_type = "network", resource_name = "nat_gateway", attribute = "id", value = module.network.nat_gateway_id },
    { resource_type = "network", resource_name = "service_gateway", attribute = "id", value = module.network.service_gateway_id },
    { resource_type = "network", resource_name = "private_route_table", attribute = "id", value = module.network.private_route_table_id },
    { resource_type = "network", resource_name = "private_security_list", attribute = "id", value = module.network.private_security_list_id },

    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "id", value = module.compute.instance_id },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "state", value = module.compute.state },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "availability_domain", value = module.compute.availability_domain },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "image_id", value = module.compute.image_id },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "shape", value = module.compute.shape },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "ocpus", value = tostring(module.compute.ocpus) },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "memory_in_gbs", value = tostring(module.compute.memory_in_gbs) },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "boot_volume_size_in_gbs", value = tostring(module.compute.boot_volume_size_in_gbs) },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "private_ip", value = module.compute.private_ip },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "public_ip", value = coalesce(module.compute.public_ip, "none") },
    { resource_type = "compute", resource_name = module.compute.instance_name, attribute = "imds_v2_only", value = tostring(module.compute.imds_v2_only) },

    { resource_type = "iam_instance_principal", resource_name = local.effective_iam_dynamic_group_name, attribute = "enabled", value = tostring(var.iam_instance_principal_enabled) },
    { resource_type = "iam_dynamic_group", resource_name = local.effective_iam_dynamic_group_name, attribute = "id", value = coalesce(try(module.iam_instance_principal[0].dynamic_group_id, null), "not created") },
    { resource_type = "iam_dynamic_group", resource_name = local.effective_iam_dynamic_group_name, attribute = "compartment_id", value = coalesce(try(module.iam_instance_principal[0].dynamic_group_compartment_id, null), "not created") },
    { resource_type = "iam_dynamic_group", resource_name = local.effective_iam_dynamic_group_name, attribute = "matching_rule", value = coalesce(try(module.iam_instance_principal[0].dynamic_group_matching_rule, null), "not created") },
    { resource_type = "iam_policy", resource_name = local.effective_iam_policy_name, attribute = "id", value = coalesce(try(module.iam_instance_principal[0].policy_id, null), "not created") },
    { resource_type = "iam_policy", resource_name = local.effective_iam_policy_name, attribute = "compartment_id", value = coalesce(try(module.iam_instance_principal[0].policy_compartment_id, null), "not created") },
    { resource_type = "iam_policy", resource_name = local.effective_iam_policy_name, attribute = "statements", value = var.iam_instance_principal_enabled ? join(" | ", module.iam_instance_principal[0].policy_statements) : "not created" },

    { resource_type = "bastion", resource_name = module.bastion.bastion_name, attribute = "id", value = module.bastion.bastion_id },
    { resource_type = "bastion", resource_name = module.bastion.bastion_name, attribute = "state", value = module.bastion.bastion_state },
    { resource_type = "bastion", resource_name = module.bastion.bastion_name, attribute = "private_endpoint_ip", value = module.bastion.bastion_private_endpoint_ip },
    { resource_type = "bastion", resource_name = module.bastion.bastion_name, attribute = "plugin_status", value = coalesce(module.bastion.plugin_status, "not checked; session disabled") },
    { resource_type = "bastion", resource_name = module.bastion.bastion_name, attribute = "plugin_message", value = module.bastion.plugin_message != null ? module.bastion.plugin_message : "" },
    { resource_type = "bastion_session", resource_name = "ansible", attribute = "enabled", value = tostring(module.bastion.session_enabled) },
    { resource_type = "bastion_session", resource_name = "ansible", attribute = "id", value = coalesce(module.bastion.session_id, "not created") },
    { resource_type = "bastion_session", resource_name = "ansible", attribute = "state", value = coalesce(module.bastion.session_state, "not created") },
    { resource_type = "bastion_session", resource_name = "ansible", attribute = "ttl_in_seconds", value = module.bastion.session_ttl_in_seconds != null ? tostring(module.bastion.session_ttl_in_seconds) : "not created" },
    { resource_type = "bastion_session", resource_name = "ansible", attribute = "ssh_command", value = coalesce(module.bastion.ssh_command, "not created") },

    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "id", value = module.autonomous_database.id },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "db_name", value = module.autonomous_database.db_name },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "state", value = module.autonomous_database.state },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "db_version", value = module.autonomous_database.db_version },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "workload", value = module.autonomous_database.db_workload },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "compute_model", value = module.autonomous_database.compute_model },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "compute_count", value = tostring(module.autonomous_database.compute_count) },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "storage_size_in_tbs", value = tostring(module.autonomous_database.data_storage_size_in_tbs) },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "license_model", value = module.autonomous_database.license_model },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "mtls_required", value = tostring(module.autonomous_database.is_mtls_connection_required) },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "private_endpoint", value = module.autonomous_database.private_endpoint },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "private_endpoint_ip", value = module.autonomous_database.private_endpoint_ip },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "subnet_id", value = module.autonomous_database.subnet_id },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "network_security_group_id", value = module.autonomous_database.network_security_group_id },
    { resource_type = "autonomous_database", resource_name = module.autonomous_database.display_name, attribute = "tls_high_connection_string", value = module.autonomous_database.tls_high_connection_string },

    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "enabled", value = tostring(var.database_tools_enabled) },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "connection_id", value = coalesce(module.database_tools.connection_id, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "connection_state", value = coalesce(module.database_tools.connection_state, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "connection_type", value = coalesce(module.database_tools.connection_type, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "authentication_type", value = coalesce(module.database_tools.authentication_type, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "runtime_identity", value = coalesce(module.database_tools.runtime_identity, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "runtime_endpoint", value = coalesce(module.database_tools.runtime_endpoint, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "database_user", value = coalesce(module.database_tools.database_user_name, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "connection_string", value = coalesce(module.database_tools.connection_string, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "related_autonomous_database_id", value = coalesce(module.database_tools.related_autonomous_database_id, "not created") },
    { resource_type = "database_tools", resource_name = coalesce(module.database_tools.connection_display_name, "not created"), attribute = "endpoint_service_id", value = coalesce(module.database_tools.endpoint_service_id, "not created") },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "id", value = coalesce(module.database_tools.private_endpoint_id, "not created") },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "state", value = coalesce(module.database_tools.private_endpoint_state, "not created") },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "ip", value = coalesce(module.database_tools.private_endpoint_ip, "not created") },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "fqdn", value = coalesce(module.database_tools.private_endpoint_fqdn, "not created") },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "vnic_id", value = coalesce(module.database_tools.private_endpoint_vnic_id, "not created") },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "subnet_id", value = module.network.private_subnet_id },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "network_security_group_id", value = coalesce(module.database_tools.network_security_group_id, "not created") },
    { resource_type = "database_tools_private_endpoint", resource_name = coalesce(module.database_tools.private_endpoint_display_name, "not created"), attribute = "database_destination_network_security_group_id", value = module.autonomous_database.network_security_group_id },
    { resource_type = "vault_secret", resource_name = "database_tools_password", attribute = "secret_id", value = coalesce(module.database_tools.password_secret_id, "not created") },
    { resource_type = "vault", resource_name = "database_tools", attribute = "vault_id", value = coalesce(module.database_tools.vault_id, var.database_tools_password_secret_id != null ? "existing secret supplied" : "not created") },
    { resource_type = "vault", resource_name = "database_tools", attribute = "key_id", value = coalesce(module.database_tools.key_id, var.database_tools_password_secret_id != null ? "existing secret supplied" : "not created") },
    { resource_type = "vault", resource_name = "database_tools", attribute = "dns_wait_duration", value = var.database_tools_vault_dns_wait_duration }
  ]

  infrastructure_report_csv = join("\n", concat(
    ["\"resource_type\",\"resource_name\",\"attribute\",\"value\""],
    [
      for row in local.infrastructure_report_rows : format(
        "\"%s\",\"%s\",\"%s\",\"%s\"",
        replace(row.resource_type, "\"", "\"\""),
        replace(row.resource_name, "\"", "\"\""),
        replace(row.attribute, "\"", "\"\""),
        replace(row.value, "\"", "\"\"")
      )
    ]
  ))
}

resource "local_file" "infrastructure_report" {
  filename = abspath("${path.root}/../reports/terraform-resources.csv")
  content  = "${local.infrastructure_report_csv}\n"
}
