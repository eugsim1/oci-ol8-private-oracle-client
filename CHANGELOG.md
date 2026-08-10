# Changelog

All notable operational changes to this project are documented here.

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
