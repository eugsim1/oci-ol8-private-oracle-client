#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"
terraform_bin="${TERRAFORM_BIN:-terraform}"
oci_bin="${OCI_CLI_BIN:-oci}"
instance_id=""
region="${OCI_CLI_REGION:-}"
profile="${OCI_CLI_PROFILE:-DEFAULT}"
auth_mode="${OCI_AUTH_MODE:-}"
wait_seconds=900
poll_seconds=10
dry_run=false

usage() {
  cat <<'EOF'
Wait until the Compute instance's Oracle Cloud Agent Bastion plugin reports
RUNNING. Transient OCI CLI/API failures are displayed and retried until the
timeout; a Bastion session is not created by this command.

Usage:
  wait-for-bastion-plugin.sh [options]

Options:
  --instance-id OCID        Compute OCID; default Terraform output instance_id
  --region REGION           OCI region; default Terraform output region
  --terraform-dir PATH      Terraform root; default PROJECT/terraform
  --profile NAME            OCI CLI profile; default DEFAULT
  --auth MODE               OCI CLI auth mode, such as instance_principal
  --wait-seconds SECONDS    Timeout; default 900
  --poll-seconds SECONDS    Polling interval; default 10
  --dry-run                 Validate inputs and print the planned readiness gate
  -h, --help
EOF
}

require_value() {
  local option="$1" value="${2:-}"
  [[ -n "$value" ]] || { echo "$option requires a value." >&2; exit 2; }
}

while (( $# > 0 )); do
  case "$1" in
    --instance-id) require_value "$1" "${2:-}"; instance_id="$2"; shift 2 ;;
    --region) require_value "$1" "${2:-}"; region="$2"; shift 2 ;;
    --terraform-dir) require_value "$1" "${2:-}"; terraform_dir="$2"; shift 2 ;;
    --profile) require_value "$1" "${2:-}"; profile="$2"; shift 2 ;;
    --auth) require_value "$1" "${2:-}"; auth_mode="$2"; shift 2 ;;
    --wait-seconds) require_value "$1" "${2:-}"; wait_seconds="$2"; shift 2 ;;
    --poll-seconds) require_value "$1" "${2:-}"; poll_seconds="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "--wait-seconds must be a positive integer." >&2; exit 2; }
[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "--poll-seconds must be a positive integer." >&2; exit 2; }

clean_value() {
  local value="${1:-}"
  value="${value//$'\r'/}"
  value="${value%$'\n'}"
  printf '%s' "$value"
}

tf_output_optional() {
  local output_name="$1" value=""
  if command -v "$terraform_bin" >/dev/null 2>&1 && [[ -d "$terraform_dir" ]]; then
    value="$($terraform_bin -chdir="$terraform_dir" output -raw "$output_name" 2>/dev/null || true)"
  fi
  clean_value "$value"
}

instance_id="${instance_id:-$(tf_output_optional instance_id)}"
region="${region:-$(tf_output_optional region)}"
[[ "$instance_id" == ocid1.instance.* ]] || { echo "A valid Compute instance OCID is required." >&2; exit 1; }
[[ "$region" =~ ^[a-z]{2}-[a-z0-9-]+-[0-9]+$ ]] || { echo "A valid OCI region is required." >&2; exit 1; }
command -v "$oci_bin" >/dev/null 2>&1 || { echo "OCI CLI executable not found: $oci_bin" >&2; exit 1; }

oci_global_args=(--profile "$profile" --region "$region")
[[ -n "$auth_mode" ]] && oci_global_args+=(--auth "$auth_mode")

oci_cli() {
  "$oci_bin" "${oci_global_args[@]}" "$@"
}

# Sets OCI_VALUE and OCI_ERROR without terminating the polling loop.
try_oci() {
  local stderr_file
  OCI_VALUE=""
  OCI_ERROR=""
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/bastion-plugin-stderr.XXXXXX")" || {
    OCI_ERROR="could not create a temporary stderr file"
    return 1
  }
  if OCI_VALUE="$(oci_cli "$@" 2>"$stderr_file")"; then
    if [[ -s "$stderr_file" ]]; then
      cat "$stderr_file" >&2
    fi
    rm -f "$stderr_file"
    OCI_VALUE="$(clean_value "$OCI_VALUE")"
    return 0
  fi
  OCI_ERROR="$(<"$stderr_file")"
  rm -f "$stderr_file"
  OCI_ERROR="${OCI_ERROR//$'\r'/ }"
  OCI_ERROR="${OCI_ERROR//$'\n'/ }"
  OCI_ERROR="${OCI_ERROR:0:500}"
  return 1
}

echo "Bastion plugin readiness gate"
echo "Compute: $instance_id"
echo "Region: $region"
echo "Timeout: ${wait_seconds}s; polling interval: ${poll_seconds}s"
if [[ "$dry_run" == "true" ]]; then
  echo "Dry run: would poll the Bastion plugin until status=RUNNING."
  exit 0
fi

deadline=$((SECONDS + wait_seconds))
iteration=0
compartment_id=""
last_status="NOT_REPORTED"
while (( SECONDS < deadline )); do
  iteration=$((iteration + 1))

  if [[ -z "$compartment_id" ]]; then
    if ! try_oci compute instance get \
      --instance-id "$instance_id" \
      --query 'data."compartment-id"' \
      --raw-output; then
      last_status="QUERY_ERROR"
      echo "Bastion plugin check $iteration: status=$last_status; retrying; error=${OCI_ERROR:-unknown OCI error}"
      sleep "$poll_seconds"
      continue
    fi
    compartment_id="$OCI_VALUE"
    if [[ "$compartment_id" != ocid1.compartment.* && "$compartment_id" != ocid1.tenancy.* ]]; then
      last_status="COMPARTMENT_NOT_READY"
      echo "Bastion plugin check $iteration: status=$last_status; retrying"
      compartment_id=""
      sleep "$poll_seconds"
      continue
    fi
  fi

  if ! try_oci instance-agent plugin list \
    --compartment-id "$compartment_id" \
    --instanceagent-id "$instance_id" \
    --name Bastion \
    --query 'data[0].status' \
    --raw-output; then
    last_status="QUERY_ERROR"
    echo "Bastion plugin check $iteration: status=$last_status; retrying; error=${OCI_ERROR:-unknown OCI error}"
    sleep "$poll_seconds"
    continue
  fi

  last_status="$OCI_VALUE"
  case "$last_status" in
    ""|None|null) last_status="NOT_REPORTED" ;;
  esac
  echo "Bastion plugin check $iteration: status=$last_status; expected=RUNNING"
  case "$last_status" in
    RUNNING)
      echo "Bastion plugin is RUNNING after $iteration iteration(s)."
      exit 0
      ;;
    INVALID|NOT_SUPPORTED)
      echo "Bastion plugin cannot become ready from status $last_status. Check Oracle Cloud Agent configuration." >&2
      exit 1
      ;;
  esac
  sleep "$poll_seconds"
done

echo "Bastion plugin did not reach RUNNING within ${wait_seconds}s after $iteration iteration(s); final status: $last_status" >&2
exit 1
