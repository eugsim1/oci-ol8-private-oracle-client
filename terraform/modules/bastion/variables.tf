variable "compartment_id" { type = string }
variable "name" { type = string }
variable "target_subnet_id" { type = string }
variable "target_instance_id" { type = string }
variable "target_private_ip" { type = string }
variable "create_session" { type = bool }
variable "session_public_key_content" {
  type     = string
  nullable = true
  validation {
    condition     = !var.create_session ? true : try(length(trimspace(var.session_public_key_content)) > 0, false)
    error_message = "session_public_key_content is required when create_session is true."
  }
}
variable "target_os_user" { type = string }
variable "controller_public_cidr" { type = string }
variable "session_ttl_in_seconds" { type = number }
variable "plugin_wait_duration" { type = string }
