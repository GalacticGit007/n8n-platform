# n8n DR recovery scripts — initial scaffold

## Scripts

- `scripts/dr-bootstrap.sh`: installs baseline packages from configured Ubuntu APT repositories, enables Docker, and clones the repository using an already-provisioned GitHub deploy key. It does not create a Kubernetes cluster or restore data.
- `scripts/dr-preflight.sh`: read-only checks for required tools, network, GitHub SSH authentication, AWS STS identity, and S3 prefix list access.
- `scripts/dr-recover.sh`: only runs preflight or prints the recovery plan. PostgreSQL restoration and application deployment are intentionally not implemented yet.

## First-run bootstrap dependency

A bootstrap script cannot download itself from the repository before it exists on the VM. For first-time provisioning, copy `scripts/dr-bootstrap.sh` to the recovery VM through a trusted method. For a real DR event, keep a tested copy outside the primary Git repository (protected recovery media or an independently hosted, checksum-verified release). Do not execute an unverified `curl | bash` command.

## Initial setup on serverx

1. Provision `~/.ssh/n8n-dr-deploy` securely and verify GitHub's SSH host key independently.
2. Copy `scripts/dr-bootstrap.sh` onto the VM.
3. Run it as the normal user, not root:

   ```bash
   chmod 700 dr-bootstrap.sh
   ./dr-bootstrap.sh
   ```

4. After cloning:

   ```bash
   cd ~/dr/n8n-platform
   chmod 700 scripts/dr-*.sh
   scripts/dr-preflight.sh
   scripts/dr-recover.sh --plan
   ```

## Optional configuration

```bash
export DR_REPO_SSH_URL='git@github.com:GalacticGit007/n8n-platform.git'
export DR_ROOT="$HOME/dr"
export DR_S3_BUCKET='n8n-dr-backups-20261023-8f039112'
export DR_S3_PREFIX='cnpg/n8n-db-cluster/'
export AWS_REGION='ap-south-1'
```

Do not place AWS keys, tokens, passwords, private keys, Kubernetes Secret values, or the n8n encryption key in these variables or in Git.

## Known limitations

- AWS credentials must be provided by a separately configured credential provider; the scripts do not create credentials. STS and S3 access are checked without printing secrets.
- S3 list permission does not prove KMS decrypt permission or that a base backup and WAL chain can be restored.
- Bootstrap uses Ubuntu's configured APT repositories; versions of Docker, kubectl, kind and Helm are not yet pinned. Before relying on this for production, pin versions and verify release checksums/signatures.
- The script installs Ubuntu's `docker.io` package. Use `sudo docker` until group access is configured in a separate login session.
- Actual recovery remains unimplemented. `dr-recover.sh --plan` is a plan only and makes no changes.
- Review the repository's ignored `secrets/` and `backups/` directories before pushing. Never commit secret values.
