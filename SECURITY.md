# Security

## Sensitive inputs

Never commit Terraform state, variable files, saved plans, OCI configuration,
API private keys, SSH private keys, generated Ansible inventory/group variables,
Autonomous Database wallets, or deployment reports.

Supply the Autonomous Database ADMIN password from the controller environment:

```bash
read -rsp "ADB ADMIN password: " TF_VAR_adb_admin_password
echo
export TF_VAR_adb_admin_password
```

Supply wallet, SQL test, VNC, and optional loader passwords through the
environment variables documented in `README.md`. Terraform marks password
variables as sensitive, but sensitive values can still be present in state.
Use an encrypted remote backend with tightly scoped access for production.

## Before committing

Review staged files and run a secret scanner appropriate for your organization.
At minimum, confirm that only the `.example` Terraform and Ansible configuration
files are staged:

```bash
git status --short
git diff --cached --check
git grep -nE 'gh[pousr]_[A-Za-z0-9]{20,}|BEGIN .*PRIVATE KEY|ocid1\..*[a-z0-9]{24,}'
```

If a credential has ever been committed, removing it from the current tree is
not sufficient. Revoke or rotate it immediately and purge it from Git history.

## Reporting a vulnerability

Do not open a public issue containing credentials, OCIDs, IP addresses, wallet
files, Terraform state, or logs. Contact the repository owner privately and
include only sanitized reproduction details.
