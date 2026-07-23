#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"
tfvars_file="${1:-terraform.tfvars}"
ssh_private_key="${2:-${SSH_PRIVATE_KEY_PATH:-}}"
run_ansible="${RUN_ANSIBLE_AFTER_RENEWAL:-true}"
session_address='module.bastion.oci_bastion_session.ansible[0]'
wait_seconds="${BASTION_SESSION_ACTIVE_TIMEOUT:-300}"

command -v terraform >/dev/null || { echo "terraform is required" >&2; exit 1; }

case "$run_ansible" in
  true|false) ;;
  *) echo "RUN_ANSIBLE_AFTER_RENEWAL must be true or false." >&2; exit 1 ;;
esac

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

bash "$root_dir/scripts/select-compartment-workspace.sh" "$tfvars_file"

session_enabled="$(terraform -chdir="$terraform_dir" output -raw bastion_session_enabled 2>/dev/null || true)"
[[ "$session_enabled" == "true" ]] || {
  echo "create_bastion_session must be true before a session can be renewed." >&2
  exit 2
}

old_session_id="$(terraform -chdir="$terraform_dir" output -raw bastion_session_id 2>/dev/null || true)"
old_session_state="$(terraform -chdir="$terraform_dir" output -raw bastion_session_state 2>/dev/null || true)"

echo "Old Bastion session ID: ${old_session_id:-not available}"
echo "Old Bastion session state: ${old_session_state:-not available}"
echo "Replacing Terraform resource: $session_address"

# A fresh plan is created and applied in one operation. This avoids the stale
# saved-plan error that occurs if the state changes between plan and apply.
terraform -chdir="$terraform_dir" apply \
  -input=false \
  -auto-approve \
  -var-file="$tfvars_file" \
  -target="$session_address" \
  -replace="$session_address"

# A targeted apply can leave newly added root outputs absent from older state.
# Refresh-only records all configured outputs without modifying OCI resources.
terraform -chdir="$terraform_dir" apply \
  -refresh-only \
  -input=false \
  -auto-approve \
  -var-file="$tfvars_file"

deadline=$((SECONDS + wait_seconds))
new_session_state=""
while (( SECONDS < deadline )); do
  new_session_state="$(terraform -chdir="$terraform_dir" output -raw bastion_session_state 2>/dev/null || true)"
  [[ "$new_session_state" == "ACTIVE" ]] && break
  echo "Waiting for Bastion session to become ACTIVE; current state: ${new_session_state:-unknown}"
  sleep 5
done

new_session_id="$(terraform -chdir="$terraform_dir" output -raw bastion_session_id 2>/dev/null || true)"
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

if [[ "$run_ansible" == "true" ]]; then
  echo "Regenerating inventory and running Ansible through the new session."
  if [[ -n "$ssh_private_key" ]]; then
    "$root_dir/scripts/run-ansible.sh" "$ssh_private_key"
  else
    "$root_dir/scripts/run-ansible.sh"
  fi
else
  echo "Session renewed. Ansible was not run because RUN_ANSIBLE_AFTER_RENEWAL=false."
  echo "Run $root_dir/scripts/run-ansible.sh to regenerate inventory and execute the playbook."
fi
