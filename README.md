# Private OCI FOCUS FinOps ETL Platform

This project deploys and configures a private OCI utility environment for the
multi-worker FinOps ETL described in
[Building a Fast Multi-Worker ETL Pipeline for OCI FOCUS FinOps](https://www.linkedin.com/pulse/building-fast-multi-worker-etl-pipeline-oci-focus-finops-eugene-simos-vbytf/).
Terraform creates the private infrastructure and Ansible turns the Oracle Linux
host into a ready-to-run ETL node. Ansible clones the
[`eugsim1/focus-loader-report-upload`](https://github.com/eugsim1/focus-loader-report-upload)
project, installs its Go and Oracle runtime dependencies, creates the target
database schema, downloads the Autonomous Database wallet, and verifies the
private database connection.

**Current main-branch documentation version: `v1.4.0` (2026-08-08).**

The deployed utility reads OCI FOCUS cost-report objects from Object Storage,
processes multiple gzip CSV files concurrently, enriches and normalizes the
FOCUS rows, produces SQL*Loader-ready data, and loads it into an Autonomous AI
Database. Load status, SQL*Loader audit data, tag metadata, and restart
checkpoints make the pipeline suitable for repeatable FinOps processing rather
than a one-time import.

## Disclaimer and community use

> **Independent community project:** This repository is not an Oracle product
> and is not affiliated with, sponsored by, endorsed by, reviewed by, or
> supported by Oracle Corporation. Use of Oracle product names, OCI service
> names, documentation links, and architecture icons does not imply Oracle
> endorsement. Oracle products and services remain subject to their applicable
> licenses and service terms.

This project is provided as a reference implementation, without warranty or
official support. Review and test the source, IAM policies, database schema,
cost model, regional availability, and security controls before using it with
production systems or billing data. You are responsible for the OCI resources,
security configuration, and charges created in your tenancy.

The original code and documentation in this repository may be used, copied,
modified, and redistributed under the [MIT License](LICENSE). That license does
not grant rights to Oracle software, service content, trademarks, or any other
third-party component; those remain governed by their respective terms.

If this project helps you, an optional way to support it is to star the
[GitHub repository](https://github.com/eugsim1/oci-ol8-private-oracle-client)
and give the related
[LinkedIn article](https://www.linkedin.com/pulse/building-fast-multi-worker-etl-pipeline-oci-focus-finops-eugene-simos-vbytf/)
a reaction, comment, or share. Feedback and improvements through GitHub issues
and pull requests are welcome.

## Why the platform is private

Cost and billing data is sensitive. The design therefore places both the ETL
Compute instance and Autonomous Database endpoint inside a private VCN:

- The Oracle Linux VNIC has no public IP and the subnet prohibits public IPs.
- Autonomous Database uses a private endpoint and a dedicated network security
  group; SQL traffic is limited to TLS/mTLS on TCP 1522 from the VCN.
- The VCN has no Internet Gateway. A NAT Gateway provides outbound-only access
  for GitHub, DNF, PyPI, and Oracle package repositories.
- A Service Gateway provides private routing to regional Oracle services,
  including Object Storage.
- OCI Bastion creates a temporary, controller-CIDR-restricted SSH path. No
  permanently running public jump host is required.
- The Compute instance enforces IMDSv2 and disables legacy metadata endpoints.
- SSH and OCI private keys remain on the Linux controller until Ansible copies
  only the explicitly configured OCI credential files with restrictive modes.
- Database Tools uses its own private endpoint and a Vault-backed password
  reference instead of embedding a password in the connection resource.

Oracle documents that an Autonomous Database private endpoint keeps database
traffic off the public Internet. See
[Autonomous Database private endpoint network access](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-network-access.html).

## Safe deployments to multiple compartments

Every created resource now receives the `compartment_id` configured in
`terraform/terraform.tfvars`, and Terraform verifies the reported resource
compartments after apply. Immutable Autonomous Database and Bastion names get a
deterministic compartment suffix by default, preventing collisions when the
same stack is deployed in another compartment. Independent compartments also
use independent Terraform workspaces:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars and set the target compartment_id.

bash scripts/select-compartment-workspace.sh terraform.tfvars
cd terraform
terraform plan -var-file=terraform.tfvars
```

The helper refuses to leave a workspace that already contains managed
resources unless the new-environment override is explicitly enabled. See
[the Terraform multi-compartment and import guide](terraform/README.md#deploying-the-same-project-to-another-compartment)
before changing `compartment_id` on an existing deployment.

## Solution architecture

### OCI deployment topology

[![OCI FOCUS private FinOps architecture](docs/architecture/oci-focus-private-finops.png)](docs/architecture/oci-focus-private-finops.drawio)

This physical view shows the OCI Region, VCN, private subnet, managed Bastion,
private Compute host, private Autonomous Database, Database Tools private
endpoint, Vault, gateways, Object Storage, and the planned private Oracle
Analytics Cloud path.

### Solution Design Architecture (SDA)

[![FOCUS FinOps Solution Design Architecture](docs/architecture/oci-focus-private-finops-sda.png)](docs/architecture/oci-focus-private-finops-sda.drawio)

The SDA view separates consumers, analytics, data products, ETL/application,
OCI platform, delivery/operations, and cross-cutting security controls. Solid
elements are implemented by this project; dashed red elements identify the
planned Oracle Analytics Cloud phase.

Both PNGs are generated from their linked editable Draw.io sources. They use
service stencils from Oracle's official
[OCI Architecture Diagram Toolkit](https://docs.oracle.com/en-us/iaas/Content/General/Reference/graphicsfordiagrams.htm).
Diagram sources, regeneration instructions, and scope notes are in
[`docs/architecture`](docs/architecture/README.md).

### End-to-end data and deployment flow

1. A Linux controller runs Terraform against OCI APIs and creates the VCN,
   private subnet, gateways, Compute instance, Bastion, Autonomous Database,
   Database Tools private endpoint, Vault, KMS key, and secret.
2. The controller opens a temporary OCI Bastion managed SSH session to the
   private Compute IP. Ansible connects as `oracle` using the controller's local
   SSH private key.
3. Ansible installs Python, OCI CLI, Git, the Go toolchain, Oracle Instant
   Client 26ai, SQL*Plus, SQL*Loader, and the optional minimal graphical tools.
4. Ansible clones the FOCUS ETL repository, deploys the target database schema,
   downloads and extracts the wallet, configures `TNS_ADMIN`, and validates an
   ADMIN connection through the Autonomous Database private endpoint.
5. The ETL lists objects below `FOCUS Reports/` in the Oracle-managed Object
   Storage cost-report bucket and applies date and checkpoint filters.
6. Concurrent Go workers download `.csv.gz` reports, decompress them, enrich
   FOCUS fields, resolve compartment hierarchy and tags, and produce
   deterministic SQL*Loader-ready CSV files.
7. SQL*Loader sends each transformed file over the private TLS/mTLS connection
   to Autonomous Database. Database load status and `SQLLOADER_AUDIT` retain
   operational outcomes and restart history.
8. Terraform and the deployment wrapper generate infrastructure and execution
   reports without writing passwords, wallet contents, or private-key contents.

### Current scope and roadmap

| Capability | Status | Purpose |
|---|---|---|
| Private Oracle Linux ETL node | Deployed | Runs the Go workers, OCI SDK, transformation, and SQL*Loader processes. |
| Autonomous Database private endpoint | Deployed | Stores queryable FOCUS cost, tag, audit, and checkpoint data. |
| OCI Bastion | Deployed | Provides temporary administrative SSH access to the private host. |
| OCI Database Tools private connection | Deployed | Enables a Vault-backed private database tools connection. |
| Oracle Analytics Cloud | Planned for the next blog | Will consume the private FOCUS data mart and expose configurable cost-management dashboards. |

The next article will add Oracle Analytics Cloud (OAC), a private access channel
to the Autonomous Database endpoint, a governed semantic model, and configurable
dashboards for cost trends, allocation, tag governance, anomalies, and
chargeback/showback. OAC is shown with a dashed border in the diagram because it
is **not** deployed by the current Terraform modules. Oracle documents that an
OAC private access channel can reach private data sources in an OCI VCN; see
[About Private Access Channels](https://docs.oracle.com/en-us/iaas/analytics-cloud/doc/private-access-channels.html).

## What this repository deploys

Terraform creates five modules:

- `network`: VCN, private subnet, private route table, NAT Gateway, Service
  Gateway, and subnet security list.
- `compute`: Oracle Linux 8 flexible VM, private VNIC, boot volume, `oracle`
  account bootstrap, Bastion agent, and IMDSv2-only metadata configuration.
- `bastion`: OCI Bastion service, plugin readiness test, and optional temporary
  managed SSH session.
- `autonomous_database`: ECPU Autonomous AI Database, private endpoint, NSG, and
  TLS/mTLS connection information.
- `database_tools`: service-managed private endpoint, dedicated NSG, Vault/KMS
  password secret or existing-secret reference, and private ADB connection.

Ansible then provisions the operating system, Oracle client software, OCI CLI,
Go, Git repository, wallet, SQL connection test, optional GUI, and optional
final FOCUS schema/load workflow.

## Project structure

```text
.
├── terraform/
│   ├── modules/
│   │   ├── network/
│   │   ├── compute/
│   │   ├── bastion/
│   │   ├── autonomous_database/
│   │   └── database_tools/
│   ├── terraform.tfvars.example
│   ├── report.tf
│   └── README.md
├── ansible/
│   ├── roles/oracle_client/
│   ├── inventory/hosts.yml.example
│   ├── group_vars/all.yml.example
│   ├── site.yml
│   └── README.md
├── scripts/
│   ├── README.md
│   ├── deploy.sh
│   ├── run-ansible.sh
│   ├── renew-bastion-session.sh
│   ├── start-and-connect.sh
│   ├── manage-existing-stack.sh
│   ├── connect-oracle-server.sh
│   ├── open-vnc-tunnel.sh
│   └── select-compartment-workspace.sh
├── tests/
│   ├── test-manage-existing-stack.sh
│   └── test-bastion-session-scripts.sh
├── docs/architecture/
│   ├── oci-focus-private-finops.drawio
│   ├── oci-focus-private-finops.png
│   ├── oci-focus-private-finops-sda.drawio
│   ├── oci-focus-private-finops-sda.png
│   ├── generate-diagrams.ps1
│   └── README.md
├── docs/EXISTING_STACK_LIFECYCLE.md
├── reports/                  # generated locally; contents are ignored
├── Location.md
├── RELEASE_NOTES_v1.4.0.md
├── RELEASE_NOTES_v1.3.0.md
├── LICENSE
├── SECURITY.md
└── SANITIZATION_REPORT.md
```

## Prerequisites on the Linux controller

- Terraform 1.6 or later
- Ansible Core 2.15 or later
- OCI CLI, OpenSSH client, Bash, and OCI provider credentials
- An SSH key pair; Terraform reads its public-key file and installs the key for both `opc` and `oracle`, while Ansible reads the matching private-key file locally
- IAM permission to manage VCN, Compute, NAT Gateway, Bastion, and Bastion Session resources
- IAM permission to manage Autonomous Database, Network Security Groups, Database Tools, Vaults, Keys, and Secrets

The controller's public IP must be stable for the duration of the run and must match `controller_public_cidr`.

Open Internet access is rejected unless it is explicitly acknowledged with both `controller_public_cidr = "0.0.0.0/0"` and `allow_open_bastion_cidr = true`. Keep the override `false` outside temporary test environments.

Set `ssh_public_key_path` in `terraform.tfvars` to the public-key file on the controller. Terraform reads the file content; do not paste the OpenSSH key into the variables file.

Set `create_bastion_session = true` to create the temporary managed SSH session. `bastion_session_public_key_path` may point to a separate local `.pub` file; when it is `null`, Terraform reuses `ssh_public_key_path`. Only the public key is sent to OCI, while the matching private key stays on the Linux controller.

Set `compute_node_name` to control the OCI Compute display name and the naming prefix for its related network and Bastion resources.

Availability domains are discovered automatically from OCI using `compartment_id`. The names are sorted and `availability_domain_index = 0` is selected by default, so no tenancy-specific AD name is required in `terraform.tfvars`.

## Terraform deployment

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
read -rsp "ADB ADMIN password: " TF_VAR_adb_admin_password
export TF_VAR_adb_admin_password
terraform init
terraform fmt -recursive
terraform validate
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

### Select Oracle Database 19c or Oracle AI Database 26ai

Set `adb_db_version` in `terraform/terraform.tfvars` before the first apply:

```hcl
# Create a 19c Autonomous Database
adb_db_version = "19c"
```

or:

```hcl
# Create a 26ai Autonomous AI Database
adb_db_version = "26ai"
```

The validation accepts only `"19c"`, `"26ai"`, or `null`. With `null`,
Terraform omits `db_version` and OCI selects its current regional default. The
supplied example explicitly selects `26ai`. Confirm that the selected version is
available for the workload and region before applying:

```bash
oci db autonomous-db-version list \
  --compartment-id "$COMPARTMENT_OCID" \
  --db-workload OLTP \
  --region eu-frankfurt-1 \
  --all \
  --query 'data[].version'
```

For an existing database, changing the value is a database-version operation.
Review `terraform plan` and the OCI maintenance requirements first. Changing
from `26ai` to `19c` is not a rollback procedure; use an Oracle-supported
restore, clone, or migration plan when rollback is required.

Verify that no public address exists and obtain the Bastion command:

```bash
terraform output private_ip
terraform output public_ip
terraform output -raw bastion_ssh_command
terraform output available_availability_domains
terraform output selected_availability_domain
terraform output bastion_plugin_status
terraform output bastion_plugin_message
terraform output autonomous_database_private_endpoint
terraform output autonomous_database_private_ip
terraform output autonomous_database_version
terraform output -raw terraform_csv_report
```

Terraform itself writes `reports/terraform-resources.csv` after a successful apply. It is a full inventory of the network, Compute node and IPs, Bastion/session/plugin, Autonomous Database/private endpoint, Database Tools connection/private endpoint, and Vault/key/secret identifiers. It excludes passwords, secret contents, wallet contents, and private-key contents. The end-to-end Bash wrapper additionally creates a timestamped execution report in the same directory.

The five modules summarized above have explicit dependencies: Compute waits for
Network, Bastion waits for Compute, Autonomous Database waits for Network, and
Database Tools waits for Autonomous Database. When
`create_bastion_session = true`, Terraform waits for
`bastion_plugin_wait_duration`, queries the live Compute Instance Agent status,
and blocks the session unless the `Bastion` plugin is `RUNNING`. When false, the
wait, test, and session are skipped while the Bastion service remains. The
default is `600s` because OCI documents that plugin enablement can take up to 10
minutes.

If OCI shows the plugin as **Enabled / Stopped**, apply the updated network and 600-second wait first. If it stays stopped, create an SSH port-forwarding session to the private IP on port 22; unlike managed SSH, port forwarding does not require Oracle Cloud Agent. Use the tunnel to restart and inspect `oracle-cloud-agent` on Linux. Detailed commands are in `terraform/README.md`.

The database has no public SQL endpoint because `subnet_id` and `private_endpoint_label` are set. The ADMIN password is a sensitive Terraform input. It is omitted from `terraform.tfvars.example`; secure the Terraform state because providers can retain sensitive values in state.

## How Ansible connects

Ansible targets the server's private IP as `oracle`. OpenSSH's `ProxyCommand` first connects to the regional OCI Bastion endpoint using the Bastion Session OCID as its SSH username. Bastion then forwards the SSH stream to `oracle@PRIVATE_IP:22`. Cloud-init creates `oracle` with the filesystem-loaded public key and passwordless sudo before Ansible connects.

The inventory pattern is:

```yaml
ansible_host: 10.30.1.10
ansible_user: oracle
ansible_ssh_private_key_file: /home/admin/.ssh/id_ed25519
ansible_ssh_common_args: >-
  -o ProxyCommand="ssh -i /home/admin/.ssh/id_ed25519 -W %h:%p -p 22 SESSION_OCID@host.bastion.eu-paris-1.oci.oraclecloud.com"
```

Create the files:

```bash
cd ../ansible
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all.yml.example group_vars/all.yml
```

Replace the private IP, session OCID, region, and SSH private-key path in
`inventory/hosts.yml`. Configure `oracle_oci_auth_mode` and
`oracle_oci_region` in `group_vars/all.yml`; local OCI config/API-key paths are
needed only for legacy `api_key` mode. Instant Client defaults to the Oracle
26ai DNF release channel, with Basic, Tools/SQL*Loader, and SQL*Plus packages.

Then run:

```bash
ansible-galaxy collection install -r requirements.yml
ansible -i inventory/hosts.yml oracle_linux -m wait_for_connection -a 'timeout=600'
ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
ansible-playbook -i inventory/hosts.yml site.yml
```

Ansible waits for the managed SSH path, connects directly as `oracle`, installs
Python/OCI CLI/Git/Instant Client, downloads and configures the Autonomous
Database wallet, and clones
`https://github.com/eugsim1/focus-loader-report-upload.git` into
`/home/oracle/focus-loader-report-upload`. In instance-principal mode it does
not require or copy user API credentials. In legacy API-key mode it verifies
the controller's `oci_config_source` and `oci_private_key_source`, creates
`/home/oracle/.oci` securely, and copies both files with mode `0600`.

## One-command Linux deployment and report

From the project root:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
read -rsp "ADB ADMIN password: " TF_VAR_adb_admin_password
export TF_VAR_adb_admin_password
read -rsp "ADB wallet password (Enter to reuse ADMIN password): " ADB_WALLET_PASSWORD
export ADB_WALLET_PASSWORD="${ADB_WALLET_PASSWORD:-$TF_VAR_adb_admin_password}"
read -rsp "oracle VNC password: " ORACLE_VNC_PASSWORD
export ORACLE_VNC_PASSWORD
chmod +x scripts/*.sh tests/*.sh
./scripts/deploy.sh terraform.tfvars
```

After Terraform succeeds, the wrapper derives the SSH private-key path from
the Terraform session public-key path, generates the complete Ansible inventory
and group variables, and runs Ansible through OCI Bastion. If
`iam_instance_principal_enabled` is true it selects instance-principal
authentication automatically. Otherwise it reads the controller's
`$HOME/.oci/config` and discovers its `key_file`. No placeholder substitution
is required.

If the matching SSH private key cannot be derived by removing `.pub`, pass its path as argument 2:

```bash
./scripts/deploy.sh terraform.tfvars /secure/keys/bastion_key
```

Override OCI or debug discovery with environment variables:

```bash
OCI_CONFIG_SOURCE=/secure/oci/config \
OCI_PRIVATE_KEY_SOURCE=/secure/oci/api_key.pem \
APPLICATION_REPOSITORY_URL=https://github.com/example/another-repository.git \
APPLICATION_REPOSITORY_VERSION=main \
APPLICATION_REPOSITORY_DESTINATION=/home/oracle/another-repository \
ADB_WALLET_PASSWORD='replace-with-a-secure-password' \
ADB_WALLET_DIRECTORY=/home/oracle/adb_wallet \
ORACLE_VNC_PASSWORD='replace-with-a-vnc-password' \
ORACLE_GUI_VNC_GEOMETRY=1280x800 \
ANSIBLE_VERBOSITY=3 \
./scripts/deploy.sh terraform.tfvars
```

The same `APPLICATION_REPOSITORY_*` variables can be supplied to `scripts/run-ansible.sh`. `APPLICATION_REPOSITORY_VERSION` accepts a branch, tag, or commit and defaults to `HEAD`. The repository must be reachable by the target server through its NAT Gateway. The clone is idempotent, updates on later runs, preserves local modifications, and runs as `oracle`. After cloning, Ansible uses `git rev-parse --show-toplevel` on the target to verify and print the repository's full Linux installation path. The core role also installs Go 1.21 or newer, creates `/home/oracle/go/bin`, configures `GOROOT`, `GOPATH`, and `PATH` through `/etc/profile.d/go.sh`, and prints the verified Go installation details as `oracle`.

Wallet deployment is enabled by default. The runner reads the Autonomous
Database OCID directly from Terraform output, downloads
`/home/oracle/Wallet_AutonomousDatabase.zip`, extracts it securely to
`/home/oracle/adb_wallet`, replaces `?/network/admin` in `sqlnet.ora` with that
absolute directory, and configures `TNS_ADMIN`. Supply `ADB_WALLET_PASSWORD`;
when the end-to-end deployment wrapper is used, it falls back to
`TF_VAR_adb_admin_password`. Use a separate strong wallet password in
production. Set `ADB_WALLET_ENABLED=false` to skip wallet deployment. The
selected OCI identity—instance principal or API-key profile—must be authorized
to inspect the database and generate its wallet.

After Instant Client installation, Ansible installs and runs `/home/oracle/test_adb/test_adb_connection.sh`. The script finds the first `_high` alias in the wallet's `tnsnames.ora`, connects with SQLPlus as `ADMIN`, and prints the connected user, database, service, instance, timestamp, and exit status. The ADMIN password is read from `ADB_ADMIN_PASSWORD`, falling back to `TF_VAR_adb_admin_password`; it is neither stored in the script nor printed. Results remain in `/home/oracle/test_adb/last_test_result.txt`. Override the alias with `ADB_TNS_ALIAS=database_high`, or disable the test with `ADB_TEST_ENABLED=false`.

Debug output deliberately shows the wallet OCID, archive and installation paths, password configured state and length, extracted filenames, complete `sqlnet.ora`, selected high-service alias, and safe SQLPlus query results. Only the OCI wallet download and SQLPlus invocation remain under Ansible `no_log` because their module arguments contain passwords.

By default, wallet download and the SQLPlus test use `terraform output autonomous_database_id`. To target another Autonomous Database, set `ADB_DATABASE_ID`. When changing databases, use a different archive and extraction directory so an existing wallet is not reused by the idempotent `creates` checks:

```bash
export ADB_DATABASE_ID='ocid1.autonomousdatabase.oc1.eu-frankfurt-1...'
export ADB_WALLET_ARCHIVE_PATH='/home/oracle/Wallet_AnotherDatabase.zip'
export ADB_WALLET_DIRECTORY='/home/oracle/adb_wallet_another'
export ADB_WALLET_PASSWORD='another-wallet-password'
export ADB_ADMIN_PASSWORD='another-database-admin-password'
./scripts/run-ansible.sh
```

The alternate OCID and wallet path are included in the Ansible debug output and CSV report. Remove `ADB_DATABASE_ID` to return to the Terraform-created database.

If `oracle_adb_wallet_database_id` is empty during a direct `ansible-playbook` run, the role now executes `terraform -chdir=../terraform output -raw autonomous_database_id` on the controller and uses the result. It prints the Terraform lookup diagnostics, the complete safe JSON returned by `oci db autonomous-database get`, and a sanitized wallet-download result containing the return code, archive path, size, SHA-256 checksum, owner, mode, stdout, and stderr. Password arguments remain redacted.

The graphical interface uses the supported Oracle Linux 8 GNOME server environment with weak dependencies omitted, TigerVNC, and Firefox. It does not change the machine's default boot target or start a public display manager. Instead, `vncserver@:1.service` starts the desktop as `oracle`. VNC is forced to `127.0.0.1:5901`; no OCI security rule or host firewall opening is created. Supply `ORACLE_VNC_PASSWORD` before running Ansible. TigerVNC uses only the first eight password characters, so access must remain inside the SSH tunnel.

Open the secure tunnel from the Linux controller in a separate terminal:

```bash
chmod +x scripts/open-vnc-tunnel.sh
./scripts/open-vnc-tunnel.sh /secure/keys/bastion_key
```

Then connect a VNC viewer to `localhost:5901` and enter `ORACLE_VNC_PASSWORD`. Override the local port with `VNC_LOCAL_PORT=15901`. Disable graphical provisioning with `ORACLE_GUI_ENABLED=false`, or change resolution with `ORACLE_GUI_VNC_GEOMETRY=1600x900`.

Graphical provisioning is nonfatal. If GNOME, Firefox, TigerVNC, service startup, or verification fails, Ansible prints the failed GUI task and reason, writes `gui-provisioning-status.txt` on both the target and controller, and continues with wallet, database, and application configuration. The final CSV uses this status instead of reporting an unconditional GUI success.

The script writes the CSV deployment report and a verbose Ansible log under `reports/`. It requires `create_bastion_session = true`; when session creation is disabled, it finishes Terraform and stops before Ansible with guidance to use a directly routed inventory.

To rerun only Ansible against an existing active Terraform-managed session:

```bash
./scripts/run-ansible.sh
```

To run the cloned FOCUS loader as the final Ansible stage, explicitly enable it
and supply its settings from the controller environment:

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

The stage is disabled by default. `FOCUS_LOADER_DROP_EXISTING=false` is also
the default; setting it to `true` permits destructive schema recreation. See
`ansible/README.md` for all variables, separate-password handling, OCI Vault
authentication, TNS alias auto-discovery, and verification behavior.

After Ansible completes, connect interactively as `oracle` without supplying any
parameters:

```bash
./scripts/connect-oracle-server.sh
```

Before its first SSH attempt, `run-ansible.sh` writes the resolved target
private IP, current Bastion session OCID/state, region, and private-key path to
the controller-only `reports/ssh-connection.env` file with mode `0600`. The
login helper uses this file without requiring any arguments; Terraform outputs
and the generated Ansible inventory are its fallbacks when the file does not exist. It constructs the SSH ProxyCommand
safely and refuses to connect when the recorded session is not `ACTIVE`. Renew
an expired session first with `scripts/renew-bastion-session.sh`.

For routine access when Compute or Autonomous Database may be stopped, use the
artifact-driven workflow instead:

```bash
./scripts/start-and-connect.sh --tfvars terraform.tfvars
```

It selects the compartment workspace, resolves the existing key artifacts,
starts only stopped resources, waits for Compute `RUNNING`, prints numbered
polling iterations until the Compute instance's `Bastion` plugin is `RUNNING`,
then waits for ADB `AVAILABLE`, creates a fresh Bastion session, writes a
timestamped CSV, and opens SSH. It does not run Ansible. See
[`scripts/README.md`](scripts/README.md) for the decision table and
documentation for every script.

The role intentionally separates required package installation from full OS patching. `oracle_update_all_packages` defaults to `false`, preventing unrelated enabled-repository conflicts from blocking Python, OCI CLI, and Instant Client setup. It installs Python 3.12 as the latest OL8.10 application runtime and uses Python 3.11 for the OCI CLI virtual environment according to Oracle's OL8 support matrix.

Instant Client installation uses `oracle-instantclient-release-26ai-el8` and the generic `oracle-instantclient-basic`, `oracle-instantclient-tools`, and `oracle-instantclient-sqlplus` RPM names. This avoids brittle, release-specific ZIP filenames. The Tools package supplies SQL*Loader and Oracle Data Pump utilities.

## Start or stop the existing OCI stack

Release `v1.3.0` adds `scripts/manage-existing-stack.sh` for operating the
existing resource OCIDs without a Terraform apply. By default it reads these
current Terraform outputs:

For the normal "start if required and connect" path, the v1.4.0 wrapper is
simpler and automatically selects the correct workspace and key artifacts:

```bash
./scripts/start-and-connect.sh --tfvars terraform.tfvars --dry-run
./scripts/start-and-connect.sh --tfvars terraform.tfvars
```

Use `manage-existing-stack.sh` directly for automation, explicit resource
OCIDs, session-only creation without login, or `--stop-all`.

```bash
terraform -chdir=terraform output -raw instance_id
terraform -chdir=terraform output -raw autonomous_database_id
terraform -chdir=terraform output -raw bastion_id
terraform -chdir=terraform output -raw private_ip
terraform -chdir=terraform output -raw region
terraform -chdir=terraform output -raw bastion_session_public_key_path
```

The start workflow sends both start requests, waits for Compute `RUNNING`, and
then queries the OCI Compute Instance Agent once per polling interval. Each
console iteration shows the current `Bastion` plugin state. Session creation
cannot begin until that state is `RUNNING`. The workflow then waits for
Autonomous Database `AVAILABLE`, creates a fresh OCI Bastion managed SSH session,
and waits for `ACTIVE`. `AVAILABLE` is OCI's running/ready lifecycle state for
Autonomous Database. The script prints a complete OpenSSH ProxyCommand and
exits; add `--connect` only when an interactive login is wanted.

Run it from an **external Linux controller**. The controller needs Bash, OCI CLI,
Terraform when reading state outputs, and OpenSSH for `--connect`. Confirm the
OCI identity and perform a read-only preview first:

```bash
oci iam region-subscription list --profile DEFAULT --all
chmod +x scripts/manage-existing-stack.sh
./scripts/manage-existing-stack.sh --dry-run
```

Start the existing resources and create the session:

```bash
./scripts/manage-existing-stack.sh
```

Create the session and immediately open interactive SSH:

```bash
./scripts/manage-existing-stack.sh \
  --ssh-private-key /secure/keys/bastion_key \
  --connect
```

Explicit resource flags support existing/imported resources when the local
Terraform outputs are unavailable. The following OCIDs are test placeholders:

```bash
./scripts/manage-existing-stack.sh \
  --instance-id ocid1.instance.oc1.eu-frankfurt-1.testcompute \
  --autonomous-database-id ocid1.autonomousdatabase.oc1.eu-frankfurt-1.testadb \
  --bastion-id ocid1.bastion.oc1.eu-frankfurt-1.testbastion \
  --private-ip 10.0.1.10 \
  --region eu-frankfurt-1 \
  --ssh-public-key /secure/keys/bastion_key.pub \
  --ssh-private-key /secure/keys/bastion_key \
  --profile DEFAULT
```

Replace every `test...` OCID before a live run. The lifecycle API calls do not
need a compartment argument because each existing resource is addressed by its
OCID; the resources' compartments still determine IAM authorization.

To use an authorized controller instance principal:

```bash
./scripts/manage-existing-stack.sh \
  --auth instance_principal \
  --region eu-frankfurt-1
```

### Stop all sessions and services

Preview first, because this action can disconnect other operators:

```bash
./scripts/stop-all.sh --tfvars terraform.tfvars --dry-run
```

Then close **every non-deleted session returned for the selected Bastion**,
stop Autonomous Database, gracefully stop Compute with `SOFTSTOP`, and wait for
both services to report `STOPPED`:

```bash
./scripts/stop-all.sh --tfvars terraform.tfvars
```

For an approved emergency hard power-off only:

```bash
./scripts/stop-all.sh --tfvars terraform.tfvars --force-stop
```

Do not execute `--stop-all` from the Compute instance being managed. Its own
shutdown can terminate the process before final validation and CSV completion.

### Main flags

| Flag | Purpose |
|---|---|
| `--start` | Start resources and create a managed SSH session; this is the default. |
| `--stop-all` | Delete all selected-Bastion sessions and stop ADB and Compute. |
| `--force-stop` | Use Compute `STOP` instead of graceful `SOFTSTOP`. |
| `--connect` | Open interactive SSH after the new session is active. |
| `--dry-run` | Perform read-only discovery and write planned actions only. |
| `--profile NAME` | Select an OCI CLI profile; default is `DEFAULT`. |
| `--auth MODE` | Select an OCI CLI auth mode such as `instance_principal`. |
| `--session-ttl SECONDS` | Set session lifetime from 30 through 10800 seconds. |
| `--wait-seconds SECONDS` | Set state wait timeout; default is 3600. |
| `--bastion-plugin-wait-seconds SECONDS` | Set the Bastion plugin readiness timeout; default is 600. |
| `--poll-seconds SECONDS` | Set poll interval; default is 10. |
| `--report-dir PATH` | Override the default `reports/` CSV destination. |

Run `./scripts/manage-existing-stack.sh --help` for every resource, SSH, region,
authentication, wait, and report flag.

### Timestamped audit report

Every valid start, stop, or dry-run invocation creates:

```text
reports/stack-lifecycle-YYYYMMDDTHHMMSSZ-PID.csv
```

It records the UTC timestamp, run ID, action, resource type and OCID, operation,
before/after states, status, and a safe message. Reports contain infrastructure
identifiers and are excluded by `.gitignore`; they never include key contents,
wallets, or database passwords. Failures are recorded by an exit trap whenever
the report has already been initialized.

### Required IAM scope

Use a dedicated operator group or dynamic group. A broad starting point is
`manage instance-family`, `manage autonomous-database-family`, `read bastion`,
and `manage bastion-session` in the stack compartment. Reduce this with IAM
conditions where possible and validate it with the tenancy security team.

The full runbook includes every flag, least-privilege considerations, test-OCID
examples, CSV fields, troubleshooting, and rollback steps in
[`docs/EXISTING_STACK_LIFECYCLE.md`](docs/EXISTING_STACK_LIFECYCLE.md).
Official command references are the OCI CLI pages for
[Compute instance action](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/instance/action.html),
[Autonomous Database start](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/db/autonomous-database/start.html), and
[Bastion managed SSH session creation](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/bastion/session/create-managed-ssh.html).

## Expired Bastion sessions

Sessions are deliberately temporary. When Compute is already `RUNNING` and ADB
is already `AVAILABLE`, renew only the Terraform-managed session:

```bash
./scripts/renew-bastion-session.sh terraform.tfvars
```

The script targets and replaces the Terraform-managed session resource, creates
a fresh plan instead of reusing a stale plan, waits for the new session to be
`ACTIVE`, and performs a refresh-only apply so configured outputs are recorded.
It does **not** run Ansible, start Compute or ADB, or open SSH.

Connect through the new session:

```bash
./scripts/connect-oracle-server.sh
```

When Compute or ADB may be stopped, use the start workflow instead; it starts
them before creating the session and then opens SSH:

```bash
./scripts/start-and-connect.sh --tfvars terraform.tfvars
```

Run Ansible separately only when Linux provisioning or configuration must be
changed:

```bash
./scripts/run-ansible.sh /secure/keys/bastion_key
```

The equivalent manual session replacement is:

```bash
cd terraform
terraform apply -var-file=terraform.tfvars -replace='module.bastion.oci_bastion_session.ansible[0]'
```

See [`scripts/README.md`](scripts/README.md) for exact responsibilities,
artifact resolution, flags, tests, and troubleshooting.

## Retrying a partial destroy

An Autonomous Database private endpoint uses a service-managed VNIC attached to the database NSG. OCI can briefly return from database deletion before that VNIC has detached, causing NSG deletion to fail with `412-PreconditionFailed`. The module now places `adb_private_endpoint_detach_wait_duration` (default `300s`) between database and NSG deletion.

For the deployment that has already failed during destroy, wait for this command to return an empty `data` list and then rerun destroy:

```bash
oci network nsg vnics list \
  --nsg-id ocid1.networksecuritygroup.oc1.eu-frankfurt-1.aaaa... \
  --all

cd terraform
terraform destroy -var-file=terraform.tfvars
```

Do not run `terraform apply` merely to add the delay to an already-partially-destroyed stack, because it can recreate resources. The barrier protects future deployments after it has first been included in a successful apply.

## Other private connectivity options

OCI Bastion is the default here. Ansible can instead run from a controller that already has private routing into the VCN through Site-to-Site VPN, FastConnect, DRG peering, or a CI runner inside the VCN. In those cases, remove the `ProxyCommand` and connect directly to the private IP.

## Security

- Never commit Terraform state/tfvars, generated inventory, OCI config, or private keys.
- Use a `/32` controller CIDR where possible.
- The NAT Gateway allows outbound connections only; it does not make the server reachable from the Internet.
- Autonomous Database accepts TLS and mTLS SQL connections on TCP 1522 only from the VCN CIDR through its NSG; Database Tools reaches it through a separate service-managed private endpoint.
- Store Terraform state in an encrypted, access-controlled backend because it can contain the database ADMIN password.
- Rotate or revoke the OCI API signing key if the target server is compromised.

## v1.4.0 latest changes

Updated on 2026-08-08, this change separates session renewal, provisioning,
and routine interactive access:

- makes `renew-bastion-session.sh` session-only and removes automatic Ansible;
- adds `start-and-connect.sh` to start stopped Compute/ADB resources, wait for
  ready states, create a fresh Bastion session, and open SSH;
- automatically resolves keys and resource information from existing
  Terraform, connection-cache, and inventory artifacts;
- preserves the tested `manage-existing-stack.sh` lifecycle engine and its
  timestamped CSV reporting;
- adds offline mock tests for renewal, artifact resolution, connect, and
  dry-run behavior; and
- adds [`scripts/README.md`](scripts/README.md), an explicit runbook for every
  script.

See [`RELEASE_NOTES_v1.4.0.md`](RELEASE_NOTES_v1.4.0.md) for compatibility and
operator guidance.

## v1.3.0 changes

Released on 2026-08-07, this update adds safe lifecycle operations for the
already-deployed stack:

- starts existing Compute and Autonomous Database resources from their OCIDs;
- waits for Compute `RUNNING` and Autonomous Database `AVAILABLE` before access;
- creates and validates a new Bastion managed SSH session, with optional
  interactive `--connect`;
- adds explicit `--stop-all` and emergency-only `--force-stop` behavior;
- closes every non-deleted session belonging to the selected Bastion before
  shutdown;
- uses existing Terraform outputs by default and supports full CLI overrides;
- creates a timestamped CSV for every valid operational invocation, including
  planned actions and failures;
- includes an OCI-free mock test using documentation-only test OCIDs; and
- adds the complete operator runbook, release notes, and sanitized local
  location record.

See [`RELEASE_NOTES_v1.3.0.md`](RELEASE_NOTES_v1.3.0.md) for the safety and
compatibility notes.

## v1.1.0 modifications

Released on 2026-07-23, this update makes repeated deployments to different
OCI compartments safe and auditable:

- Uses `compartment_id` from `terraform.tfvars` as the single target
  compartment for the network, Compute, Bastion, Autonomous Database, Database
  Tools, Vault, key, secret, and NSG resources.
- Adds an apply-time Terraform check and the `target_compartment_id` and
  `resource_compartment_ids` outputs to verify the actual resource placement.
- Appends a deterministic compartment-specific suffix to the immutable
  Autonomous Database `db_name` and Bastion name by default. This prevents an
  `ORAPRIV` collision across a tenancy/region and conflicts with an existing
  Bastion when the project is deployed into another compartment.
- Adds `immutable_name_suffix` for an explicit deployment identifier and
  `append_compartment_suffix_to_immutable_names = false` for importing legacy
  unsuffixed resources.
- Adds `scripts/select-compartment-workspace.sh` so independent compartments
  use independent Terraform state workspaces.
- Refuses to leave a workspace containing managed resources unless
  `ALLOW_EXISTING_STATE_WORKSPACE_SWITCH=true` explicitly authorizes a new,
  separate deployment.
- Updates the deployment and Bastion-session renewal scripts to select the
  compartment workspace before applying changes.
- Adds effective ADB/Bastion name and Terraform workspace outputs, and records
  deployment compartment metadata in the generated CSV inventory.
- Documents new-compartment deployment, existing-resource imports, state
  isolation, and recovery of Database Tools outputs after a failed apply.
- Requires and validates Oracle OCI Terraform provider `8.24.x`.

The original pre-update code remains available in the
[`v1.0.0` release](https://github.com/eugsim1/oci-ol8-private-oracle-client/releases/tag/v1.0.0).

## v1.2.0 changes

Released on 2026-07-23, this update adds optional Compute instance-principal
authentication while retaining API-key authentication for backward
compatibility. Existing deployments are unchanged until
`iam_instance_principal_enabled` is set to `true`.

### Terraform IAM resources and placement

The project now includes `terraform/modules/iam_instance_principal`, which
creates a dynamic group matching the current Compute instance and a
least-privilege IAM policy for it.

OCI does **not** allow the dynamic group itself to be deployed into the Compute
compartment. It is a root-tenancy IAM resource and therefore requires
`tenancy_id`. The related policy is deployed into the `compartment_id` supplied
through `terraform.tfvars`, so its grants remain scoped to the Compute
compartment and descendants.

The default rule matches the exact instance OCID:

```text
instance.id = '<module.compute.instance_id>'
```

The security-sensitive
`iam_instance_principal_match_all_instances_in_compartment = true` option is
available for fleets, but is disabled by default because it grants the same
principal permissions to every Compute instance in the compartment.

### Configuration

Enable exact-instance authentication with:

```hcl
tenancy_id                     = "ocid1.tenancy.oc1..aaaa..."
iam_instance_principal_enabled = true
iam_instance_principal_compartment_permissions = [
  "read autonomous-database-family",
]
iam_instance_principal_match_all_instances_in_compartment = false
```

`read autonomous-database-family` is the least-privilege default used to inspect
the Terraform-created Autonomous Database and generate its wallet. Optional
permission fragments such as `read object-family` and `read secret-bundles`
must be added only when the workload needs Object Storage or Vault secret
access.

The identity applying Terraform must be authorized to manage dynamic groups at
the tenancy root and policies in the target Compute compartment.

### Automation behavior

When IAM is enabled, `scripts/run-ansible.sh`:

- reads `iam_instance_principal_enabled` and the OCI region from Terraform;
- selects `oracle_oci_auth_mode: instance_principal` automatically;
- does not require or copy the controller's OCI API config/private key;
- passes `--auth instance_principal` to OCI CLI database and wallet commands;
- configures `OCI_CLI_AUTH=instance_principal` for interactive `oracle`
  sessions; and
- passes `-ip` to the FOCUS loader.

When the feature is disabled, the existing API-key workflow continues to use
`/home/oracle/.oci/config`. `OCI_AUTH_MODE=api_key` or
`OCI_AUTH_MODE=instance_principal` can explicitly override automatic selection
when equivalent external credentials or IAM already exist.

### New verification outputs and report fields

Terraform now exposes:

```bash
terraform output -raw iam_instance_principal_enabled
terraform output -raw iam_dynamic_group_id
terraform output -raw iam_dynamic_group_name
terraform output -raw iam_dynamic_group_compartment_id
terraform output -raw iam_dynamic_group_matching_rule
terraform output -raw iam_policy_id
terraform output -raw iam_policy_name
terraform output -raw iam_policy_compartment_id
terraform output -json iam_policy_statements
```

The generated CSV infrastructure report records the dynamic group, matching
rule, policy, policy compartment, and statements. The existing
`resource_compartment_ids` placement invariant includes the compartment policy
but intentionally excludes the tenancy-level dynamic group.

### Upgrade and validation

After adding `tenancy_id` and enabling the feature, run:

```bash
cd terraform
terraform fmt -recursive
terraform init
terraform validate
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

Allow OCI IAM changes time to propagate before testing from the Compute node:

```bash
oci db autonomous-database get \
  --auth instance_principal \
  --region eu-frankfurt-1 \
  --autonomous-database-id ocid1.autonomousdatabase...
```

This release was statically verified with Oracle OCI Terraform provider
`8.24.0`, Terraform validation, Bash syntax checks, and YAML/Jinja parsing of
the Ansible configuration.

Review the full setup, output checks, verification commands, optional Object
Storage/Vault permissions, cross-compartment limitation, and security notes in
[Compute instance principal IAM](docs/instance-principal.md).

The previous compartment-safe implementation remains available in the
[`v1.1.0` release](https://github.com/eugsim1/oci-ol8-private-oracle-client/releases/tag/v1.1.0).
