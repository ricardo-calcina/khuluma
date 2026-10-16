#!/usr/bin/env bash
# Generate Khuluma's TextPipeline parity fixtures from the CLI's bash cleanup,
# or verify they are current (--check). See tests/gen_cleanup_fixtures.py.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="python3"
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if [[ -x "$candidate" ]]; then
    PYTHON="$candidate"
    break
  fi
done
exec "$PYTHON" "$ROOT/tests/gen_cleanup_fixtures.py" "$@"
