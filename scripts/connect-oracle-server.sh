#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$script_dir/terraform" && -d "$script_dir/ansible" ]]; then
  root_dir="$script_dir"
elif [[ -d "$script_dir/../terraform" && -d "$script_dir/../ansible" ]]; then
  root_dir="$(cd "$script_dir/.." && pwd)"
else
  echo "Cannot locate the project root from $script_dir." >&2
  exit 1
fi
terraform_dir="$root_dir/terraform"
connection_file="$root_dir/reports/ssh-connection.env"
inventory_file="$root_dir/ansible/inventory/hosts.yml"

command -v ssh >/dev/null || { echo "OpenSSH client is required" >&2; exit 1; }

tf_output() {
  terraform -chdir="$terraform_dir" output -raw "$1"
}

tf_output_optional() {
  terraform -chdir="$terraform_dir" output -raw "$1" 2>/dev/null || true
}

cached_private_ip=""
cached_session_id=""
cached_session_state=""
cached_region=""
cached_ssh_private_key=""
if [[ -r "$connection_file" ]]; then
  # Generated locally by run-ansible.sh with shell-escaped values and mode 0600.
  # shellcheck disable=SC1090
  source "$connection_file"
  cached_private_ip="${TARGET_PRIVATE_IP:-}"
  cached_session_id="${BASTION_SESSION_ID:-}"
  cached_session_state="${BASTION_SESSION_STATE:-}"
  cached_region="${OCI_REGION:-}"
  cached_ssh_private_key="${SSH_PRIVATE_KEY:-}"
fi

if command -v terraform >/dev/null && [[ -d "$terraform_dir" ]]; then
  # Always prefer current Terraform connection values, because a cached file may
  # refer to a Bastion session that has since expired and been replaced.
  private_ip="$(tf_output private_ip)"
  session_enabled="$(tf_output bastion_session_enabled)"
  session_id="$(tf_output bastion_session_id)"
  session_state="$(tf_output bastion_session_state)"
  region="$(tf_output region)"
  session_public_key_path="$(tf_output_optional bastion_session_public_key_path)"
  ssh_private_key=""
  if [[ -n "$session_public_key_path" ]]; then
    ssh_private_key="${session_public_key_path%.pub}"
  elif [[ -n "$cached_ssh_private_key" ]]; then
    ssh_private_key="$cached_ssh_private_key"
  elif [[ -r "$inventory_file" ]]; then
    ssh_private_key="$(
      awk '
        /ansible_ssh_private_key_file:/ {
          value=$0
          sub(/^.*ansible_ssh_private_key_file:[[:space:]]*/, "", value)
          sub(/^"/, "", value)
          sub(/"[[:space:]]*$/, "", value)
          print value
          exit
        }
      ' "$inventory_file"
    )"
  fi
elif [[ -n "$cached_session_id" ]]; then
  private_ip="$cached_private_ip"
  session_enabled="true"
  session_id="$cached_session_id"
  session_state="$cached_session_state"
  region="$cached_region"
  ssh_private_key="$cached_ssh_private_key"
  session_public_key_path="${ssh_private_key}.pub"
else
  echo "Neither usable Terraform outputs nor $connection_file are available." >&2
  exit 1
fi

[[ "$session_enabled" == "true" ]] || {
  echo "The Terraform configuration does not have create_bastion_session=true." >&2
  exit 2
}
[[ "$session_state" == "ACTIVE" ]] || {
  echo "The Bastion session is ${session_state:-unknown}, not ACTIVE." >&2
  echo "Run ./scripts/renew-bastion-session.sh terraform.tfvars first." >&2
  exit 2
}
[[ "$session_id" == ocid1.bastionsession.* ]] || {
  echo "Terraform did not return a valid Bastion session OCID." >&2
  exit 2
}
[[ "$private_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Terraform did not return a valid target private IP: $private_ip" >&2
  exit 2
}
[[ -r "$ssh_private_key" ]] || {
  echo "The SSH private key is not readable: ${ssh_private_key:-not resolved}" >&2
  echo "Run scripts/run-ansible.sh with the private-key path to regenerate controller connection metadata." >&2
  exit 2
}

bastion_host="host.bastion.$region.oci.oraclecloud.com"
printf -v private_key_shell '%q' "$ssh_private_key"
printf -v bastion_user_shell '%q' "$session_id@$bastion_host"
proxy_command="ssh -i $private_key_shell -o StrictHostKeyChecking=accept-new -W %h:%p -p 22 $bastion_user_shell"

echo "Connecting to oracle@$private_ip through Bastion session $session_id"
echo "Bastion endpoint: $bastion_host"
echo "SSH private key: $ssh_private_key"

exec ssh \
  -i "$ssh_private_key" \
  -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o "ProxyCommand=$proxy_command" \
  -p 22 \
  "oracle@$private_ip"
