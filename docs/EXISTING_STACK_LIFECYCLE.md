# Operate an existing Compute, Autonomous Database, and Bastion stack

`scripts/manage-existing-stack.sh` operates resources that already exist. It
does not create or change Terraform-managed infrastructure definitions.

The default `--start` workflow is:

1. Resolve the Compute, Autonomous Database, and Bastion OCIDs, region, target
   private IP, and Bastion session public key from the current Terraform state.
2. Inspect both lifecycle states.
3. Send Compute `START` and Autonomous Database `start` only when stopped.
4. Wait for Compute `RUNNING` and Autonomous Database `AVAILABLE`. OCI calls the
   running/ready Autonomous Database state `AVAILABLE`, not `RUNNING`.
5. Create an OCI Bastion `MANAGED_SSH` session to `oracle@PRIVATE_IP:22` and wait
   for it to become `ACTIVE`.
6. Print a usable OpenSSH command. `--connect` also opens the interactive login.
7. Record every inspected, requested, completed, planned, or failed event in a
   timestamped CSV under `reports/`.

The explicit `--stop-all` workflow closes every non-deleted session returned by
the Bastion Session list API, requests Autonomous Database stop, requests a
graceful Compute `SOFTSTOP`, and waits for both resources to reach `STOPPED`.

## 1. Controller requirements

Run the script from an external Linux controller, not from the Compute instance
that the script may stop. Install:

- Bash 4 or later;
- OCI CLI configured with a user profile, instance principal, resource
  principal, or security token;
- Terraform when using the existing state outputs; and
- OpenSSH only when using `--connect`.

Validate the tools and identity:

```bash
bash --version
oci --version
terraform version
oci iam region-subscription list --profile DEFAULT --all
```

The script defaults to OCI CLI profile `DEFAULT`. Use `--profile OPERATIONS` for
another config-file profile or, for example, `--auth instance_principal` on an
authorized OCI controller instance.

## 2. IAM authorization

The selected OCI identity needs permission to inspect and start/stop the exact
Compute instance and Autonomous Database, inspect the Bastion, and manage
Bastion sessions. The following is an intentionally broad starting example for
a dedicated operations group; scope and conditions should be reduced for the
tenancy's security model:

```text
Allow group StackLifecycleOperators to manage instance-family in compartment FinOps
Allow group StackLifecycleOperators to manage autonomous-database-family in compartment FinOps
Allow group StackLifecycleOperators to read bastion in compartment FinOps
Allow group StackLifecycleOperators to manage bastion-session in compartment FinOps
Allow group StackLifecycleOperators to read virtual-network-family in compartment FinOps
```

The last statement supports target network lookup performed by OCI services and
troubleshooting. Policy syntax and resource types can change; validate the
least-privilege policy against current OCI IAM documentation before production.
Do not put API keys, private SSH keys, passwords, Terraform state, or real OCIDs
in Git.

## 3. Confirm the existing Terraform outputs

From the project root:

```bash
terraform -chdir=terraform output -raw instance_id
terraform -chdir=terraform output -raw autonomous_database_id
terraform -chdir=terraform output -raw bastion_id
terraform -chdir=terraform output -raw private_ip
terraform -chdir=terraform output -raw region
terraform -chdir=terraform output -raw bastion_session_public_key_path
```

The expected OCID kinds are:

```text
ocid1.instance.oc1.eu-frankfurt-1...
ocid1.autonomousdatabase.oc1.eu-frankfurt-1...
ocid1.bastion.oc1.eu-frankfurt-1...
```

The compartment OCID is not required by the lifecycle script because each API
operation addresses an existing resource by OCID. IAM policy evaluation still
uses the resources' compartments.

## 4. Make the scripts executable and run a dry run

```bash
chmod +x scripts/manage-existing-stack.sh tests/test-manage-existing-stack.sh

./scripts/manage-existing-stack.sh --dry-run
```

Dry-run mode performs read-only state and session-list calls. It does not start,
stop, or delete resources, and it does not create a Bastion session. Planned
mutations are written to the CSV with status `PLANNED`.

Inspect the newest report:

```bash
latest_report="$(find reports -maxdepth 1 -name 'stack-lifecycle-*.csv' -type f -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
echo "$latest_report"
column -s, -t < "$latest_report"
```

## 5. Start Compute and Autonomous Database and create the session

With the existing Terraform state, no OCIDs are required on the command line:

```bash
./scripts/manage-existing-stack.sh
```

Equivalent explicit form using test OCIDs:

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

The `test...` OCIDs are documentation-only placeholders and will not resolve in
OCI. Replace them with values from the deployed stack.

To start and then log in interactively:

```bash
./scripts/manage-existing-stack.sh \
  --ssh-private-key /secure/keys/bastion_key \
  --connect
```

Without `--connect`, the workflow does not block: it creates the session, waits
for `ACTIVE`, prints the exact ProxyCommand-based SSH command, writes the CSV,
and exits. The public key supplied at session creation must match the private
key used by OpenSSH.

For a controller using an instance principal:

```bash
./scripts/manage-existing-stack.sh \
  --auth instance_principal \
  --region eu-frankfurt-1
```

## 6. Stop every Bastion session, Autonomous Database, and Compute

First preview the shutdown:

```bash
./scripts/manage-existing-stack.sh --stop-all --dry-run
```

Then perform it:

```bash
./scripts/manage-existing-stack.sh --stop-all
```

`--stop-all` means all non-deleted sessions returned for the selected Bastion,
not only sessions created by this script. It can disconnect other operators.
The default Compute action is `SOFTSTOP`, allowing the guest operating system to
shut down gracefully. During an approved emergency only, explicitly request
hard power-off:

```bash
./scripts/manage-existing-stack.sh --stop-all --force-stop
```

If a resource is already in its desired state, the report records `NO_CHANGE`.
If a resource is `STARTING` during shutdown, the script waits for its ready
state before requesting stop. Other unexpected/transitional states fail closed
and remain visible in the CSV.

## 7. Complete flag reference

| Flag | Default | Effect |
|---|---|---|
| `--start` | selected | Start and create a fresh managed SSH session. |
| `--stop-all` | off | Close all selected-Bastion sessions and stop ADB/Compute. |
| `--force-stop` | off | Replace graceful Compute `SOFTSTOP` with `STOP`. |
| `--connect` | off | Open interactive SSH after session activation. |
| `--dry-run` | off | Read state and report planned mutations only. |
| `--instance-id` | Terraform output | Existing Compute instance OCID. |
| `--autonomous-database-id` | Terraform output | Existing Autonomous Database OCID. |
| `--bastion-id` | Terraform output | Existing Bastion OCID. |
| `--private-ip` | Terraform output | Compute VNIC private IPv4 target. |
| `--region` | environment/Terraform | OCI region, for example `eu-frankfurt-1`. |
| `--ssh-public-key` | Terraform output | Public key sent to Bastion. |
| `--ssh-private-key` | inferred `.pub` peer | Matching private key for `--connect`. |
| `--terraform-dir` | `PROJECT/terraform` | Directory containing the current state. |
| `--profile` | `DEFAULT` | OCI CLI config profile. |
| `--auth` | OCI CLI default | Explicit OCI CLI authentication mode. |
| `--os-user` | `oracle` | Managed SSH target username. |
| `--target-port` | `22` | Managed SSH target port. |
| `--session-ttl` | `10800` | Bastion lifetime in seconds, 30-10800. |
| `--session-display-name` | timestamped | Name of the new Bastion session. |
| `--wait-seconds` | `3600` | Maximum state wait. |
| `--poll-seconds` | `10` | State polling interval. |
| `--report-dir` | `PROJECT/reports` | Timestamped CSV directory. |

Environment equivalents used by automation are `OCI_CLI_PROFILE`,
`OCI_CLI_REGION`, `OCI_CLI_BIN`, and `TERRAFORM_BIN`. `OCI_CLI_BIN` and
`TERRAFORM_BIN` primarily support controlled test harnesses and nonstandard
installations.

## 8. CSV report

Every valid operational invocation creates:

```text
reports/stack-lifecycle-YYYYMMDDTHHMMSSZ-PID.csv
```

Columns are:

```text
timestamp_utc,run_id,mode,resource_type,resource_ocid,operation,
before_state,after_state,status,message
```

Reports intentionally contain resource and session OCIDs and are ignored by
Git. Protect and retain them according to the organization's audit policy. No
key content, database password, wallet content, or OCI signing material is
written.

## 9. Offline test

The included test uses fake OCI responses and test OCIDs. It never contacts OCI:

```bash
bash -n scripts/manage-existing-stack.sh
bash -n tests/test-manage-existing-stack.sh
./tests/test-manage-existing-stack.sh
```

The assertions cover a mutation-free dry run, stopped-to-running transitions,
ADB `AVAILABLE`, session creation and activation, deletion of two previous
sessions, graceful Compute shutdown, ADB shutdown, and three independent CSV
reports.

## 10. Troubleshooting and rollback

### OCI returns NotAuthorizedOrNotFound

Verify the selected `--profile`/`--auth`, region, OCID, and policy scope. OCI can
return the same status for a missing resource and an unauthorized identity.

### A resource remains transitional

Increase `--wait-seconds`, inspect the OCI work requests and service events, and
rerun after the state stabilizes. The script does not retry an unsafe state by
issuing a second mutation blindly.

### Bastion session cannot become ACTIVE

Confirm the Bastion plugin is `RUNNING` on the Compute instance, the Bastion can
reach the private IP/port, the public key file is valid, and the operating-system
user exists. Inspect:

```bash
oci compute instance-agent plugin list \
  --instanceagent-id INSTANCE_OCID \
  --compartment-id COMPARTMENT_OCID

oci bastion session list --bastion-id BASTION_OCID --all
```

### Reverse an unintended start

Review the timestamped CSV, then run the explicit stop preview and apply:

```bash
./scripts/manage-existing-stack.sh --stop-all --dry-run
./scripts/manage-existing-stack.sh --stop-all
```

### Reverse an unintended stop

Rerun the default start workflow. Deleted Bastion sessions cannot be restored;
the start workflow creates a new temporary session by design.

## Official OCI CLI command references

- [Compute instance action](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/instance/action.html)
- [Autonomous Database start](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/db/autonomous-database/start.html)
- [OCI Bastion managed SSH session creation](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/bastion/session/create-managed-ssh.html)
- [OCI Bastion session list](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/bastion/session/list.html)
- [OCI Bastion session delete](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/bastion/session/delete.html)

This project is an independent community reference implementation, not an
Oracle product, and is not affiliated with, endorsed by, or supported by Oracle
Corporation. Validate all commands and policies in a non-production tenancy.
