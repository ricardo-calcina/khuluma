#!/usr/bin/env bash
# Build Khuluma.app (the native menu-bar dictation app) and install it to
# ~/Applications. Needs only the Command Line Tools.
#
#   tools/make-signing-identity.sh   # once
#   tools/build-khuluma-app.sh        # build, sign, install
#   tools/build-khuluma-app.sh --no-install --out /tmp/Khuluma.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/tmux-whisperd"
APP_NAME="Khuluma"
BUNDLE_ID="com.ricardo-nth.lowkey"
# The identity keeps its Lowkey-era name: macOS ties the Microphone and
# Accessibility grants to it, so renaming it would ask for them again.
IDENTITY="${KHULUMA_SIGNING_IDENTITY:-${LOWKEY_SIGNING_IDENTITY:-Lowkey Local Code Signing}}"
OUT="$HOME/Applications/$APP_NAME.app"
INSTALL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --no-install) INSTALL=0 ;;
    --identity) IDENTITY="$2"; shift ;;
    *) echo "usage: $0 [--out PATH.app] [--no-install] [--identity NAME]" >&2; exit 2 ;;
  esac
  shift
done

# Refuse destinations that aren't a .app path or are anything other than an
# existing Khuluma bundle, so a mistyped --out can never delete a folder.
[[ "$OUT" == *.app ]] || { echo "--out must end in .app: $OUT" >&2; exit 2; }
if [[ -L "$OUT" ]]; then
  echo "refusing to replace a symlink: $OUT" >&2; exit 2
fi
if [[ -e "$OUT" ]]; then
  existing_id="$(plutil -extract CFBundleIdentifier raw -o - "$OUT/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "$BUNDLE_ID" ]]; then
    echo "refusing to replace $OUT: not a $APP_NAME bundle (bundle id: ${existing_id:-none})" >&2; exit 2
  fi
fi

version="$(sed -n 's/^TMUX_WHISPER_CLI_VERSION="\(.*\)"$/\1/p' "$ROOT/bin/tmux-whisper")"
build_number="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "Building $APP_NAME $version ($build_number)…"
(cd "$PKG" && swift build -c release --product "$APP_NAME")
binary="$PKG/.build/release/$APP_NAME"
[[ -x "$binary" ]] || { echo "build did not produce $binary" >&2; exit 1; }

stage="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$binary" "$stage/Contents/MacOS/$APP_NAME"
cat >"$stage/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$build_number</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Khuluma records your voice while dictation is active and transcribes it locally on this Mac.</string>
</dict>
</plist>
PLIST
plutil -lint "$stage/Contents/Info.plist" >/dev/null

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --options runtime --timestamp=none \
    --entitlements "$PKG/App/Khuluma.entitlements" \
    --sign "$IDENTITY" "$stage"
  echo "Signed with: $IDENTITY"
else
  echo "warning: signing identity \"$IDENTITY\" not found; signing ad hoc." >&2
  echo "         Permissions will reset on every rebuild. Run tools/make-signing-identity.sh." >&2
  codesign --force --options runtime --entitlements "$PKG/App/Khuluma.entitlements" --sign - "$stage"
fi
codesign --verify --strict "$stage"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The executable an installed bundle runs (Lowkey for builds from before the
# rename).
bundle_executable() {
  plutil -extract CFBundleExecutable raw -o - "$1/Contents/Info.plist" 2>/dev/null || echo "$APP_NAME"
}

# Quits the app at bundle path $1 (executable $2) if it's running, after
# letting a dictation in progress finish. Sets was_running=1 if it was.
# Exits if it won't quit.
quit_running() {
  local bundle="$1" exe_name="$2" bundle_abs exe pid waited
  # Match the running executable by its exact, resolved path (not a regex,
  # so relative --out paths and special characters can't cause a miss).
  bundle_abs="$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")"
  exe="$bundle_abs/Contents/MacOS/$exe_name"
  running_pid() {
    local pid command
    while read -r pid command; do
      if [[ "$command" == "$exe" || "$command" == "$exe "* ]]; then
        printf '%s\n' "$pid"
        return 0
      fi
    done < <(ps -axo pid=,command=)
    return 0
  }
  # A take in progress has a marker naming the running app's pid (from
  # recording start to delivery). Builds from before the rename write
  # inline-lowkey-* markers.
  take_in_progress() {
    local pid="$1" marker line
    for marker in "${DICTATE_PROCESSING_DIR:-/tmp/dictate-processing}"/inline-khuluma-* \
                  "${DICTATE_PROCESSING_DIR:-/tmp/dictate-processing}"/inline-lowkey-*; do
      [[ -f "$marker" ]] || continue
      IFS= read -r line <"$marker" 2>/dev/null || true
      [[ "$line" == "pid=$pid" ]] && return 0
    done
    return 1
  }
  pid="$(running_pid)"
  if [[ -n "$pid" ]]; then
    # Let a dictation finish so it lands where it was meant to. Quitting
    # mid-take is safe too (the audio is saved and transcribed into
    # history), so give up waiting after 5 minutes.
    waited=0
    while take_in_progress "$pid" && (( waited < 3000 )); do
      (( waited == 0 )) && echo "Waiting for the dictation in progress to finish (up to 5 min)…"
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
  if [[ -n "$(running_pid)" ]]; then
    was_running=1
    # Quit this copy by its pid's bundle path: both copies share a bundle id.
    osascript -e "tell application \"$bundle_abs\" to quit" >/dev/null 2>&1 || true
    waited=0
    while [[ -n "$(running_pid)" ]] && (( waited < 600 )); do
      (( waited == 10 )) && echo "Waiting for $exe_name to finish its current dictation…"
      sleep 0.1
      waited=$((waited + 1))
    done
    if [[ -n "$(running_pid)" ]]; then
      echo "$exe_name is still running after 60s; not replacing it. Quit it and rerun." >&2
      exit 1
    fi
  fi
}

if [[ "$INSTALL" == "1" || "$OUT" != "$HOME/Applications/$APP_NAME.app" ]]; then
  mkdir -p "$(dirname "$OUT")"
  was_running=0
  # Before the rename the app was ~/Applications/Lowkey.app (same bundle id).
  # Quit it like a running copy; once the new app is installed and verified,
  # move it to the Trash, so only one app answers to the bundle id.
  legacy="$HOME/Applications/Lowkey.app"
  retire_legacy=0
  if [[ "$OUT" == "$HOME/Applications/$APP_NAME.app" && -d "$legacy" && ! -L "$legacy" ]] \
    && [[ "$(plutil -extract CFBundleIdentifier raw -o - "$legacy/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]; then
    quit_running "$legacy" "$(bundle_executable "$legacy")"
    retire_legacy=1
  fi
  if [[ -d "$OUT" ]]; then
    # Quit a running copy so the new build takes over. The app finishes a
    # take in progress (transcribe, paste, record) before it exits, so wait
    # for the process to go rather than replacing the bundle underneath it.
    quit_running "$OUT" "$(bundle_executable "$OUT")"
    rm -rf "$OUT"
  fi
  if ! ditto "$stage" "$OUT" || ! codesign --verify --strict "$OUT"; then
    echo "error: could not install $OUT" >&2
    if [[ "$retire_legacy" == "1" && "$was_running" == "1" ]]; then
      open "$legacy" && echo "Relaunched the old Lowkey.app." >&2
    fi
    exit 1
  fi
  echo "Installed: $OUT"
  if [[ "$retire_legacy" == "1" ]]; then
    "$LSREGISTER" -u "$legacy" >/dev/null 2>&1 || true
    trashed="$HOME/.Trash/Lowkey $(date '+%Y-%m-%d %H.%M.%S').app"
    if mv "$legacy" "$trashed"; then
      echo "Moved the old Lowkey.app to the Trash. If you used Start at Login, turn it on again in Khuluma's menu."
    else
      echo "warning: could not move $legacy to the Trash; remove it by hand." >&2
    fi
  fi
  # Register with Launch Services and Spotlight, so "Khuluma" shows up in
  # Spotlight/Launchpad even from ~/Applications (Finder's Applications
  # sidebar item is /Applications).
  "$LSREGISTER" -f "$OUT" >/dev/null 2>&1 || true
  mdimport "$OUT" >/dev/null 2>&1 || true
  if [[ "$was_running" == "1" ]]; then
    open "$OUT"
    echo "Relaunched $APP_NAME."
  fi
fi
rm -rf "$(dirname "$stage")"
