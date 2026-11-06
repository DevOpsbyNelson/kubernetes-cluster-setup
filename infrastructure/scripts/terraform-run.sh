#!/bin/bash
# Initialize the backend for ENVIRONMENT, then run a Terraform command in its workspace.
# Usage: ENVIRONMENT=staging ./scripts/terraform-run.sh plan|apply|destroy|output [extra terraform args]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

if [ "$#" -eq 0 ]; then
  echo "Usage: ENVIRONMENT=<development|staging|production> $0 <terraform command> [args...]" >&2
  exit 1
fi

"$SCRIPT_DIR/terraform-init.sh"

cd "$INFRA_DIR"

# Refuse to run if the selected workspace doesn't match the requested environment.
CURRENT_WORKSPACE="$(terraform workspace show)"
if [ "$CURRENT_WORKSPACE" != "$ENVIRONMENT" ]; then
  echo "ERROR: workspace is '$CURRENT_WORKSPACE' but ENVIRONMENT is '$ENVIRONMENT'" >&2
  exit 1
fi

# Show where resources will go, so a missing emulator setting can't silently hit real AWS.
if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  echo "Target: AWS emulator at $AWS_ENDPOINT_URL"
else
  echo "Target: real AWS account $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '<unknown: check your AWS credentials>')"
fi

echo "Running 'terraform $*' for $ENVIRONMENT..."
terraform "$@"
