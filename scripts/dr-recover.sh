#!/usr/bin/env bash
# Guarded recovery entry point. Actual restore/deploy stages are not implemented yet.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
case "${1:-}" in
  --preflight-only) exec "$SCRIPT_DIR/dr-preflight.sh" ;;
  --plan)
    cat <<EOF
PLAN ONLY — no resources changed.
Repository: $REPO_ROOT
1. Run read-only preflight.
2. Verify AWS identity, exact S3 access and KMS decrypt permission.
3. Validate selected base backup and complete WAL recovery chain.
4. Create an isolated, single-node kind recovery cluster.
5. Install pinned CNPG operator and Barman plugin/chart versions.
6. Restore PostgreSQL into a NEW recovery cluster/namespace.
7. Restore the original n8n encryption key and required binary data securely.
8. Deploy Redis and n8n from reviewed configuration.
9. Validate schema, workflows, credential decryption, health and a test workflow.
10. Write a Markdown report with evidence, timestamps, RPO and RTO.
No restore, deployment, deletion, or traffic switch is performed by this script yet.
EOF
    ;;
  *)
    echo "Usage: $0 --preflight-only | --plan" >&2
    exit 2
    ;;
esac
