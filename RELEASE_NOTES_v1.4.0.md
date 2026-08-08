# v1.4.0 - Session-only renewal and start-to-SSH workflow

Main-branch update dated 2026-08-08.

## Changed

- `scripts/renew-bastion-session.sh` now has one responsibility: replace the
  Terraform-managed Bastion session, refresh outputs, and wait for `ACTIVE`.
- Renewal no longer invokes Ansible and no longer accepts a private-key
  argument. Provisioning remains an explicit `run-ansible.sh` operation.
- `select-compartment-workspace.sh` respects `TERRAFORM_BIN`, improving
  testability and support for controlled Terraform installation paths.
- The distribution's existing `adb_db_version` support is now preserved in the
  Git history and accepts `19c`, `26ai`, or `null` for the OCI regional default.

## Added

- `scripts/start-and-connect.sh` selects the compartment workspace, resolves
  the existing SSH artifacts, starts stopped Compute and Autonomous Database
  resources, waits for their ready states, creates a fresh Bastion managed SSH
  session, and opens interactive SSH without Ansible.
- The wrapper delegates OCI mutations, waits, and CSV reporting to the tested
  `manage-existing-stack.sh` lifecycle engine.
- `scripts/README.md` documents every script, artifact source, decision path,
  flag, safety boundary, example, and troubleshooting check.
- `tests/test-bastion-session-scripts.sh` validates session-only renewal,
  Terraform replacement/refresh calls, matching public/private key resolution,
  connect behavior, and mutation-free dry-run behavior using mocks.

## Operator guidance

- Use `start-and-connect.sh` when Compute or ADB may be stopped.
- Use `renew-bastion-session.sh` only when resources are already running and
  the Terraform-managed session alone has expired.
- Use `run-ansible.sh` only when host provisioning or configuration is needed.
- Run `start-and-connect.sh --dry-run` before the first live lifecycle action.

This remains an independent community project and is not an Oracle product or
an Oracle-supported utility. Review `SECURITY.md` and the project disclaimer
before production use.
