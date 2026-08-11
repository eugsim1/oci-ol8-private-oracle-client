#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "${TEST_DIR}"' EXIT

mkdir -p "${TEST_DIR}/terraform" "${TEST_DIR}/.oci" "${TEST_DIR}/.ssh"
printf '%s\n' 'test-only-api-key' > "${TEST_DIR}/.oci/api.pem"
printf '%s\n' 'test-only-ssh-key' > "${TEST_DIR}/.ssh/bastion_key"
printf '%s\n' 'ssh-ed25519 AAAATESTONLY' > "${TEST_DIR}/.ssh/bastion_key.pub"
printf '%s\n' '# test connector' > "${TEST_DIR}/connect-streamlit-api-key-auth.ps1"

cat > "${TEST_DIR}/.oci/config" <<EOF
[STREAMLIT_API_KEY]
user=ocid1.user.oc1..testuser
fingerprint=AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99
key_file=api.pem
tenancy=ocid1.tenancy.oc1..testtenancy
region=eu-frankfurt-1
EOF

cat > "${TEST_DIR}/terraform-mock" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
name=${4:?missing output name}
case "${name}" in
  bastion_id) printf '%s\n' 'ocid1.bastion.oc1.eu-frankfurt-1.testbastion' ;;
  instance_id) printf '%s\n' 'ocid1.instance.oc1.eu-frankfurt-1.testinstance' ;;
  private_ip) printf '%s\n' '10.30.1.159' ;;
  region) printf '%s\n' 'eu-frankfurt-1' ;;
  *) exit 2 ;;
esac
EOF
chmod 0700 "${TEST_DIR}/terraform-mock"

OUTPUT_FILE="${TEST_DIR}/output_assets.txt"
bash "${PROJECT_DIR}/scripts/generate-output-assets.sh" \
  --output "${OUTPUT_FILE}" \
  --terraform-dir "${TEST_DIR}/terraform" \
  --terraform-bin "${TEST_DIR}/terraform-mock" \
  --oci-config "${TEST_DIR}/.oci/config" \
  --profile STREAMLIT_API_KEY \
  --ssh-private-key "${TEST_DIR}/.ssh/bastion_key" \
  --ssh-public-key "${TEST_DIR}/.ssh/bastion_key.pub" \
  --connector-script "${TEST_DIR}/connect-streamlit-api-key-auth.ps1"

grep -Fx 'AssetsVersion=1' "${OUTPUT_FILE}" >/dev/null
grep -Fx 'BastionId=ocid1.bastion.oc1.eu-frankfurt-1.testbastion' "${OUTPUT_FILE}" >/dev/null
grep -Fx 'InstanceId=ocid1.instance.oc1.eu-frankfurt-1.testinstance' "${OUTPUT_FILE}" >/dev/null
grep -Fx 'PrivateIp=10.30.1.159' "${OUTPUT_FILE}" >/dev/null
grep -Fx 'ApiKeyFingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99' "${OUTPUT_FILE}" >/dev/null
grep -Fx "ApiPrivateKeyPath=${TEST_DIR}/.oci/api.pem" "${OUTPUT_FILE}" >/dev/null
grep -Fx "SshPrivateKeyPath=${TEST_DIR}/.ssh/bastion_key" "${OUTPUT_FILE}" >/dev/null
if [[ $(uname -s) != MINGW* ]]; then
  [[ $(stat -c '%a' "${OUTPUT_FILE}") == 600 ]]
fi
! grep -F 'test-only-api-key' "${OUTPUT_FILE}" >/dev/null
! grep -F 'test-only-ssh-key' "${OUTPUT_FILE}" >/dev/null

printf '%s\n' 'PASS: Linux asset generator created a validated mode-0600 inventory.'
