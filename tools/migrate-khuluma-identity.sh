#!/usr/bin/env bash
set -euo pipefail
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$tool_dir/khuluma_identity_migration.py" "$@"
