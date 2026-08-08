#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tfvars_file="${1:-terraform.tfvars}"
ssh_private_key="${2:-}"
: "${TF_VAR_adb_admin_password:?Set TF_VAR_adb_admin_password before running the deployment}"

cd "$root_dir/terraform"
test -f "$tfvars_file" || { echo "Missing terraform/$tfvars_file" >&2; exit 1; }
bash "$root_dir/scripts/select-compartment-workspace.sh" "$tfvars_file"
terraform apply -auto-approve -var-file="$tfvars_file"

private_ip="$(terraform output -raw private_ip)"
session_enabled="$(terraform output -raw bastion_session_enabled)"
if [[ "$session_enabled" != "true" ]]; then
  echo "Terraform completed, but Ansible cannot use OCI Bastion because create_bastion_session=false." >&2
  echo "Set create_bastion_session=true, or use an inventory with direct private routing to the compute node." >&2
  exit 2
fi
session_id="$(terraform output -raw bastion_session_id)"
plugin_status="$(terraform output -raw bastion_plugin_status)"
region="$(terraform output -raw region)"
instance_id="$(terraform output -raw instance_id)"
instance_name="$(terraform output -raw instance_name)"
shape="$(terraform output -raw shape)"
memory="$(terraform output -raw memory_in_gbs)"
boot_size="$(terraform output -raw boot_volume_size_in_gbs)"
availability_domain="$(terraform output -raw selected_availability_domain)"
adb_id="$(terraform output -raw autonomous_database_id)"
adb_name="$(terraform output -raw autonomous_database_name)"
adb_state="$(terraform output -raw autonomous_database_state)"
adb_version="$(terraform output -raw autonomous_database_version)"
adb_private_endpoint="$(terraform output -raw autonomous_database_private_endpoint)"
adb_private_ip="$(terraform output -raw autonomous_database_private_ip)"
wallet_adb_id="${ADB_DATABASE_ID:-$adb_id}"
gui_status_file="$root_dir/reports/gui-provisioning-status.txt"

if [[ -n "$ssh_private_key" ]]; then
  "$root_dir/scripts/run-ansible.sh" "$ssh_private_key"
else
  "$root_dir/scripts/run-ansible.sh"
fi

timestamp="$(date -u +%Y%m%d-%H%M%S)"
report="$root_dir/reports/deployment-report-$timestamp.csv"
{
  printf '%s\n' 'phase,item,status,detail'
  printf 'terraform,instance_id,success,"%s"\n' "$instance_id"
  printf 'terraform,instance_name,success,"%s"\n' "$instance_name"
  printf 'terraform,private_ip,success,"%s"\n' "$private_ip"
  printf '%s\n' 'terraform,public_ip,success,"none"'
  printf 'terraform,shape,success,"%s"\n' "$shape"
  printf 'terraform,memory_in_gbs,success,"%s"\n' "$memory"
  printf 'terraform,boot_volume_size_in_gbs,success,"%s"\n' "$boot_size"
  printf 'terraform,availability_domain,success,"%s"\n' "$availability_domain"
  printf 'terraform,bastion_session,success,"%s"\n' "$session_id"
  printf 'terraform,bastion_plugin_status,success,"%s"\n' "$plugin_status"
  printf 'terraform,autonomous_database_id,success,"%s"\n' "$adb_id"
  printf 'terraform,autonomous_database_name,success,"%s"\n' "$adb_name"
  printf 'terraform,autonomous_database_state,success,"%s"\n' "$adb_state"
  printf 'terraform,autonomous_database_version,success,"%s"\n' "$adb_version"
  printf 'terraform,autonomous_database_private_endpoint,success,"%s"\n' "$adb_private_endpoint"
  printf 'terraform,autonomous_database_private_ip,success,"%s"\n' "$adb_private_ip"
  printf '%s\n' 'ansible,oracle_user,success,"connected directly through OCI Bastion"'
  printf 'ansible,controller_login_script,success,"%s"\n' "$root_dir/scripts/connect-oracle-server.sh"
  printf '%s\n' 'ansible,oci_cli,success,"installed and configured under /home/oracle/.oci"'
  if [[ "${ADB_WALLET_ENABLED:-true}" == "true" ]]; then
    printf 'ansible,autonomous_database_wallet_ocid,success,"%s"\n' "$wallet_adb_id"
    printf 'ansible,autonomous_database_wallet,success,"%s"\n' "${ADB_WALLET_DIRECTORY:-/home/oracle/adb_wallet}"
    printf 'ansible,autonomous_database_sqlnet,success,"%s/sqlnet.ora"\n' "${ADB_WALLET_DIRECTORY:-/home/oracle/adb_wallet}"
  else
    printf '%s\n' 'ansible,autonomous_database_wallet,skipped,"disabled by ADB_WALLET_ENABLED"'
  fi
  if [[ "${ADB_TEST_ENABLED:-true}" == "true" ]]; then
    printf '%s\n' 'ansible,autonomous_database_connection_test,success,"ADMIN connection through high TNS service"'
    printf '%s\n' 'ansible,autonomous_database_test_script,success,"/home/oracle/test_adb/test_adb_connection.sh"'
  else
    printf '%s\n' 'ansible,autonomous_database_connection_test,skipped,"disabled by ADB_TEST_ENABLED"'
  fi
  if [[ -r "$gui_status_file" ]]; then
    gui_status="$(awk -F= '$1 == "status" { print $2; exit }' "$gui_status_file")"
    gui_detail="$(awk -F= '$1 == "message" { sub(/^[^=]*=/, ""); print; exit }' "$gui_status_file")"
    gui_detail="${gui_detail//\"/\"\"}"
    printf 'ansible,graphical_desktop,%s,"%s"\n' "$gui_status" "$gui_detail"
  elif [[ "${ORACLE_GUI_ENABLED:-true}" == "true" ]]; then
    printf '%s\n' 'ansible,graphical_desktop,unknown,"status file not produced; inspect Ansible log"'
  else
    printf '%s\n' 'ansible,graphical_desktop,skipped,"disabled by ORACLE_GUI_ENABLED"'
  fi
  printf '%s\n' 'ansible,instant_client,success,"full configured package set installed"'
} > "$report"
echo "Deployment completed: $report"
