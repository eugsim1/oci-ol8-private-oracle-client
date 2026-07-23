#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"
ansible_dir="$root_dir/ansible"

command -v terraform >/dev/null || { echo "terraform is required" >&2; exit 1; }
command -v ansible-playbook >/dev/null || { echo "ansible-playbook is required" >&2; exit 1; }
command -v ansible-galaxy >/dev/null || { echo "ansible-galaxy is required" >&2; exit 1; }

tf_output() {
  terraform -chdir="$terraform_dir" output -raw "$1"
}

tf_output_optional() {
  terraform -chdir="$terraform_dir" output -raw "$1" 2>/dev/null || true
}

private_ip="$(tf_output private_ip)"
session_enabled="$(tf_output bastion_session_enabled)"
session_id="$(tf_output bastion_session_id)"
session_state="$(tf_output bastion_session_state)"
region="$(tf_output region)"
terraform_instance_principal_enabled="$(tf_output_optional iam_instance_principal_enabled)"
terraform_instance_principal_enabled="${terraform_instance_principal_enabled:-false}"
session_public_key_path="$(tf_output_optional bastion_session_public_key_path)"
if [[ -n "${ADB_DATABASE_ID:-}" ]]; then
  autonomous_database_id="$ADB_DATABASE_ID"
  autonomous_database_id_source="ADB_DATABASE_ID override"
else
  autonomous_database_id="$(tf_output autonomous_database_id)"
  autonomous_database_id_source="Terraform output"
fi

[[ "$autonomous_database_id" == ocid1.autonomousdatabase.* ]] || {
  echo "ADB_DATABASE_ID is not a valid Autonomous Database OCID: $autonomous_database_id" >&2
  exit 1
}

[[ "$session_enabled" == "true" ]] || {
  echo "create_bastion_session must be true to use the generated Bastion inventory." >&2
  exit 2
}
[[ "$session_state" == "ACTIVE" ]] || {
  echo "Bastion session is $session_state, not ACTIVE. Create or refresh the session before running Ansible." >&2
  exit 2
}

# An explicit argument or environment variable wins. Otherwise use the private
# key adjacent to the Terraform public-key path (for example id_ed25519.pub -> id_ed25519).
ssh_private_key="${1:-${SSH_PRIVATE_KEY_PATH:-}}"
if [[ -z "$ssh_private_key" && -n "$session_public_key_path" ]]; then
  ssh_private_key="${session_public_key_path%.pub}"
fi
[[ -n "$ssh_private_key" ]] || {
  echo "Cannot infer the SSH private key because Terraform output bastion_session_public_key_path is unavailable." >&2
  echo "Pass the private key as argument 1 or set SSH_PRIVATE_KEY_PATH." >&2
  exit 1
}
oci_config_source="${OCI_CONFIG_SOURCE:-$HOME/.oci/config}"
if [[ -n "${OCI_AUTH_MODE:-}" ]]; then
  oci_auth_mode="$OCI_AUTH_MODE"
elif [[ "$terraform_instance_principal_enabled" == "true" ]]; then
  oci_auth_mode="instance_principal"
else
  oci_auth_mode="api_key"
fi
application_repository_url="${APPLICATION_REPOSITORY_URL:-https://github.com/eugsim1/focus-loader-report-upload.git}"
application_repository_version="${APPLICATION_REPOSITORY_VERSION:-HEAD}"
application_repository_destination="${APPLICATION_REPOSITORY_DESTINATION:-/home/oracle/focus-loader-report-upload}"
adb_wallet_enabled="${ADB_WALLET_ENABLED:-true}"
adb_wallet_archive_path="${ADB_WALLET_ARCHIVE_PATH:-/home/oracle/Wallet_AutonomousDatabase.zip}"
adb_wallet_directory="${ADB_WALLET_DIRECTORY:-/home/oracle/adb_wallet}"
adb_test_enabled="${ADB_TEST_ENABLED:-true}"
adb_tns_alias="${ADB_TNS_ALIAS:-}"
oracle_gui_enabled="${ORACLE_GUI_ENABLED:-true}"
oracle_gui_vnc_display="${ORACLE_GUI_VNC_DISPLAY:-1}"
oracle_gui_vnc_geometry="${ORACLE_GUI_VNC_GEOMETRY:-1280x800}"
focus_loader_enabled="${FOCUS_LOADER_ENABLED:-false}"

case "$terraform_instance_principal_enabled" in
  true|false) ;;
  *) echo "Terraform output iam_instance_principal_enabled must be true or false." >&2; exit 1 ;;
esac
case "$oci_auth_mode" in
  api_key|instance_principal) ;;
  *) echo "OCI_AUTH_MODE must be api_key or instance_principal." >&2; exit 1 ;;
esac
case "$adb_wallet_enabled" in
  true|false) ;;
  *) echo "ADB_WALLET_ENABLED must be true or false." >&2; exit 1 ;;
esac
case "$adb_test_enabled" in
  true|false) ;;
  *) echo "ADB_TEST_ENABLED must be true or false." >&2; exit 1 ;;
esac
case "$oracle_gui_enabled" in
  true|false) ;;
  *) echo "ORACLE_GUI_ENABLED must be true or false." >&2; exit 1 ;;
esac
case "$focus_loader_enabled" in
  true|false) ;;
  *) echo "FOCUS_LOADER_ENABLED must be true or false." >&2; exit 1 ;;
esac

if [[ "$oracle_gui_enabled" == "true" ]]; then
  oracle_vnc_password="${ORACLE_VNC_PASSWORD:-}"
  if [[ ${#oracle_vnc_password} -lt 6 ]]; then
    echo "WARNING: ORACLE_VNC_PASSWORD is missing or shorter than 6 characters." >&2
    echo "Graphical provisioning will be marked failed, but core Ansible provisioning will continue." >&2
  fi
  export ORACLE_VNC_PASSWORD="$oracle_vnc_password"
fi

if [[ "$adb_wallet_enabled" == "true" ]]; then
  adb_wallet_password="${ADB_WALLET_PASSWORD:-${TF_VAR_adb_admin_password:-}}"
  [[ -n "$adb_wallet_password" ]] || {
    echo "Set ADB_WALLET_PASSWORD (or TF_VAR_adb_admin_password) to download the Autonomous Database wallet." >&2
    exit 1
  }
  export ADB_WALLET_PASSWORD="$adb_wallet_password"
fi

if [[ "$adb_test_enabled" == "true" ]]; then
  [[ "$adb_wallet_enabled" == "true" ]] || {
    echo "ADB_TEST_ENABLED=true requires ADB_WALLET_ENABLED=true." >&2
    exit 1
  }
  adb_admin_password="${ADB_ADMIN_PASSWORD:-${TF_VAR_adb_admin_password:-}}"
  [[ -n "$adb_admin_password" ]] || {
    echo "Set ADB_ADMIN_PASSWORD or TF_VAR_adb_admin_password for the ADMIN connection test." >&2
    exit 1
  }
  export ADB_ADMIN_PASSWORD="$adb_admin_password"
fi

if [[ "$focus_loader_enabled" == "true" ]]; then
  [[ "$adb_wallet_enabled" == "true" ]] || {
    echo "FOCUS_LOADER_ENABLED=true requires ADB_WALLET_ENABLED=true." >&2
    exit 1
  }

  focus_loader_admin_password="${FOCUS_LOADER_DB_ADMIN_PASSWORD:-${ADB_ADMIN_PASSWORD:-${TF_VAR_adb_admin_password:-}}}"
  focus_loader_schema_password="${FOCUS_LOADER_TARGET_SCHEMA_PASSWORD:-$focus_loader_admin_password}"
  focus_loader_db_password="${FOCUS_LOADER_DB_PASSWORD:-$focus_loader_schema_password}"
  focus_loader_db_secret_id="${FOCUS_LOADER_DB_SECRET_ID:-}"
  focus_loader_target_schema="${FOCUS_LOADER_TARGET_SCHEMA:-FOCUS_GIT1}"
  focus_loader_minimum_date="${FOCUS_LOADER_MINIMUM_DATE:-2026-01-01}"
  focus_loader_workers="${FOCUS_LOADER_WORKERS:-5}"
  focus_loader_drop_existing="${FOCUS_LOADER_DROP_EXISTING:-false}"

  [[ -n "$focus_loader_admin_password" ]] || {
    echo "Set FOCUS_LOADER_DB_ADMIN_PASSWORD, ADB_ADMIN_PASSWORD, or TF_VAR_adb_admin_password." >&2
    exit 1
  }
  [[ -n "$focus_loader_schema_password" ]] || {
    echo "Set FOCUS_LOADER_TARGET_SCHEMA_PASSWORD." >&2
    exit 1
  }
  [[ -n "$focus_loader_db_password" || -n "$focus_loader_db_secret_id" ]] || {
    echo "Set FOCUS_LOADER_DB_PASSWORD or FOCUS_LOADER_DB_SECRET_ID." >&2
    exit 1
  }
  [[ "$focus_loader_target_schema" =~ ^[A-Za-z][A-Za-z0-9_\$#]*$ ]] || {
    echo "FOCUS_LOADER_TARGET_SCHEMA must be an unquoted Oracle identifier." >&2
    exit 1
  }
  [[ "$focus_loader_minimum_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    echo "FOCUS_LOADER_MINIMUM_DATE must use YYYY-MM-DD." >&2
    exit 1
  }
  [[ "$focus_loader_workers" =~ ^[1-9][0-9]*$ ]] || {
    echo "FOCUS_LOADER_WORKERS must be a positive integer." >&2
    exit 1
  }
  case "$focus_loader_drop_existing" in
    true|false) ;;
    *) echo "FOCUS_LOADER_DROP_EXISTING must be true or false." >&2; exit 1 ;;
  esac

  export FOCUS_LOADER_DB_ADMIN_PASSWORD="$focus_loader_admin_password"
  export FOCUS_LOADER_TARGET_SCHEMA_PASSWORD="$focus_loader_schema_password"
  export FOCUS_LOADER_DB_PASSWORD="$focus_loader_db_password"
fi

for generated_value in "$oci_auth_mode" "$region" "$application_repository_url" "$application_repository_version" "$application_repository_destination" "$adb_wallet_archive_path" "$adb_wallet_directory" "$adb_tns_alias" "$oracle_gui_vnc_display" "$oracle_gui_vnc_geometry"; do
  [[ "$generated_value" != *$'\n'* && "$generated_value" != *'"'* ]] || {
    echo "Generated Ansible override values must not contain newlines or double quotes." >&2
    exit 1
  }
done

[[ -r "$ssh_private_key" ]] || {
  echo "SSH private key is not readable: $ssh_private_key" >&2
  echo "Pass it as argument 1 or set SSH_PRIVATE_KEY_PATH." >&2
  exit 1
}
oci_private_key_source=""
oci_private_key_filename=""
if [[ "$oci_auth_mode" == "api_key" ]]; then
  [[ -r "$oci_config_source" ]] || {
    echo "OCI configuration is not readable: $oci_config_source" >&2
    echo "Set OCI_CONFIG_SOURCE if it is not under \$HOME/.oci/config." >&2
    exit 1
  }

  oci_private_key_source="${OCI_PRIVATE_KEY_SOURCE:-}"
  if [[ -z "$oci_private_key_source" ]]; then
    oci_private_key_source="$(
      awk '
        /^[[:space:]]*key_file[[:space:]]*=/ {
          value=$0
          sub(/^[^=]*=[[:space:]]*/, "", value)
          sub(/[[:space:]]+$/, "", value)
          print value
          exit
        }
      ' "$oci_config_source"
    )"
  fi

  oci_private_key_source="${oci_private_key_source%\"}"
  oci_private_key_source="${oci_private_key_source#\"}"
  if [[ "$oci_private_key_source" == "~/"* ]]; then
    oci_private_key_source="$HOME/${oci_private_key_source#\~/}"
  elif [[ "$oci_private_key_source" != /* ]]; then
    oci_private_key_source="$(dirname "$oci_config_source")/$oci_private_key_source"
  fi

  [[ -r "$oci_private_key_source" ]] || {
    echo "OCI API private key is not readable: $oci_private_key_source" >&2
    echo "Correct key_file in $oci_config_source or set OCI_PRIVATE_KEY_SOURCE." >&2
    exit 1
  }
  oci_private_key_filename="$(basename "$oci_private_key_source")"
fi

chmod 600 "$ssh_private_key"
mkdir -p "$ansible_dir/inventory" "$ansible_dir/group_vars" "$root_dir/reports"
printf '%s\n' 'status=unknown' 'failed_task=' 'message=Ansible GUI status not yet reported' > "$root_dir/reports/gui-provisioning-status.txt"

cat > "$ansible_dir/inventory/hosts.yml" <<EOF
---
all:
  children:
    oracle_linux:
      hosts:
        private_oracle_server:
          ansible_host: "$private_ip"
          ansible_user: oracle
          ansible_ssh_private_key_file: "$ssh_private_key"
          ansible_ssh_common_args: >-
            -o StrictHostKeyChecking=accept-new
            -o ProxyCommand="ssh -i $ssh_private_key -o StrictHostKeyChecking=accept-new -W %h:%p -p 22 $session_id@host.bastion.$region.oci.oraclecloud.com"
EOF

cat > "$ansible_dir/group_vars/all.yml" <<EOF
---
# Generated by scripts/run-ansible.sh. Source files remain on this controller.
oracle_oci_auth_mode: "$oci_auth_mode"
oracle_oci_region: "$region"
oci_config_source: "$oci_config_source"
oci_private_key_source: "$oci_private_key_source"
oci_private_key_filename: "$oci_private_key_filename"
oracle_application_repository_url: "$application_repository_url"
oracle_application_repository_version: "$application_repository_version"
oracle_application_repository_destination: "$application_repository_destination"
oracle_adb_wallet_enabled: $adb_wallet_enabled
oracle_adb_wallet_database_id: "$autonomous_database_id"
oracle_adb_wallet_archive_path: "$adb_wallet_archive_path"
oracle_adb_wallet_directory: "$adb_wallet_directory"
oracle_adb_test_enabled: $adb_test_enabled
oracle_adb_test_tns_alias: "$adb_tns_alias"
oracle_gui_enabled: $oracle_gui_enabled
oracle_gui_vnc_display: $oracle_gui_vnc_display
oracle_gui_vnc_geometry: "$oracle_gui_vnc_geometry"
controller_report_directory: "$root_dir/reports"
EOF

# Generate controller login metadata before making the first SSH connection, so
# the interactive helper remains available even when an Ansible task later fails.
connection_file="$root_dir/reports/ssh-connection.env"
{
  printf 'TARGET_PRIVATE_IP=%q\n' "$private_ip"
  printf 'BASTION_SESSION_ID=%q\n' "$session_id"
  printf 'BASTION_SESSION_STATE=%q\n' "$session_state"
  printf 'OCI_REGION=%q\n' "$region"
  printf 'SSH_PRIVATE_KEY=%q\n' "$ssh_private_key"
} > "$connection_file"
chmod 600 "$connection_file"
chmod +x "$root_dir/scripts/connect-oracle-server.sh"

case "${ANSIBLE_VERBOSITY:-2}" in
  0) verbosity_args=() ;;
  1) verbosity_args=(-v) ;;
  2) verbosity_args=(-vv) ;;
  3) verbosity_args=(-vvv) ;;
  4) verbosity_args=(-vvvv) ;;
  *) echo "ANSIBLE_VERBOSITY must be 0, 1, 2, 3, or 4." >&2; exit 1 ;;
esac

echo "Generated: $ansible_dir/inventory/hosts.yml"
echo "Generated: $ansible_dir/group_vars/all.yml"
echo "Target: oracle@$private_ip through Bastion session $session_id"
echo "SSH private key: $ssh_private_key"
echo "OCI authentication mode: $oci_auth_mode"
if [[ "$oci_auth_mode" == "api_key" ]]; then
  echo "OCI config source: $oci_config_source"
  echo "OCI private key source: $oci_private_key_source"
else
  echo "OCI API config/private key: not copied (instance principal)"
fi
echo "Application repository: $application_repository_url ($application_repository_version)"
echo "Application destination: $application_repository_destination"
if [[ "$adb_wallet_enabled" == "true" ]]; then
  echo "Autonomous Database wallet: $adb_wallet_directory"
  echo "Autonomous Database OCID: $autonomous_database_id ($autonomous_database_id_source)"
else
  echo "Autonomous Database wallet: disabled"
fi
if [[ "$adb_test_enabled" == "true" ]]; then
  echo "Autonomous Database connection test: enabled (high service auto-discovery)"
else
  echo "Autonomous Database connection test: disabled"
fi
if [[ "$oracle_gui_enabled" == "true" ]]; then
  echo "Graphical desktop: oracle VNC display :$oracle_gui_vnc_display, localhost only"
else
  echo "Graphical desktop: disabled"
fi
if [[ "$focus_loader_enabled" == "true" ]]; then
  echo "Final FOCUS loader stage: enabled"
  echo "FOCUS target schema: ${FOCUS_LOADER_TARGET_SCHEMA:-FOCUS_GIT1}"
  echo "FOCUS TNS alias: ${FOCUS_LOADER_DB_TNS_ALIAS:-auto-discover first *_high wallet alias}"
  echo "FOCUS namespace/date/workers: ${FOCUS_LOADER_NAMESPACE:-bling} / ${FOCUS_LOADER_MINIMUM_DATE:-2026-01-01} / ${FOCUS_LOADER_WORKERS:-5}"
  echo "FOCUS drop existing schema: ${FOCUS_LOADER_DROP_EXISTING:-false}"
else
  echo "Final FOCUS loader stage: disabled (set FOCUS_LOADER_ENABLED=true to run it)"
fi

cd "$ansible_dir"
ansible-galaxy collection install -r requirements.yml
ansible-inventory -i inventory/hosts.yml --graph
ansible -i inventory/hosts.yml oracle_linux -m ansible.builtin.wait_for_connection -a 'timeout=600' "${verbosity_args[@]}"
ansible-playbook -i inventory/hosts.yml site.yml --syntax-check

timestamp="$(date -u +%Y%m%d-%H%M%S)"
ansible_log="$root_dir/reports/ansible-run-$timestamp.log"
ansible-playbook -i inventory/hosts.yml site.yml "${verbosity_args[@]}" | tee "$ansible_log"
echo "Ansible completed. Log: $ansible_log"
echo "Generated SSH connection settings: $connection_file"
echo "Interactive oracle login: $root_dir/scripts/connect-oracle-server.sh"
