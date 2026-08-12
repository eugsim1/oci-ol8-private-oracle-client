#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$project_dir/scripts/wait-for-bastion-plugin.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

state_dir="$test_dir/state"
mkdir -p "$state_dir"
printf '0\n' > "$state_dir/compute-calls"
printf '0\n' > "$state_dir/plugin-calls"

mock_oci="$test_dir/oci"
cat > "$mock_oci" <<'MOCK_OCI'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="${MOCK_STATE_DIR:?}"
while [[ "${1:-}" == --profile || "${1:-}" == --region || "${1:-}" == --auth ]]; do
  shift 2
done

case "${1:-} ${2:-} ${3:-}" in
  "compute instance get")
    calls="$(<"$state_dir/compute-calls")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$state_dir/compute-calls"
    if (( calls == 1 )); then
      printf 'ServiceError: instance agent metadata is not ready yet\n' >&2
      exit 1
    fi
    printf 'ocid1.compartment.oc1..testcompartment\n'
    ;;
  "instance-agent plugin list")
    calls="$(<"$state_dir/plugin-calls")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$state_dir/plugin-calls"
    case "$calls" in
      1) printf 'None\n' ;;
      2) printf 'ServiceError: plugin inventory is temporarily unavailable\n' >&2; exit 1 ;;
      3) printf 'INVALID\n' ;;
      4) printf 'STOPPED\n' ;;
      *) printf 'RUNNING\n' ;;
    esac
    ;;
  *)
    printf 'Unexpected OCI arguments: %s\n' "$*" >&2
    exit 64
    ;;
esac
MOCK_OCI
chmod +x "$mock_oci"

export OCI_CLI_BIN="$mock_oci"
export MOCK_STATE_DIR="$state_dir"

output="$(
  "$script" \
    --instance-id ocid1.instance.oc1.eu-frankfurt-1.testcompute \
    --region eu-frankfurt-1 \
    --profile TESTPROFILE \
    --wait-seconds 30 \
    --poll-seconds 1
)"

grep -Fq 'Bastion plugin check 1: status=QUERY_ERROR; retrying' <<< "$output"
grep -Fq 'Bastion plugin check 2: status=NOT_REPORTED; expected=RUNNING' <<< "$output"
grep -Fq 'Bastion plugin check 3: status=QUERY_ERROR; retrying' <<< "$output"
grep -Fq 'Bastion plugin check 4: status=INVALID; expected=RUNNING' <<< "$output"
grep -Fq 'Bastion plugin status is not yet recognizable by OCI; retrying until RUNNING or timeout.' <<< "$output"
grep -Fq 'Bastion plugin check 5: status=STOPPED; expected=RUNNING' <<< "$output"
grep -Fq 'Bastion plugin check 6: status=RUNNING; expected=RUNNING' <<< "$output"
grep -Fq 'Bastion plugin is RUNNING after 6 iteration(s).' <<< "$output"
[[ "$(<"$state_dir/compute-calls")" == '2' ]]
[[ "$(<"$state_dir/plugin-calls")" == '5' ]]

before_compute_calls="$(<"$state_dir/compute-calls")"
dry_output="$(
  "$script" \
    --instance-id ocid1.instance.oc1.eu-frankfurt-1.testcompute \
    --region eu-frankfurt-1 \
    --dry-run
)"
grep -Fq 'Dry run: would poll the Bastion plugin until status=RUNNING.' <<< "$dry_output"
[[ "$(<"$state_dir/compute-calls")" == "$before_compute_calls" ]]

echo 'PASS: Bastion plugin waiter retries transient OCI failures and INVALID status until RUNNING'
