#!/usr/bin/env bash

# Keep test artifacts recoverable. A reset moves the exact fixture aside;
# complete temporary roots are retained and printed by each suite's EXIT trap.
preserve_fixture() {
  local target retained
  [[ -n "${KHULUMA_TEST_FIXTURE_ROOT:-}" ]] || {
    echo "Missing fixture root for preservation" >&2
    return 1
  }
  for target in "$@"; do
    [[ "$target" == "$KHULUMA_TEST_FIXTURE_ROOT/"* ]] || {
      echo "Refusing fixture reset outside root: $target" >&2
      return 1
    }
    [[ -e "$target" || -L "$target" ]] || continue
    mkdir -p "$KHULUMA_TEST_FIXTURE_ROOT/.retained"
    chmod 700 "$KHULUMA_TEST_FIXTURE_ROOT/.retained"
    retained="$(mktemp -d "$KHULUMA_TEST_FIXTURE_ROOT/.retained/item.XXXXXX")"
    printf '%s\n' "$target" >"$retained/original-path"
    chmod 600 "$retained/original-path"
    mv "$target" "$retained/payload"
  done
}

report_fixture_root() {
  printf 'Retained test fixtures: %s\n' "$KHULUMA_TEST_FIXTURE_ROOT" >&2
}

enable_fixture_recovery() {
  local variable
  while IFS= read -r variable; do
    case "$variable" in
      KHULUMA_TEST_FIXTURE_ROOT) ;;
      KHULUMA_*|DICTATE_*) unset "$variable" ;;
    esac
  done < <(compgen -e)
  unset SOUNDS_DIR
  export HOME="$KHULUMA_TEST_FIXTURE_ROOT/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export KHULUMA_TEST_RECOVERY_ROOT="$KHULUMA_TEST_FIXTURE_ROOT/.recovery"
  export KHULUMA_RECOVERY_HELPER="$ROOT/bin/khuluma-lib/recovery.py"
  export KHULUMA_PROCESSING_DIR="$KHULUMA_TEST_FIXTURE_ROOT/processing"
  export KHULUMA_DAEMON_BACKGROUND_REFRESH=0
  export TMPDIR="$KHULUMA_TEST_FIXTURE_ROOT/tmp"
  export KHULUMA_TMPDIR="$TMPDIR"
  mkdir -p "$KHULUMA_TEST_RECOVERY_ROOT" "$TMPDIR"
  chmod 700 "$KHULUMA_TEST_FIXTURE_ROOT" "$KHULUMA_TEST_RECOVERY_ROOT"
  python3 - "$KHULUMA_TEST_FIXTURE_ROOT" "$KHULUMA_TEST_RECOVERY_ROOT" <<'PY'
import json, os, pathlib, sys
boundary, recovery = (pathlib.Path(path).resolve() for path in sys.argv[1:])
marker = recovery / ".khuluma-recovery-fixture"
with marker.open("w", encoding="utf-8") as file:
    json.dump({"schema_version": 1, "fixture_root": str(boundary)}, file)
os.chmod(marker, 0o600)
PY
}

enable_fixture_recovery
# Direct module unit tests use the same pure recovery/bootstrap definitions
# as the canonical entry point, without loading config or starting anything.
source "$ROOT/bin/khuluma-lib/identity.sh"
