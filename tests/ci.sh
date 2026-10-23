#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash_files=()
while IFS= read -r f; do
  bash_files+=("$f")
done < <(printf '%s\n' install.sh bootstrap.sh bin/khuluma && rg --files -g '*.sh' bin integrations tools tests)

for f in "${bash_files[@]}"; do
  bash -n "$f"
done

echo "Syntax checks passed."

./tests/test_lib.sh
./tests/test_version.sh
./tests/test_identity_cli.sh
./tests/test_cli.sh
./tests/test_providers.sh
./tests/test_regression.sh
./tests/test_flow_parity.sh
./tests/test_install.sh
./tests/test_install_identity.sh
./tests/test_bootstrap.sh
./tests/test_identity_migration.sh
python3 tests/test_finder_transaction.py
python3 tests/test_app_build_helpers.py
python3 tests/test_audio_cleanup.py

echo "All CI checks passed."
