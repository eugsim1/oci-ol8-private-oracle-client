locals {
  create_password_secret = var.enabled && var.password_secret_id == null
  resource_name          = lower(replace(var.autonomous_database_display_name, " ", "-"))
  connection_name = coalesce(
    var.connection_display_name,
    "${var.autonomous_database_display_name} Database Tools"
  )
  private_endpoint_name = coalesce(
    var.private_endpoint_display_name,
    "${var.autonomous_database_display_name} Database Tools Private Endpoint"
  )
  discovered_endpoint_services = var.enabled && var.endpoint_service_id == null ? try(
    data.oci_database_tools_database_tools_endpoint_services.available[0].database_tools_endpoint_service_collection[0].items,
    []
  ) : []
  selected_endpoint_service_id = var.enabled ? coalesce(
    var.endpoint_service_id,
    try(local.discovered_endpoint_services[0].id, null)
  ) : null
  effective_password_secret_id = var.enabled ? coalesce(
    var.password_secret_id,
    try(oci_vault_secret.database_password[0].id, null)
  ) : null
}

data "oci_database_tools_database_tools_endpoint_services" "available" {
  count          = var.enabled && var.endpoint_service_id == null ? 1 : 0
  compartment_id = var.compartment_id
  state          = "ACTIVE"
}

resource "oci_kms_vault" "database_tools" {
  count          = local.create_password_secret ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-dbtools-vault"
  vault_type     = "DEFAULT"
}

# A new Vault's unique management hostname can be returned by the API before
# its DNS record is visible to the Terraform controller.
resource "time_sleep" "vault_dns_propagation" {
  count           = local.create_password_secret ? 1 : 0
  create_duration = var.vault_dns_wait_duration

  depends_on = [oci_kms_vault.database_tools]
}

resource "oci_kms_key" "database_tools" {
  count               = local.create_password_secret ? 1 : 0
  compartment_id      = var.compartment_id
  display_name        = "${local.resource_name}-dbtools-key"
  management_endpoint = oci_kms_vault.database_tools[0].management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  depends_on = [time_sleep.vault_dns_propagation]
}

resource "oci_vault_secret" "database_password" {
  count          = local.create_password_secret ? 1 : 0
  compartment_id = var.compartment_id
  vault_id       = oci_kms_vault.database_tools[0].id
  key_id         = oci_kms_key.database_tools[0].id
  secret_name    = "${local.resource_name}-dbtools-password"
  description    = "Database password for ${var.autonomous_database_display_name} Database Tools connection"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.database_user_password)
  }
}

resource "oci_core_network_security_group" "database_tools" {
  count          = var.enabled ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${local.resource_name}-dbtools-nsg"
}

resource "oci_core_network_security_group_security_rule" "database_egress" {
  count                     = var.enabled ? 1 : 0
  network_security_group_id = oci_core_network_security_group.database_tools[0].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = var.network_security_group_id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow Database Tools to reach the Autonomous Database private endpoint"

  tcp_options {
    destination_port_range {
      min = 1522
      max = 1522
    }
  }
}

resource "oci_database_tools_database_tools_private_endpoint" "autonomous_database" {
  count               = var.enabled ? 1 : 0
  compartment_id      = var.compartment_id
  display_name        = local.private_endpoint_name
  description         = "Private Database Tools access to ${var.autonomous_database_display_name}"
  endpoint_service_id = local.selected_endpoint_service_id
  subnet_id           = var.subnet_id
  nsg_ids             = [oci_core_network_security_group.database_tools[0].id]

  lifecycle {
    precondition {
      condition     = local.selected_endpoint_service_id != null
      error_message = "No active Database Tools endpoint service was discovered. Supply endpoint_service_id explicitly."
    }
  }
}

resource "oci_database_tools_database_tools_connection" "autonomous_database" {
  count               = var.enabled ? 1 : 0
  compartment_id      = var.compartment_id
  display_name        = local.connection_name
  type                = "ORACLE_DATABASE"
  authentication_type = "PASSWORD"
  runtime_identity    = var.runtime_identity
  runtime_support     = "SUPPORTED"
  user_name           = var.database_user_name
  connection_string   = var.connection_string
  private_endpoint_id = oci_database_tools_database_tools_private_endpoint.autonomous_database[0].id

  user_password {
    value_type = "SECRETID"
    secret_id  = local.effective_password_secret_id
  }

  related_resource {
    entity_type = "AUTONOMOUSDATABASE"
    identifier  = var.autonomous_database_id
  }

  lifecycle {
    precondition {
      condition     = !var.autonomous_database_mtls_required
      error_message = "Database Tools password connections require an ADB one-way TLS profile. Set adb_is_mtls_connection_required = false; wallet-based clients can still use mTLS."
    }
    precondition {
      condition     = length(trimspace(var.connection_string)) > 0
      error_message = "The Autonomous Database did not expose a one-way TLS connection string."
    }
    precondition {
      condition     = local.effective_password_secret_id != null
      error_message = "A Vault password secret could not be created or selected."
    }
  }
}
