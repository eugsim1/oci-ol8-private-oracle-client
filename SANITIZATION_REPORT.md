# Sanitization report

Date: 2026-07-21

The source tree was reviewed before its initial GitHub publication. The audit
found no embedded GitHub tokens, private-key blocks, AWS-style access keys,
hardcoded password literals, real long-form OCI OCIDs, Windows user-profile
paths, wallet archives, Terraform state, or credential files in the
publishable source set.

The repository ignore policy excludes:

- Terraform caches, state, variable files, saved plans, and crash logs.
- OCI configuration directories and common private-key/keystore formats.
- Generated Ansible inventory, group variables, and secret directories.
- Autonomous Database wallet archives and extracted wallet credentials.
- Generated CSV, log, environment, and text reports.

Only reusable Terraform modules, Ansible roles/templates, shell wrappers,
documentation, example configuration, the Terraform dependency lock file, and
the empty report-directory marker are intended for publication.

This review reduces accidental disclosure risk but does not replace credential
rotation or an organization-approved secret-scanning pipeline.
