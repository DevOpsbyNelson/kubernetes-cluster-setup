#!/bin/bash
# Initialize the S3 remote state backend for one environment and select its workspace.
# Usage: ENVIRONMENT=development ./scripts/terraform-init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

# Map ENVIRONMENT to a variable prefix (e.g. production -> PROD_REMOTE_STORAGE_AWS_S3_BUCKET)
: "${ENVIRONMENT:?ERROR: ENVIRONMENT is required (production | development | staging)}"
ENV_PREFIX="$(resolve_environment_prefix "$ENVIRONMENT")" || {
  echo "ERROR: unsupported ENVIRONMENT '$ENVIRONMENT' (expected production | development | staging)"
  return 1 2>/dev/null || exit 1
}

# Strictly resolve Terraform backend variables from ENV_PREFIX_REMOTE_STORAGE_* only.
REMOTE_STORAGE_AWS_S3_BUCKET="$(require_scoped_value "$ENV_PREFIX" REMOTE_STORAGE_AWS_S3_BUCKET)"
REMOTE_STORAGE_AWS_REGION="$(require_scoped_value "$ENV_PREFIX" REMOTE_STORAGE_AWS_REGION)"
REMOTE_STORAGE_AWS_S3_KEY="$(require_scoped_value "$ENV_PREFIX" REMOTE_STORAGE_AWS_S3_KEY)"

REMOTE_STORAGE_AWS_S3_ENDPOINT="$(get_scoped_or_global "$ENV_PREFIX" REMOTE_STORAGE_AWS_S3_ENDPOINT true)"
REMOTE_STORAGE_AWS_ACCESS_KEY_ID="$(get_scoped_or_global "$ENV_PREFIX" REMOTE_STORAGE_AWS_ACCESS_KEY_ID true)"
REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY="$(get_scoped_or_global "$ENV_PREFIX" REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY true)"

export REMOTE_STORAGE_AWS_S3_BUCKET REMOTE_STORAGE_AWS_REGION REMOTE_STORAGE_AWS_S3_KEY
export REMOTE_STORAGE_AWS_S3_ENDPOINT REMOTE_STORAGE_AWS_ACCESS_KEY_ID REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY

cd "$INFRA_DIR"

# Fail early with a clear message when the state bucket is missing or not accessible.
check_state_bucket() {
  local -a aws_args=(--bucket "$REMOTE_STORAGE_AWS_S3_BUCKET" --region "$REMOTE_STORAGE_AWS_REGION")
  local -a aws_env=()
  local output

  if ! command -v aws >/dev/null 2>&1; then
    echo "WARNING: AWS CLI not found; skipping state bucket check." >&2
    return 0
  fi

  [ -n "$REMOTE_STORAGE_AWS_S3_ENDPOINT" ] && aws_args+=(--endpoint-url "$REMOTE_STORAGE_AWS_S3_ENDPOINT")
  [ -n "$REMOTE_STORAGE_AWS_ACCESS_KEY_ID" ] && aws_env+=("AWS_ACCESS_KEY_ID=$REMOTE_STORAGE_AWS_ACCESS_KEY_ID")
  [ -n "$REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY" ] && aws_env+=("AWS_SECRET_ACCESS_KEY=$REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY")

  if output="$(env "${aws_env[@]}" aws s3api head-bucket "${aws_args[@]}" 2>&1)"; then
    return 0
  fi

  case "$output" in
    *404* | *"Not Found"* | *NoSuchBucket*)
      echo "ERROR: state bucket '$REMOTE_STORAGE_AWS_S3_BUCKET' does not exist." >&2
      echo "       Create it once with: ENVIRONMENT=$ENVIRONMENT ./scripts/bootstrap-state-bucket.sh" >&2
      ;;
    *403* | *Forbidden*)
      echo "ERROR: access denied to state bucket '$REMOTE_STORAGE_AWS_S3_BUCKET'." >&2
      echo "       It may belong to another AWS account (bucket names are global), or these credentials lack s3:ListBucket." >&2
      ;;
    *)
      echo "ERROR: could not check state bucket '$REMOTE_STORAGE_AWS_S3_BUCKET':" >&2
      echo "$output" >&2
      ;;
  esac
  return 1
}

echo "Checking state bucket $REMOTE_STORAGE_AWS_S3_BUCKET..."
check_state_bucket

TF_BACKEND_ARGS=(
  "-backend-config=bucket=${REMOTE_STORAGE_AWS_S3_BUCKET}"
  "-backend-config=key=${REMOTE_STORAGE_AWS_S3_KEY}"
  "-backend-config=region=${REMOTE_STORAGE_AWS_REGION}"
)

TF_INIT_FLAGS=()
[ "${TF_INIT_RECONFIGURE:-false}" = "true" ] && TF_INIT_FLAGS+=("-reconfigure")
echo "Initializing Terraform backend in $INFRA_DIR (environment: $ENVIRONMENT)..."

run_terraform_init() {
  local -a init_args=("${TF_BACKEND_ARGS[@]}")
  local _backend_file _rc=0

  # Credentials and endpoint go into a private temp file instead of the command line,
  # so they don't show up in the process list or shell history.
  _backend_file="$(mktemp --suffix=.hcl)"
  chmod 600 "$_backend_file"
  trap 'rm -f "$_backend_file"' RETURN

  if [ -n "$REMOTE_STORAGE_AWS_ACCESS_KEY_ID" ]; then
    printf 'access_key = "%s"\n' "$REMOTE_STORAGE_AWS_ACCESS_KEY_ID" >> "$_backend_file"
  fi
  if [ -n "$REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY" ]; then
    printf 'secret_key = "%s"\n' "$REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY" >> "$_backend_file"
  fi

  # Custom S3 endpoint (LocalStack, MinIO, ...): path-style URLs and no AWS-only checks.
  if [ -n "$REMOTE_STORAGE_AWS_S3_ENDPOINT" ]; then
    printf 'endpoints = {\n  s3 = "%s"\n}\n' "$REMOTE_STORAGE_AWS_S3_ENDPOINT" >> "$_backend_file"
    cat >> "$_backend_file" <<'EOF'
use_path_style              = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_s3_checksum            = true
EOF
  fi

  init_args+=("-backend-config=${_backend_file}")

  terraform init -input=false -no-color "${TF_INIT_FLAGS[@]}" "${init_args[@]}" || _rc=$?
  return $_rc
}

run_terraform_init

# One workspace per environment; its state lives at env:/<ENVIRONMENT>/<key> in the bucket.
terraform workspace select -or-create=true -no-color "$ENVIRONMENT"
