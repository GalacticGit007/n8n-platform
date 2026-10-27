
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# -------------------------------------------------------------------
# Configuration: override any value through environment variables.
# -------------------------------------------------------------------
PROJECT_DIR="${PROJECT_DIR:-$HOME/Study/DevOps/Projects/n8n-platform}"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_DIR/backups/automated}"
NAMESPACE="${NAMESPACE:-default}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
S3_BUCKET="${S3_BUCKET:-n8n-dr-backups-20261023-8f039112}"
KMS_KEY_ARN="${KMS_KEY_ARN:-arn:aws:kms:ap-south-1:761595200834:key/d51a8888-7514-4282-b442-be677d153974}"

PYTHON="${PYTHON:-$PROJECT_DIR/.venv-backup/bin/python}"
ENCRYPT_SCRIPT="${ENCRYPT_SCRIPT:-$PROJECT_DIR/scripts/encrypt_n8n_backup.py}"
DECRYPT_SCRIPT="${DECRYPT_SCRIPT:-$PROJECT_DIR/scripts/decrypt_n8n_backup.py}"

cd "$PROJECT_DIR"

# -------------------------------------------------------------------
# Preflight checks
# -------------------------------------------------------------------
for cmd in kubectl tar sha256sum aws python3 cmp date git; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Required command missing: $cmd" >&2
        exit 1
    }
done

[[ -x "$PYTHON" ]] || {
    echo "ERROR: Virtualenv Python not executable: $PYTHON" >&2
    exit 1
}
[[ -r "$ENCRYPT_SCRIPT" ]] || {
    echo "ERROR: Encryption script missing: $ENCRYPT_SCRIPT" >&2
    exit 1
}
[[ -r "$DECRYPT_SCRIPT" ]] || {
    echo "ERROR: Decryption script missing: $DECRYPT_SCRIPT" >&2
    exit 1
}
[[ -n "$S3_BUCKET" && -n "$AWS_REGION" && -n "$KMS_KEY_ARN" ]] || {
    echo "ERROR: S3 bucket, AWS region, and KMS key ARN are required." >&2
    exit 1
}

# Check AWS credentials without printing credential material.
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null

# -------------------------------------------------------------------
# Per-run paths
# -------------------------------------------------------------------
BACKUP_ID="$(date +%Y%m%dT%H%M%S%z)"
BACKUP_DIR="$BACKUP_ROOT/$BACKUP_ID"
PAYLOAD_DIR="$BACKUP_DIR/package"
PAYLOAD="$BACKUP_DIR/n8n-backup.tar"
ENCRYPTED="$BACKUP_DIR/n8n-backup.tar.encrypted"
DOWNLOADED="$BACKUP_DIR/n8n-backup.downloaded.encrypted"
RESTORED="$BACKUP_DIR/n8n-backup.restored.tar"
S3_KEY="backups/$BACKUP_ID/n8n-backup.tar.encrypted"

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
mkdir "$BACKUP_DIR"  # Fail rather than reuse a same-second backup directory.
mkdir -p "$PAYLOAD_DIR/recovery-material"
chmod 700 "$BACKUP_DIR" "$PAYLOAD_DIR"

cleanup() {
    rc=$?
    if (( rc != 0 )); then
        echo "ERROR: Backup run failed (exit $rc)." >&2
        echo "Incomplete artifacts retained at: $BACKUP_DIR" >&2
        echo "Do not treat this backup as complete." >&2
    fi
}
trap cleanup EXIT

echo "Backup ID: $BACKUP_ID"

# -------------------------------------------------------------------
# Discover ready pods by stable labels
# -------------------------------------------------------------------
POSTGRES_POD="$(
    kubectl get pods -n "$NAMESPACE" -l app=postgres \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}'
)"
N8N_POD="$(
    kubectl get pods -n "$NAMESPACE" -l app=n8n \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}'
)"

[[ -n "$POSTGRES_POD" && -n "$N8N_POD" ]] || {
    echo "ERROR: Could not discover running PostgreSQL and n8n pods." >&2
    exit 1
}

# Check that the selected pods are ready.
kubectl wait -n "$NAMESPACE" --for=condition=Ready \
    "pod/$POSTGRES_POD" --timeout=60s
kubectl wait -n "$NAMESPACE" --for=condition=Ready \
    "pod/$N8N_POD" --timeout=60s

echo "PostgreSQL pod: $POSTGRES_POD"
echo "n8n pod: $N8N_POD"

GIT_REVISION="$(git rev-parse HEAD)"

# -------------------------------------------------------------------
# 1. PostgreSQL dump
# -------------------------------------------------------------------
kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- sh -c '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc
' > "$PAYLOAD_DIR/n8n-postgres.dump"

test -s "$PAYLOAD_DIR/n8n-postgres.dump"
echo "PostgreSQL dump created."

# -------------------------------------------------------------------
# 2. n8n filesystem archive
# -------------------------------------------------------------------
kubectl exec -n "$NAMESPACE" "$N8N_POD" -- \
    tar -czf - -C /home/node/.n8n . \
    > "$PAYLOAD_DIR/n8n-filesystem.tar.gz"

test -s "$PAYLOAD_DIR/n8n-filesystem.tar.gz"
tar -tzf "$PAYLOAD_DIR/n8n-filesystem.tar.gz" >/dev/null
echo "n8n filesystem archive created."

# -------------------------------------------------------------------
# 3. Recovery Secrets
# -------------------------------------------------------------------
for secret in n8n-db-credentials n8n-encryption-key redis-credentials; do
    kubectl get secret "$secret" -n "$NAMESPACE" -o yaml \
        > "$PAYLOAD_DIR/recovery-material/$secret.yaml"
    chmod 600 "$PAYLOAD_DIR/recovery-material/$secret.yaml"
done

echo "Recovery material exported."

# -------------------------------------------------------------------
# 4. Checksums for backup components
# -------------------------------------------------------------------
(
    cd "$PAYLOAD_DIR"
    sha256sum \
        n8n-postgres.dump \
        n8n-filesystem.tar.gz \
        recovery-material/n8n-db-credentials.yaml \
        recovery-material/n8n-encryption-key.yaml \
        recovery-material/redis-credentials.yaml \
        > SHA256SUMS

    sha256sum --check SHA256SUMS
)

# -------------------------------------------------------------------
# 5. Manifest
# -------------------------------------------------------------------
python3 - "$PAYLOAD_DIR/manifest.json" "$BACKUP_ID" \
    "$GIT_REVISION" "$S3_BUCKET" "$S3_KEY" "$KMS_KEY_ARN" \
    "$AWS_REGION" "$NAMESPACE" <<'PY'
import json
import sys
from datetime import datetime

path, backup_id, revision, bucket, key, kms_arn, region, namespace = sys.argv[1:]

manifest = {
    "backup_id": backup_id,
    "created_at": datetime.now().astimezone().isoformat(),
    "git_revision": revision,
    "namespace": namespace,
    "components": {
        "postgresql": "n8n-postgres.dump",
        "n8n_filesystem": "n8n-filesystem.tar.gz",
        "recovery_material": [
            "recovery-material/n8n-db-credentials.yaml",
            "recovery-material/n8n-encryption-key.yaml",
            "recovery-material/redis-credentials.yaml"
        ]
    },
    "redis_recovery_policy": (
        "Do not restore stale Redis queue state. Start Redis clean and "
        "validate interrupted or pending executions during recovery."
    ),
    "checksums_file": "SHA256SUMS",
    "checksum_scope": (
        "PostgreSQL dump, filesystem archive, and recovery material; "
        "manifest and checksum file are excluded."
    ),
    "encryption": {
        "method": "AWS Encryption SDK client-side envelope encryption",
        "kms_key_arn": kms_arn,
        "aws_region": region,
        "s3_server_side_encryption": "AES256"
    },
    "s3": {
        "bucket": bucket,
        "object_key": key
    },
    "verification": {
        "component_checksums": "passed",
        "upload_download_ciphertext_sha256_match": "pending",
        "decrypted_payload_sha256_match": "pending",
        "full_application_restore_test": "pending"
    },
    "status": "prepared"
}

with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

python3 -m json.tool "$PAYLOAD_DIR/manifest.json" >/dev/null

# -------------------------------------------------------------------
# 6. Package and encrypt
# -------------------------------------------------------------------
tar -C "$PAYLOAD_DIR" -cf "$PAYLOAD" .
chmod 600 "$PAYLOAD"

KMS_KEY_ARN="$KMS_KEY_ARN" AWS_REGION="$AWS_REGION" "$PYTHON" "$ENCRYPT_SCRIPT" "$PAYLOAD" "$ENCRYPTED"
chmod 600 "$ENCRYPTED"

# -------------------------------------------------------------------
# 7. Upload encrypted package to S3
# -------------------------------------------------------------------
aws s3 cp "$ENCRYPTED" "s3://$S3_BUCKET/$S3_KEY" \
    --region "$AWS_REGION" \
    --sse AES256

# -------------------------------------------------------------------
# 8. Download and compare ciphertext
# -------------------------------------------------------------------
aws s3 cp "s3://$S3_BUCKET/$S3_KEY" "$DOWNLOADED" \
    --region "$AWS_REGION"

if cmp -s "$ENCRYPTED" "$DOWNLOADED"; then
    CIPHERTEXT_MATCH=true
    echo "S3 ciphertext comparison passed."
else
    CIPHERTEXT_MATCH=false
    echo "ERROR: Downloaded ciphertext differs from local ciphertext." >&2
fi

# -------------------------------------------------------------------
# 9. Decrypt downloaded object and compare plaintext
# -------------------------------------------------------------------
if KMS_KEY_ARN="$KMS_KEY_ARN" AWS_REGION="$AWS_REGION" \
    "$PYTHON" "$DECRYPT_SCRIPT" "$DOWNLOADED" "$RESTORED"; then
    if cmp -s "$PAYLOAD" "$RESTORED"; then
        PLAINTEXT_MATCH=true
        echo "Decrypted payload comparison passed."
    else
        PLAINTEXT_MATCH=false
        echo "ERROR: Decrypted payload differs from original payload." >&2
    fi
else
    PLAINTEXT_MATCH=false
    echo "ERROR: Decryption of the downloaded backup failed." >&2
fi


# -------------------------------------------------------------------
# 10. Verify S3 object metadata and capture the object version
# -------------------------------------------------------------------
S3_METADATA="$BACKUP_DIR/s3-metadata.json"
FINAL_MANIFEST="$BACKUP_DIR/manifest.final.json"
FINAL_MANIFEST_STATUS_FILE="$BACKUP_DIR/final-manifest-status.txt"

aws s3api head-object \
    --bucket "$S3_BUCKET" \
    --key "$S3_KEY" \
    --region "$AWS_REGION" \
    > "$S3_METADATA"

S3_VERSION_ID="$(
    python3 - "$S3_METADATA" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    metadata = json.load(f)

version_id = metadata.get("VersionId")
size = metadata.get("ContentLength")
encryption = metadata.get("ServerSideEncryption")

if not version_id or version_id == "null":
    raise SystemExit("ERROR: S3 object version ID is missing.")

if not isinstance(size, int) or size <= 0:
    raise SystemExit("ERROR: S3 object size is invalid.")

if encryption != "AES256":
    raise SystemExit("ERROR: Expected S3 SSE-S3 AES256.")

print(version_id)
PY
)"

# -------------------------------------------------------------------
# 11. Generate final verification manifest
# -------------------------------------------------------------------
python3 - "$PAYLOAD_DIR/manifest.json" "$FINAL_MANIFEST" \
    "$BACKUP_ID" "$S3_BUCKET" "$S3_KEY" "$S3_VERSION_ID" \
    "$S3_METADATA" "$ENCRYPTED" "$DOWNLOADED" "$PAYLOAD" "$RESTORED" \
    "$FINAL_MANIFEST_STATUS_FILE" "$CIPHERTEXT_MATCH" "$PLAINTEXT_MATCH" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone

(
    original_path,
    final_path,
    backup_id,
    bucket,
    key,
    version_id,
    metadata_path,
    encrypted_path,
    downloaded_path,
    payload_path,
    restored_path,
    status_file,
    ciphertext_match_text,
    plaintext_match_text,
) = sys.argv[1:]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


with open(original_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
with open(metadata_path, encoding="utf-8") as stream:
    metadata = json.load(stream)

# Recheck S3 metadata. The shell step already rejects missing/invalid metadata.
if metadata.get("VersionId") != version_id:
    raise SystemExit("ERROR: S3 version ID does not match.")
if metadata.get("ServerSideEncryption") != "AES256":
    raise SystemExit("ERROR: S3 SSE-S3 AES256 verification failed.")
if metadata.get("ContentLength") != os.path.getsize(encrypted_path):
    raise SystemExit("ERROR: S3 object size does not match local ciphertext.")

ciphertext_match = ciphertext_match_text == "true"
plaintext_match = plaintext_match_text == "true"

# Independently recalculate file hashes where possible.
if os.path.isfile(encrypted_path) and os.path.isfile(downloaded_path):
    ciphertext_match = ciphertext_match and sha256(encrypted_path) == sha256(downloaded_path)
else:
    ciphertext_match = False
if os.path.isfile(payload_path) and os.path.isfile(restored_path):
    plaintext_match = plaintext_match and sha256(payload_path) == sha256(restored_path)
else:
    plaintext_match = False

# Validate package checksums in a temporary directory. Reject path traversal
# and links before extraction; this package is generated by this script.
component_checksums = "failed"
try:
    if not os.path.isfile(restored_path):
        raise RuntimeError("Decrypted package is unavailable.")
    with tempfile.TemporaryDirectory(prefix="n8n-checksum-") as temp_dir:
        with tarfile.open(restored_path, "r:") as archive:
            members = archive.getmembers()
            for member in members:
                name = member.name
                normalized = os.path.normpath(name)
                if os.path.isabs(name) or normalized == ".." or normalized.startswith(".." + os.sep):
                    raise RuntimeError("Unsafe path detected in decrypted archive.")
                if member.issym() or member.islnk() or member.isdev():
                    raise RuntimeError("Links/devices are not allowed in the backup package.")
                target = os.path.realpath(os.path.join(temp_dir, name))
                if os.path.commonpath([os.path.realpath(temp_dir), target]) != os.path.realpath(temp_dir):
                    raise RuntimeError("Unsafe extraction target detected.")
            archive.extractall(temp_dir)

        checksum_file = os.path.join(temp_dir, "SHA256SUMS")
        if not os.path.isfile(checksum_file):
            raise RuntimeError("SHA256SUMS missing from restored package.")
        result = subprocess.run(
            ["sha256sum", "--check", "SHA256SUMS"],
            cwd=temp_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            component_checksums = "passed"
        else:
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
except (OSError, tarfile.TarError, RuntimeError, ValueError) as error:
    print(f"ERROR: Component checksum validation failed: {error}", file=sys.stderr)

manifest.setdefault("s3", {})
manifest["s3"].update({
    "bucket": bucket,
    "object_key": key,
    "version_id": version_id,
    "object_size_bytes": metadata["ContentLength"],
    "server_side_encryption": metadata["ServerSideEncryption"],
})
manifest["verification"] = {
    "component_checksums": component_checksums,
    "upload_download_ciphertext_sha256_match": "passed" if ciphertext_match else "failed",
    "decrypted_payload_sha256_match": "passed" if plaintext_match else "failed",
    "full_application_restore_test": "not_run_by_this_backup_job",
    "historical_restore_drill": "passed_with_limitations",
    "verified_at": datetime.now(timezone.utc).isoformat(),
}

checks = [
    component_checksums == "passed",
    ciphertext_match,
    plaintext_match,
]
manifest["status"] = "verified" if all(checks) else "failed"
manifest["final_manifest_created_at"] = datetime.now(timezone.utc).isoformat()

# Write status separately for Bash; pass the path as an argument (not env).
with open(status_file, "w", encoding="utf-8") as stream:
    stream.write(manifest["status"] + "\n")

# Write the final manifest atomically and keep it private.
temporary_manifest = final_path + ".tmp"
with open(temporary_manifest, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(temporary_manifest, 0o600)
os.replace(temporary_manifest, final_path)

print("Component checksums:", component_checksums)
print("Ciphertext comparison:", "passed" if ciphertext_match else "failed")
print("Decrypted payload comparison:", "passed" if plaintext_match else "failed")
print("Final manifest status:", manifest["status"])
PY
# -------------------------------------------------------------------
# 12. Upload final verification manifest separately
# -------------------------------------------------------------------
aws s3 cp "$FINAL_MANIFEST" \
    "s3://$S3_BUCKET/backups/$BACKUP_ID/manifest.final.json" \
    --region "$AWS_REGION" \
    --sse AES256

FINAL_MANIFEST_STATUS="$(cat "$FINAL_MANIFEST_STATUS_FILE")"
if [[ "$FINAL_MANIFEST_STATUS" != "verified" ]]; then
    echo "ERROR: Backup verification failed. Final manifest was uploaded with status: $FINAL_MANIFEST_STATUS" >&2
    echo "Manifest: s3://$S3_BUCKET/backups/$BACKUP_ID/manifest.final.json" >&2
    exit 1
fi

echo "Backup workflow completed: $BACKUP_ID"
echo "S3 object: s3://$S3_BUCKET/$S3_KEY"
echo "S3 version ID: $S3_VERSION_ID"
echo "Final manifest: s3://$S3_BUCKET/backups/$BACKUP_ID/manifest.final.json"

