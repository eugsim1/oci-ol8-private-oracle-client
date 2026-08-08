#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"
report_dir="$root_dir/reports"
oci_bin="${OCI_CLI_BIN:-oci}"
terraform_bin="${TERRAFORM_BIN:-terraform}"

action="start"
dry_run=false
connect_after_start=false
force_stop=false
instance_id=""
autonomous_database_id=""
bastion_id=""
private_ip=""
region="${OCI_CLI_REGION:-}"
ssh_public_key=""
ssh_private_key=""
profile="${OCI_CLI_PROFILE:-DEFAULT}"
auth_mode=""
target_os_user="oracle"
target_port=22
session_ttl=10800
wait_seconds=3600
poll_seconds=10
session_display_name=""

usage() {
  cat <<'EOF'
Start an existing Compute instance and Autonomous Database, wait until they are
ready, and create a new OCI Bastion managed SSH session. The destructive mode
closes every non-deleted session for the Bastion and stops both resources.

Usage:
  manage-existing-stack.sh [--start] [options]
  manage-existing-stack.sh --stop-all [options]

Actions:
  --start                       Start resources and create a session (default).
  --stop-all                    Close all Bastion sessions, stop ADB and Compute.
  --force-stop                  Use Compute STOP instead of graceful SOFTSTOP.
  --connect                     Open interactive SSH after creating the session.
  --dry-run                     Query state and report planned mutations only.

Resource inputs (Terraform outputs are used when omitted):
  --instance-id OCID
  --autonomous-database-id OCID
  --bastion-id OCID
  --private-ip IPV4
  --region REGION
  --ssh-public-key PATH
  --ssh-private-key PATH        Needed only with --connect; inferred from .pub.
  --terraform-dir PATH

OCI and session options:
  --profile NAME                OCI CLI profile (default: DEFAULT).
  --auth MODE                   OCI CLI auth mode, for example instance_principal.
  --os-user USER                Target operating-system user (default: oracle).
  --target-port PORT            Managed SSH target port (default: 22).
  --session-ttl SECONDS         Bastion session TTL, 30-10800 (default: 10800).
  --session-display-name NAME
  --wait-seconds SECONDS        Overall state wait timeout (default: 3600).
  --poll-seconds SECONDS        State polling interval (default: 10).
  --report-dir PATH             CSV destination (default: PROJECT/reports).
  -h, --help

Every valid start or stop invocation creates a timestamped CSV report. Run this
from an external controller; --stop-all can power off the managed Compute host.
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
    --start) action="start"; shift ;;
    --stop-all) action="stop-all"; shift ;;
    --force-stop) force_stop=true; shift ;;
    --connect) connect_after_start=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    --instance-id) require_value "$1" "${2:-}"; instance_id="$2"; shift 2 ;;
    --autonomous-database-id) require_value "$1" "${2:-}"; autonomous_database_id="$2"; shift 2 ;;
    --bastion-id) require_value "$1" "${2:-}"; bastion_id="$2"; shift 2 ;;
    --private-ip) require_value "$1" "${2:-}"; private_ip="$2"; shift 2 ;;
    --region) require_value "$1" "${2:-}"; region="$2"; shift 2 ;;
    --ssh-public-key) require_value "$1" "${2:-}"; ssh_public_key="$2"; shift 2 ;;
    --ssh-private-key) require_value "$1" "${2:-}"; ssh_private_key="$2"; shift 2 ;;
    --terraform-dir) require_value "$1" "${2:-}"; terraform_dir="$2"; shift 2 ;;
    --profile) require_value "$1" "${2:-}"; profile="$2"; shift 2 ;;
    --auth) require_value "$1" "${2:-}"; auth_mode="$2"; shift 2 ;;
    --os-user) require_value "$1" "${2:-}"; target_os_user="$2"; shift 2 ;;
    --target-port) require_value "$1" "${2:-}"; target_port="$2"; shift 2 ;;
    --session-ttl) require_value "$1" "${2:-}"; session_ttl="$2"; shift 2 ;;
    --session-display-name) require_value "$1" "${2:-}"; session_display_name="$2"; shift 2 ;;
    --wait-seconds) require_value "$1" "${2:-}"; wait_seconds="$2"; shift 2 ;;
    --poll-seconds) require_value "$1" "${2:-}"; poll_seconds="$2"; shift 2 ;;
    --report-dir) require_value "$1" "${2:-}"; report_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$target_port" =~ ^[1-9][0-9]*$ ]] && (( target_port <= 65535 )) || {
  echo "--target-port must be between 1 and 65535." >&2
  exit 2
}
[[ "$session_ttl" =~ ^[0-9]+$ ]] && (( session_ttl >= 30 && session_ttl <= 10800 )) || {
  echo "--session-ttl must be between 30 and 10800 seconds." >&2
  exit 2
}
[[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "--wait-seconds must be a positive integer." >&2
  exit 2
}
[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "--poll-seconds must be a positive integer." >&2
  exit 2
}
if [[ "$action" == "stop-all" && "$connect_after_start" == "true" ]]; then
  echo "--connect cannot be combined with --stop-all." >&2
  exit 2
fi
if [[ "$action" == "start" && "$force_stop" == "true" ]]; then
  echo "--force-stop is valid only with --stop-all." >&2
  exit 2
fi

if [[ "$report_dir" != /* && ! "$report_dir" =~ ^[A-Za-z]:[\\/] ]]; then
  report_dir="$root_dir/$report_dir"
fi
mkdir -p "$report_dir"
run_timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
run_id="${run_timestamp}-$$"
report_file="$report_dir/stack-lifecycle-${run_id}.csv"
printf '%s\n' 'timestamp_utc,run_id,mode,resource_type,resource_ocid,operation,before_state,after_state,status,message' > "$report_file"
report_complete=false
main_bash_pid="$BASHPID"

csv_quote() {
  local value="${1:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

record_event() {
  local timestamp
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  local fields=(
    "$timestamp" "$run_id" "$action" "${1:-}" "${2:-}" "${3:-}"
    "${4:-}" "${5:-}" "${6:-}" "${7:-}"
  )
  local separator=""
  local field
  for field in "${fields[@]}"; do
    printf '%s' "$separator" >> "$report_file"
    csv_quote "$field" >> "$report_file"
    separator=","
  done
  printf '\n' >> "$report_file"
}

on_exit() {
  local exit_code=$?
  if [[ "$BASHPID" != "$main_bash_pid" ]]; then
    return "$exit_code"
  fi
  trap - EXIT
  set +e
  if [[ "$report_complete" != "true" ]]; then
    if (( exit_code == 0 )); then
      record_event "run" "$run_id" "complete" "IN_PROGRESS" "COMPLETE" "SUCCEEDED" "Lifecycle execution completed."
    else
      record_event "run" "$run_id" "complete" "IN_PROGRESS" "FAILED" "FAILED" "Lifecycle execution exited with code $exit_code."
    fi
  fi
  echo "CSV report: $report_file"
  exit "$exit_code"
}
trap on_exit EXIT

fail() {
  local message="$1"
  record_event "run" "$run_id" "error" "" "" "FAILED" "$message"
  echo "ERROR: $message" >&2
  return 1
}

clean_value() {
  local value="${1:-}"
  value="${value//$'\r'/}"
  value="${value%$'\n'}"
  printf '%s' "$value"
}

tf_output_optional() {
  local output_name="$1"
  local value=""
  if command -v "$terraform_bin" >/dev/null 2>&1 && [[ -d "$terraform_dir" ]]; then
    value="$($terraform_bin -chdir="$terraform_dir" output -raw "$output_name" 2>/dev/null || true)"
  fi
  clean_value "$value"
}

instance_id="${instance_id:-$(tf_output_optional instance_id)}"
autonomous_database_id="${autonomous_database_id:-$(tf_output_optional autonomous_database_id)}"
bastion_id="${bastion_id:-$(tf_output_optional bastion_id)}"
region="${region:-$(tf_output_optional region)}"

if [[ "$action" == "start" ]]; then
  private_ip="${private_ip:-$(tf_output_optional private_ip)}"
  ssh_public_key="${ssh_public_key:-$(tf_output_optional bastion_session_public_key_path)}"
  if [[ -z "$ssh_private_key" && "$ssh_public_key" == *.pub ]]; then
    ssh_private_key="${ssh_public_key%.pub}"
  fi
fi

[[ "$instance_id" == ocid1.instance.* ]] || fail "A valid Compute instance OCID is required. Use --instance-id or apply Terraform first."
[[ "$autonomous_database_id" == ocid1.autonomousdatabase.* ]] || fail "A valid Autonomous Database OCID is required. Use --autonomous-database-id or apply Terraform first."
[[ "$bastion_id" == ocid1.bastion.* ]] || fail "A valid Bastion OCID is required. Use --bastion-id or apply Terraform first."
[[ "$region" =~ ^[a-z]{2}-[a-z0-9-]+-[0-9]+$ ]] || fail "A valid OCI region is required. Use --region or a Terraform region output."
command -v "$oci_bin" >/dev/null 2>&1 || fail "OCI CLI executable not found: $oci_bin"

if [[ "$action" == "start" ]]; then
  [[ "$private_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "A target private IPv4 address is required. Use --private-ip or a Terraform private_ip output."
  [[ -r "$ssh_public_key" ]] || fail "The Bastion SSH public key is not readable: ${ssh_public_key:-not resolved}"
fi

oci_global_args=(--profile "$profile" --region "$region")
if [[ -n "$auth_mode" ]]; then
  oci_global_args+=(--auth "$auth_mode")
fi

oci_cli() {
  "$oci_bin" "${oci_global_args[@]}" "$@"
}

capture_oci() {
  local variable_name="$1"
  local description="$2"
  shift 2
  local value
  if ! value="$(oci_cli "$@" 2>&1)"; then
    fail "$description failed: $value"
    return 1
  fi
  value="$(clean_value "$value")"
  printf -v "$variable_name" '%s' "$value"
}

get_compute_state() {
  local variable_name="$1"
  capture_oci "$variable_name" "Reading Compute state" \
    compute instance get --instance-id "$instance_id" \
    --query 'data."lifecycle-state"' --raw-output
}

get_adb_state() {
  local variable_name="$1"
  capture_oci "$variable_name" "Reading Autonomous Database state" \
    db autonomous-database get --autonomous-database-id "$autonomous_database_id" \
    --query 'data."lifecycle-state"' --raw-output
}

get_session_state_optional() {
  local variable_name="$1"
  local session_id="$2"
  local value
  if value="$(oci_cli bastion session get --session-id "$session_id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)"; then
    value="$(clean_value "$value")"
  else
    value="DELETED_OR_NOT_FOUND"
  fi
  printf -v "$variable_name" '%s' "$value"
}

wait_for_resource_state() {
  local resource_type="$1"
  local resource_id="$2"
  local expected_state="$3"
  local getter="$4"
  local deadline=$((SECONDS + wait_seconds))
  local current_state=""
  while (( SECONDS < deadline )); do
    "$getter" current_state || return 1
    if [[ "$current_state" == "$expected_state" ]]; then
      record_event "$resource_type" "$resource_id" "wait" "" "$current_state" "SUCCEEDED" "Reached $expected_state."
      return 0
    fi
    echo "Waiting for $resource_type to reach $expected_state; current state: ${current_state:-unknown}"
    sleep "$poll_seconds"
  done
  fail "$resource_type did not reach $expected_state within ${wait_seconds}s; final state: ${current_state:-unknown}"
}

run_mutation() {
  local description="$1"
  shift
  local output
  if ! output="$(oci_cli "$@" 2>&1)"; then
    fail "$description failed: $output"
    return 1
  fi
}

start_resources() {
  local compute_state adb_state
  get_compute_state compute_state
  get_adb_state adb_state
  record_event "compute" "$instance_id" "inspect" "$compute_state" "$compute_state" "SUCCEEDED" "Current Compute state."
  record_event "autonomous_database" "$autonomous_database_id" "inspect" "$adb_state" "$adb_state" "SUCCEEDED" "Current Autonomous Database state; AVAILABLE is its running state."

  case "$compute_state" in
    RUNNING|STARTING) ;;
    STOPPED)
      if [[ "$dry_run" == "true" ]]; then
        record_event "compute" "$instance_id" "start" "$compute_state" "RUNNING" "PLANNED" "Would request Compute START."
      else
        run_mutation "Starting Compute" compute instance action --instance-id "$instance_id" --action START
        record_event "compute" "$instance_id" "start" "$compute_state" "STARTING" "REQUESTED" "Compute START accepted."
      fi
      ;;
    *) fail "Compute cannot be started safely from state $compute_state. Wait for a stable state and retry."; return 1 ;;
  esac

  case "$adb_state" in
    AVAILABLE|STARTING) ;;
    STOPPED)
      if [[ "$dry_run" == "true" ]]; then
        record_event "autonomous_database" "$autonomous_database_id" "start" "$adb_state" "AVAILABLE" "PLANNED" "Would start Autonomous Database."
      else
        run_mutation "Starting Autonomous Database" db autonomous-database start --autonomous-database-id "$autonomous_database_id"
        record_event "autonomous_database" "$autonomous_database_id" "start" "$adb_state" "STARTING" "REQUESTED" "Autonomous Database start accepted."
      fi
      ;;
    *) fail "Autonomous Database cannot be started safely from state $adb_state. Wait for a stable state and retry."; return 1 ;;
  esac

  if [[ "$dry_run" == "true" ]]; then
    record_event "bastion_session" "$bastion_id" "create" "NOT_CREATED" "ACTIVE" "PLANNED" "Would create a managed SSH session after both resources become ready."
    echo "Dry run complete; no OCI resource was changed."
    return 0
  fi

  wait_for_resource_state "compute" "$instance_id" "RUNNING" get_compute_state
  wait_for_resource_state "autonomous_database" "$autonomous_database_id" "AVAILABLE" get_adb_state
  create_bastion_session
}

discover_session_id() {
  local variable_name="$1"
  local deadline=$((SECONDS + wait_seconds))
  local discovered=""
  while (( SECONDS < deadline )); do
    if ! discovered="$(oci_cli bastion session list \
      --bastion-id "$bastion_id" \
      --display-name "$session_display_name" \
      --all \
      --query 'data[0].id' \
      --raw-output 2>/dev/null)"; then
      discovered=""
    fi
    discovered="$(clean_value "$discovered")"
    if [[ "$discovered" == ocid1.bastionsession.* ]]; then
      printf -v "$variable_name" '%s' "$discovered"
      return 0
    fi
    sleep "$poll_seconds"
  done
  fail "The Bastion work request succeeded, but its new session OCID could not be resolved."
}

wait_for_session_active() {
  local session_id="$1"
  local deadline=$((SECONDS + wait_seconds))
  local state=""
  while (( SECONDS < deadline )); do
    get_session_state_optional state "$session_id"
    case "$state" in
      ACTIVE) record_event "bastion_session" "$session_id" "wait" "CREATING" "ACTIVE" "SUCCEEDED" "Managed SSH session is active."; return 0 ;;
      FAILED|DELETED|DELETED_OR_NOT_FOUND) fail "Bastion session $session_id entered state $state before becoming ACTIVE."; return 1 ;;
    esac
    echo "Waiting for Bastion session to become ACTIVE; current state: ${state:-unknown}"
    sleep "$poll_seconds"
  done
  fail "Bastion session $session_id did not become ACTIVE within ${wait_seconds}s; final state: ${state:-unknown}"
}

print_or_open_ssh() {
  local session_id="$1"
  local bastion_host="host.bastion.$region.oci.oraclecloud.com"
  if [[ ! -r "$ssh_private_key" ]]; then
    echo "Managed SSH session created. Pass --ssh-private-key with the matching private key to use --connect."
    echo "Session OCID: $session_id"
    return 0
  fi

  local proxy_command
  printf -v proxy_command 'ssh -i %q -o StrictHostKeyChecking=accept-new -W %%h:%%p -p 22 %q' \
    "$ssh_private_key" "$session_id@$bastion_host"
  printf 'SSH command:\nssh -i %q -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o %q -p %q %q\n' \
    "$ssh_private_key" "ProxyCommand=$proxy_command" "$target_port" "$target_os_user@$private_ip"

  if [[ "$connect_after_start" == "true" ]]; then
    command -v ssh >/dev/null 2>&1 || fail "OpenSSH is required by --connect."
    record_event "ssh" "$session_id" "connect" "READY" "CONNECTING" "REQUESTED" "Opening interactive SSH."
    local ssh_status=0
    ssh \
      -i "$ssh_private_key" \
      -o StrictHostKeyChecking=accept-new \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -o "ProxyCommand=$proxy_command" \
      -p "$target_port" \
      "$target_os_user@$private_ip" || ssh_status=$?
    if (( ssh_status != 0 )); then
      fail "Interactive SSH exited with code $ssh_status."
      return 1
    fi
    record_event "ssh" "$session_id" "connect" "CONNECTING" "CLOSED" "SUCCEEDED" "Interactive SSH ended normally."
  fi
}

create_bastion_session() {
  if [[ -z "$session_display_name" ]]; then
    session_display_name="focus-lifecycle-$run_timestamp"
  fi
  local session_id=""
  local create_output=""
  if ! create_output="$(oci_cli bastion session create-managed-ssh \
    --bastion-id "$bastion_id" \
    --display-name "$session_display_name" \
    --key-type PUB \
    --session-ttl "$session_ttl" \
    --ssh-public-key-file "$ssh_public_key" \
    --target-os-username "$target_os_user" \
    --target-port "$target_port" \
    --target-private-ip "$private_ip" \
    --target-resource-id "$instance_id" \
    --wait-for-state SUCCEEDED \
    --max-wait-seconds "$wait_seconds" \
    --wait-interval-seconds "$poll_seconds" 2>&1)"; then
    fail "Creating the Bastion managed SSH session failed: $create_output"
    return 1
  fi
  discover_session_id session_id || return 1
  record_event "bastion_session" "$session_id" "create" "NOT_CREATED" "CREATING" "REQUESTED" "Managed SSH session work request succeeded."
  wait_for_session_active "$session_id"
  print_or_open_ssh "$session_id"
}

list_open_session_ids() {
  local variable_name="$1"
  local ids=""
  capture_oci ids "Listing Bastion sessions" bastion session list \
    --bastion-id "$bastion_id" \
    --all \
    --query 'join(`\n`, data[?"lifecycle-state" != `DELETED`].id)' \
    --raw-output || return 1
  [[ "$ids" == "None" || "$ids" == "null" ]] && ids=""
  printf -v "$variable_name" '%s' "$ids"
}

wait_for_session_deleted() {
  local session_id="$1"
  local initial_state="$2"
  local deadline=$((SECONDS + wait_seconds))
  local state=""
  while (( SECONDS < deadline )); do
    get_session_state_optional state "$session_id"
    case "$state" in
      DELETED|DELETED_OR_NOT_FOUND)
        record_event "bastion_session" "$session_id" "delete" "$initial_state" "$state" "SUCCEEDED" "Session closed."
        return 0
        ;;
    esac
    sleep "$poll_seconds"
  done
  fail "Bastion session $session_id was not deleted within ${wait_seconds}s; final state: ${state:-unknown}"
}

close_all_sessions() {
  local session_ids=""
  list_open_session_ids session_ids || return 1
  if [[ -z "$session_ids" ]]; then
    record_event "bastion" "$bastion_id" "list_sessions" "NONE" "NONE" "SUCCEEDED" "No non-deleted Bastion sessions found."
    return 0
  fi

  local session_id state
  while IFS= read -r session_id; do
    session_id="$(clean_value "$session_id")"
    [[ -n "$session_id" ]] || continue
    [[ "$session_id" == ocid1.bastionsession.* ]] || {
      fail "Unexpected session identifier returned by OCI CLI: $session_id"
      return 1
    }
    get_session_state_optional state "$session_id"
    if [[ "$dry_run" == "true" ]]; then
      record_event "bastion_session" "$session_id" "delete" "$state" "DELETED" "PLANNED" "Would close the Bastion session."
    else
      if [[ "$state" != "DELETING" ]]; then
        run_mutation "Deleting Bastion session $session_id" bastion session delete --session-id "$session_id" --force
        record_event "bastion_session" "$session_id" "delete" "$state" "DELETING" "REQUESTED" "Session delete accepted."
      fi
      wait_for_session_deleted "$session_id" "$state"
    fi
  done <<< "$session_ids"
}

stop_resources() {
  close_all_sessions || return 1

  local compute_state adb_state
  get_compute_state compute_state
  get_adb_state adb_state
  record_event "compute" "$instance_id" "inspect" "$compute_state" "$compute_state" "SUCCEEDED" "Current Compute state."
  record_event "autonomous_database" "$autonomous_database_id" "inspect" "$adb_state" "$adb_state" "SUCCEEDED" "Current Autonomous Database state."

  if [[ "$adb_state" == "STARTING" ]]; then
    if [[ "$dry_run" == "true" ]]; then
      record_event "autonomous_database" "$autonomous_database_id" "stop" "$adb_state" "STOPPED" "PLANNED" "Would wait for AVAILABLE, then stop."
      adb_state="STOPPED"
    else
      wait_for_resource_state "autonomous_database" "$autonomous_database_id" "AVAILABLE" get_adb_state
      adb_state="AVAILABLE"
    fi
  fi
  case "$adb_state" in
    STOPPED) record_event "autonomous_database" "$autonomous_database_id" "stop" "STOPPED" "STOPPED" "NO_CHANGE" "Already stopped." ;;
    STOPPING) ;;
    AVAILABLE)
      if [[ "$dry_run" == "true" ]]; then
        record_event "autonomous_database" "$autonomous_database_id" "stop" "$adb_state" "STOPPED" "PLANNED" "Would stop Autonomous Database."
      else
        run_mutation "Stopping Autonomous Database" db autonomous-database stop --autonomous-database-id "$autonomous_database_id"
        record_event "autonomous_database" "$autonomous_database_id" "stop" "$adb_state" "STOPPING" "REQUESTED" "Autonomous Database stop accepted."
      fi
      ;;
    *) fail "Autonomous Database cannot be stopped safely from state $adb_state."; return 1 ;;
  esac

  if [[ "$compute_state" == "STARTING" ]]; then
    if [[ "$dry_run" == "true" ]]; then
      record_event "compute" "$instance_id" "stop" "$compute_state" "STOPPED" "PLANNED" "Would wait for RUNNING, then stop."
      compute_state="STOPPED"
    else
      wait_for_resource_state "compute" "$instance_id" "RUNNING" get_compute_state
      compute_state="RUNNING"
    fi
  fi
  case "$compute_state" in
    STOPPED) record_event "compute" "$instance_id" "stop" "STOPPED" "STOPPED" "NO_CHANGE" "Already stopped." ;;
    STOPPING) ;;
    RUNNING)
      local compute_action="SOFTSTOP"
      [[ "$force_stop" == "true" ]] && compute_action="STOP"
      if [[ "$dry_run" == "true" ]]; then
        record_event "compute" "$instance_id" "stop" "$compute_state" "STOPPED" "PLANNED" "Would request Compute $compute_action."
      else
        run_mutation "Stopping Compute" compute instance action --instance-id "$instance_id" --action "$compute_action"
        record_event "compute" "$instance_id" "stop" "$compute_state" "STOPPING" "REQUESTED" "Compute $compute_action accepted."
      fi
      ;;
    *) fail "Compute cannot be stopped safely from state $compute_state."; return 1 ;;
  esac

  if [[ "$dry_run" == "true" ]]; then
    echo "Dry run complete; no OCI resource was changed."
    return 0
  fi
  wait_for_resource_state "autonomous_database" "$autonomous_database_id" "STOPPED" get_adb_state
  wait_for_resource_state "compute" "$instance_id" "STOPPED" get_compute_state
}

echo "Lifecycle action: $action"
echo "Compute: $instance_id"
echo "Autonomous Database: $autonomous_database_id"
echo "Bastion: $bastion_id"
echo "Region: $region"
echo "Dry run: $dry_run"

if [[ "$action" == "start" ]]; then
  start_resources
else
  stop_resources
fi

record_event "run" "$run_id" "complete" "IN_PROGRESS" "COMPLETE" "SUCCEEDED" "Lifecycle execution completed."
report_complete=true
