#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$TMP_ROOT"
source "$ROOT/tests/fixture_helpers.sh"
trap report_fixture_root EXIT

CUSTOM_HOME="$TMP_ROOT/custom-home"
CUSTOM_BIN="$TMP_ROOT/prefix/bin"
PROFILE="$TMP_ROOT/profile"
MODELS="$TMP_ROOT/models"
NATIVE="$TMP_ROOT/runtime"
SOUNDS="$TMP_ROOT/sounds"
mkdir -p "$CUSTOM_HOME" "$SOUNDS"
printf 'custom-start-fixture\n' >"$SOUNDS/start.wav"

custom_install() {
  HOME="$CUSTOM_HOME" XDG_CONFIG_HOME="$CUSTOM_HOME/xdg-config" XDG_DATA_HOME="$CUSTOM_HOME/xdg-data" \
    KHULUMA_BIN_DIR="$CUSTOM_BIN" KHULUMA_CONFIG_DIR="$PROFILE" KHULUMA_CONFIG_FILE="$PROFILE/settings.toml" \
    KHULUMA_NATIVE_DIR="$NATIVE" KHULUMA_PARAKEET_MODELS_DIR="$MODELS" KHULUMA_SOUNDS_DIR="$SOUNDS" \
    KHULUMA_INSTALL_WARMUP=0 "$ROOT/install.sh" "$@"
}

custom_install --no-sounds >"$TMP_ROOT/custom-install.log"
# The installer environment is gone; matching receipt routing must persist.
HOME="$CUSTOM_HOME" XDG_CONFIG_HOME="$CUSTOM_HOME/xdg-config" XDG_DATA_HOME="$CUSTOM_HOME/xdg-data" \
  "$CUSTOM_BIN/khuluma" version --json >"$TMP_ROOT/version.json"
HOME="$CUSTOM_HOME" XDG_CONFIG_HOME="$CUSTOM_HOME/xdg-config" XDG_DATA_HOME="$CUSTOM_HOME/xdg-data" \
  "$CUSTOM_BIN/khuluma" config path --json >"$TMP_ROOT/path.json"
HOME="$CUSTOM_HOME" XDG_CONFIG_HOME="$CUSTOM_HOME/xdg-config" XDG_DATA_HOME="$CUSTOM_HOME/xdg-data" \
  "$CUSTOM_BIN/khuluma" app-config --json >"$TMP_ROOT/app-config.json"
python3 - "$TMP_ROOT" <<'PY'
import json, pathlib, shlex, sys
r = pathlib.Path(sys.argv[1])
version = json.loads((r / "version.json").read_text())
assert version["identity"]["config_dir"] == str(r / "profile")
assert version["receipt"]["path"] == str(r / "profile/install-receipt.env")
assert json.loads((r / "path.json").read_text())["config_path"] == str(r / "profile/settings.toml")
app = json.loads((r / "app-config.json").read_text())
assert app["app_contract"] == 3
assert app["transcription"]["socket_path"] == str(r / "profile/.cache/khulumad.sock")
assert app["sounds"]["start"]["path"] == str(r / "sounds/start.wav")
receipt = {}
for line in (r / "profile/install-receipt.env").read_text().splitlines():
    key, sep, raw = line.partition("=")
    if sep:
        receipt[key] = shlex.split(raw)[0]
assert receipt["native_dir"] == str(r / "runtime/khulumad")
assert receipt["models_dir"] == str(r / "models")
assert receipt["sounds_dir"] == str(r / "sounds")
assert receipt["sounds_installed"] == "0"
assert (r / "sounds/start.wav").read_text() == "custom-start-fixture\n"
assert sorted(path.name for path in (r / "sounds").glob("*.wav")) == ["start.wav"]
assert not (r / "custom-home/xdg-config/khuluma").exists()
assert (r / "profile/install-receipt.env").stat().st_mode & 0o077 == 0
PY
echo "PASS: install_custom_roots_persist_without_environment"

custom_install --force --no-sounds >"$TMP_ROOT/custom-reinstall.log"
HOME="$CUSTOM_HOME" XDG_CONFIG_HOME="$CUSTOM_HOME/xdg-config" XDG_DATA_HOME="$CUSTOM_HOME/xdg-data" \
  "$CUSTOM_BIN/khuluma" app-config --json >"$TMP_ROOT/reinstalled-app-config.json"
python3 - "$TMP_ROOT" <<'PYNO'
import json, pathlib, shlex, sys
r = pathlib.Path(sys.argv[1])
app = json.loads((r / "reinstalled-app-config.json").read_text())
assert app["sounds"]["start"]["path"] == str(r / "sounds/start.wav")
assert (r / "sounds/start.wav").read_text() == "custom-start-fixture\n"
assert sorted(path.name for path in (r / "sounds").glob("*.wav")) == ["start.wav"]
values = dict(line.split("=", 1) for line in (r / "profile/install-receipt.env").read_text().splitlines() if "=" in line)
assert shlex.split(values["sounds_dir"]) == [str(r / "sounds")]
assert shlex.split(values["sounds_installed"]) == ["0"]
PYNO
echo "PASS: install_no_sounds_reinstall_keeps_custom_routing_without_copy"

printf '\n# retained previous-install fixture\n' >>"$CUSTOM_BIN/khuluma"
before="$(cksum <"$CUSTOM_BIN/khuluma")"
mkdir "$TMP_ROOT/mock-bin"
cat >"$TMP_ROOT/mock-bin/cp" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in */bin/khuluma-lib.sh) exit 73 ;; esac
done
exec /bin/cp "$@"
SH
chmod +x "$TMP_ROOT/mock-bin/cp"
rc=0
PATH="$TMP_ROOT/mock-bin:$PATH" custom_install --force --no-sounds >"$TMP_ROOT/failed-install.log" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || { echo "Expected injected copy failure" >&2; exit 1; }
[[ "$(cksum <"$CUSTOM_BIN/khuluma")" == "$before" ]] || { echo "Previous executable was not restored" >&2; exit 1; }
echo "PASS: install_copy_failure_restores_previous_executable"

mkdir "$TMP_ROOT/other-target"
printf 'retain\n' >"$TMP_ROOT/other-target/marker"
ln -s "$TMP_ROOT/other-target" "$TMP_ROOT/linked-ancestor"
rc=0
KHULUMA_BIN_DIR="$TMP_ROOT/linked-ancestor/bin" KHULUMA_INSTALL_WARMUP=0 \
  "$ROOT/install.sh" --no-sounds >"$TMP_ROOT/rejected-link.log" 2>&1 || rc=$?
[[ "$rc" -ne 0 && ! -e "$TMP_ROOT/other-target/bin" ]] || { echo "Installer followed a symlink ancestor" >&2; exit 1; }
[[ "$(cat "$TMP_ROOT/other-target/marker")" == retain ]] || exit 1
echo "PASS: install_refuses_symlink_ancestor_before_writes"
echo "Install identity tests passed."
