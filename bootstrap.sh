#!/usr/bin/env bash
set -euo pipefail

# Standalone curl|bash cannot load the source module yet. Normalize only inputs
# consumed before that module is available; the installer normalizes the rest.
for suffix in BOOTSTRAP_REPO BOOTSTRAP_REF BOOTSTRAP_ARCHIVE_URL INSTALL_SOURCE INSTALL_ARCHIVE_URL TMPDIR; do
  canonical="KHULUMA_$suffix"; legacy="DICTATE_$suffix"
  if [[ -z "${!canonical:-}" && -n "${!legacy:-}" ]]; then
    printf -v "$canonical" '%s' "${!legacy}"
    export "$canonical"
  fi
done
usage() {
  cat <<'USAGE'
Usage: curl -fsSL <bootstrap-url> | bash -s -- [bootstrap options] [install options]

Installs Khuluma from a GitHub source archive.
Environment: KHULUMA_BOOTSTRAP_REPO, KHULUMA_BOOTSTRAP_REF,
             KHULUMA_BOOTSTRAP_ARCHIVE_URL (legacy DICTATE aliases accepted).
Options:
  --repo OWNER/REPO  source repository (default: ricardo-nth/khuluma)
  --ref REF          source branch/tag/commit (default: main)
  --archive-url URL  exact source archive URL (advanced/testing)
  -h, --help         show this help
Other arguments are forwarded to install.sh.
Example:
  curl -fsSL https://raw.githubusercontent.com/ricardo-nth/khuluma/main/bootstrap.sh | bash -s -- --no-sounds
USAGE
}
REPO="${KHULUMA_BOOTSTRAP_REPO:-ricardo-nth/khuluma}"
REF="${KHULUMA_BOOTSTRAP_REF:-main}"
ARCHIVE_URL="${KHULUMA_BOOTSTRAP_ARCHIVE_URL:-}"
INSTALL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo|--ref|--archive-url)
      option="$1"; shift
      [[ $# -gt 0 && -n "$1" ]] || { echo "$option requires a value" >&2; exit 2; }
      case "$option" in --repo) REPO="$1" ;; --ref) REF="$1" ;; --archive-url) ARCHIVE_URL="$1" ;; esac ;;
    --repo=*) REPO="${1#*=}" ;;
    --ref=*) REF="${1#*=}" ;;
    --archive-url=*) ARCHIVE_URL="${1#*=}" ;;
    --) shift; INSTALL_ARGS+=("$@"); break ;;
    *) INSTALL_ARGS+=("$1") ;;
  esac
  shift
done
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && -n "$REF" ]] || { echo "Invalid repository or ref" >&2; exit 2; }
for command in bash curl python3 mktemp; do
  command -v "$command" >/dev/null 2>&1 || { echo "bootstrap error: missing $command" >&2; exit 2; }
done
ARCHIVE_URL="${ARCHIVE_URL:-https://codeload.github.com/${REPO}/tar.gz/${REF}}"
echo "Bootstrap source: $REPO@$REF"
echo "Bootstrap archive: $ARCHIVE_URL"
TMP_DIR="$(mktemp -d "${KHULUMA_TMPDIR:-${TMPDIR:-/tmp}}/khuluma-bootstrap.XXXXXX")"
chmod 700 "$TMP_DIR"
# Retention is deliberate: diagnostics and an exact recovery target survive
# failed extraction/install; no permanent-delete trap is used.
trap 'printf "Bootstrap workspace retained: %s\n" "$TMP_DIR" >&2' EXIT
curl -fsSL "$ARCHIVE_URL" -o "$TMP_DIR/repo.tar.gz"
SRC_DIR="$(python3 - "$TMP_DIR/repo.tar.gz" "$TMP_DIR/source" <<'PY'
import os, pathlib, sys, tarfile
archive, destination = sys.argv[1:]
with tarfile.open(archive, "r:gz") as tar:
    members = tar.getmembers()
    roots = set()
    for item in members:
        path = pathlib.PurePosixPath(item.name)
        if path.is_absolute() or not path.parts or ".." in path.parts or "\\" in item.name:
            raise SystemExit("bootstrap error: unsafe archive path")
        if not (item.isfile() or item.isdir()):
            raise SystemExit("bootstrap error: links and special archive entries are not supported")
        roots.add(path.parts[0])
    if len(roots) != 1:
        raise SystemExit("bootstrap error: expected a single source archive root")
    root = next(iter(roots))
    entries = {item.name.rstrip("/"): item for item in members}
    required = (f"{root}/install.sh", f"{root}/bin/khuluma", f"{root}/bin/khuluma-lib/identity.sh", f"{root}/native/Package.swift")
    if any(name not in entries or not entries[name].isfile() for name in required):
        raise SystemExit("bootstrap error: incomplete canonical Khuluma source archive")
    if not entries[required[0]].mode & 0o111:
        raise SystemExit("bootstrap error: installer is not executable")
    os.mkdir(destination, 0o700)
    # Every member has been checked before any extraction; no archive links can
    # redirect a later member outside this fresh private destination.
    for item in members:
        tar.extract(item, destination)
    print(os.path.join(destination, root))
PY
)"
KHULUMA_INSTALL_SOURCE="bootstrap:$REPO@$REF" KHULUMA_INSTALL_ARCHIVE_URL="$ARCHIVE_URL" \
  bash "$SRC_DIR/install.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}
