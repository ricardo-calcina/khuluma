#!/usr/bin/env bash
# Run only the checks a change affects. See tools/test_affected.py.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -B "$ROOT/tools/test_affected.py" "$@"
