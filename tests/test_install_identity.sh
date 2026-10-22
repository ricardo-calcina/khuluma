#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$TMP_ROOT"
source "$ROOT/tests/fixture_helpers.sh"
trap report_fixture_root EXIT
unset LOWKEY_KEYCHAIN LOWKEY_SIGNING_IDENTITY

fail() { echo "FAIL: $1" >&2; exit 1; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected_path: $1"; }
fixture_snapshot() {
  python3 - "$@" <<'PYSNAPSHOT'
import hashlib, json, os, pathlib, stat, sys
result = {}
for name in sys.argv[1:]:
    root = pathlib.Path(name)
    if not os.path.lexists(root):
        result[str(root)] = None
        continue
    paths = [root, *sorted(root.rglob("*"))] if root.is_dir() and not root.is_symlink() else [root]
    for path in paths:
        info = path.lstat()
        payload = os.readlink(path) if stat.S_ISLNK(info.st_mode) else hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else None
        result[str(path)] = [info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_mtime_ns, payload]
print(json.dumps(result, sort_keys=True))
PYSNAPSHOT
}

# Historical v0.10.0 bytes, never executed. Only this exact released regular
# owned shim is eligible for the installer's recoverable retirement.
released_shim() {
  cat >"$1" <<'SHIM'
#!/usr/bin/env bash
# Temporary compatibility entry point. One canonical implementation and root.
set -euo pipefail
compat_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compat_target="$compat_dir/khuluma"
[[ -x "$compat_target" ]] || { printf '%s\n' 'tmux-whisper: canonical khuluma is missing; reinstall Khuluma' >&2; exit 2; }
if [[ $# -eq 2 && "$1" == "doctor" && "$2" == "--json" ]]; then
  # Diagnostic-only schema adapter; failure bytes/status and stderr are retained.
  exec python3 "$compat_dir/khuluma-lib/doctor_compat.py" "$compat_target" "$@"
fi
exec "$compat_target" "$@"
SHIM
  chmod 755 "$1"
  python3 - "$1" <<'PYSHIM'
import hashlib, pathlib, sys
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == "ab5f0067c075c177c2f56e99fe065a04662cde3636ca8f820957a9daf7e9fab6"
PYSHIM
}

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

fixture_snapshot "$CUSTOM_HOME" "$CUSTOM_BIN" "$PROFILE" "$MODELS" "$NATIVE" "$SOUNDS" \
  >"$TMP_ROOT/guard-before.json"
for variable in DICTATE_CONFIG_DIR DICTATE_UNKNOWN_INPUT LOWKEY_KEYCHAIN LOWKEY_SIGNING_IDENTITY; do
  for value in '' legacy-secret-value; do
    rc=0
    (export "$variable=$value"; custom_install --force --no-sounds) \
      >"$TMP_ROOT/guard.out" 2>"$TMP_ROOT/guard.err" || rc=$?
    [[ "$rc" == 2 ]] || fail "install_legacy_input_not_refused: $variable"
    grep -Fq "$variable" "$TMP_ROOT/guard.err" || fail "install_legacy_input_name_missing: $variable"
    if grep -Fq 'legacy-secret-value' "$TMP_ROOT/guard.out" "$TMP_ROOT/guard.err"; then
      fail "install_legacy_input_value_disclosed: $variable"
    fi
    fixture_snapshot "$CUSTOM_HOME" "$CUSTOM_BIN" "$PROFILE" "$MODELS" "$NATIVE" "$SOUNDS" \
      >"$TMP_ROOT/guard-after.json"
    cmp "$TMP_ROOT/guard-before.json" "$TMP_ROOT/guard-after.json" || fail "install_legacy_input_wrote_targets"
  done
done
DICTATE_CONFIG_DIR=legacy-secret-value LOWKEY_SIGNING_IDENTITY= \
  "$ROOT/install.sh" --help >"$TMP_ROOT/guard-help.out"
fixture_snapshot "$CUSTOM_HOME" "$CUSTOM_BIN" "$PROFILE" "$MODELS" "$NATIVE" "$SOUNDS" \
  >"$TMP_ROOT/guard-help-after.json"
cmp "$TMP_ROOT/guard-before.json" "$TMP_ROOT/guard-help-after.json" || fail "install_help_wrote_targets"
echo "PASS: install_rejects_present_legacy_inputs_before_writes_and_keeps_help_pure"

custom_install --no-sounds >"$TMP_ROOT/custom-install.log"
absent "$CUSTOM_BIN/tmux-whisper"
absent "$CUSTOM_BIN/khuluma-lib/doctor_compat.py"
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

retirement_install() {
  local case_root="$1"
  shift
  HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/home/.config" XDG_DATA_HOME="$case_root/home/.local/share" \
    KHULUMA_BIN_DIR="$case_root/bin" KHULUMA_CONFIG_DIR="$case_root/profile" \
    KHULUMA_CONFIG_FILE="$case_root/profile/config.toml" KHULUMA_NATIVE_DIR="$case_root/native" \
    KHULUMA_PARAKEET_MODELS_DIR="$case_root/models" KHULUMA_SOUNDS_DIR="$case_root/sounds" \
    KHULUMA_INSTALL_WARMUP=0 "$ROOT/install.sh" "$@"
}

retired="$TMP_ROOT/retirement-success"
mkdir -p "$retired/home" "$retired/bin"
released_shim "$retired/bin/tmux-whisper"
shim_identity="$(python3 - "$retired/bin/tmux-whisper" <<'PYTOKEN'
import os, sys
s = os.lstat(sys.argv[1])
print(f"{s.st_dev}:{s.st_ino}:{s.st_mode}")
PYTOKEN
)"
retirement_install "$retired" --force --no-sounds >"$TMP_ROOT/retirement-success.log"
absent "$retired/bin/tmux-whisper"
[[ -x "$retired/bin/khuluma" ]] || fail "retirement_missing_canonical_cli"
python3 - "$retired/bin" "$shim_identity" <<'PYRETAINED'
import hashlib, pathlib, sys
matches = []
for path in pathlib.Path(sys.argv[1]).glob(".khuluma-install.*/previous"):
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == "ab5f0067c075c177c2f56e99fe065a04662cde3636ca8f820957a9daf7e9fab6":
        info = path.lstat()
        matches.append(f"{info.st_dev}:{info.st_ino}:{info.st_mode}")
assert matches == [sys.argv[2]], matches
PYRETAINED
echo "PASS: install_retires_exact_released_shim_with_original_inode_retained"

failed="$TMP_ROOT/retirement-failure"
mkdir -p "$failed/home" "$failed/bin" "$failed/mock-bin"
released_shim "$failed/bin/tmux-whisper"
cat >"$failed/mock-bin/cp" <<'SHFAIL'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    */bin/khuluma)
      [[ ! -e "$RETIREMENT_TARGET" && ! -L "$RETIREMENT_TARGET" ]] || exit 75
      printf 'retired before injected failure\n' >"$RETIREMENT_PROOF"
      exit 74 ;;
  esac
done
exec /bin/cp "$@"
SHFAIL
chmod +x "$failed/mock-bin/cp"
fixture_snapshot "$failed/bin/tmux-whisper" >"$TMP_ROOT/retirement-failure-before.json"
rc=0
RETIREMENT_TARGET="$failed/bin/tmux-whisper" RETIREMENT_PROOF="$TMP_ROOT/post-retirement-proof" \
  PATH="$failed/mock-bin:$PATH" retirement_install "$failed" --force --no-sounds \
  >"$TMP_ROOT/retirement-failure.log" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "retirement_expected_post_retirement_failure"
[[ -f "$TMP_ROOT/post-retirement-proof" ]] || fail "retirement_failure_happened_before_shim_retired"
fixture_snapshot "$failed/bin/tmux-whisper" >"$TMP_ROOT/retirement-failure-after.json"
cmp "$TMP_ROOT/retirement-failure-before.json" "$TMP_ROOT/retirement-failure-after.json" \
  || fail "retirement_failed_to_restore_original_shim"
absent "$failed/bin/khuluma"
absent "$failed/profile"
absent "$failed/native"
absent "$failed/models"
echo "PASS: install_failure_after_retirement_restores_exact_original_shim"

# Race the interval between the second shim verification and its exclusive
# rename. Both mutations keep the inode, so a dev:ino check alone cannot catch
# them. The mocked boundary delegates all other mktemp operations unchanged.
real_mktemp="$(command -v mktemp)"
for mutation in bytes mode; do
  raced="$TMP_ROOT/retirement-race-$mutation"
  mkdir -p "$raced/home" "$raced/bin" "$raced/mock-bin"
  released_shim "$raced/bin/tmux-whisper"
  fixture_snapshot "$raced/bin/tmux-whisper" >"$TMP_ROOT/race-$mutation-before.json"
  cat >"$raced/mock-bin/mktemp" <<'SHRACE'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    */.khuluma-install.XXXXXX)
      [[ ! -e "$RACE_PROOF" ]] || break
      python3 - "$RACE_TARGET" "$RACE_MUTATION" "$RACE_PROOF" <<'PYRACE'
import hashlib, json, os, pathlib, stat, sys
target, mutation, proof = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
assert not proof.exists(), "race boundary was invoked more than once"
before = target.lstat()
assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
data = target.read_bytes()
assert hashlib.sha256(data).hexdigest() == "ab5f0067c075c177c2f56e99fe065a04662cde3636ca8f820957a9daf7e9fab6"
if mutation == "bytes":
    changed = data.replace(b"Temporary compatibility", b"temporary compatibility", 1)
    assert changed != data and len(changed) == len(data)
    with target.open("r+b") as handle:
        handle.write(changed)
        handle.flush()
        os.fsync(handle.fileno())
else:
    target.chmod(0o700)
info = target.lstat()
assert (info.st_dev, info.st_ino) == (before.st_dev, before.st_ino)
record = [info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_mtime_ns,
          hashlib.sha256(target.read_bytes()).hexdigest()]
with proof.open("x") as handle:
    handle.write(json.dumps({str(target): record}, sort_keys=True) + "\n")
proof.chmod(0o600)
PYRACE
      [[ "$?" == 0 ]] || exit 76 ;;
  esac
done
exec "$RACE_REAL_MKTEMP" "$@"
SHRACE
  chmod +x "$raced/mock-bin/mktemp"
  rc=0
  RACE_TARGET="$raced/bin/tmux-whisper" RACE_MUTATION="$mutation" \
    RACE_PROOF="$TMP_ROOT/race-$mutation-mutated.json" RACE_REAL_MKTEMP="$real_mktemp" \
    PATH="$raced/mock-bin:$PATH" retirement_install "$raced" --force --no-sounds \
    >"$TMP_ROOT/race-$mutation.log" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "retirement_accepted_in_place_$mutation_race"
  [[ -f "$TMP_ROOT/race-$mutation-mutated.json" ]] || fail "retirement_$mutation_race_not_injected"
  fixture_snapshot "$raced/bin/tmux-whisper" >"$TMP_ROOT/race-$mutation-after.json"
  cmp "$TMP_ROOT/race-$mutation-mutated.json" "$TMP_ROOT/race-$mutation-after.json" \
    || fail "retirement_did_not_restore_exact_changed_$mutation_shim"
  python3 - "$TMP_ROOT/race-$mutation-before.json" "$TMP_ROOT/race-$mutation-mutated.json" "$mutation" <<'PYCHANGED'
import json, sys
before, changed = (next(iter(json.load(open(path)).values())) for path in sys.argv[1:3])
assert before[:2] == changed[:2], "mutation replaced the inode instead of racing in place"
if sys.argv[3] == "bytes":
    assert before[5] != changed[5]
else:
    assert before[2] != changed[2]
PYCHANGED
  for path in "$raced/bin/khuluma" "$raced/profile" "$raced/native" "$raced/models" "$raced/sounds" "$raced/share"; do
    absent "$path"
  done
done
echo "PASS: install_refuses_in_place_shim_byte_or_mode_races_and_restores_changed_original"

for kind in unknown symlink; do
  rejected="$TMP_ROOT/retirement-$kind"
  mkdir -p "$rejected/home" "$rejected/bin"
  if [[ "$kind" == unknown ]]; then
    printf '#!/usr/bin/env bash\nprintf retained\n' >"$rejected/bin/tmux-whisper"
    chmod +x "$rejected/bin/tmux-whisper"
  else
    released_shim "$rejected/released-shim"
    ln -s "$rejected/released-shim" "$rejected/bin/tmux-whisper"
  fi
  fixture_snapshot "$rejected" >"$TMP_ROOT/retirement-$kind-before.json"
  rc=0
  retirement_install "$rejected" --force --no-sounds >"$TMP_ROOT/retirement-$kind.log" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "retirement_unsafe_$kind_not_refused"
  fixture_snapshot "$rejected" >"$TMP_ROOT/retirement-$kind-after.json"
  cmp "$TMP_ROOT/retirement-$kind-before.json" "$TMP_ROOT/retirement-$kind-after.json" \
    || fail "retirement_unsafe_$kind_changed_targets"
done
echo "PASS: install_refuses_unknown_or_symlink_shim_before_any_target_writes"
echo "Install identity tests passed."
