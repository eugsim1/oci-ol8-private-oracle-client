# Changelog

All notable operational changes to this project are documented here.

## 1.8.1 - 2026-08-11

- Documented that `output_assets.txt` is input to
  `connect-streamlit-from-terraform.ps1`, not directly to the lower-level
  `connect-streamlit-api-key-auth.ps1` connector.
- Added explicit Windows and Linux/PowerShell 7 execution commands, the
  connector flow, required path entries, and cross-platform path guidance.

## 1.8.0 - 2026-08-11

- Added `scripts/generate-output-assets.sh` for Oracle Linux 8 and other Bash
  controllers.
- Read individual Terraform outputs without requiring `jq`, parse the selected
  OCI API-key profile, validate identifiers and local files, and atomically
  write `output_assets.txt` with mode `0600`.
- Added an offline Linux integration test and CI coverage for the generator.

## 1.7.0 - 2026-08-11

- Added the standalone `scripts/generate-output-assets.ps1` command.
- The generator reads Terraform outputs and the selected OCI API-key profile,
  validates all paths and identifiers, and writes `scripts/output_assets.txt`
  without creating a Bastion session or opening SSH.
- Updated the offline PowerShell integration test to generate the inventory
  through the standalone command before testing connection-from-file.

## 1.6.0 - 2026-08-11

- Added a validated `scripts/output_assets.txt` runtime inventory for the
  Streamlit Bastion connection parameters.
- Added `-RefreshAssets -AssetsOnly` to regenerate the inventory from the
  selected Terraform state and OCI API-key profile without opening a session.
- Changed the normal launcher flow to read the local inventory and connect
  without repeating OCIDs, profile values, or key paths on the command line.
- Added a safe committed example and ignored the real local asset inventory.

## 1.5.1 - 2026-08-11

- Made `-SshPrivateKeyPath` an explicit mandatory launcher parameter.
- Documented the optional `-SshPublicKeyPath` parameter for key pairs whose
  public key is not stored beside the private key.

## 1.5.0 - 2026-08-11

- Added `scripts/connect-streamlit-from-terraform.ps1` for Windows clients.
- Resolve Bastion OCID, Compute OCID, private IP, and region from the current
  Terraform state instead of requiring manually copied values.
- Resolve the OCI user, tenancy, fingerprint, and API signing-key path from a
  selected profile in `$HOME\.oci\config`.
- Added strict identifier, IP address, profile, and key-file validation plus a
  dry-run workflow.
- Added an offline PowerShell integration test and Windows CI coverage.

## 1.4.1 - 2026-08-10

- Added a readiness gate that waits for the Compute instance's `Bastion`
  Oracle Cloud Agent plugin to report `RUNNING` before creating a Bastion
  session.
- Added numbered plugin polling iterations to the console and the configurable
  `--bastion-plugin-wait-seconds` timeout.
- Kept OCI CLI warnings on stderr so they can no longer corrupt parsed lifecycle
  states.
- Added `scripts/stop-all.sh` as the focused command for closing Bastion
  sessions and stopping Autonomous Database and Compute.
- Expanded the offline shell tests for OCI warnings, plugin polling, and the
  stop-all wrapper.
- Added Linux CI and changelog-driven GitHub release automation for successful
  pushes to `main`.

## 1.4.0 - 2026-08-08

- See [`RELEASE_NOTES_v1.4.0.md`](RELEASE_NOTES_v1.4.0.md).

## 1.3.0 - 2026-07-23

- See [`RELEASE_NOTES_v1.3.0.md`](RELEASE_NOTES_v1.3.0.md).
