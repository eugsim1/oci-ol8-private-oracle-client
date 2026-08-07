# v1.3.0 - Existing stack lifecycle operations

Released 2026-08-07.

## Added

- `scripts/manage-existing-stack.sh` starts an existing Terraform-managed OCI
  Compute instance and Autonomous Database, waits for Compute `RUNNING` and ADB
  `AVAILABLE`, and creates a fresh OCI Bastion managed SSH session.
- `--stop-all` closes every non-deleted session returned for the specified
  Bastion, stops Autonomous Database, and gracefully stops Compute with
  `SOFTSTOP`. `--force-stop` explicitly selects the non-graceful `STOP` action.
- Existing resource OCIDs, region, target private IP, and session public-key
  path are read from Terraform outputs by default. Explicit flags support
  imported or externally managed resources.
- `--dry-run` performs read-only OCI state discovery and records planned
  actions without changing resources.
- `--connect` optionally opens interactive SSH after session creation; normal
  start mode creates the session and prints the exact SSH command without
  blocking an automation workflow.
- Every valid lifecycle invocation creates an ignored, timestamped CSV audit
  under `reports/`, including success, no-change, planned, requested, and
  failure events.
- `tests/test-manage-existing-stack.sh` validates mutation-free dry-run, start,
  waits, session creation, stop-all, graceful Compute shutdown, ADB shutdown,
  and CSV output against test OCIDs without contacting OCI.
- `Location.md` records the requested sanitized local path.

## Safety notes

- Run stop operations from an external controller. Running `--stop-all` on the
  managed Compute instance can terminate the script before its final CSV rows
  are written.
- The script does not create, update, or destroy Terraform resources. It calls
  lifecycle and Bastion Session APIs for the existing OCIDs.
- `--stop-all` is intentionally explicit because it closes all active or
  in-progress sessions belonging to the selected Bastion and stops billable
  services.
- Review IAM policy scope and test `--dry-run` before the first live execution.

This remains an independent community project and is not an Oracle product or
an Oracle-supported utility. See the repository disclaimer and MIT license.
