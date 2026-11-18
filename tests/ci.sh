#!/usr/bin/env bash
# Checks for the repo tools (the app itself is tested by swift.yml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for f in tools/*.sh tests/*.sh; do
  bash -n "$f"
done
echo "Syntax checks passed."

python3 tests/check_packaging.py
python3 tests/test_app_build_helpers.py
python3 tests/test_test_affected.py

echo "All CI checks passed."
