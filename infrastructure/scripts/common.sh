#!/bin/bash
# Shared helpers for the Terraform scripts. Source this file; don't execute it.
# Expects SCRIPT_DIR to be set by the calling script.

INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export INFRA_DIR

# Optional KEY=value settings file: ENV_FILE when set (e.g. written by CI), else the gitignored
# infrastructure/.env. Real environment variables take precedence. Values are taken literally (no quotes).
if [ -n "${ENV_FILE:-}" ] && [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: ENV_FILE '$ENV_FILE' does not exist" >&2
  return 1 2>/dev/null || exit 1
fi
_env_file="${ENV_FILE:-$INFRA_DIR/.env}"
if [ -f "$_env_file" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in '' | '#'*) continue ;; esac
    _name="${_line%%=*}"
    if [ -z "${!_name+x}" ]; then
      export "${_line?}" # _line is KEY=value
    fi
  done < "$_env_file"
  unset _line _name
fi
unset _env_file

# production -> PROD, staging -> STAGING, development -> DEV
resolve_environment_prefix() {
  case "${1:-}" in
    production) echo "PROD" ;;
    staging) echo "STAGING" ;;
    development) echo "DEV" ;;
    *) return 1 ;;
  esac
}

# Print <PREFIX>_<NAME>; fail if it is unset or empty.
require_scoped_value() {
  local prefix="$1" name="$2"
  local var="${prefix}_${name}"
  local value="${!var:-}"

  if [ -z "$value" ]; then
    echo "ERROR: $var is required" >&2
    return 1
  fi
  printf '%s' "$value"
}

# Print <PREFIX>_<NAME>, falling back to the global <NAME>.
# When the third argument is "true" the value is optional (empty output); otherwise it is required.
get_scoped_or_global() {
  local prefix="$1" name="$2" optional="${3:-false}"
  local scoped="${prefix}_${name}"
  local value="${!scoped:-${!name:-}}"

  if [ -z "$value" ] && [ "$optional" != "true" ]; then
    echo "ERROR: $scoped (or $name) is required" >&2
    return 1
  fi
  printf '%s' "$value"
}
