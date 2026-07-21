resource "oci_bastion_bastion" "this" {
  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_id
  target_subnet_id             = var.target_subnet_id
  name                         = "${var.name}-bastion"
  client_cidr_block_allow_list = [var.controller_public_cidr]
  max_session_ttl_in_seconds   = var.session_ttl_in_seconds
}

resource "time_sleep" "wait_for_bastion_plugin" {
  count           = var.create_session ? 1 : 0
  create_duration = var.plugin_wait_duration

  triggers = {
    target_instance_id = var.target_instance_id
    wait_duration      = var.plugin_wait_duration
  }
}

data "oci_computeinstanceagent_instance_agent_plugin" "bastion" {
  count            = var.create_session ? 1 : 0
  compartment_id   = var.compartment_id
  instanceagent_id = var.target_instance_id
  plugin_name      = "Bastion"

  depends_on = [time_sleep.wait_for_bastion_plugin]
}

resource "terraform_data" "bastion_plugin_ready" {
  count = var.create_session ? 1 : 0

  input = {
    name    = data.oci_computeinstanceagent_instance_agent_plugin.bastion[0].name
    status  = data.oci_computeinstanceagent_instance_agent_plugin.bastion[0].status
    message = data.oci_computeinstanceagent_instance_agent_plugin.bastion[0].message
  }

  lifecycle {
    precondition {
      condition     = data.oci_computeinstanceagent_instance_agent_plugin.bastion[0].status == "RUNNING"
      error_message = "The target instance Bastion plugin is not RUNNING after ${var.plugin_wait_duration}. Check Oracle Cloud Agent health, outbound connectivity, and the instance agent_config."
    }
  }
}

resource "oci_bastion_session" "ansible" {
  count                  = var.create_session ? 1 : 0
  bastion_id             = oci_bastion_bastion.this.id
  display_name           = "${var.name}-ansible"
  key_type               = "PUB"
  session_ttl_in_seconds = var.session_ttl_in_seconds

  key_details {
    public_key_content = var.session_public_key_content
  }

  target_resource_details {
    session_type                               = "MANAGED_SSH"
    target_resource_id                         = var.target_instance_id
    target_resource_private_ip_address         = var.target_private_ip
    target_resource_port                       = 22
    target_resource_operating_system_user_name = var.target_os_user
  }

  depends_on = [terraform_data.bastion_plugin_ready]
}
