#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KHULUMA_BIN="$ROOT/bin/khuluma"
KHULUMA_TEST_FIXTURE_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
source "$ROOT/tests/fixture_helpers.sh"
trap report_fixture_root EXIT
# Never inherit the operator's credentials into this network-free suite.
unset ELEVENLABS_API_KEY ELEVEN_LABS_API_KEY ZDOTDIR

OUTPUT_DIR="$KHULUMA_TEST_FIXTURE_ROOT/output"
STUB_DIR="$HOME/.local/bin"
mkdir -p "$OUTPUT_DIR" "$STUB_DIR" "$HOME/.config/zsh" "$HOME/.config/khuluma"
export KHULUMA_CONFIG_DIR="$HOME/.config/khuluma"
export KHULUMA_CONFIG_FILE="$KHULUMA_CONFIG_DIR/config.toml"
export KHULUMA_TRANSCRIBE_LOG="$OUTPUT_DIR/transcribe.log"
export KHULUMA_TRANSCRIBE_FILE_LOG="$OUTPUT_DIR/file-transcribe.log"
export KHULUMA_DAEMON_BIN="$STUB_DIR/khulumad"
export KHULUMA_TRANSCRIBE_TAIL_PAD_MS=0
export KHULUMA_CLEAN=1
export KHULUMA_TEST_CURL_LOG="$OUTPUT_DIR/curl.jsonl"
export KHULUMA_TEST_DAEMON_LOG="$OUTPUT_DIR/daemon.log"
export KHULUMA_TEST_EXPECTED_KEY="fixture-shell-key"
export KHULUMA_SOUNDS_DIR="$KHULUMA_TEST_FIXTURE_ROOT/sounds"
mkdir -p "$KHULUMA_SOUNDS_DIR"
: >"$KHULUMA_SOUNDS_DIR/start.wav"
: >"$KHULUMA_SOUNDS_DIR/stop.wav"
cp "$ROOT/config/config.toml" "$KHULUMA_CONFIG_FILE"
: >"$KHULUMA_CONFIG_DIR/vocab"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

assert_json() {
  local name="$1" file="$2" expression="$3"
  python3 - "$file" "$expression" <<'PY' || fail "$name"
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert eval(sys.argv[2], {"data": data}), sys.argv[2]
PY
  pass "$name"
}

assert_absent() {
  [[ ! -e "$2" ]] || fail "$1"
  pass "$1"
}

reject_setting() {
  local name="$1" key="$2" value="$3" rc=0
  cp "$KHULUMA_CONFIG_FILE" "$OUTPUT_DIR/before-$name.toml"
  "$KHULUMA_BIN" app-settings set "$key" "$value" --json >"$OUTPUT_DIR/$name.json" 2>"$OUTPUT_DIR/$name.err" || rc=$?
  [[ "$rc" != 0 ]] || fail "$name exits nonzero"
  cmp -s "$KHULUMA_CONFIG_FILE" "$OUTPUT_DIR/before-$name.toml" || fail "$name preserves config"
  pass "$name refuses mutation"
}

reject_expected_provider() {
  local name="$1" message="$2" rc=0
  shift 2
  cp "$KHULUMA_TEST_CURL_LOG" "$OUTPUT_DIR/before-$name-curl.jsonl"
  "$KHULUMA_BIN" inline process "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --json "$@" \
    >"$OUTPUT_DIR/$name.json" 2>"$OUTPUT_DIR/$name.err" || rc=$?
  [[ "$rc" == 2 && ! -s "$OUTPUT_DIR/$name.json" ]] || fail "$name exits 2 before processing"
  [[ "$(cat "$OUTPUT_DIR/$name.err")" == *"$message"* ]] || fail "$name reports the provider guard"
  cmp -s "$KHULUMA_TEST_CURL_LOG" "$OUTPUT_DIR/before-$name-curl.jsonl" || fail "$name makes no cloud request"
  [[ ! -e "$KHULUMA_TEST_DAEMON_LOG" ]] || fail "$name starts no local daemon"
  pass "$name rejects before transcription"
}

# The actual curl executable is replaced at the CLI's first PATH entry. Its
# log contains only request structure and a credential comparison boolean.
cat >"$STUB_DIR/curl" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
config = sys.stdin.read()
expected = os.environ["KHULUMA_TEST_EXPECTED_KEY"]
with open(os.environ["KHULUMA_TEST_CURL_LOG"], "a", encoding="utf-8") as log:
    json.dump({"args": args, "credential_matches": expected in config,
               "credential_in_args": any(expected in arg for arg in args)}, log)
    log.write("\n")
mode = os.environ.get("KHULUMA_TEST_CURL_MODE", "ok")
if mode == "auth":
    sys.stdout.write(json.dumps({"detail": {"message": "rejected " + expected}}) + "\n401")
elif mode == "rate-limit":
    sys.stdout.write(json.dumps({"detail": {"message": "limited " + expected}}) + "\n429")
elif mode == "transport":
    print("network diagnostic " + expected, file=sys.stderr)
    sys.exit(7)
elif mode == "invalid-json":
    sys.stdout.write("not json " + expected + "\n200")
elif mode == "no-speech":
    sys.stdout.write('{"text":""}\n200')
else:
    sys.stdout.write('{"text":"um color is is useful"}\n200')
PY
cat >"$STUB_DIR/ffmpeg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
input=""
while [[ $# -gt 1 ]]; do
  if [[ "$1" == -i && -z "$input" ]]; then input="$2"; fi
  shift
done
cp "$input" "$1"
SH
cat >"$STUB_DIR/ffprobe" <<'SH'
#!/usr/bin/env bash
printf '3.000000\n'
SH
cat >"$STUB_DIR/khulumad" <<'SH'
#!/usr/bin/env bash
printf 'unexpected local daemon invocation\n' >>"$KHULUMA_TEST_DAEMON_LOG"
exit 99
SH
chmod +x "$STUB_DIR/curl" "$STUB_DIR/ffmpeg" "$STUB_DIR/ffprobe" "$STUB_DIR/khulumad"

"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/default.json"
assert_json "provider defaults to local Parakeet" "$OUTPUT_DIR/default.json" 'data["transcription"]["provider"] == "parakeet" and data["transcription"]["key_available"] is False'
assert_absent "reading config makes no cloud request" "$KHULUMA_TEST_CURL_LOG"

"$KHULUMA_BIN" app-settings set app.hotkey ctrl+shift+d --json >"$OUTPUT_DIR/hotkey.json"
assert_json "hotkey save returns effective settings" "$OUTPUT_DIR/hotkey.json" 'data["hotkey"] == "ctrl+shift+d"'
"$KHULUMA_BIN" app-settings set inline.autosend 0 --json >"$OUTPUT_DIR/autosend.json"
assert_json "boolean zero saves false" "$OUTPUT_DIR/autosend.json" 'data["inline"]["autosend"] is False'
"$KHULUMA_BIN" app-settings set debug.keep_logs true --json >"$OUTPUT_DIR/logging.json"
assert_json "logging save returns effective settings" "$OUTPUT_DIR/logging.json" 'data["transcription"]["keep_logs"] is True'
"$KHULUMA_BIN" app-settings set debug.keep_logs false --json >"$OUTPUT_DIR/logging-off.json"
python3 - "$KHULUMA_CONFIG_FILE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
assert "start_enabled = true" in text
path.write_text(text.replace("start_enabled = true", "start_enabled = false", 1), encoding="utf-8")
PY
"$KHULUMA_BIN" app-settings set audio.sounds.enabled 1 --json >"$OUTPUT_DIR/sounds-master-on.json"
assert_json "master sound setting is independent of the start event" "$OUTPUT_DIR/sounds-master-on.json" 'data["sounds_enabled"] is True and data["sounds"]["start"]["enabled"] is False and data["sounds"]["stop"]["enabled"] is True'
"$KHULUMA_BIN" app-settings set audio.sounds.enabled 0 --json >"$OUTPUT_DIR/sounds.json"
assert_json "sound switch disables every sound" "$OUTPUT_DIR/sounds.json" 'data["sounds_enabled"] is False and all(event["enabled"] is False for event in data["sounds"].values())'

reject_setting unknown-setting history.retention_days 42
reject_setting invalid-provider transcription.provider unknown
reject_setting invalid-boolean inline.autosend perhaps
reject_setting invalid-model-version swift_parakeet.model_version v4
reject_setting invalid-hotkey app.hotkey d

MODEL_DIR="$KHULUMA_TEST_FIXTURE_ROOT/parakeet-tdt-0.6b-v2-coreml"
OVERRIDE_MODEL_DIR="$KHULUMA_TEST_FIXTURE_ROOT/parakeet-tdt-0.6b-v3-coreml"
mkdir -p "$MODEL_DIR" "$OVERRIDE_MODEL_DIR"
"$KHULUMA_BIN" app-settings set swift_parakeet.model_path "$MODEL_DIR" --json >"$OUTPUT_DIR/model-path.json"
"$KHULUMA_BIN" app-settings set swift_parakeet.model_version v2 --json >"$OUTPUT_DIR/model-version.json"
assert_json "saved local model resolves version" "$OUTPUT_DIR/model-version.json" 'data["transcription"]["model_version"] == "v2"'
KHULUMA_SWIFT_PARAKEET_MODEL_PATH="$OVERRIDE_MODEL_DIR" KHULUMA_SWIFT_PARAKEET_MODEL_VERSION=v3 \
  "$KHULUMA_BIN" app-settings set swift_parakeet.model_version v2 --json >"$OUTPUT_DIR/model-override.json"
assert_json "saved settings report effective environment override" "$OUTPUT_DIR/model-override.json" 'data["transcription"]["model_version"] == "v3" and data["transcription"]["model_path"].endswith("-v3-coreml")'

REAL_CONFIG="$KHULUMA_TEST_FIXTURE_ROOT/dotfiles/config.toml"
mkdir -p "$(dirname "$REAL_CONFIG")"
mv "$KHULUMA_CONFIG_FILE" "$REAL_CONFIG"
ln -s "$REAL_CONFIG" "$KHULUMA_CONFIG_FILE"
"$KHULUMA_BIN" app-settings set inline.autosend 1 --json >"$OUTPUT_DIR/symlink.json"
[[ -L "$KHULUMA_CONFIG_FILE" ]] || fail "settings save preserves config symlink"
assert_json "settings writer updates symlink target" "$OUTPUT_DIR/symlink.json" 'data["inline"]["autosend"] is True'

# A malformed file must never be replaced by a settings write, even when a
# last-good snapshot lets the app continue reading the previous settings.
cp "$REAL_CONFIG" "$OUTPUT_DIR/valid-config.toml"
printf '[inline\nautosend = false\n' >"$REAL_CONFIG"
reject_setting invalid-config inline.autosend true
cp "$OUTPUT_DIR/valid-config.toml" "$REAL_CONFIG"

"$KHULUMA_BIN" app-settings set swift_parakeet.model_path '' --json >"$OUTPUT_DIR/model-clear.json"
assert_json "empty model path restores discovery without requiring a model" "$OUTPUT_DIR/model-clear.json" 'data["transcription"]["model_path"] is None'
"$KHULUMA_BIN" app-settings set transcription.provider elevenlabs --json >"$OUTPUT_DIR/cloud-no-key.json"
assert_json "cloud is an explicit setting with no implicit credential" "$OUTPUT_DIR/cloud-no-key.json" 'data["transcription"]["provider"] == "elevenlabs" and data["transcription"]["key_available"] is False and data["pipeline"]["supervise"] is False'
"$KHULUMA_BIN" warmup --json >"$OUTPUT_DIR/cloud-warmup.json"
assert_json "cloud warmup requires no local model" "$OUTPUT_DIR/cloud-warmup.json" 'data["reason"] == "cloud_provider"'
printf 'fixture audio\n' >"$KHULUMA_TEST_FIXTURE_ROOT/input.wav"
rc=0
"$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/missing-key.json" 2>"$OUTPUT_DIR/missing-key.err" || rc=$?
[[ "$rc" != 0 ]] || fail "missing key refuses cloud transcription"
assert_absent "missing key never reaches curl" "$KHULUMA_TEST_CURL_LOG"

# Both zshrc locations are treated as text. Neither command substitution nor
# unrelated shell commands may be executed while resolving the credential.
printf "export ELEVENLABS_API_KEY='fixture-shell-key'\ntouch '%s'\n" "$KHULUMA_TEST_FIXTURE_ROOT/zshrc-executed" >"$HOME/.config/zsh/.zshrc"
printf "export ELEVENLABS_API_KEY='fixture-fallback-key'\n" >"$HOME/.zshrc"
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/shell-key.json"
assert_json "literal zshrc export is available to GUI callers" "$OUTPUT_DIR/shell-key.json" 'data["transcription"]["key_available"] is True'
assert_absent "credential lookup does not execute zshrc" "$KHULUMA_TEST_FIXTURE_ROOT/zshrc-executed"
"$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/cloud-file.json" 2>"$OUTPUT_DIR/cloud-file.err"
assert_json "cloud files return raw text and provider metadata" "$OUTPUT_DIR/cloud-file.json" 'data["text"] == "um color is is useful" and data["model"] == "scribe_v2" and data["engine"] == "elevenlabs"'
assert_absent "file transcription writes no usage" "$KHULUMA_CONFIG_DIR/usage.json"
assert_absent "file transcription writes no history" "$KHULUMA_CONFIG_DIR/history"

reject_expected_provider queued-local-provider-changed "provider changed" --expected-provider parakeet
"$KHULUMA_BIN" app-settings set transcription.provider parakeet --json >"$OUTPUT_DIR/local-provider.json"
reject_expected_provider queued-cloud-provider-changed "provider changed" --expected-provider elevenlabs
"$KHULUMA_BIN" app-settings set transcription.provider elevenlabs --json >"$OUTPUT_DIR/cloud-provider-restored.json"
reject_expected_provider invalid-expected-provider "requires parakeet or elevenlabs" --expected-provider unknown
reject_expected_provider missing-expected-provider "requires parakeet or elevenlabs" --expected-provider

ELEVENLABS_API_KEY=fixture-env-key KHULUMA_TEST_EXPECTED_KEY=fixture-env-key \
  "$KHULUMA_BIN" inline process "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --json --defer-usage --expected-provider elevenlabs >"$OUTPUT_DIR/cloud-inline.json" 2>"$OUTPUT_DIR/cloud-inline.err"
assert_json "cloud inline uses the same deterministic cleanup and history" "$OUTPUT_DIR/cloud-inline.json" 'data["ok"] is True and data["raw_text"] == "color is useful" and data["text"] == "colour is useful" and data["history_saved"] is True and data["usage_deferred"] is True'
assert_absent "deferred cloud processing writes no usage" "$KHULUMA_CONFIG_DIR/usage.json"

printf '# no credential in the configured zshrc\n' >"$HOME/.config/zsh/.zshrc"
KHULUMA_TEST_EXPECTED_KEY=fixture-fallback-key \
  "$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/fallback-file.json" 2>"$OUTPUT_DIR/fallback-file.err"
assert_json "home zshrc literal export supplies the fallback credential" "$OUTPUT_DIR/fallback-file.json" 'data["engine"] == "elevenlabs"'
printf "export ELEVENLABS_API_KEY='fixture-shell-key'\n" >"$HOME/.config/zsh/.zshrc"

for failure in auth transport invalid-json no-speech; do
  rc=0
  KHULUMA_TEST_CURL_MODE="$failure" "$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet \
    >"$OUTPUT_DIR/$failure.json" 2>"$OUTPUT_DIR/$failure.err" || rc=$?
  [[ "$rc" != 0 && ! -s "$OUTPUT_DIR/$failure.json" ]] || fail "$failure cannot produce a successful transcript"
  pass "$failure reports file failure"
done
KHULUMA_TEST_CURL_MODE=auth "$KHULUMA_BIN" inline process "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --json --defer-usage >"$OUTPUT_DIR/auth-inline.json" 2>"$OUTPUT_DIR/auth-inline.err"
assert_json "cloud inline failure retains app JSON contract and authentication reason" "$OUTPUT_DIR/auth-inline.json" 'data["ok"] is False and data["status"] == "failed" and data["text"] == "" and data["history_saved"] is False and "ElevenLabs authentication failed (HTTP 401)" in data["message"]'
KHULUMA_TEST_CURL_MODE=rate-limit "$KHULUMA_BIN" inline process "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --json --defer-usage >"$OUTPUT_DIR/rate-limit-inline.json" 2>"$OUTPUT_DIR/rate-limit-inline.err"
assert_json "cloud inline rate limit reports its safe reason" "$OUTPUT_DIR/rate-limit-inline.json" 'data["ok"] is False and data["status"] == "failed" and data["text"] == "" and data["history_saved"] is False and "ElevenLabs request limit reached (HTTP 429)" in data["message"]'

# Only an explicit conventional source pair makes a private sibling eligible.
# Shell statements in either file remain inert data throughout lookup.
PRIVATE_CREDENTIAL_FILE="$HOME/.config/zsh/.zshrc.private"
HOME_PRIVATE_CREDENTIAL_FILE="$HOME/.zshrc.private"
ARBITRARY_PRIVATE_CREDENTIAL_FILE="$HOME/other/.zshrc.private"
export ZDOTDIR="$HOME/.config/zsh"
mkdir -p "$HOME/other"
printf "export ELEVENLABS_API_KEY='fixture-shell-key'\ntouch '%s'\n" "$HOME/private-executed" >"$PRIVATE_CREDENTIAL_FILE"
printf "export ELEVENLABS_API_KEY='fixture-shell-key'\ntouch '%s'\n" "$HOME/arbitrary-private-executed" >"$ARBITRARY_PRIVATE_CREDENTIAL_FILE"
printf '# no fallback credential\n' >"$HOME/.zshrc"
printf "touch '%s'\n" "$HOME/private-rc-executed" >"$HOME/.config/zsh/.zshrc"
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/private-unreferenced.json"
assert_json "unreferenced private sibling is not a credential source" "$OUTPUT_DIR/private-unreferenced.json" 'data["transcription"]["key_available"] is False'

cat >"$HOME/.config/zsh/.zshrc" <<'SH'
zsh_private_env="${ZDOTDIR:-$HOME}/.zshrc.private"
source "$zsh_private_env"
touch "$HOME/private-rc-executed"
SH
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/private-source.json"
assert_json "explicit conventional private source resolves its literal key" "$OUTPUT_DIR/private-source.json" 'data["transcription"]["key_available"] is True'
"$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/private-file.json" 2>"$OUTPUT_DIR/private-file.err"
assert_json "cloud request uses the explicitly sourced private key" "$OUTPUT_DIR/private-file.json" 'data["engine"] == "elevenlabs"'
ELEVENLABS_API_KEY=fixture-env-key KHULUMA_TEST_EXPECTED_KEY=fixture-env-key \
  "$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/private-env-override.json" 2>"$OUTPUT_DIR/private-env-override.err"
assert_json "environment key overrides the private sibling" "$OUTPUT_DIR/private-env-override.json" 'data["engine"] == "elevenlabs"'

printf "export ELEVEN_LABS_API_KEY='fixture-shell-key'\ntouch '%s'\n" "$HOME/private-executed" >"$PRIVATE_CREDENTIAL_FILE"
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/private-alias.json"
assert_json "private literal accepts the alternate key identifier" "$OUTPUT_DIR/private-alias.json" 'data["transcription"]["key_available"] is True'
"$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/private-alias-file.json" 2>"$OUTPUT_DIR/private-alias-file.err"
assert_json "cloud request uses the private alias key" "$OUTPUT_DIR/private-alias-file.json" 'data["engine"] == "elevenlabs"'
ELEVEN_LABS_API_KEY=fixture-env-key KHULUMA_TEST_EXPECTED_KEY=fixture-env-key \
  "$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/private-alias-env.json" 2>"$OUTPUT_DIR/private-alias-env.err"
assert_json "alternate environment key overrides a private file" "$OUTPUT_DIR/private-alias-env.json" 'data["engine"] == "elevenlabs"'
ELEVENLABS_API_KEY=fixture-env-key ELEVEN_LABS_API_KEY=fixture-fallback-key KHULUMA_TEST_EXPECTED_KEY=fixture-env-key \
  "$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/private-canonical-env.json" 2>"$OUTPUT_DIR/private-canonical-env.err"
assert_json "canonical environment key wins over the alternate environment key" "$OUTPUT_DIR/private-canonical-env.json" 'data["engine"] == "elevenlabs"'
printf "export ELEVENLABS_API_KEY='fixture-shell-key'\nexport ELEVEN_LABS_API_KEY='fixture-fallback-key'\ntouch '%s'\n" "$HOME/private-executed" >"$PRIVATE_CREDENTIAL_FILE"
"$KHULUMA_BIN" transcribe "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --format json --quiet >"$OUTPUT_DIR/private-canonical-literal.json" 2>"$OUTPUT_DIR/private-canonical-literal.err"
assert_json "canonical private literal wins even when the alternate literal comes later" "$OUTPUT_DIR/private-canonical-literal.json" 'data["engine"] == "elevenlabs"'

cat >"$HOME/.config/zsh/.zshrc" <<'SH'
zsh_private_env="$ZDOTDIR/.zshrc.private"
. "$zsh_private_env"
SH
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/private-dot-source.json"
assert_json "literal ZDOTDIR sibling and dot source are supported" "$OUTPUT_DIR/private-dot-source.json" 'data["transcription"]["key_available"] is True'
printf '# no credential in the configured zshrc\n' >"$HOME/.config/zsh/.zshrc"
printf "export ELEVENLABS_API_KEY='fixture-shell-key'\n" >"$HOME_PRIVATE_CREDENTIAL_FILE"
cat >"$HOME/.zshrc" <<'SH'
zsh_private_env="$HOME/.zshrc.private"
source "$zsh_private_env"
SH
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/private-home-source.json"
assert_json "literal HOME sibling source is supported for home zshrc" "$OUTPUT_DIR/private-home-source.json" 'data["transcription"]["key_available"] is True'
printf '# no fallback credential\n' >"$HOME/.zshrc"

cat >"$HOME/.config/zsh/.zshrc" <<'SH'
zsh_private_env="$(touch "$HOME/private-variable-executed"; printf '%s' "$ZDOTDIR/.zshrc.private")"
source "$zsh_private_env"
SH
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/private-substitution.json"
assert_json "private source variable cannot execute a substitution" "$OUTPUT_DIR/private-substitution.json" 'data["transcription"]["key_available"] is False'
assert_absent "private variable substitution never executes" "$HOME/private-variable-executed"
cat >"$HOME/.config/zsh/.zshrc" <<'SH'
zsh_private_env="$HOME/other/.zshrc.private"
source "$zsh_private_env"
SH
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/private-arbitrary-path.json"
assert_json "private source cannot follow a different arbitrary path" "$OUTPUT_DIR/private-arbitrary-path.json" 'data["transcription"]["key_available"] is False'
assert_absent "private source lookup never executes zshrc" "$HOME/private-rc-executed"
assert_absent "private source lookup never executes its sibling" "$HOME/private-executed"
assert_absent "private source lookup never executes an arbitrary file" "$HOME/arbitrary-private-executed"
preserve_fixture "$PRIVATE_CREDENTIAL_FILE" "$HOME_PRIVATE_CREDENTIAL_FILE" "$ARBITRARY_PRIVATE_CREDENTIAL_FILE"
unset ZDOTDIR

python3 - "$KHULUMA_TEST_CURL_LOG" <<'PY' || fail "cloud request structure and credential precedence"
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    requests = [json.loads(line) for line in stream]
assert len(requests) >= 6
for request in requests:
    assert request["credential_matches"] is True, request
    assert request["credential_in_args"] is False, request
    args = request["args"]
    assert "--config" in args and args[args.index("--config") + 1] == "-", request
    assert "https://api.elevenlabs.io/v1/speech-to-text" in args, request
    assert "model_id=scribe_v2" in args, request
PY
pass "cloud request structure and credential precedence"

printf "export ELEVENLABS_API_KEY=\$(touch '%s')\n" "$KHULUMA_TEST_FIXTURE_ROOT/substitution-executed" >"$HOME/.config/zsh/.zshrc"
printf '# no fallback credential\n' >"$HOME/.zshrc"
"$KHULUMA_BIN" app-config --json >"$OUTPUT_DIR/unsafe-key.json"
assert_json "shell substitutions are rejected as credentials" "$OUTPUT_DIR/unsafe-key.json" 'data["transcription"]["key_available"] is False'
assert_absent "credential substitution never executes" "$KHULUMA_TEST_FIXTURE_ROOT/substitution-executed"
cp "$KHULUMA_TEST_CURL_LOG" "$OUTPUT_DIR/before-missing-key-inline-curl.jsonl"
"$KHULUMA_BIN" inline process "$KHULUMA_TEST_FIXTURE_ROOT/input.wav" --json --defer-usage --expected-provider elevenlabs >"$OUTPUT_DIR/missing-key-inline.json" 2>"$OUTPUT_DIR/missing-key-inline.err"
assert_json "cloud inline missing key reports its safe reason" "$OUTPUT_DIR/missing-key-inline.json" 'data["ok"] is False and data["status"] == "failed" and data["text"] == "" and data["history_saved"] is False and "ElevenLabs API key unavailable" in data["message"]'
cmp -s "$KHULUMA_TEST_CURL_LOG" "$OUTPUT_DIR/before-missing-key-inline-curl.jsonl" || fail "missing inline key makes no API request"
pass "missing inline key makes no API request"
assert_absent "cloud file and inline never start local daemon" "$KHULUMA_TEST_DAEMON_LOG"

python3 - "$KHULUMA_TEST_FIXTURE_ROOT" "$PRIVATE_CREDENTIAL_FILE" "$HOME_PRIVATE_CREDENTIAL_FILE" "$ARBITRARY_PRIVATE_CREDENTIAL_FILE" <<'PY' || fail "credentials stay out of app JSON, logs, and diagnostics"
import pathlib, sys
secrets = (b"fixture-shell-key", b"fixture-fallback-key", b"fixture-env-key")
root = pathlib.Path(sys.argv[1])
credential_sources = set(sys.argv[2:])
for path in root.rglob("*"):
    if path.is_file():
        # The retained source fixtures intentionally contain mock credentials.
        # Skip only their exact recoverable payloads; logs and recovery stay
        # covered by the same whole-tree leak check.
        if path.name == "payload" and path.parent.parent == root / ".retained":
            marker = path.parent / "original-path"
            if marker.read_text(encoding="utf-8").strip() in credential_sources:
                continue
        payload = path.read_bytes()
        assert not any(secret in payload for secret in secrets), str(path)
PY
pass "credentials stay out of app JSON, logs, and diagnostics"
printf 'Provider and app-settings tests passed.\n'
