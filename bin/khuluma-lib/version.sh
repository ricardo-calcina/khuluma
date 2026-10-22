#!/usr/bin/env bash

# Version information is a small, stable CLI support surface. Keep the
# currently executing binary separate from install receipt provenance: a
# receipt says how an install was created, not which source checkout is live.

version_running_binary_path() {
  local invoked="${KHULUMA_RUNNING_BINARY:-$0}"
  local resolved=""

  if [[ "$invoked" == */* ]]; then
    resolved="$invoked"
  else
    resolved="$(command -v "$invoked" 2>/dev/null || true)"
  fi
  [[ -n "$resolved" ]] || resolved="$invoked"

  local parent base
  parent="$(dirname "$resolved")"
  base="$(basename "$resolved")"
  if [[ -d "$parent" ]]; then
    printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$base"
  else
    printf '%s\n' "$resolved"
  fi
}

version_receipt_value() {
  local key="${1:-}"
  local receipt="${2:-$KHULUMA_CONFIG_DIR/install-receipt.env}"
  local raw=""
  [[ -n "$key" && -r "$receipt" ]] || return 0

  # Install receipts are generated as shell-style key/value pairs. Read only
  # the expected key as data; never source a user-local receipt for a version
  # query. Decode Bash printf %q output as data so escaped provenance renders
  # as the installed value without evaluating substitutions or expansions.
  raw="$(awk -v expected="$key" '
    index($0, expected "=") == 1 {
      print substr($0, length(expected) + 2)
      exit
    }
  ' "$receipt" 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0

  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$raw"
    return 0
  fi

  VERSION_RECEIPT_RAW="$raw" python3 - <<'PYEOF'
import os
import shlex

raw = os.environ["VERSION_RECEIPT_RAW"]

try:
    values = shlex.split(raw, posix=True)
except ValueError:
    values = []

# A receipt value is one Bash-quoted word. Preserve malformed or multi-word
# input verbatim rather than attempting shell evaluation.
print(values[0] if len(values) == 1 else raw)
PYEOF
}

show_version() {
  local json_output="0"
  case "${1:-}" in
    "") ;;
    --json) json_output="1" ;;
    *) die "usage: khuluma version [--json]" ;;
  esac
  [[ $# -le 1 ]] || die "usage: khuluma version [--json]"

  local binary_path receipt_path receipt_present receipt_readable
  local installed_at source ref commit migration_required="false"
  binary_path="$(version_running_binary_path)"
  receipt_path="$KHULUMA_CONFIG_DIR/install-receipt.env"
  receipt_present="false"
  receipt_readable="false"
  if [[ -f "$receipt_path" ]]; then
    receipt_present="true"
  fi
  if [[ -r "$receipt_path" ]]; then
    receipt_readable="true"
  fi
  installed_at="$(version_receipt_value installed_at "$receipt_path")"
  source="$(version_receipt_value install_source "$receipt_path")"
  ref="$(version_receipt_value repo_git_ref "$receipt_path")"
  commit="$(version_receipt_value repo_git_commit "$receipt_path")"

  if [[ "$json_output" == "1" ]]; then
    need python3
    khuluma_identity_migration_required && migration_required="true"
    VERSION_IDENTITY_CONFIG_DIR="$KHULUMA_CONFIG_DIR" \
    VERSION_IDENTITY_MIGRATION_REQUIRED="$migration_required" \
    VERSION_CLI_VERSION="$KHULUMA_CLI_VERSION" \
    VERSION_CONFIG_SCHEMA_VERSION="$KHULUMA_CONFIG_SCHEMA_VERSION" \
    VERSION_RUNNING_BINARY="$binary_path" \
    VERSION_RECEIPT_PATH="$receipt_path" \
    VERSION_RECEIPT_PRESENT="$receipt_present" \
    VERSION_RECEIPT_READABLE="$receipt_readable" \
    VERSION_RECEIPT_INSTALLED_AT="$installed_at" \
    VERSION_RECEIPT_SOURCE="$source" \
    VERSION_RECEIPT_REF="$ref" \
    VERSION_RECEIPT_COMMIT="$commit" \
    python3 - <<'PYEOF'
import json
import os

def optional(name):
    value = os.environ.get(name, "")
    return value if value else None

payload = {
    "command": "version",
    "schema_version": 1,
    "cli_version": os.environ["VERSION_CLI_VERSION"],
    "config_schema_version": int(os.environ["VERSION_CONFIG_SCHEMA_VERSION"]),
    "running_binary": {"path": os.environ["VERSION_RUNNING_BINARY"]},
    "identity": {
        "product": "khuluma",
        "identity_version": 1,
        "canonical_binary": os.path.abspath(os.environ["VERSION_RUNNING_BINARY"]),
        "config_dir": os.environ["VERSION_IDENTITY_CONFIG_DIR"],
        "migration_required": os.environ["VERSION_IDENTITY_MIGRATION_REQUIRED"] == "true",
    },
    "receipt": {
        "path": os.environ["VERSION_RECEIPT_PATH"],
        "present": os.environ["VERSION_RECEIPT_PRESENT"] == "true",
        "readable": os.environ["VERSION_RECEIPT_READABLE"] == "true",
        "installed_at": optional("VERSION_RECEIPT_INSTALLED_AT"),
        "source": optional("VERSION_RECEIPT_SOURCE"),
        "ref": optional("VERSION_RECEIPT_REF"),
        "commit": optional("VERSION_RECEIPT_COMMIT"),
    },
}
print(json.dumps(payload, sort_keys=True))
PYEOF
    return 0
  fi

  echo "Khuluma version"
  echo "CLI version: $KHULUMA_CLI_VERSION"
  echo "Config schema: v$KHULUMA_CONFIG_SCHEMA_VERSION"
  echo "Running binary: $binary_path"
  if [[ "$receipt_present" != "true" ]]; then
    echo "Install receipt: missing ($receipt_path)"
    echo "Receipt provenance is unavailable until an install writes this file."
    return 0
  fi

  if [[ "$receipt_readable" != "true" ]]; then
    echo "Install receipt: present but unreadable ($receipt_path)"
    return 0
  fi

  echo "Install receipt: present ($receipt_path)"
  [[ -n "$installed_at" ]] && echo "  installed at: $installed_at"
  [[ -n "$source" ]] && echo "  source: $source"
  [[ -n "$ref" ]] && echo "  ref: $ref"
  [[ -n "$commit" ]] && echo "  commit: $commit"
  echo "Receipt provenance records install metadata; the running binary is listed separately."
}
