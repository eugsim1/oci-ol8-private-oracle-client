#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"
tfvars_file="terraform.tfvars"
terraform_bin="${TERRAFORM_BIN:-terraform}"
workspace_selector="${WORKSPACE_SELECTOR_BIN:-$root_dir/scripts/select-compartment-workspace.sh}"
lifecycle_script="${LIFECYCLE_SCRIPT_BIN:-$root_dir/scripts/manage-existing-stack.sh}"

profile="${OCI_CLI_PROFILE:-DEFAULT}"
auth_mode="${OCI_AUTH_MODE:-}"
wait_seconds=3600
poll_seconds=10
report_dir="$root_dir/reports"
dry_run=false
force_stop=false
skip_workspace_selection=false

usage() {
  cat <<'EOF'
Close all non-deleted sessions for the selected OCI Bastion, stop Autonomous
Database, and gracefully stop the Compute instance. Run this command from an
external controller, never from the Compute instance being stopped.

Usage:
  stop-all.sh [options]

Workspace options:
  --tfvars PATH                 Terraform variables file; default terraform.tfvars
  --terraform-dir PATH          Terraform root; default PROJECT/terraform
  --skip-workspace-selection    Use the currently selected Terraform workspace

OCI and lifecycle options:
  --profile NAME                OCI CLI profile; default DEFAULT
  --auth MODE                   OCI CLI auth mode, such as instance_principal
  --wait-seconds SECONDS        Lifecycle timeout; default 3600
  --poll-seconds SECONDS        State polling interval; default 10
  --report-dir PATH             CSV directory; default PROJECT/reports
  --force-stop                  Use Compute STOP instead of graceful SOFTSTOP
  --dry-run                     Inspect and report planned changes only
  -h, --help

Always run with --dry-run first. The normal command deletes active Bastion
sessions, stops Autonomous Database, and powers off the Compute instance.
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || {
    echo "$option requires a value." >&2
    exit 2
  }
}

while (( $# > 0 )); do
  case "$1" in
    --tfvars) require_value "$1" "${2:-}"; tfvars_file="$2"; shift 2 ;;
    --terraform-dir) require_value "$1" "${2:-}"; terraform_dir="$2"; shift 2 ;;
    --skip-workspace-selection) skip_workspace_selection=true; shift ;;
    --profile) require_value "$1" "${2:-}"; profile="$2"; shift 2 ;;
    --auth) require_value "$1" "${2:-}"; auth_mode="$2"; shift 2 ;;
    --wait-seconds) require_value "$1" "${2:-}"; wait_seconds="$2"; shift 2 ;;
    --poll-seconds) require_value "$1" "${2:-}"; poll_seconds="$2"; shift 2 ;;
    --report-dir) require_value "$1" "${2:-}"; report_dir="$2"; shift 2 ;;
    --force-stop) force_stop=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v "$terraform_bin" >/dev/null || {
  echo "terraform is required: $terraform_bin" >&2
  exit 1
}
[[ -x "$lifecycle_script" ]] || {
  echo "Lifecycle script is not executable: $lifecycle_script" >&2
  exit 1
}

if [[ "$skip_workspace_selection" != "true" ]]; then
  [[ -x "$workspace_selector" ]] || {
    echo "Workspace selector is not executable: $workspace_selector" >&2
    exit 1
  }
  TERRAFORM_DIR="$terraform_dir" "$workspace_selector" "$tfvars_file"
fi

lifecycle_args=(
  --stop-all
  --terraform-dir "$terraform_dir"
  --profile "$profile"
  --wait-seconds "$wait_seconds"
  --poll-seconds "$poll_seconds"
  --report-dir "$report_dir"
)
[[ -n "$auth_mode" ]] && lifecycle_args+=(--auth "$auth_mode")
[[ "$force_stop" == "true" ]] && lifecycle_args+=(--force-stop)
[[ "$dry_run" == "true" ]] && lifecycle_args+=(--dry-run)

if [[ "$dry_run" == "true" ]]; then
  echo "Dry run: inspecting the stop plan; no OCI resource will be changed."
else
  echo "WARNING: closing Bastion sessions and stopping Autonomous Database and Compute."
fi

exec "$lifecycle_script" "${lifecycle_args[@]}"
