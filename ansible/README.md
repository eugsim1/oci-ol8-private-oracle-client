# Ansible through OCI Bastion

This project provisions the private Oracle Linux host created by the sibling Terraform project.

## Connection path

Ansible does not need a public IP on the target. Its OpenSSH transport uses a `ProxyCommand`:

```text
Ansible -> regional OCI Bastion endpoint -> managed session -> oracle@private-IP:22
```

The managed session must be `ACTIVE`, the controller CIDR must be permitted on the Bastion, and the session public key must match the local file in `ansible_ssh_private_key_file`. Terraform cloud-init bootstraps `oracle` with this key and passwordless sudo.

## Automatic configuration and execution

After Terraform has completed successfully, run from the project root:

```bash
chmod +x scripts/run-ansible.sh
./scripts/run-ansible.sh
```

On success, the runner prepares a zero-argument interactive login command. Run
it from the project root on the Linux controller:

```bash
./scripts/connect-oracle-server.sh
```

The Ansible runner generates `reports/ssh-connection.env` with mode `0600` and
the login helper reads every connection value from it. Terraform outputs are
used as a fallback if that generated file is missing. It logs in as `oracle`
through the active managed SSH session; no IP address, session OCID, region,
user, port, or key argument is required.

If the generated inventory references an expired or closed OCI Bastion session,
renew it from the project root. The renewal script waits for `ACTIVE`, regenerates
the inventory with the new session OCID, verifies SSH, and reruns Ansible:

```bash
chmod +x scripts/renew-bastion-session.sh
./scripts/renew-bastion-session.sh terraform.tfvars
```

Use `RUN_ANSIBLE_AFTER_RENEWAL=false` to create the new session without running
the playbook immediately. A later `./scripts/run-ansible.sh` invocation will
regenerate the inventory before connecting.

The script reads `private_ip`, region, Bastion session OCID/state, the session
public-key path, and `iam_instance_principal_enabled` directly from Terraform
outputs. It derives the matching SSH private-key path by removing `.pub` and
generates both files automatically:

```text
ansible/inventory/hosts.yml
ansible/group_vars/all.yml
```

It then installs the required collection, displays the parsed inventory, waits for SSH, performs a syntax check, and runs the playbook with verbosity level 2. Output is also saved under `reports/ansible-run-<UTC timestamp>.log`.

When Terraform instance-principal IAM is enabled, the script does not require
or copy a user OCI config/API key. OCI CLI wallet operations use
`--auth instance_principal`, and the FOCUS loader uses `-ip`.

When it is disabled, the legacy API-key mode remains available. In that mode
the runner reads `$HOME/.oci/config`, discovers its first `key_file=`, and uses
these conventions:

```text
session key:  /home/oracle/.ssh/key_name.pub
private key:  /home/oracle/.ssh/key_name
OCI config:   /home/oracle/.oci/config
OCI API key:  the key_file value in the OCI config
```

Override discovery only when necessary:

```bash
SSH_PRIVATE_KEY_PATH=/secure/keys/bastion_key \
OCI_CONFIG_SOURCE=/secure/oci/config \
OCI_PRIVATE_KEY_SOURCE=/secure/oci/api_key.pem \
ANSIBLE_VERBOSITY=3 \
./scripts/run-ansible.sh
```

Force a mode only when the corresponding IAM or credential configuration
already exists:

```bash
OCI_AUTH_MODE=instance_principal ./scripts/run-ansible.sh
OCI_AUTH_MODE=api_key ./scripts/run-ansible.sh
```

The SSH private key can alternatively be argument 1:

```bash
./scripts/run-ansible.sh /secure/keys/bastion_key
```

## Manual configuration and execution

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all.yml.example group_vars/all.yml
```

Obtain the required values:

```bash
cd ../terraform
terraform output -raw private_ip
terraform output -raw bastion_session_id
terraform output -raw region
terraform output -raw bastion_ssh_command
```

Put the private IP, session OCID, region, and local SSH private-key path in
`inventory/hosts.yml`. Keep `ansible_user: oracle`. For instance-principal
authentication, put this in `group_vars/all.yml`:

```yaml
oracle_oci_auth_mode: "instance_principal"
oracle_oci_region: "eu-frankfurt-1"
oci_config_source: ""
oci_private_key_source: ""
oci_private_key_filename: ""
```

For legacy API-key authentication, use:

```yaml
oracle_oci_auth_mode: "api_key"
oracle_oci_region: "eu-frankfurt-1"
oci_config_source: "/home/admin/.oci/config"
oci_private_key_source: "/home/admin/.oci/oci_api_key.pem"
oci_private_key_filename: "oci_api_key.pem"
```

Only API-key mode verifies and copies the controller files. The role creates
`/home/oracle/.oci` with mode `0700`, copies both files with mode `0600`, and
rewrites `key_file=` in the copied config. Instance-principal mode creates
`/etc/profile.d/oci-auth.sh` and does not copy user credentials.

By default, the role uses the configured OCI CLI credentials to download the Terraform-created Autonomous Database wallet to `/home/oracle/Wallet_AutonomousDatabase.zip`, extracts it into `/home/oracle/adb_wallet`, updates `sqlnet.ora` with that absolute path, and configures `TNS_ADMIN`. The generated inventory runner supplies the database OCID automatically. Export the wallet password before running Ansible:

```bash
read -rsp "ADB wallet password: " ADB_WALLET_PASSWORD
export ADB_WALLET_PASSWORD
./scripts/run-ansible.sh
```

The password is not written to generated group variables or Ansible logs. Set `ADB_WALLET_ENABLED=false` to skip this feature, or override `ADB_WALLET_ARCHIVE_PATH` and `ADB_WALLET_DIRECTORY`. Required wallet files and the corrected `sqlnet.ora` path are verified after extraction. `TNS_ADMIN` is configured globally in `/etc/environment` and for shells under `/etc/profile.d`. The OCI user configured under `/home/oracle/.oci` needs permission to generate the database wallet.

Set `ADB_DATABASE_ID` to use an Autonomous Database other than the Terraform-created one. Also select unique `ADB_WALLET_ARCHIVE_PATH` and `ADB_WALLET_DIRECTORY` values when switching databases; otherwise the role intentionally preserves the existing wallet during an idempotent rerun. Use `ADB_ADMIN_PASSWORD` when the alternate database has a different ADMIN password.

When no OCID is supplied, the role attempts to recover it from the controller's Terraform state under `../terraform`. Before downloading the wallet, it prints the complete safe response from `oci db autonomous-database get`. After the password-protected download task, it prints a sanitized result and verifies the archive size and SHA-256 checksum. This provides full OCI diagnostics without exposing either wallet or ADMIN passwords.

The reusable `/home/oracle/test_adb/test_adb_connection.sh` script auto-discovers the first `_high` alias from `tnsnames.ora` and tests a SQLPlus connection as `ADMIN`. Ansible supplies the Terraform ADMIN password through the process environment with output redaction, then prints only the safe SQL query results. To rerun it later:

```bash
export TNS_ADMIN=/home/oracle/adb_wallet
read -rsp "ADB ADMIN password: " ADB_ADMIN_PASSWORD
export ADB_ADMIN_PASSWORD
/home/oracle/test_adb/test_adb_connection.sh
```

Set `ADB_TNS_ALIAS` to override auto-discovery. The last result is saved with mode `0600` under `/home/oracle/test_adb/last_test_result.txt`; the password is never saved there. Set `ADB_TEST_ENABLED=false` to skip the automated connection test.

Wallet validation errors are visible and identify the failed assertion. The play also prints all non-secret wallet settings, the wallet directory contents, complete `sqlnet.ora`, connection-test inputs, and SQLPlus results. Password-bearing download and connection invocations remain redacted to prevent credentials from entering verbose Ansible logs.

## Graphical desktop and Firefox

The role installs the Oracle Linux 8 graphical server environment without weak dependencies, Firefox, and TigerVNC. Display `:1` is mapped to `oracle`, enabled at boot, and forced to listen only on `127.0.0.1:5901` with VNC password authentication. The server remains on its normal non-graphical boot target, avoiding an unnecessary console display manager.

```bash
read -rsp "oracle VNC password: " ORACLE_VNC_PASSWORD
export ORACLE_VNC_PASSWORD
./scripts/run-ansible.sh
```

The password is not logged. TigerVNC authentication uses only its first eight characters. From the project root, run `scripts/open-vnc-tunnel.sh` on the controller and connect the VNC viewer to `localhost:5901`. No VNC listener is exposed through the OCI subnet or NSG. Set `ORACLE_GUI_ENABLED=false` to skip the desktop and Firefox installation.

All GUI tasks run inside a nonfatal Ansible `block/rescue`. A failure is printed but does not stop core provisioning. Status is saved to `/home/oracle/gui-provisioning-status.txt`, mirrored to `reports/gui-provisioning-status.txt` on the controller, and incorporated into the final CSV report.

The role also installs Git and, by default, clones the application repository as `oracle`:

```yaml
oracle_application_repository_enabled: true
oracle_application_repository_url: "https://github.com/eugsim1/focus-loader-report-upload.git"
oracle_application_repository_version: "HEAD"
oracle_application_repository_destination: "/home/oracle/focus-loader-report-upload"
oracle_application_repository_update: true
```

Override the URL with `APPLICATION_REPOSITORY_URL` when using `scripts/run-ansible.sh`, or change these variables in `group_vars/all.yml` for a manual Ansible run. The revision may be a branch, tag, or commit. The clone destination must be below `/home/oracle` and the target repository must be reachable through the NAT Gateway. The role verifies the checkout with `git rev-parse --show-toplevel` and prints the resolved full target path.

## Go toolchain

The core role always installs the Oracle Linux `golang` package, independently
of the optional FOCUS loader stage. It requires Go 1.21 or newer, creates
`/home/oracle/go/bin`, and writes `/etc/profile.d/go.sh` so `GOROOT`, `GOPATH`,
the Go toolchain, and user-installed Go binaries are available in login shells.
The playbook verifies the setup as `oracle` and prints the full Go binary path,
version, `GOROOT`, `GOPATH`, and effective `PATH`.

Defaults can be overridden in group variables:

```yaml
oracle_go_packages:
  - golang
oracle_go_minimum_version: "1.21"
oracle_go_workspace: "/home/oracle/go"
```

## Optional final FOCUS loader stage

The role can build and run the cloned FOCUS loader as its final task set. This
stage is disabled by default because it changes database schema objects. Enable
it explicitly on the controller:

```bash
read -rsp "ADB and FOCUS database password: " ADB_ADMIN_PASSWORD
echo
export ADB_ADMIN_PASSWORD
export FOCUS_LOADER_ENABLED=true
export FOCUS_LOADER_TARGET_SCHEMA=FOCUS_GIT1
export FOCUS_LOADER_DB_TNS_ALIAS=finops_high
export FOCUS_LOADER_NAMESPACE=bling
export FOCUS_LOADER_MINIMUM_DATE=2026-01-01
export FOCUS_LOADER_WORKERS=5
./scripts/run-ansible.sh
```

When the ADMIN, target-schema, and loader passwords are identical, the single
`ADB_ADMIN_PASSWORD` value above is reused without being written to generated
inventory or group-variable files. For different credentials, export
`FOCUS_LOADER_DB_ADMIN_PASSWORD`, `FOCUS_LOADER_TARGET_SCHEMA_PASSWORD`, and
`FOCUS_LOADER_DB_PASSWORD` separately. Alternatively, configure
`FOCUS_LOADER_DB_SECRET_ID` and `FOCUS_LOADER_DB_SECRET_PROFILE` so the loader
uses OCI Vault instead of `-dp`.

`FOCUS_LOADER_DB_TNS_ALIAS` is optional; when empty, the role discovers the
first `*_high` alias in the downloaded wallet. Tag-column keys can be changed
with `FOCUS_LOADER_TAG_SPECIAL_1` through `FOCUS_LOADER_TAG_SPECIAL_4`.

`FOCUS_LOADER_DROP_EXISTING` defaults to `false`, retaining an existing schema
user and updating its password. Setting it to `true` authorizes the deployment
script to execute `DROP USER ... CASCADE` before recreating the schema.

The final stage installs Go and GCC, requires Go 1.21 or newer, builds the
binary as `oracle`, verifies the requested CLI option, deploys the schema,
checks that `sql_scripts/focus.conf` was copied identically to the repository
root, and runs the loader. Password-bearing invocations remain protected by
`no_log`, while safe stdout, stderr, return codes, paths, and selected settings
are printed.

Instant Client uses Oracle's OL8 DNF repository instead of version-specific ZIP URLs. Defaults install the 26ai channel, Basic libraries, Tools (including SQL*Loader and Data Pump), and SQL*Plus:

```yaml
oracle_instant_client_release: "26ai"
oracle_instant_client_install_sqlplus: true
```

Set the release to `23ai` only if that channel is required. On a package failure, the role prints enabled Instant Client repositories and all available matching RPM names before stopping.

```bash
cd ../ansible
ansible-galaxy collection install -r requirements.yml
ansible -i inventory/hosts.yml oracle_linux -m wait_for_connection -a 'timeout=600'
ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
ansible-playbook -i inventory/hosts.yml site.yml
```

The root `scripts/deploy.sh` runs Terraform and then calls `scripts/run-ansible.sh`, so generated variables never need manual substitution.

## Debug output

`ansible.cfg` enables task argument display, task timings, and total runtime. The playbook reports the target host, remote OS, Python interpreter, planned actions, OCI CLI version, Python version, SQLPlus version, Instant Client directory, and destination OCI configuration path. Credential-copy and config-rewrite tasks retain `no_log: true` so key material is not printed.

Set `ANSIBLE_VERBOSITY` from `0` through `4`; the default is `2` (`-vv`).

## DNF dependency conflicts during OS update

The role does not run `dnf upgrade '*'` by default. Broad upgrades inspect the best candidate for every package in all enabled repositories and can fail because of unrelated optional packages such as GraalVM, APEX, MySQL, Ruby, or Node.js. Required packages are installed in a separate, controlled transaction.

The default settings are:

```yaml
oracle_update_all_packages: false
oracle_os_update_skip_broken: true
oracle_python_executable: /usr/bin/python3.12
oracle_oci_cli_python_executable: /usr/bin/python3.11
```

Oracle Linux 8.10 installs Python 3.12 as the latest application runtime while retaining the platform Python. OCI CLI uses an isolated Python 3.11 virtual environment because Python 3.11 is in Oracle's documented OCI CLI support matrix for Oracle Linux 8.

If full operating-system patching is required, set `oracle_update_all_packages: true`. That optional transaction uses `update_only` and `skip_broken`, but repository/module-stream health should still be managed independently from this application role.

After receiving a dependency-solver failure from an older version of the role, update the files and simply rerun:

```bash
ANSIBLE_VERBOSITY=3 ./scripts/run-ansible.sh
```

Completed tasks are idempotent and the corrected package task resumes the deployment.

If the controller already has private VCN routing through VPN, FastConnect, peering, or an in-VCN runner, delete `ansible_ssh_common_args` and connect directly to `ansible_host`.
