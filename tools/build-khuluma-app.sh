#!/usr/bin/env bash
# Assemble Khuluma.app. Preview requires a fresh explicit output; installation
# preserves the previous verified bundle for rollback and never creates a key.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/bin/khuluma-lib/identity.sh"
source "$ROOT/bin/khuluma-lib/migration.sh"
PKG="$ROOT/native"
APP_NAME=Khuluma
BUNDLE_ID=com.ricardo-nth.khuluma
LEGACY_BUNDLE_ID=com.ricardo-nth.lowkey
IDENTITY="${KHULUMA_SIGNING_IDENTITY:-Khuluma Local Code Signing}"
KEYCHAIN="${KHULUMA_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OUT="$HOME/Applications/Khuluma.app"
INSTALL=1
EXPLICIT_OUT=0
usage() { echo "usage: $0 [--out PATH.app] [--no-install] [--identity NAME]" >&2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out|--identity)
      option="$1"; shift
      [[ $# -gt 0 && -n "$1" ]] || { usage; exit 2; }
      if [[ "$option" == --out ]]; then OUT="$1"; EXPLICIT_OUT=1; else IDENTITY="$1"; fi ;;
    --no-install) INSTALL=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
APP_ICON="$ROOT/assets/icons/app/Khuluma.icns"
MENU_ICON="$ROOT/assets/icons/menu-bar/khuluma-menu-template.pdf"
for resource in "$APP_ICON" "$MENU_ICON"; do
  [[ -s "$resource" ]] || { echo "Required icon resource missing: $resource" >&2; exit 2; }
done
khuluma_reject_obsolete_environment
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }
OUT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$OUT")"
[[ "$OUT" == *.app && ! -L "$OUT" ]] || { echo "Refusing non-app or symlink output: $OUT" >&2; exit 2; }
# Directory-aware shell mv can treat a raced destination as a container. Use
# the platform's exclusive rename syscall, and validate the owned source inode.
path_token() {
  python3 - "$1" <<'PYTOKEN'
import os, sys
try:
    info = os.lstat(sys.argv[1])
    print(f"{info.st_dev}:{info.st_ino}")
except OSError:
    raise SystemExit(1)
PYTOKEN
}
exclusive_rename() {
  python3 - "$1" "$2" "${3:-}" <<'PYRENAME'
import ctypes, os, sys
source, destination, expected = sys.argv[1:]
info = os.lstat(source)
if info.st_uid != os.getuid() or (expected and expected != f"{info.st_dev}:{info.st_ino}"):
    raise SystemExit(f"Refusing changed or unowned rename source: {source}")
libc = ctypes.CDLL(None, use_errno=True)
if sys.platform == "darwin":
    operation = libc.renamex_np
    operation.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    result = operation(os.fsencode(source), os.fsencode(destination), 0x00000004) # RENAME_EXCL
elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
    operation = libc.renameat2
    operation.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    result = operation(-100, os.fsencode(source), -100, os.fsencode(destination), 1) # RENAME_NOREPLACE
else:
    raise SystemExit("Platform lacks an atomic exclusive rename; destination left unchanged")
if result != 0:
    error = ctypes.get_errno()
    raise SystemExit(f"Refusing rename {source} -> {destination}: {os.strerror(error)}")
PYRENAME
}

# Every existing parent must be a real directory owned by this user or root.
python3 - "$(dirname "$OUT")" <<'PYPARENTS'
import os, pathlib, stat, sys
for path in sys.argv[1:]:
    current = pathlib.Path("/")
    for component in pathlib.Path(path).parts[1:]:
        current = current / component
        if not os.path.lexists(current):
            break
        info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid()):
            raise SystemExit(f"Refusing symlink, non-directory or unowned install ancestor: {current}")
    if os.path.lexists(path) and os.lstat(path).st_uid != os.getuid():
        raise SystemExit(f"Refusing unowned installation root: {path}")
PYPARENTS
# Resolve existing parents as well, so an alias/symlink cannot disguise a daily
# app path as a preview. Preview never replaces any existing destination.
if [[ "$INSTALL" == 0 ]]; then
  [[ "$EXPLICIT_OUT" == 1 && ! -e "$OUT" ]] || { echo "--no-install requires a fresh explicit --out PATH.app" >&2; exit 2; }
  python3 - "$OUT" "$HOME" <<'PY'
import os, sys
output, home = sys.argv[1:]
protected = (os.path.join(home, "Applications", "Khuluma.app"), os.path.join(home, "Applications", "Lowkey.app"), "/Applications/Khuluma.app", "/Applications/Lowkey.app")
if os.path.realpath(output) in {os.path.realpath(path) for path in protected}:
    raise SystemExit("preview output must be separate from the daily app")
PY
else
  # A direct build must not perform a partial legacy runtime/data cutover.
  khuluma_identity_preflight "${KHULUMA_BIN_DIR:-$HOME/.local/bin}/khuluma"
fi
[[ "$IDENTITY" != - && "$IDENTITY" != "Lowkey Local Code Signing" ]] || { echo "Select the new Khuluma signing identity; the legacy certificate is retained for rollback." >&2; exit 2; }
# find-identity requires a usable private key, unlike find-certificate. Signing
# fails closed; ad-hoc output cannot silently become an accepted installation.
identity_listing="$(security find-identity -p codesigning "$KEYCHAIN")"
# A self-signed local identity need not be a globally trusted root. Select one
# exact private-key identity, then let actual signing/strict verification prove
# usability; never broaden TLS trust or fall back to ad-hoc output.
IDENTITY_HASH="$(printf '%s\n' "$identity_listing" | python3 -c '
import re, sys
requested = sys.argv[1]
found = {}
for line in sys.stdin:
    match = re.match(r"\s*\d+\)\s+([0-9A-Fa-f]{40})\s+\"([^\"]+)\"", line)
    if not match:
        continue
    digest, name = match.groups()
    if name == requested or digest.casefold() == requested.casefold():
        if name == "Lowkey Local Code Signing":
            raise SystemExit("The legacy shared certificate cannot complete the Khuluma identity transition")
        found[digest.upper()] = name
if len(found) != 1:
    raise SystemExit("Signing identity missing or ambiguous; see tools/make-signing-identity.sh")
print(next(iter(found)))
' "$IDENTITY")" || exit 2

bundle_executable() { plutil -extract CFBundleExecutable raw -o - "$1/Contents/Info.plist"; }
verify_existing_bundle() {
  local bundle="$1" existing_id executable
  [[ -d "$bundle" && ! -L "$bundle" ]] || return 1
  existing_id="$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)"
  executable="$(bundle_executable "$bundle" 2>/dev/null || true)"
  [[ "$existing_id" == "$BUNDLE_ID" && "$executable" == Khuluma ]] || return 1
  [[ -x "$bundle/Contents/MacOS/$executable" ]] || return 1
  codesign --verify --strict "$bundle"
}
# A separate pre-Khuluma app must be quiesced by the serialized migration
# controller, including its login/admission route. A direct build cannot make
# that proof and must not install a competing writer beside it.
legacy_app="$HOME/Applications/Lowkey.app"
if [[ "$INSTALL" == 1 && "$OUT" != "$legacy_app" && -e "$legacy_app" ]]; then
  legacy_id="$(plutil -extract CFBundleIdentifier raw -o - "$legacy_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$legacy_id" == "$LEGACY_BUNDLE_ID" ]]; then
    echo "Controlled identity migration must drain and retain $legacy_app and its login route before installing Khuluma. Legacy app left unchanged." >&2
    exit 2
  fi
fi
initial_output_token=""
if [[ -e "$OUT" ]]; then
  verify_existing_bundle "$OUT" || { echo "Refusing unrelated or unverifiable bundle: $OUT" >&2; exit 2; }
  initial_output_token="$(path_token "$OUT")"
fi
version="$(sed -n 's/^KHULUMA_CLI_VERSION="\(.*\)"$/\1/p' "$ROOT/bin/khuluma")"
[[ -n "$version" ]] || { echo "Could not read canonical CLI version" >&2; exit 2; }
build_number="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
stage_root="$(mktemp -d "${KHULUMA_TMPDIR:-${TMPDIR:-/tmp}}/khuluma-app-build.XXXXXX")"
chmod 700 "$stage_root"
echo "Build workspace: $stage_root"
stage="$stage_root/Khuluma.app"
echo "Building Khuluma $version ($build_number)…"
# An isolated scratch path prevents a preview from changing the source build
# cache or using an unrelated cached binary. The workspace remains inspectable.
swift build --package-path "$PKG" --scratch-path "$stage_root/swift-build" --jobs 1 -c release --product Khuluma
binary="$stage_root/swift-build/release/Khuluma"
[[ -x "$binary" ]] || { echo "Build did not produce $binary" >&2; exit 1; }
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$binary" "$stage/Contents/MacOS/Khuluma"
cp "$APP_ICON" "$stage/Contents/Resources/Khuluma.icns"
cp "$MENU_ICON" "$stage/Contents/Resources/KhulumaMenuTemplate.pdf"
python3 - "$stage/Contents/Info.plist" "$BUNDLE_ID" "$version" "$build_number" <<'PY'
import plistlib, sys
path, identifier, version, build = sys.argv[1:]
with open(path, "wb") as handle:
    plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleName": "Khuluma", "CFBundleDisplayName": "Khuluma", "CFBundleExecutable": "Khuluma", "CFBundleIconFile": "Khuluma.icns", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build, "CFBundleInfoDictionaryVersion": "6.0", "LSMinimumSystemVersion": "14.0", "LSUIElement": True, "NSHighResolutionCapable": True, "NSMicrophoneUsageDescription": "Khuluma records your voice while dictation is active. Parakeet transcribes on this Mac; audio is sent to ElevenLabs only when you choose Scribe."}, handle)
PY
plutil -lint "$stage/Contents/Info.plist" >/dev/null
codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" \
  --entitlements "$PKG/App/Khuluma.entitlements" --sign "$IDENTITY_HASH" "$stage"
codesign --verify --strict "$stage"
signature_details="$(codesign -dvv "$stage" 2>&1)"
[[ "$signature_details" != *"Authority=Lowkey Local Code Signing"* ]] || { echo "Legacy signer cannot complete the Khuluma identity transition" >&2; exit 2; }
echo "Signed with: $IDENTITY ($IDENTITY_HASH)"

was_running=0
quit_running() {
  local bundle="$1" exe
  exe="$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")/Contents/MacOS/$(bundle_executable "$bundle")"
  # Always use the supported lifecycle API. A failed process-list probe must
  # never be mistaken for an idle app. Quit lets the app durably recover takes.
  was_running="$(swift - "$bundle" "$exe" <<'SWIFTQUIT'
import AppKit
let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let executable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard let identifier = Bundle(url: bundle)?.bundleIdentifier else {
  fputs("Cannot establish existing app identity; destination left unchanged\n", stderr)
  exit(1)
}
let atBundle = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == bundle }
guard atBundle.allSatisfy({ $0.executableURL?.standardizedFileURL == executable && $0.bundleIdentifier == identifier }) else {
  fputs("Running app identity mismatch; destination left unchanged\n", stderr)
  exit(1)
}
func currentApplicationsAtBundle() -> [NSRunningApplication] {
  let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
  guard candidates.allSatisfy({ $0.bundleURL != nil }) else {
    fputs("Cannot establish running app path; destination left unchanged\n", stderr)
    exit(1)
  }
  let matches = candidates.filter { $0.bundleURL?.standardizedFileURL == bundle }
  guard matches.allSatisfy({ $0.executableURL?.standardizedFileURL == executable && $0.bundleIdentifier == identifier }) else {
    fputs("Running app identity mismatch; destination left unchanged\n", stderr)
    exit(1)
  }
  return matches
}
for application in atBundle {
  guard application.terminate() else {
    fputs("App refused graceful termination; destination left unchanged\n", stderr)
    exit(1)
  }
}
let deadline = Date().addingTimeInterval(60)
while !currentApplicationsAtBundle().isEmpty && Date() < deadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard currentApplicationsAtBundle().isEmpty else {
  fputs("App did not finish graceful termination; destination left unchanged\n", stderr)
  exit(1)
}
print(atBundle.isEmpty ? "0" : "1")
SWIFTQUIT
)"
}

parent="$(dirname "$OUT")"
mkdir -p "$parent"
transaction="$(mktemp -d "$parent/.khuluma-app.XXXXXX")"
chmod 700 "$transaction"
ditto "$stage" "$transaction/candidate.app"
codesign --verify --strict "$transaction/candidate.app"
previous=0
installed_token="$(path_token "$transaction/candidate.app")"
restore_bundle() {
  local status="$1" current_token
  trap - ERR INT TERM
  current_token="$(path_token "$OUT" 2>/dev/null || true)"
  if [[ ! -e "$transaction/candidate.app" && "$current_token" == "$installed_token" ]]; then
    exclusive_rename "$OUT" "$transaction/failed.app" "$installed_token" || true
  fi
  if [[ -e "$transaction/previous.app" ]]; then
    exclusive_rename "$transaction/previous.app" "$OUT" || { echo "Destination preserved; restore manually: $transaction/previous.app -> $OUT" >&2; exit "$status"; }
    if [[ "$was_running" == 1 ]]; then open "$OUT" || true; fi
  fi
  echo "App install failed; recovery workspace: $transaction" >&2
  exit "$status"
}
trap 'restore_bundle $?' ERR
trap 'restore_bundle 130' INT
trap 'restore_bundle 143' TERM
# Only a bundle observed and verified before the build can be replaced. A new
# destination appearing while the build ran is unrelated and remains untouched.
current_output_token="$(path_token "$OUT" 2>/dev/null || true)"
if [[ "$current_output_token" != "$initial_output_token" ]]; then
  echo "Output changed during build; refusing replacement: $OUT" >&2
  false
fi
if [[ -n "$initial_output_token" ]]; then
  [[ "$INSTALL" == 1 ]] || { echo "Preview cannot replace an existing app" >&2; false; }
  verify_existing_bundle "$OUT"
  quit_running "$OUT"
  exclusive_rename "$OUT" "$transaction/previous.app" "$initial_output_token"
  previous=1
fi
exclusive_rename "$transaction/candidate.app" "$OUT" "$installed_token"
codesign --verify --strict "$OUT"
trap - ERR INT TERM
if [[ "$INSTALL" == 1 ]]; then
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -f "$OUT" >/dev/null 2>&1 || true
  mdimport "$OUT" >/dev/null 2>&1 || true
  if [[ "$was_running" == 1 ]]; then open "$OUT"; fi
  echo "Installed: $OUT"
else
  echo "Preview ready: $OUT (no app launch or service registration)"
fi
[[ "$previous" == 0 ]] || echo "Previous app retained for rollback: $transaction/previous.app"
echo "Build workspace retained: $stage_root"
