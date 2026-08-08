#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="$root_dir/terraform"

command -v terraform >/dev/null || { echo "terraform is required" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh is required" >&2; exit 1; }

tf_output() {
  terraform -chdir="$terraform_dir" output -raw "$1"
}

private_ip="$(tf_output private_ip)"
session_id="$(tf_output bastion_session_id)"
session_state="$(tf_output bastion_session_state)"
region="$(tf_output region)"
session_public_key_path="$(tf_output bastion_session_public_key_path)"

[[ "$session_state" == "ACTIVE" ]] || {
  echo "Bastion session is $session_state, not ACTIVE." >&2
  echo "Renew it when resources are running, or use start-and-connect.sh when they may be stopped." >&2
  exit 2
}

ssh_private_key="${1:-${SSH_PRIVATE_KEY_PATH:-${session_public_key_path%.pub}}}"
local_port="${VNC_LOCAL_PORT:-5901}"
remote_port="${VNC_REMOTE_PORT:-5901}"

[[ -r "$ssh_private_key" ]] || {
  echo "SSH private key is not readable: $ssh_private_key" >&2
  exit 1
}

proxy_command="ssh -i $ssh_private_key -o StrictHostKeyChecking=accept-new -W %h:%p -p 22 $session_id@host.bastion.$region.oci.oraclecloud.com"

echo "Opening localhost:$local_port -> oracle@$private_ip:127.0.0.1:$remote_port"
echo "Keep this command running, then connect a VNC viewer to localhost:$local_port."

exec ssh \
  -i "$ssh_private_key" \
  -N \
  -L "$local_port:127.0.0.1:$remote_port" \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new \
  -o "ProxyCommand=$proxy_command" \
  "oracle@$private_ip"
