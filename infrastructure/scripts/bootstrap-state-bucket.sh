#!/bin/bash
# Create the S3 bucket that stores Terraform state for ENVIRONMENT (run once per bucket).
# Safe to re-run: settings are re-applied and an existing bucket is kept.
# Usage: ENVIRONMENT=development ./scripts/bootstrap-state-bucket.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

: "${ENVIRONMENT:?ERROR: ENVIRONMENT is required (production | development | staging)}"
ENV_PREFIX="$(resolve_environment_prefix "$ENVIRONMENT")" || {
  echo "ERROR: unsupported ENVIRONMENT '$ENVIRONMENT' (expected production | development | staging)" >&2
  exit 1
}

BUCKET="$(require_scoped_value "$ENV_PREFIX" REMOTE_STORAGE_AWS_S3_BUCKET)"
REGION="$(require_scoped_value "$ENV_PREFIX" REMOTE_STORAGE_AWS_REGION)"
ENDPOINT="$(get_scoped_or_global "$ENV_PREFIX" REMOTE_STORAGE_AWS_S3_ENDPOINT true)"
ACCESS_KEY_ID="$(get_scoped_or_global "$ENV_PREFIX" REMOTE_STORAGE_AWS_ACCESS_KEY_ID true)"
SECRET_ACCESS_KEY="$(get_scoped_or_global "$ENV_PREFIX" REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY true)"

# Use the state-storage credentials/endpoint when given, otherwise the default AWS credentials.
[ -n "$ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID"
[ -n "$SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY"
AWS_ARGS=(--region "$REGION")
[ -n "$ENDPOINT" ] && AWS_ARGS+=(--endpoint-url "$ENDPOINT")

if aws s3api head-bucket --bucket "$BUCKET" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
  echo "State bucket $BUCKET already exists."
else
  echo "Creating state bucket $BUCKET in $REGION..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" "${AWS_ARGS[@]}" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" "${AWS_ARGS[@]}" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi

# Versioning lets you recover earlier state files; state may contain secrets, so keep it private and encrypted.
aws s3api put-bucket-versioning --bucket "$BUCKET" "${AWS_ARGS[@]}" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" "${AWS_ARGS[@]}" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" "${AWS_ARGS[@]}" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "State bucket $BUCKET is ready."
