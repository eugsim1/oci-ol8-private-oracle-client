#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$project_dir/scripts/manage-existing-stack.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

mock_state_dir="$test_dir/state"
mock_report_dir="$test_dir/reports"
mkdir -p "$mock_state_dir" "$mock_report_dir"
printf 'STOPPED\n' > "$mock_state_dir/compute"
printf 'STOPPED\n' > "$mock_state_dir/adb"
: > "$mock_state_dir/deleted-sessions"

public_key="$test_dir/bastion_key.pub"
private_key="$test_dir/bastion_key"
printf 'ssh-rsa AAAATESTONLY lifecycle-test\n' > "$public_key"
printf 'TEST-ONLY-PRIVATE-KEY-PLACEHOLDER\n' > "$private_key"

mock_oci="$test_dir/oci"
cat > "$mock_oci" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${MOCK_STATE_DIR:?}"
while [[ "${1:-}" == --profile || "${1:-}" == --region || "${1:-}" == --auth ]]; do
  shift 2
done

value_after() {
  local wanted="$1"
  shift
  while (( $# > 0 )); do
    if [[ "$1" == "$wanted" ]]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
  return 1
}

case "${1:-} ${2:-} ${3:-}" in
  "compute instance get")
    cat "$state_dir/compute"
    ;;
  "compute instance action")
    requested_action="$(value_after --action "$@")"
    case "$requested_action" in
      START) printf 'RUNNING\n' > "$state_dir/compute" ;;
      SOFTSTOP|STOP) printf 'STOPPED\n' > "$state_dir/compute" ;;
      *) exit 64 ;;
    esac
    printf '{}\n'
    ;;
  "db autonomous-database get")
    cat "$state_dir/adb"
    ;;
  "db autonomous-database start")
    printf 'AVAILABLE\n' > "$state_dir/adb"
    printf '{}\n'
    ;;
  "db autonomous-database stop")
    printf 'STOPPED\n' > "$state_dir/adb"
    printf '{}\n'
    ;;
  "bastion session create-managed-ssh")
    printf 'ocid1.bastionsession.oc1.eu-frankfurt-1.testnewsession\n'
    ;;
  "bastion session list")
    if value_after --display-name "$@" >/dev/null 2>&1; then
      printf 'ocid1.bastionsession.oc1.eu-frankfurt-1.testnewsession\n'
    else
      printf '%s\n' \
        'ocid1.bastionsession.oc1.eu-frankfurt-1.testoldsession1' \
        'ocid1.bastionsession.oc1.eu-frankfurt-1.testoldsession2'
    fi
    ;;
  "bastion session get")
    session_id="$(value_after --session-id "$@")"
    if grep -Fqx "$session_id" "$state_dir/deleted-sessions"; then
      exit 1
    fi
    printf 'ACTIVE\n'
    ;;
  "bastion session delete")
    session_id="$(value_after --session-id "$@")"
    printf '%s\n' "$session_id" >> "$state_dir/deleted-sessions"
    printf '{}\n'
    ;;
  *)
    printf 'Unexpected mock OCI arguments: %s\n' "$*" >&2
    exit 65
    ;;
esac
MOCK
chmod +x "$mock_oci"

export OCI_CLI_BIN="$mock_oci"
export MOCK_STATE_DIR="$mock_state_dir"

common_args=(
  --instance-id ocid1.instance.oc1.eu-frankfurt-1.testcompute
  --autonomous-database-id ocid1.autonomousdatabase.oc1.eu-frankfurt-1.testadb
  --bastion-id ocid1.bastion.oc1.eu-frankfurt-1.testbastion
  --region eu-frankfurt-1
  --poll-seconds 1
  --wait-seconds 5
  --report-dir "$mock_report_dir"
)

"$script" \
  --dry-run \
  "${common_args[@]}" \
  --private-ip 10.0.1.10 \
  --ssh-public-key "$public_key" \
  --ssh-private-key "$private_key"

[[ "$(<"$mock_state_dir/compute")" == "STOPPED" ]]
[[ "$(<"$mock_state_dir/adb")" == "STOPPED" ]]
dry_run_report="$(find "$mock_report_dir" -name 'stack-lifecycle-*.csv' -print | sort | head -n 1)"
grep -q 'PLANNED' "$dry_run_report"
grep -q 'Would create a managed SSH session' "$dry_run_report"

sleep 1
"$script" \
  "${common_args[@]}" \
  --private-ip 10.0.1.10 \
  --ssh-public-key "$public_key" \
  --ssh-private-key "$private_key"

[[ "$(<"$mock_state_dir/compute")" == "RUNNING" ]]
[[ "$(<"$mock_state_dir/adb")" == "AVAILABLE" ]]
start_report="$(find "$mock_report_dir" -name 'stack-lifecycle-*.csv' -print | sort | sed -n '2p')"
grep -q 'bastion_session' "$start_report"
grep -q 'testnewsession' "$start_report"
grep -q 'SUCCEEDED' "$start_report"

sleep 1
"$script" --stop-all "${common_args[@]}"

[[ "$(<"$mock_state_dir/compute")" == "STOPPED" ]]
[[ "$(<"$mock_state_dir/adb")" == "STOPPED" ]]
grep -Fqx 'ocid1.bastionsession.oc1.eu-frankfurt-1.testoldsession1' "$mock_state_dir/deleted-sessions"
grep -Fqx 'ocid1.bastionsession.oc1.eu-frankfurt-1.testoldsession2' "$mock_state_dir/deleted-sessions"

report_count="$(find "$mock_report_dir" -name 'stack-lifecycle-*.csv' -print | wc -l | tr -d ' ')"
[[ "$report_count" == "3" ]]
stop_report="$(find "$mock_report_dir" -name 'stack-lifecycle-*.csv' -print | sort | tail -n 1)"
grep -q 'SOFTSTOP accepted' "$stop_report"
grep -q 'Autonomous Database stop accepted' "$stop_report"
grep -q 'Lifecycle execution completed' "$stop_report"
while IFS= read -r report; do
  [[ "$(wc -c < "$report")" -lt 50000 ]]
  [[ "$(wc -l < "$report")" -lt 50 ]]
done < <(find "$mock_report_dir" -name 'stack-lifecycle-*.csv' -type f -print)

echo "PASS: dry-run, start, waits, Bastion sessions, stop-all, and CSV reporting"
