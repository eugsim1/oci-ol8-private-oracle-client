resource "oci_core_network_security_group" "database" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.db_name}-private-endpoint-nsg"
}

resource "oci_core_network_security_group_security_rule" "database_mtls" {
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.client_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Allow TLS and mTLS database connections from the VCN"

  tcp_options {
    destination_port_range {
      min = 1522
      max = 1522
    }
  }
}

# OCI can report Autonomous Database deletion before the service-managed
# private-endpoint VNIC has finished detaching from this NSG. This dependency
# chain enforces: database destroy -> detach wait -> NSG destroy.
resource "time_sleep" "private_endpoint_vnic_detach" {
  destroy_duration = var.private_endpoint_detach_wait_duration

  triggers = {
    network_security_group_id = oci_core_network_security_group.database.id
  }

  depends_on = [oci_core_network_security_group.database]
}

resource "oci_database_autonomous_database" "this" {
  compartment_id              = var.compartment_id
  db_name                     = var.db_name
  display_name                = var.display_name
  admin_password              = var.admin_password
  db_workload                 = var.db_workload
  compute_model               = "ECPU"
  compute_count               = var.compute_count
  data_storage_size_in_tbs    = var.data_storage_size_in_tbs
  license_model               = var.license_model
  is_auto_scaling_enabled     = true
  is_mtls_connection_required = var.is_mtls_connection_required
  subnet_id                   = var.subnet_id
  private_endpoint_label      = var.private_endpoint_label
  nsg_ids                     = [oci_core_network_security_group.database.id]

  depends_on = [time_sleep.private_endpoint_vnic_detach]
}

locals {
  tls_high_connection_strings = flatten([
    for connection_set in oci_database_autonomous_database.this.connection_strings : [
      for profile in connection_set.profiles : profile.value
      if upper(profile.consumer_group) == "HIGH" && upper(profile.tls_authentication) == "SERVER"
    ]
  ])
}
