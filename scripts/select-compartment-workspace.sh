#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tfvars_argument="${1:-terraform.tfvars}"

case "$tfvars_argument" in
  /*) tfvars_file="$tfvars_argument" ;;
  *) tfvars_file="$root_dir/terraform/$tfvars_argument" ;;
esac

test -f "$tfvars_file" || {
  echo "Missing Terraform variables file: $tfvars_file" >&2
  exit 1
}

compartment_id="$(
  sed -nE 's/^[[:space:]]*compartment_id[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' \
    "$tfvars_file" | tail -n 1
)"

if [[ ! "$compartment_id" =~ ^ocid1\.(compartment|tenancy)\. ]]; then
  echo "Could not read a quoted compartment_id OCID from $tfvars_file" >&2
  exit 1
fi

compartment_hash="$(printf '%s' "$compartment_id" | sha256sum | awk '{print substr($1, 1, 12)}')"
target_workspace="compartment-$compartment_hash"

cd "$root_dir/terraform"
terraform init -input=false

current_workspace="$(terraform workspace show)"
current_state="$(terraform state list 2>/dev/null || true)"
current_state_count="$(printf '%s\n' "$current_state" | awk 'NF { count++ } END { print count + 0 }')"

if [[ "$current_workspace" != "$target_workspace" && "$current_state_count" -gt 0 ]]; then
  if [[ "${ALLOW_EXISTING_STATE_WORKSPACE_SWITCH:-false}" != "true" ]]; then
    cat >&2 <<EOF
Refusing to switch from workspace '$current_workspace' because it contains
$current_state_count managed resource(s). Reusing one state for another
compartment can move, replace, or orphan the existing environment.

For a deliberate NEW deployment in the compartment from:
  $tfvars_file

preserve the current workspace and run:
  ALLOW_EXISTING_STATE_WORKSPACE_SWITCH=true bash \
    ./scripts/select-compartment-workspace.sh $(basename "$tfvars_file")

Do not enable that override when you intend to move or import the resources
already recorded in '$current_workspace'.
EOF
    exit 3
  fi
fi

terraform workspace select -or-create "$target_workspace"

echo "Terraform workspace: $target_workspace"
echo "Target compartment:  $compartment_id"
selected_state="$(terraform state list 2>/dev/null || true)"
selected_state_count="$(printf '%s\n' "$selected_state" | awk 'NF { count++ } END { print count + 0 }')"
echo "State resources:     $selected_state_count"
