#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

OUTPUT_FILE="${SCRIPT_DIR}/output_assets.txt"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"
OCI_PROFILE="STREAMLIT_API_KEY"
OCI_CONFIG_FILE="${HOME}/.oci/config"
SSH_PRIVATE_KEY=""
SSH_PUBLIC_KEY=""
CONNECTOR_SCRIPT=""
TERRAFORM_BIN="terraform"
OCI_BIN="oci"
SSH_BIN="ssh"
SESSION_TTL=3600
LOCAL_PORT=8501
REMOTE_PORT=8501
WAIT_SECONDS=1200
POLL_SECONDS=10
TARGET_USER="oracle"
KEEP_SESSION="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/generate-output-assets.sh \
    --ssh-private-key /path/to/bastion_private_key \
    --connector-script /path/to/connect-streamlit-api-key-auth.ps1 [options]

Required:
  --ssh-private-key PATH     SSH private key path stored in the inventory
  --connector-script PATH    connect-streamlit-api-key-auth.ps1 path

Options:
  --ssh-public-key PATH      Matching public key path
  --output PATH              Output file (default: scripts/output_assets.txt)
  --terraform-dir DIR        Terraform root/state directory
  --profile NAME             OCI profile (default: STREAMLIT_API_KEY)
  --oci-config PATH          OCI config (default: $HOME/.oci/config)
  --terraform-bin COMMAND    Terraform executable (default: terraform)
  --oci-bin COMMAND          OCI executable recorded in the inventory
  --ssh-bin COMMAND          SSH executable recorded in the inventory
  --session-ttl SECONDS      Bastion session TTL, 30-10800
  --local-port PORT          Local Streamlit port
  --remote-port PORT         Remote Streamlit port
  --wait-seconds SECONDS     Session wait timeout, 60-3600
  --poll-seconds SECONDS     Poll interval, 1-60
  --target-user USER         SSH target user (default: oracle)
  --keep-session             Keep the Bastion session after SSH exits
  -h, --help                 Show this help

This command only writes the asset inventory. It does not create a Bastion
session and does not run SSH.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_value() {
  [[ $# -ge 2 && -n ${2:-} ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) need_value "$@"; OUTPUT_FILE=$2; shift 2 ;;
    --terraform-dir) need_value "$@"; TERRAFORM_DIR=$2; shift 2 ;;
    --profile) need_value "$@"; OCI_PROFILE=$2; shift 2 ;;
    --oci-config) need_value "$@"; OCI_CONFIG_FILE=$2; shift 2 ;;
    --ssh-private-key) need_value "$@"; SSH_PRIVATE_KEY=$2; shift 2 ;;
    --ssh-public-key) need_value "$@"; SSH_PUBLIC_KEY=$2; shift 2 ;;
    --connector-script) need_value "$@"; CONNECTOR_SCRIPT=$2; shift 2 ;;
    --terraform-bin) need_value "$@"; TERRAFORM_BIN=$2; shift 2 ;;
    --oci-bin) need_value "$@"; OCI_BIN=$2; shift 2 ;;
    --ssh-bin) need_value "$@"; SSH_BIN=$2; shift 2 ;;
    --session-ttl) need_value "$@"; SESSION_TTL=$2; shift 2 ;;
    --local-port) need_value "$@"; LOCAL_PORT=$2; shift 2 ;;
    --remote-port) need_value "$@"; REMOTE_PORT=$2; shift 2 ;;
    --wait-seconds) need_value "$@"; WAIT_SECONDS=$2; shift 2 ;;
    --poll-seconds) need_value "$@"; POLL_SECONDS=$2; shift 2 ;;
    --target-user) need_value "$@"; TARGET_USER=$2; shift 2 ;;
    --keep-session) KEEP_SESSION="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n ${SSH_PRIVATE_KEY} ]] || die "--ssh-private-key is required"
[[ -n ${CONNECTOR_SCRIPT} ]] || die "--connector-script is required"
[[ ${OCI_PROFILE} =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid OCI profile name: ${OCI_PROFILE}"
[[ ${TARGET_USER} =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid target user: ${TARGET_USER}"

require_integer() {
  local name=$1 value=$2 minimum=$3 maximum=$4
  [[ ${value} =~ ^[0-9]+$ ]] || die "${name} must be an integer"
  (( value >= minimum && value <= maximum )) || die "${name} must be from ${minimum} through ${maximum}"
}

require_integer "session TTL" "${SESSION_TTL}" 30 10800
require_integer "local port" "${LOCAL_PORT}" 1 65535
require_integer "remote port" "${REMOTE_PORT}" 1 65535
require_integer "wait seconds" "${WAIT_SECONDS}" 60 3600
require_integer "poll seconds" "${POLL_SECONDS}" 1 60

expand_path() {
  local value=$1 base=${2:-}
  case "${value}" in
    '~') value=${HOME} ;;
    '~/'*) value="${HOME}/${value#\~/}" ;;
    '\$HOME') value=${HOME} ;;
    '\$HOME/'*) value="${HOME}/${value#\$HOME/}" ;;
    '\${HOME}') value=${HOME} ;;
    '\${HOME}/'*) value="${HOME}/${value#\$\{HOME\}/}" ;;
    /*) ;;
    *) [[ -n ${base} ]] && value="${base}/${value}" ;;
  esac
  printf '%s\n' "${value}"
}

resolve_file() {
  local value=$1 label=$2 base=${3:-} expanded directory filename
  expanded=$(expand_path "${value}" "${base}")
  [[ -f ${expanded} ]] || die "${label} does not exist or is not a file: ${expanded}"
  directory=$(cd -- "$(dirname -- "${expanded}")" && pwd -P)
  filename=$(basename -- "${expanded}")
  printf '%s/%s\n' "${directory}" "${filename}"
}

[[ -d ${TERRAFORM_DIR} ]] || die "Terraform directory does not exist: ${TERRAFORM_DIR}"
TERRAFORM_DIR=$(cd -- "${TERRAFORM_DIR}" && pwd -P)
if [[ ${TERRAFORM_BIN} == */* ]]; then
  [[ -x ${TERRAFORM_BIN} ]] || die "Terraform executable is not executable: ${TERRAFORM_BIN}"
else
  command -v "${TERRAFORM_BIN}" >/dev/null 2>&1 || die "Terraform executable not found: ${TERRAFORM_BIN}"
fi

OCI_CONFIG_FILE=$(resolve_file "${OCI_CONFIG_FILE}" "OCI config file")
OCI_CONFIG_DIR=$(dirname -- "${OCI_CONFIG_FILE}")
SSH_PRIVATE_KEY=$(resolve_file "${SSH_PRIVATE_KEY}" "SSH private key")
if [[ -n ${SSH_PUBLIC_KEY} ]]; then
  SSH_PUBLIC_KEY=$(resolve_file "${SSH_PUBLIC_KEY}" "SSH public key")
fi
CONNECTOR_SCRIPT=$(resolve_file "${CONNECTOR_SCRIPT}" "Streamlit API-key connector script")

oci_profile_value() {
  local wanted_key=$1
  awk -v wanted_profile="${OCI_PROFILE}" -v wanted_key="${wanted_key}" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section=$0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      section=trim(section)
      sub(/^PROFILE[[:space:]]+/, "", section)
      selected=(section == wanted_profile)
      next
    }
    selected && $0 !~ /^[[:space:]]*[#;]/ {
      separator=index($0, "=")
      if (separator > 1) {
        key=trim(substr($0, 1, separator - 1))
        if (key == wanted_key) {
          value=trim(substr($0, separator + 1))
          gsub(/\r$/, "", value)
          print value
          exit
        }
      }
    }
  ' "${OCI_CONFIG_FILE}"
}

OCI_USER_ID=$(oci_profile_value user)
OCI_TENANCY_ID=$(oci_profile_value tenancy)
API_KEY_FINGERPRINT=$(oci_profile_value fingerprint)
API_PRIVATE_KEY_VALUE=$(oci_profile_value key_file)
[[ -n ${OCI_USER_ID} ]] || die "profile [${OCI_PROFILE}] has no user in ${OCI_CONFIG_FILE}"
[[ -n ${OCI_TENANCY_ID} ]] || die "profile [${OCI_PROFILE}] has no tenancy in ${OCI_CONFIG_FILE}"
[[ -n ${API_KEY_FINGERPRINT} ]] || die "profile [${OCI_PROFILE}] has no fingerprint in ${OCI_CONFIG_FILE}"
[[ -n ${API_PRIVATE_KEY_VALUE} ]] || die "profile [${OCI_PROFILE}] has no key_file in ${OCI_CONFIG_FILE}"
API_PRIVATE_KEY=$(resolve_file "${API_PRIVATE_KEY_VALUE}" "OCI API private key" "${OCI_CONFIG_DIR}")

tf_output() {
  local name=$1 value
  value=$("${TERRAFORM_BIN}" "-chdir=${TERRAFORM_DIR}" output -raw "${name}") || die "terraform output failed for ${name}"
  [[ -n ${value} ]] || die "Terraform output ${name} is empty"
  printf '%s\n' "${value}"
}

BASTION_ID=$(tf_output bastion_id)
INSTANCE_ID=$(tf_output instance_id)
PRIVATE_IP=$(tf_output private_ip)
REGION=$(tf_output region)

[[ ${BASTION_ID} == ocid1.bastion.* ]] || die "invalid bastion_id Terraform output"
[[ ${INSTANCE_ID} == ocid1.instance.* ]] || die "invalid instance_id Terraform output"
[[ ${OCI_USER_ID} == ocid1.user.* ]] || die "invalid user OCID in profile [${OCI_PROFILE}]"
[[ ${OCI_TENANCY_ID} == ocid1.tenancy.* ]] || die "invalid tenancy OCID in profile [${OCI_PROFILE}]"
[[ ${API_KEY_FINGERPRINT} =~ ^([0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}$ ]] || die "invalid fingerprint in profile [${OCI_PROFILE}]"
[[ ${REGION} =~ ^[a-z]{2}-[a-z0-9-]+-[0-9]+$ ]] || die "invalid region Terraform output: ${REGION}"

valid_ipv4() {
  local ip=$1 octet
  local -a octets
  IFS=. read -r -a octets <<< "${ip}"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ ${octet} =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done
}
valid_ipv4 "${PRIVATE_IP}" || die "invalid private_ip Terraform output: ${PRIVATE_IP}"

OUTPUT_DIRECTORY=$(dirname -- "${OUTPUT_FILE}")
mkdir -p -- "${OUTPUT_DIRECTORY}"
OUTPUT_DIRECTORY=$(cd -- "${OUTPUT_DIRECTORY}" && pwd -P)
OUTPUT_FILE="${OUTPUT_DIRECTORY}/$(basename -- "${OUTPUT_FILE}")"
[[ ! -L ${OUTPUT_FILE} ]] || die "refusing to replace symbolic link: ${OUTPUT_FILE}"

umask 077
TEMP_FILE=$(mktemp "${OUTPUT_DIRECTORY}/.output_assets.XXXXXX")
cleanup() { rm -f -- "${TEMP_FILE:-}"; }
trap cleanup EXIT

{
  printf '%s\n' '# Local Streamlit/OCI asset inventory. Do not commit this file.'
  printf '%s\n' '# Generated by generate-output-assets.sh.'
  printf 'AssetsVersion=1\n'
  printf 'BastionId=%s\n' "${BASTION_ID}"
  printf 'InstanceId=%s\n' "${INSTANCE_ID}"
  printf 'PrivateIp=%s\n' "${PRIVATE_IP}"
  printf 'Region=%s\n' "${REGION}"
  printf 'SshPrivateKeyPath=%s\n' "${SSH_PRIVATE_KEY}"
  printf 'SshPublicKeyPath=%s\n' "${SSH_PUBLIC_KEY}"
  printf 'OciUserId=%s\n' "${OCI_USER_ID}"
  printf 'OciTenancyId=%s\n' "${OCI_TENANCY_ID}"
  printf 'ApiKeyFingerprint=%s\n' "${API_KEY_FINGERPRINT,,}"
  printf 'ApiPrivateKeyPath=%s\n' "${API_PRIVATE_KEY}"
  printf 'ProfileName=%s\n' "${OCI_PROFILE}"
  printf 'OciConfigFilePath=%s\n' "${OCI_CONFIG_FILE}"
  printf 'ConnectorScriptPath=%s\n' "${CONNECTOR_SCRIPT}"
  printf 'BastionSessionTtl=%s\n' "${SESSION_TTL}"
  printf 'LocalPort=%s\n' "${LOCAL_PORT}"
  printf 'RemotePort=%s\n' "${REMOTE_PORT}"
  printf 'WaitSeconds=%s\n' "${WAIT_SECONDS}"
  printf 'PollSeconds=%s\n' "${POLL_SECONDS}"
  printf 'TargetUser=%s\n' "${TARGET_USER}"
  printf 'OciExecutable=%s\n' "${OCI_BIN}"
  printf 'SshExecutable=%s\n' "${SSH_BIN}"
  printf 'KeepSession=%s\n' "${KEEP_SESSION}"
} > "${TEMP_FILE}"

chmod 0600 "${TEMP_FILE}"
mv -f -- "${TEMP_FILE}" "${OUTPUT_FILE}"
trap - EXIT
printf 'Wrote local asset inventory: %s\n' "${OUTPUT_FILE}"
