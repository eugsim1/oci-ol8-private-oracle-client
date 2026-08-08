#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"
tfvars_file="${1:-terraform.tfvars}"
terraform_bin="${TERRAFORM_BIN:-terraform}"
workspace_selector="${WORKSPACE_SELECTOR_BIN:-$root_dir/scripts/select-compartment-workspace.sh}"
# "ansible" is the historical Terraform resource label. Targeting this address
# replaces an OCI Bastion Session resource; it does not execute Ansible.
session_address='module.bastion.oci_bastion_session.ansible[0]'
wait_seconds="${BASTION_SESSION_ACTIVE_TIMEOUT:-300}"

usage() {
  cat <<'EOF'
Replace only the Terraform-managed OCI Bastion session and wait for ACTIVE.
This script does not execute Ansible and does not start stopped OCI resources.

Usage:
  renew-bastion-session.sh [TFVARS_FILE]

Environment:
  BASTION_SESSION_ACTIVE_TIMEOUT  wait timeout in seconds; default 300
  TERRAFORM_BIN                   Terraform executable; default terraform
  WORKSPACE_SELECTOR_BIN          workspace selector override for testing

Use start-and-connect.sh when Compute or Autonomous Database may be stopped.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
(( $# <= 1 )) || { usage >&2; exit 2; }

command -v "$terraform_bin" >/dev/null || { echo "terraform is required: $terraform_bin" >&2; exit 1; }
[[ -x "$workspace_selector" ]] || { echo "Workspace selector is not executable: $workspace_selector" >&2; exit 1; }

[[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "BASTION_SESSION_ACTIVE_TIMEOUT must be a positive number of seconds." >&2
  exit 1
}

if [[ "$tfvars_file" != /* ]]; then
  tfvars_file="$terraform_dir/$tfvars_file"
fi
[[ -r "$tfvars_file" ]] || {
  echo "Terraform variable file is not readable: $tfvars_file" >&2
  exit 1
}

"$workspace_selector" "$tfvars_file"

session_enabled="$("$terraform_bin" -chdir="$terraform_dir" output -raw bastion_session_enabled 2>/dev/null || true)"
[[ "$session_enabled" == "true" ]] || {
  echo "create_bastion_session must be true before a session can be renewed." >&2
  exit 2
}

old_session_id="$("$terraform_bin" -chdir="$terraform_dir" output -raw bastion_session_id 2>/dev/null || true)"
old_session_state="$("$terraform_bin" -chdir="$terraform_dir" output -raw bastion_session_state 2>/dev/null || true)"

echo "Old Bastion session ID: ${old_session_id:-not available}"
echo "Old Bastion session state: ${old_session_state:-not available}"
echo "Replacing Terraform resource: $session_address"

# A fresh plan is created and applied in one operation. This avoids the stale
# saved-plan error that occurs if the state changes between plan and apply.
"$terraform_bin" -chdir="$terraform_dir" apply \
  -input=false \
  -auto-approve \
  -var-file="$tfvars_file" \
  -target="$session_address" \
  -replace="$session_address"

# A targeted apply can leave newly added root outputs absent from older state.
# Refresh-only records all configured outputs without modifying OCI resources.
"$terraform_bin" -chdir="$terraform_dir" apply \
  -refresh-only \
  -input=false \
  -auto-approve \
  -var-file="$tfvars_file"

deadline=$((SECONDS + wait_seconds))
new_session_state=""
while (( SECONDS < deadline )); do
  new_session_state="$("$terraform_bin" -chdir="$terraform_dir" output -raw bastion_session_state 2>/dev/null || true)"
  [[ "$new_session_state" == "ACTIVE" ]] && break
  echo "Waiting for Bastion session to become ACTIVE; current state: ${new_session_state:-unknown}"
  sleep 5
done

new_session_id="$("$terraform_bin" -chdir="$terraform_dir" output -raw bastion_session_id 2>/dev/null || true)"
[[ -n "$new_session_id" ]] || {
  echo "Terraform did not return a new Bastion session OCID." >&2
  exit 3
}
[[ "$new_session_state" == "ACTIVE" ]] || {
  echo "Bastion session did not become ACTIVE within ${wait_seconds}s; final state: ${new_session_state:-unknown}" >&2
  exit 3
}

echo "New Bastion session ID: $new_session_id"
echo "New Bastion session state: $new_session_state"
echo "Session renewal completed. No Ansible playbook was executed."
echo "Connect with $root_dir/scripts/connect-oracle-server.sh, or run run-ansible.sh separately when provisioning is required."
