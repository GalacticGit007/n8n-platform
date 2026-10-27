
import os
import sys
import boto3
import aws_encryption_sdk

from aws_encryption_sdk import CommitmentPolicy
from aws_cryptographic_material_providers.mpl import AwsCryptographicMaterialProviders
from aws_cryptographic_material_providers.mpl.config import MaterialProvidersConfig
from aws_cryptographic_material_providers.mpl.models import CreateAwsKmsKeyringInput


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "Usage: encrypt_n8n_backup.py INPUT_PATH OUTPUT_PATH"
        )

    source_path, output_path = sys.argv[1:3]

    kms_key_arn = os.environ.get("KMS_KEY_ARN")
    aws_region = os.environ.get("AWS_REGION", "ap-south-1")

    if not kms_key_arn:
        raise SystemExit("ERROR: KMS_KEY_ARN environment variable is required.")

    if not os.path.isfile(source_path):
        raise SystemExit(f"ERROR: Input file not found: {source_path}")

    if os.path.abspath(source_path) == os.path.abspath(output_path):
        raise SystemExit("ERROR: Input and output paths must differ.")

    kms_client = boto3.client("kms", region_name=aws_region)

    keyring = AwsCryptographicMaterialProviders(
        config=MaterialProvidersConfig()
    ).create_aws_kms_keyring(
        input=CreateAwsKmsKeyringInput(
            kms_key_id=kms_key_arn,
            kms_client=kms_client,
        )
    )

    client = aws_encryption_sdk.EncryptionSDKClient(
        commitment_policy=CommitmentPolicy.REQUIRE_ENCRYPT_REQUIRE_DECRYPT
    )

    encryption_context = {
        "project": "n8n-platform",
        "purpose": "disaster-recovery-backup",
    }

    try:
        with open(source_path, "rb") as source:
            with open(output_path, "xb") as destination:
                with client.stream(
                    mode="e",
                    source=source,
                    keyring=keyring,
                    encryption_context=encryption_context,
                ) as encrypted:
                    for chunk in encrypted:
                        destination.write(chunk)

                destination.flush()
                os.fsync(destination.fileno())

        os.chmod(output_path, 0o600)

    except Exception:
        # Avoid leaving a partial ciphertext file after encryption fails.
        try:
            os.unlink(output_path)
        except FileNotFoundError:
            pass
        raise

    print("Client-side encryption completed successfully.")


if __name__ == "__main__":
    main()
