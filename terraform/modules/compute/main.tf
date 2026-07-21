data "oci_core_images" "oracle_linux_8" {
  compartment_id           = var.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  oracle_cloud_init = <<-EOT
    #cloud-config
    ${yamlencode({
  users = [
    "default",
    {
      name                = "oracle"
      gecos               = "Oracle automation user"
      groups              = ["wheel"]
      shell               = "/bin/bash"
      sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
      ssh_authorized_keys = [var.ssh_public_key_content]
    }
  ]
})}
  EOT
}

resource "oci_core_instance" "this" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = var.instance_display_name
  shape               = var.shape
  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }
  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.oracle_linux_8.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }
  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = false
    display_name     = "${var.instance_display_name}-vnic"
  }
  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false
    plugins_config {
      desired_state = "ENABLED"
      name          = "Bastion"
    }
  }
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }
  metadata = {
    ssh_authorized_keys = var.ssh_public_key_content
    user_data           = base64encode(local.oracle_cloud_init)
  }
  preserve_boot_volume = false
}
