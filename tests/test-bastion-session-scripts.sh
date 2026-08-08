#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

private_key="$test_dir/bastion_key"
public_key="${private_key}.pub"
printf '%s\n' 'TEST-ONLY-PRIVATE-KEY-PLACEHOLDER' > "$private_key"
printf '%s\n' 'ssh-ed25519 AAAATESTONLY bastion-test' > "$public_key"
chmod 600 "$private_key"

mock_terraform="$test_dir/terraform"
terraform_log="$test_dir/terraform.log"
session_state_file="$test_dir/session-state"
session_id_file="$test_dir/session-id"
printf '%s\n' 'EXPIRED' > "$session_state_file"
printf '%s\n' 'ocid1.bastionsession.oc1.eu-frankfurt-1.testold' > "$session_id_file"

cat > "$mock_terraform" <<'MOCK_TERRAFORM'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${MOCK_TERRAFORM_LOG:?}"
[[ "${1:-}" == -chdir=* ]] && shift

case "${1:-} ${2:-}" in
  "init -input=false") exit 0 ;;
  "workspace show") printf '%s\n' 'default'; exit 0 ;;
  "state list") exit 0 ;;
  "workspace select") exit 0 ;;
esac

if [[ "${1:-}" == "output" && "${2:-}" == "-raw" ]]; then
  case "${3:-}" in
    bastion_session_enabled) printf '%s\n' 'true' ;;
    bastion_session_public_key_path) printf '%s\n' "${MOCK_PUBLIC_KEY:?}" ;;
    bastion_session_id) cat "${MOCK_SESSION_ID_FILE:?}" ;;
    bastion_session_state) cat "${MOCK_SESSION_STATE_FILE:?}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "apply" ]]; then
  if [[ " $* " == *' -replace='* ]]; then
    printf '%s\n' 'ACTIVE' > "${MOCK_SESSION_STATE_FILE:?}"
    printf '%s\n' 'ocid1.bastionsession.oc1.eu-frankfurt-1.testnew' > "${MOCK_SESSION_ID_FILE:?}"
  fi
  exit 0
fi

printf 'Unexpected mock Terraform arguments: %s\n' "$*" >&2
exit 64
MOCK_TERRAFORM
chmod +x "$mock_terraform"

workspace_selector="$test_dir/select-workspace"
workspace_log="$test_dir/workspace.log"
cat > "$workspace_selector" <<'MOCK_SELECTOR'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${MOCK_WORKSPACE_LOG:?}"
MOCK_SELECTOR
chmod +x "$workspace_selector"

lifecycle_script="$test_dir/manage-existing-stack"
lifecycle_log="$test_dir/lifecycle.log"
cat > "$lifecycle_script" <<'MOCK_LIFECYCLE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" > "${MOCK_LIFECYCLE_LOG:?}"
MOCK_LIFECYCLE
chmod +x "$lifecycle_script"

export MOCK_TERRAFORM_LOG="$terraform_log"
export MOCK_PUBLIC_KEY="$public_key"
export MOCK_SESSION_STATE_FILE="$session_state_file"
export MOCK_SESSION_ID_FILE="$session_id_file"
export MOCK_WORKSPACE_LOG="$workspace_log"
export MOCK_LIFECYCLE_LOG="$lifecycle_log"

tfvars_file="$test_dir/terraform.tfvars"
printf '%s\n' 'compartment_id = "ocid1.compartment.oc1..test"' > "$tfvars_file"

# Validate the real workspace selector with an injected Terraform executable
# and Terraform directory. It must not require the project's default path.
custom_terraform_dir="$test_dir/custom-terraform"
mkdir -p "$custom_terraform_dir"
TERRAFORM_BIN="$mock_terraform" \
TERRAFORM_DIR="$custom_terraform_dir" \
"$project_dir/scripts/select-compartment-workspace.sh" "$tfvars_file" >/dev/null
grep -Fq 'workspace select -or-create compartment-' "$terraform_log"

renew_output="$(
  TERRAFORM_BIN="$mock_terraform" \
  WORKSPACE_SELECTOR_BIN="$workspace_selector" \
  BASTION_SESSION_ACTIVE_TIMEOUT=2 \
  "$project_dir/scripts/renew-bastion-session.sh" "$tfvars_file"
)"
grep -Fq 'No Ansible playbook was executed.' <<< "$renew_output"
grep -Fq -- '-replace=module.bastion.oci_bastion_session.ansible[0]' "$terraform_log"
grep -Fq -- '-refresh-only' "$terraform_log"
grep -Fqx "$tfvars_file" "$workspace_log"
[[ "$(<"$session_state_file")" == 'ACTIVE' ]]
[[ "$(<"$session_id_file")" == 'ocid1.bastionsession.oc1.eu-frankfurt-1.testnew' ]]

: > "$lifecycle_log"
TERRAFORM_BIN="$mock_terraform" \
WORKSPACE_SELECTOR_BIN="$workspace_selector" \
LIFECYCLE_SCRIPT_BIN="$lifecycle_script" \
"$project_dir/scripts/start-and-connect.sh" \
  --tfvars "$tfvars_file" \
  --profile TESTPROFILE \
  --wait-seconds 30 \
  --poll-seconds 2 \
  --report-dir "$test_dir/reports"

grep -Fqx -- '--start' "$lifecycle_log"
grep -Fqx -- '--connect' "$lifecycle_log"
grep -Fqx -- '--ssh-private-key' "$lifecycle_log"
grep -Fqx "$private_key" "$lifecycle_log"
grep -Fqx -- '--ssh-public-key' "$lifecycle_log"
grep -Fqx "$public_key" "$lifecycle_log"
grep -Fqx 'TESTPROFILE' "$lifecycle_log"
if grep -Fqx -- '--dry-run' "$lifecycle_log"; then
  echo 'start-and-connect unexpectedly forwarded --dry-run.' >&2
  exit 1
fi

: > "$lifecycle_log"
TERRAFORM_BIN="$mock_terraform" \
WORKSPACE_SELECTOR_BIN="$workspace_selector" \
LIFECYCLE_SCRIPT_BIN="$lifecycle_script" \
"$project_dir/scripts/start-and-connect.sh" \
  --tfvars "$tfvars_file" \
  --ssh-private-key "$private_key" \
  --dry-run

grep -Fqx -- '--dry-run' "$lifecycle_log"
if grep -Fqx -- '--connect' "$lifecycle_log"; then
  echo 'Dry-run mode must not open SSH.' >&2
  exit 1
fi

# Prove the controller-only connection cache is used when the private key next
# to the Terraform public key is unavailable.
cached_private_key="$test_dir/cached_bastion_key"
cached_public_key="${cached_private_key}.pub"
printf '%s\n' 'TEST-ONLY-CACHED-PRIVATE-KEY' > "$cached_private_key"
printf '%s\n' 'ssh-ed25519 AAAATESTONLYCACHED bastion-cache-test' > "$cached_public_key"
chmod 600 "$cached_private_key"
connection_file="$test_dir/ssh-connection.env"
printf 'SSH_PRIVATE_KEY=%q\n' "$cached_private_key" > "$connection_file"
rm -f -- "$private_key"

: > "$lifecycle_log"
TERRAFORM_BIN="$mock_terraform" \
WORKSPACE_SELECTOR_BIN="$workspace_selector" \
LIFECYCLE_SCRIPT_BIN="$lifecycle_script" \
"$project_dir/scripts/start-and-connect.sh" \
  --tfvars "$tfvars_file" \
  --connection-file "$connection_file" \
  --inventory-file "$test_dir/not-present.yml" \
  --dry-run
grep -Fqx "$cached_private_key" "$lifecycle_log"
grep -Fqx "$cached_public_key" "$lifecycle_log"

# Prove the generated inventory is the final private-key fallback.
inventory_private_key="$test_dir/inventory_bastion_key"
inventory_public_key="${inventory_private_key}.pub"
printf '%s\n' 'TEST-ONLY-INVENTORY-PRIVATE-KEY' > "$inventory_private_key"
printf '%s\n' 'ssh-ed25519 AAAATESTONLYINVENTORY bastion-inventory-test' > "$inventory_public_key"
chmod 600 "$inventory_private_key"
inventory_file="$test_dir/hosts.yml"
printf '    ansible_ssh_private_key_file: "%s"\n' "$inventory_private_key" > "$inventory_file"

: > "$lifecycle_log"
TERRAFORM_BIN="$mock_terraform" \
WORKSPACE_SELECTOR_BIN="$workspace_selector" \
LIFECYCLE_SCRIPT_BIN="$lifecycle_script" \
"$project_dir/scripts/start-and-connect.sh" \
  --tfvars "$tfvars_file" \
  --connection-file "$test_dir/not-present.env" \
  --inventory-file "$inventory_file" \
  --dry-run
grep -Fqx "$inventory_private_key" "$lifecycle_log"
grep -Fqx "$inventory_public_key" "$lifecycle_log"

# An explicit pair overrides the Terraform key artifacts together.
explicit_private_key="$test_dir/explicit_bastion_key"
explicit_public_key="$test_dir/explicit_bastion_key.custom.pub"
printf '%s\n' 'TEST-ONLY-EXPLICIT-PRIVATE-KEY' > "$explicit_private_key"
printf '%s\n' 'ssh-ed25519 AAAATESTONLYEXPLICIT bastion-explicit-test' > "$explicit_public_key"
chmod 600 "$explicit_private_key"

: > "$lifecycle_log"
TERRAFORM_BIN="$mock_terraform" \
WORKSPACE_SELECTOR_BIN="$workspace_selector" \
LIFECYCLE_SCRIPT_BIN="$lifecycle_script" \
"$project_dir/scripts/start-and-connect.sh" \
  --tfvars "$tfvars_file" \
  --ssh-private-key "$explicit_private_key" \
  --ssh-public-key "$explicit_public_key" \
  --dry-run
grep -Fqx "$explicit_private_key" "$lifecycle_log"
grep -Fqx "$explicit_public_key" "$lifecycle_log"

"$project_dir/scripts/renew-bastion-session.sh" --help >/dev/null
"$project_dir/scripts/start-and-connect.sh" --help >/dev/null

echo 'PASS: session-only renewal and artifact-driven start/connect wrapper'
