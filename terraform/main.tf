data "oci_identity_availability_domains" "available" {
  compartment_id = var.compartment_id
}

locals {
  ssh_public_key_content = trimspace(file(pathexpand(var.ssh_public_key_path)))
  bastion_session_public_key_path = pathexpand(
    coalesce(var.bastion_session_public_key_path, var.ssh_public_key_path)
  )
  bastion_session_public_key_content = var.create_bastion_session ? trimspace(file(pathexpand(
    local.bastion_session_public_key_path
  ))) : null
  availability_domain_names = sort([
    for ad in data.oci_identity_availability_domains.available.availability_domains : ad.name
  ])
  selected_availability_domain = local.availability_domain_names[var.availability_domain_index]
}

module "network" {
  source              = "./modules/network"
  compartment_id      = var.compartment_id
  name                = var.compute_node_name
  vcn_cidr            = var.vcn_cidr
  private_subnet_cidr = var.private_subnet_cidr
}

module "compute" {
  source                  = "./modules/compute"
  compartment_id          = var.compartment_id
  availability_domain     = local.selected_availability_domain
  subnet_id               = module.network.private_subnet_id
  instance_display_name   = var.compute_node_name
  shape                   = var.shape
  ocpus                   = var.ocpus
  memory_in_gbs           = var.memory_in_gbs
  boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  ssh_public_key_content  = local.ssh_public_key_content

  depends_on = [module.network]
}

module "bastion" {
  source                     = "./modules/bastion"
  compartment_id             = var.compartment_id
  name                       = var.compute_node_name
  target_subnet_id           = module.network.private_subnet_id
  target_instance_id         = module.compute.instance_id
  target_private_ip          = module.compute.private_ip
  create_session             = var.create_bastion_session
  session_public_key_content = local.bastion_session_public_key_content
  target_os_user             = "oracle"
  controller_public_cidr     = var.controller_public_cidr
  session_ttl_in_seconds     = var.bastion_session_ttl_seconds
  plugin_wait_duration       = var.bastion_plugin_wait_duration

  depends_on = [module.compute]
}

module "autonomous_database" {
  source                                = "./modules/autonomous_database"
  compartment_id                        = var.compartment_id
  vcn_id                                = module.network.vcn_id
  subnet_id                             = module.network.private_subnet_id
  client_cidr                           = var.vcn_cidr
  db_name                               = var.adb_db_name
  display_name                          = var.adb_display_name
  admin_password                        = var.adb_admin_password
  db_workload                           = var.adb_workload
  compute_count                         = var.adb_compute_count
  data_storage_size_in_tbs              = var.adb_storage_size_in_tbs
  license_model                         = var.adb_license_model
  private_endpoint_label                = var.adb_private_endpoint_label
  is_mtls_connection_required           = var.adb_is_mtls_connection_required
  private_endpoint_detach_wait_duration = var.adb_private_endpoint_detach_wait_duration

  depends_on = [module.network]
}

module "database_tools" {
  source                            = "./modules/database_tools"
  enabled                           = var.database_tools_enabled
  compartment_id                    = var.compartment_id
  vcn_id                            = module.network.vcn_id
  subnet_id                         = module.network.private_subnet_id
  network_security_group_id         = module.autonomous_database.network_security_group_id
  autonomous_database_id            = module.autonomous_database.id
  autonomous_database_display_name  = module.autonomous_database.display_name
  autonomous_database_mtls_required = module.autonomous_database.is_mtls_connection_required
  connection_string                 = module.autonomous_database.tls_high_connection_string
  database_user_name                = "ADMIN"
  database_user_password            = var.adb_admin_password
  connection_display_name           = var.database_tools_connection_display_name
  private_endpoint_display_name     = var.database_tools_private_endpoint_display_name
  endpoint_service_id               = var.database_tools_endpoint_service_id
  password_secret_id                = var.database_tools_password_secret_id
  vault_dns_wait_duration           = var.database_tools_vault_dns_wait_duration
  runtime_identity                  = var.database_tools_runtime_identity

  depends_on = [module.autonomous_database]
}
