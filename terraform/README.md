# Private OCI Terraform project

The modules create a private Oracle Linux 8 workload, outbound NAT connectivity, a temporary OCI Bastion managed SSH session, an Autonomous AI Database with a private endpoint, and an OCI Database Tools connection through its own service-managed private endpoint. The compute VNIC has `assign_public_ip = false`, and the private subnet prohibits public IPs.

The Compute module enforces IMDSv2-only access by setting `instance_options.are_legacy_imds_endpoints_disabled = true`; legacy `/opc/v1` metadata endpoints are unavailable.

The Bastion controller CIDR is restricted by default. If an exceptional test environment genuinely requires `0.0.0.0/0`, both values must be explicit:

```hcl
controller_public_cidr  = "0.0.0.0/0"
allow_open_bastion_cidr = true
```

Leave `allow_open_bastion_cidr = false` for normal deployments.

Set the compute node's OCI display name in `terraform.tfvars`:

```hcl
compute_node_name = "oracle-app-01"
```

The value is also used as the naming prefix for the VCN, subnet, Bastion, and related resources.

## Deploying the same project to another compartment

`compartment_id` in `terraform.tfvars` is now the single source of truth for
every Terraform-created resource. The root module passes that value to the
network, Compute, Bastion, Autonomous Database, and Database Tools modules.
After an apply, Terraform also checks the compartment reported by every
created resource. These outputs make the result directly auditable:

```bash
terraform output -raw target_compartment_id
terraform output -json resource_compartment_ids
```

The second command must return only the value shown by the first command.
Bastion sessions and NSG rules do not accept a separate compartment argument;
they inherit the compartment of their parent Bastion or NSG.

Changing a compartment does not make an Autonomous Database name reusable.
Oracle requires `db_name` to be unique across the tenancy in the same region.
Bastion names can also conflict with an existing Bastion. By default this
project appends a stable suffix derived from `compartment_id` to those two
immutable names:

```hcl
append_compartment_suffix_to_immutable_names = true
immutable_name_suffix                        = null
```

For example, the configured `ORAPRIV` database name becomes something similar
to `ORAPRIV8A31F4C2`. Set `immutable_name_suffix = "FRATEST2"` when you prefer
an explicit deployment identifier. The effective values are available as:

```bash
terraform output -raw effective_autonomous_database_name
terraform output -raw effective_bastion_name
```

Do not reuse one Terraform state for independent deployments. Before planning
a new compartment, select the deterministic compartment workspace:

```bash
cd ..
bash scripts/select-compartment-workspace.sh terraform.tfvars
cd terraform
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

The end-to-end `scripts/deploy.sh` wrapper performs this workspace selection
automatically. If the currently selected workspace already manages resources,
the helper stops instead of silently switching state. For a deliberate new
deployment that must leave the current workspace untouched:

```bash
ALLOW_EXISTING_STATE_WORKSPACE_SWITCH=true \
  bash scripts/select-compartment-workspace.sh terraform.tfvars
```

This override selects a different workspace; it does not move or delete the
resources recorded in the original workspace.

### Existing ORAPRIV or Bastion resources

Choose one of these mutually exclusive approaches:

1. For a new environment in another compartment, keep
   `append_compartment_suffix_to_immutable_names = true`, select the new
   compartment workspace, review the plan, and create new resources.
2. To make Terraform manage existing legacy resources, set
   `append_compartment_suffix_to_immutable_names = false` and import their
   OCIDs into the correct workspace:

```bash
terraform import -var-file=terraform.tfvars \
  'module.autonomous_database.oci_database_autonomous_database.this' \
  'ocid1.autonomousdatabase...'

terraform import -var-file=terraform.tfvars \
  'module.bastion.oci_bastion_bastion.this' \
  'ocid1.bastion...'

terraform plan -var-file=terraform.tfvars
```

Never import a resource from `TestAssets` into a state intended for a different
compartment. Import means “manage this existing object”; it does not move it.

The Database Tools outputs are defined in `outputs.tf`, but Terraform records
new output definitions in state only after an apply or refresh-only apply
completes. If an earlier apply failed before outputs were recorded, fix the
resource conflict first and then run:

```bash
terraform apply -refresh-only -var-file=terraform.tfvars
terraform output database_tools_connection_id
terraform output database_tools_private_endpoint_ip
terraform output database_tools_runtime_endpoint
```

When `database_tools_enabled = false`, the resource values are `null`;
Terraform can omit null-valued outputs from state. Check
`terraform output -raw database_tools_enabled` before requesting the
Database Tools resource outputs.

## Conditional managed SSH session

The Bastion service is always deployed. Creation of its temporary managed SSH session is controlled separately:

```hcl
create_bastion_session          = true
bastion_session_public_key_path = "/home/admin/.ssh/bastion_ed25519.pub"
```

Terraform reads this OpenSSH public key from the controller filesystem with `file()` and supplies its content to OCI Bastion. Keep the matching private key on the controller and pass it as the third argument to the end-to-end script. If `bastion_session_public_key_path = null`, the session reuses `ssh_public_key_path`.

With `create_bastion_session = false`, Terraform creates the Bastion service but skips the plugin wait, plugin status test, and session resource. Session outputs are `null`, and the CSV records the session as `not created`. Ansible then requires separate private routing from its controller to the compute subnet; the supplied deployment wrapper stops before Ansible because its generated inventory is Bastion-specific.

Terraform queries the availability domains visible to `compartment_id`, sorts their names, and selects index `0` by default. You no longer need to enter an availability-domain name. In a multi-AD region, set `availability_domain_index` to `1` or `2` if required.

```bash
cp terraform.tfvars.example terraform.tfvars
read -rsp "ADB ADMIN password: " TF_VAR_adb_admin_password
export TF_VAR_adb_admin_password
terraform init
terraform fmt -recursive
terraform validate
cd ..
bash scripts/select-compartment-workspace.sh terraform.tfvars
cd terraform
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
terraform output
```

### Autonomous Database version

Choose the version in `terraform.tfvars`:

```hcl
adb_db_version = "19c"
```

or:

```hcl
adb_db_version = "26ai"
```

Only `19c`, `26ai`, or `null` are accepted. `null` omits the version from the
create request and lets OCI use its current regional default. Verify availability
for the selected workload and region before applying:

```bash
oci db autonomous-db-version list \
  --compartment-id "$COMPARTMENT_OCID" \
  --db-workload OLTP \
  --region eu-frankfurt-1 \
  --all \
  --query 'data[].version'
```

Confirm the actual service-reported version after apply:

```bash
terraform output -raw autonomous_database_version
```

Changing the value for an existing database is a database-version operation.
Review the plan and maintenance implications before applying; `26ai` to `19c`
must not be treated as a Terraform rollback.

Inspect the discovered and selected domains with:

```bash
terraform output available_availability_domains
terraform output selected_availability_domain
```

## Terraform infrastructure CSV report

Every successful apply writes a complete, current inventory to:

```text
../reports/terraform-resources.csv
```

Display its resolved path with:

```bash
terraform output -raw terraform_csv_report
```

The report contains network identifiers, Compute OCID/name/state/image/shape/OCPUs/memory/boot size/private and public IP/IMDS mode, Bastion and session identifiers/states/plugin status/SSH command, Autonomous Database configuration/private endpoint/private IP/NSG/TLS descriptor, Database Tools connection and private-endpoint details, and Vault/key/secret OCIDs. Passwords, secret contents, wallet contents, and private keys are deliberately excluded. The file is refreshed in place on each apply.

`modules/autonomous_database` uses the recommended ECPU compute model and creates an NSG ingress rule for TCP 1522 from the VCN CIDR. By default it permits both one-way TLS and mTLS: Database Tools consumes the generated one-way TLS `HIGH` descriptor, while downloaded-wallet clients can continue using mTLS. Configure its name, database version, workload, compute, storage, license model, endpoint label, and TLS policy in `terraform.tfvars`.

The password is intentionally absent from the example file. Terraform marks it sensitive, but sensitive values can still exist in state; use an encrypted remote backend with tightly scoped access.

## OCI Database Tools private connection

`modules/database_tools` derives the related Autonomous Database OCID, private
subnet, VCN, database NSG, display name, `ADMIN` user, and one-way TLS `HIGH`
connection descriptor from resources created by this Terraform project. No ADB
hostname, private IP, service name, or connect descriptor is entered manually.

The module creates:

1. A Database Tools private endpoint in the project private subnet, attached to
   a dedicated NSG whose only SQL egress is TCP 1522 to the Autonomous Database
   NSG.
2. A default OCI Vault, software AES key, and password secret containing the
   supplied `TF_VAR_adb_admin_password` when no existing secret is selected.
3. An `ORACLE_DATABASE` Database Tools connection related directly to the
   Terraform-created Autonomous Database.

Defaults are:

```hcl
adb_is_mtls_connection_required = false
database_tools_enabled          = true
database_tools_runtime_identity = "AUTHENTICATED_PRINCIPAL"
database_tools_vault_dns_wait_duration = "120s"
```

Setting `adb_is_mtls_connection_required = false` allows both TLS and mTLS; it
does not disable wallet-based mTLS. The Database Tools module rejects a
password connection when the ADB is configured as mTLS-only because that path
would also require Vault secrets for wallet keystore content.

To reuse an existing Vault secret instead of creating a dedicated Vault and
key, set:

```hcl
database_tools_password_secret_id = "ocid1.vaultsecret..."
```

Terraform discovers the active Database Tools endpoint service in the target
compartment. If the tenancy exposes more specialized endpoint services or
discovery is restricted by IAM, provide
`database_tools_endpoint_service_id` explicitly.

The default `AUTHENTICATED_PRINCIPAL` runtime identity means the OCI user using
the connection must be allowed to read its Vault secret. If you select
`RESOURCE_PRINCIPAL`, configure the required Database Tools connection dynamic
group and secret-read policy before using SQL Worksheet. The Terraform caller
also needs permissions for `database-tools-family`, virtual networking,
Autonomous Database, Vaults, Keys, and `secret-family`.

Inspect the created artifacts with:

```bash
terraform output database_tools_connection_id
terraform output database_tools_connection_state
terraform output database_tools_private_endpoint_id
terraform output database_tools_private_endpoint_ip
terraform output database_tools_private_endpoint_fqdn
terraform output database_tools_password_secret_id
```

When Terraform creates a new Vault, it waits 120 seconds before creating the
KMS key. OCI can return the Vault management endpoint before its unique DNS
record is resolvable, otherwise producing a `lookup ...-management.kms... no
such host` error. Increase `database_tools_vault_dns_wait_duration` (for
example, to `300s`) if DNS propagation is slower in the controller's network.
The wait is skipped when `database_tools_password_secret_id` selects an
existing secret.

The Bastion session lasts up to `bastion_session_ttl_seconds`. Terraform reads the compute login key from `ssh_public_key_path` using `file()` and installs it for both `opc` and the cloud-init-created `oracle` account. By default the session uses that key too; set `bastion_session_public_key_path` to use a separate filesystem-loaded session key. The session targets `oracle`. Its matching private key stays on the controller and is read by Ansible.

## Bastion plugin readiness

Module order is explicit: `network -> compute -> bastion` and `network -> autonomous_database -> database_tools`. This also forces the Database Tools private-endpoint VNIC to detach before Terraform destroys the shared database NSG. The Compute module enables the Bastion plugin and both Cloud Agent management flags. When `create_bastion_session = true`, before creating a managed SSH session the Bastion module:

1. Waits for `bastion_plugin_wait_duration` (`600s` by default, matching OCI's documented maximum propagation window).
2. Reads the live `Bastion` plugin status from OCI Compute Instance Agent.
3. Enforces a Terraform precondition requiring `RUNNING`.
4. Creates the Bastion session only after that test succeeds.

Inspect the test result with:

```bash
terraform output bastion_plugin_status
terraform output bastion_plugin_message
```

For a slow image, increase the wait in `terraform.tfvars`:

```hcl
bastion_plugin_wait_duration = "600s"
```

The wait duration is included in the `time_sleep` triggers. Changing it therefore replaces the wait resource and performs the new delay instead of merely updating the value in state.

## Bastion plugin is Enabled but Stopped

`Enabled` is the requested plugin configuration; `Stopped` means the plugin process is not operational. The network module provides both paths required by a private Linux instance:

- A Service Gateway route to all regional services in the Oracle Services Network for Oracle Cloud Agent traffic.
- A NAT Gateway default route for Linux packages, OCI CLI, Python, and Instant Client downloads.

After upgrading this project from the earlier 300-second version, run a normal apply. The changed wait trigger forces a new 600-second readiness interval:

```bash
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

If the plugin remains `STOPPED`, create a temporary **SSH port forwarding** Bastion session to the compute private IP and port 22. This session type does not require Oracle Cloud Agent. Connect through the generated tunnel and run on Oracle Linux:

```bash
sudo rpm -q oracle-cloud-agent
sudo systemctl enable --now oracle-cloud-agent
sudo systemctl restart oracle-cloud-agent
sudo systemctl status oracle-cloud-agent --no-pager
sudo journalctl -u oracle-cloud-agent -n 200 --no-pager
```

Also confirm that the private subnet uses the project route table and that its egress security rule still permits outbound traffic. When the OCI Console shows the Bastion plugin as `Running`, rerun Terraform to create the managed SSH session.

After deployment, follow `../ansible/README.md`, or run the root `scripts/deploy.sh` wrapper.

Destroy all resources with:

```bash
terraform plan -destroy -var-file=terraform.tfvars -out=destroy.tfplan
terraform apply destroy.tfplan
```

## NSG deletion during Autonomous Database destroy

OCI may finish the Autonomous Database delete operation before its service-managed private-endpoint VNIC has detached from the database NSG. The Autonomous Database module includes a destroy barrier with this default:

```hcl
adb_private_endpoint_detach_wait_duration = "300s"
```

Its dependency order is database deletion, VNIC-detach wait, then NSG deletion. Increase the value to `600s` if detach operations in the region regularly take longer. The delay must have been applied into Terraform state before destroy starts.

For a deployment already in a partially destroyed state, do not apply again because that could recreate the database. List the remaining NSG attachments, wait until the list is empty, and retry the same destroy command:

```bash
oci network nsg vnics list --nsg-id <database-nsg-ocid> --all
terraform destroy -var-file=terraform.tfvars
```

If the VNIC remains after the Autonomous Database has fully terminated, record the returned VNIC and parent-resource OCIDs and open an Oracle Support request rather than force-removing an unknown service-managed attachment.

## Compute instance principal IAM

Set `iam_instance_principal_enabled = true` and supply the root `tenancy_id` to
create an exact-instance dynamic group for `module.compute.instance_id`. OCI
requires that dynamic group to be a tenancy-level IAM resource; it cannot be
placed in the Compute compartment. The module does place the corresponding
policy in `compartment_id`, and all generated statements are scoped to that
compartment.

```hcl
tenancy_id                     = "ocid1.tenancy.oc1..aaaa..."
iam_instance_principal_enabled = true
iam_instance_principal_compartment_permissions = [
  "read autonomous-database-family",
]
iam_instance_principal_match_all_instances_in_compartment = false
```

Verify the mandatory placement split:

```bash
terraform output -raw iam_dynamic_group_compartment_id
terraform output -raw iam_policy_compartment_id
terraform output -raw iam_dynamic_group_matching_rule
terraform output -json iam_policy_statements
```

The first value must equal `tenancy_id`; the second must equal
`compartment_id`. The normal `resource_compartment_ids` invariant includes the
compartment policy and intentionally excludes the tenancy-level dynamic group.
See [Compute instance principal IAM](../docs/instance-principal.md) for
permissions, Ansible integration, verification, propagation behavior, and
security guidance.
