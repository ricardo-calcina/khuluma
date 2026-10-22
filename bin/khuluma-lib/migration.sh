#!/usr/bin/env bash
# Definitions only: sourcing this file must not create a profile or load config.

khuluma_identity_migration_committed() {
  python3 - "$1" <<'PY'
import json, os, stat, sys
root = os.path.realpath(sys.argv[1])
path = os.path.join(root, ".khuluma-identity.json")
try:
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("unowned marker")
    with open(path, encoding="utf-8") as handle:
        marker = json.load(handle)
    if (type(marker.get("schema_version")) is not int or marker["schema_version"] != 1
            or marker.get("migration_version") != "rename-v1"
            or marker.get("state") != "committed" or marker.get("config_root") != root):
        raise ValueError("uncommitted or mismatched marker")
except (OSError, ValueError, AssertionError, TypeError):
    sys.exit(1)
PY
}

khuluma_identity_migration_staged() {
  local module_dir engine
  module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  # Installed tooling can provide its colocated engine without invoking the CLI.
  if [[ -n "${KHULUMA_IDENTITY_MIGRATION_ENGINE:-}" ]]; then
    engine="$KHULUMA_IDENTITY_MIGRATION_ENGINE"
  elif [[ -f "$module_dir/../../tools/khuluma_identity_migration.py" ]]; then
    engine="$module_dir/../../tools/khuluma_identity_migration.py"
  else
    engine="$module_dir/../../share/khuluma/tools/khuluma_identity_migration.py"
  fi
  [[ -f "$engine" ]] || return 1
  python3 "$engine" --check-staged "$1" --admission-receipt "$2" >/dev/null
}
