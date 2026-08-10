#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"
tfvars_file="terraform.tfvars"
connection_file="$root_dir/reports/ssh-connection.env"
inventory_file="$root_dir/ansible/inventory/hosts.yml"
terraform_bin="${TERRAFORM_BIN:-terraform}"
workspace_selector="${WORKSPACE_SELECTOR_BIN:-$root_dir/scripts/select-compartment-workspace.sh}"
lifecycle_script="${LIFECYCLE_SCRIPT_BIN:-$root_dir/scripts/manage-existing-stack.sh}"

ssh_private_key="${SSH_PRIVATE_KEY_PATH:-}"
ssh_public_key="${SSH_PUBLIC_KEY_PATH:-}"
profile="${OCI_CLI_PROFILE:-DEFAULT}"
auth_mode="${OCI_AUTH_MODE:-}"
target_os_user="oracle"
target_port=22
session_ttl=10800
wait_seconds=3600
poll_seconds=10
bastion_plugin_wait_seconds=600
report_dir="$root_dir/reports"
dry_run=false
skip_workspace_selection=false

usage() {
  cat <<'EOF'
Start the Terraform-created Compute instance and Autonomous Database when
needed, create a fresh OCI Bastion managed SSH session, and connect to Linux.
No Ansible playbook is executed.

Usage:
  start-and-connect.sh [options]

Artifact and workspace options:
  --tfvars PATH                 Terraform variables file; default terraform.tfvars
  --terraform-dir PATH          Terraform root; default PROJECT/terraform
  --ssh-private-key PATH        Matching private key; otherwise auto-detected
  --ssh-public-key PATH         Matching public key; otherwise auto-detected
  --connection-file PATH        run-ansible connection cache fallback
  --inventory-file PATH         generated Ansible inventory fallback
  --skip-workspace-selection    use the currently selected Terraform workspace

OCI and connection options:
  --profile NAME                OCI CLI profile; default DEFAULT
  --auth MODE                   OCI CLI auth mode, such as instance_principal
  --os-user USER                target Linux user; default oracle
  --target-port PORT            target SSH port; default 22
  --session-ttl SECONDS         Bastion TTL, 30-10800; default 10800
  --wait-seconds SECONDS        lifecycle timeout; default 3600
  --poll-seconds SECONDS        polling interval; default 10
  --bastion-plugin-wait-seconds SECONDS
                                Bastion plugin timeout; default 600
  --report-dir PATH             timestamped CSV directory; default PROJECT/reports
  --dry-run                     inspect and report only; do not start or connect
  -h, --help

Private-key lookup order:
  1. --ssh-private-key
  2. SSH_PRIVATE_KEY_PATH
  3. Terraform bastion_session_public_key_path with .pub removed
  4. reports/ssh-connection.env
  5. ansible/inventory/hosts.yml

Public-key lookup order:
  1. --ssh-public-key or SSH_PUBLIC_KEY_PATH
  2. the selected private key plus .pub
  3. Terraform's public key only when its adjacent private key was selected
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || { echo "$option requires a value." >&2; exit 2; }
}

while (( $# > 0 )); do
  case "$1" in
    --tfvars) require_value "$1" "${2:-}"; tfvars_file="$2"; shift 2 ;;
    --terraform-dir) require_value "$1" "${2:-}"; terraform_dir="$2"; shift 2 ;;
    --ssh-private-key) require_value "$1" "${2:-}"; ssh_private_key="$2"; shift 2 ;;
    --ssh-public-key) require_value "$1" "${2:-}"; ssh_public_key="$2"; shift 2 ;;
    --connection-file) require_value "$1" "${2:-}"; connection_file="$2"; shift 2 ;;
    --inventory-file) require_value "$1" "${2:-}"; inventory_file="$2"; shift 2 ;;
    --skip-workspace-selection) skip_workspace_selection=true; shift ;;
    --profile) require_value "$1" "${2:-}"; profile="$2"; shift 2 ;;
    --auth) require_value "$1" "${2:-}"; auth_mode="$2"; shift 2 ;;
    --os-user) require_value "$1" "${2:-}"; target_os_user="$2"; shift 2 ;;
    --target-port) require_value "$1" "${2:-}"; target_port="$2"; shift 2 ;;
    --session-ttl) require_value "$1" "${2:-}"; session_ttl="$2"; shift 2 ;;
    --wait-seconds) require_value "$1" "${2:-}"; wait_seconds="$2"; shift 2 ;;
    --poll-seconds) require_value "$1" "${2:-}"; poll_seconds="$2"; shift 2 ;;
    --bastion-plugin-wait-seconds) require_value "$1" "${2:-}"; bastion_plugin_wait_seconds="$2"; shift 2 ;;
    --report-dir) require_value "$1" "${2:-}"; report_dir="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v "$terraform_bin" >/dev/null || { echo "terraform is required: $terraform_bin" >&2; exit 1; }
[[ -x "$lifecycle_script" ]] || { echo "Lifecycle script is not executable: $lifecycle_script" >&2; exit 1; }

if [[ "$skip_workspace_selection" != "true" ]]; then
  [[ -x "$workspace_selector" ]] || { echo "Workspace selector is not executable: $workspace_selector" >&2; exit 1; }
  TERRAFORM_DIR="$terraform_dir" "$workspace_selector" "$tfvars_file"
fi

tf_output_optional() {
  "$terraform_bin" -chdir="$terraform_dir" output -raw "$1" 2>/dev/null || true
}

resolve_readable_path() {
  local candidate="${1:-}"
  [[ -n "$candidate" ]] || return 1
  if [[ -r "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  if [[ "$candidate" != /* && -r "$terraform_dir/$candidate" ]]; then
    printf '%s' "$terraform_dir/$candidate"
    return 0
  fi
  return 1
}

session_public_key_path="$(tf_output_optional bastion_session_public_key_path)"
session_public_key_path="${session_public_key_path%$'\r'}"
terraform_private_key="$(resolve_readable_path "${session_public_key_path%.pub}" || true)"

if [[ -n "$ssh_private_key" ]]; then
  requested_private_key="$ssh_private_key"
  ssh_private_key="$(resolve_readable_path "$requested_private_key")" || {
    echo "The explicitly selected SSH private key is not readable: $requested_private_key" >&2
    exit 1
  }
else
  ssh_private_key="$terraform_private_key"

  if [[ -z "$ssh_private_key" && -r "$connection_file" ]]; then
    cached_private_key=""
    # Generated by run-ansible.sh with mode 0600 and shell-escaped values.
    # shellcheck disable=SC1090
    source "$connection_file"
    cached_private_key="${SSH_PRIVATE_KEY:-}"
    ssh_private_key="$(resolve_readable_path "$cached_private_key" || true)"
  fi

  if [[ -z "$ssh_private_key" && -r "$inventory_file" ]]; then
    inventory_private_key="$(
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
    ssh_private_key="$(resolve_readable_path "$inventory_private_key" || true)"
  fi
fi

[[ -n "$ssh_private_key" && -r "$ssh_private_key" ]] || {
  echo "Could not resolve a readable SSH private key from the created artifacts." >&2
  echo "Pass --ssh-private-key or set SSH_PRIVATE_KEY_PATH." >&2
  exit 1
}

if [[ -n "$ssh_public_key" ]]; then
  requested_public_key="$ssh_public_key"
  ssh_public_key="$(resolve_readable_path "$requested_public_key")" || {
    echo "The explicitly selected SSH public key is not readable: $requested_public_key" >&2
    exit 1
  }
else
  ssh_public_key="$(resolve_readable_path "${ssh_private_key}.pub" || true)"
  if [[ -z "$ssh_public_key" && -n "$terraform_private_key" && "$ssh_private_key" == "$terraform_private_key" ]]; then
    ssh_public_key="$(resolve_readable_path "$session_public_key_path" || true)"
  fi
fi
[[ -n "$ssh_public_key" && -r "$ssh_public_key" ]] || {
  echo "Could not resolve a public key matching the selected private key: $ssh_private_key" >&2
  echo "Create ${ssh_private_key}.pub, or pass --ssh-public-key / set SSH_PUBLIC_KEY_PATH." >&2
  exit 1
}

lifecycle_args=(
  --start
  --terraform-dir "$terraform_dir"
  --ssh-public-key "$ssh_public_key"
  --ssh-private-key "$ssh_private_key"
  --profile "$profile"
  --os-user "$target_os_user"
  --target-port "$target_port"
  --session-ttl "$session_ttl"
  --wait-seconds "$wait_seconds"
  --poll-seconds "$poll_seconds"
  --bastion-plugin-wait-seconds "$bastion_plugin_wait_seconds"
  --report-dir "$report_dir"
)
[[ -n "$auth_mode" ]] && lifecycle_args+=(--auth "$auth_mode")
if [[ "$dry_run" == "true" ]]; then
  lifecycle_args+=(--dry-run)
  echo "Dry run: resource state will be inspected, but no resource will be started and SSH will not open."
else
  lifecycle_args+=(--connect)
fi

echo "Terraform directory: $terraform_dir"
echo "SSH private key: $ssh_private_key"
echo "SSH public key: $ssh_public_key"
if [[ "$dry_run" == "true" ]]; then
  echo "Inspecting the resources and planned Bastion/SSH workflow as $target_os_user."
else
  echo "Starting stopped resources, creating a fresh Bastion session, and opening SSH as $target_os_user."
fi

exec "$lifecycle_script" "${lifecycle_args[@]}"
