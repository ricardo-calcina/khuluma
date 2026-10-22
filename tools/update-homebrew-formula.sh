#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/bin/khuluma-lib/identity.sh"

usage() {
  cat <<'EOF'
Usage:
  tools/update-homebrew-formula.sh vX.Y.Z [--write] [--formula /path/to/khuluma.rb] [--repo owner/name]

Examples:
  tools/update-homebrew-formula.sh v0.5.1
  tools/update-homebrew-formula.sh v0.5.1 --write
  tools/update-homebrew-formula.sh v0.5.1 --write --formula ../homebrew-tap/Formula/khuluma.rb

Behavior:
  - Downloads the GitHub tag tarball for the requested version.
  - Computes the sha256 Homebrew expects.
  - Prints the resolved url + sha256.
  - With --write, updates the formula file in place.
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing dependency: $1" >&2
    exit 2
  }
}

repo_slug="ricardo-nth/khuluma"
formula_path="$ROOT/../homebrew-tap/Formula/khuluma.rb"
write_mode="0"
tag=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --write)
      write_mode="1"
      shift
      ;;
    --formula)
      [[ $# -ge 2 ]] || {
        echo "--formula requires a path" >&2
        exit 2
      }
      formula_path="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || {
        echo "--repo requires owner/name" >&2
        exit 2
      }
      repo_slug="$2"
      shift 2
      ;;
    --*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$tag" ]]; then
        echo "unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      tag="$1"
      shift
      ;;
  esac
done
khuluma_reject_obsolete_environment

if [[ -z "$tag" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$tag" =~ ^v[0-9]+(\.[0-9]+)*([-.][A-Za-z0-9]+)?$ ]]; then
  echo "tag must look like vX.Y.Z: $tag" >&2
  exit 2
fi

[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repo slug" >&2; exit 2; }

need curl
need shasum
need python3

url="https://github.com/${repo_slug}/archive/refs/tags/${tag}.tar.gz"
tmpdir="$(mktemp -d "${KHULUMA_TMPDIR:-${TMPDIR:-/tmp}}/khuluma-formula.XXXXXX")"
trap 'printf "Formula workspace retained: %s\n" "$tmpdir" >&2' EXIT
archive="$tmpdir/${tag}.tar.gz"

curl -fsSL "$url" -o "$archive"
sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"

printf 'Tag: %s\n' "$tag"
printf 'Repo: %s\n' "$repo_slug"
printf 'URL: %s\n' "$url"
printf 'SHA256: %s\n' "$sha256"

if [[ "$write_mode" != "1" ]]; then
  printf '\nPreview only. Re-run with --write to update:\n  %s\n' "$formula_path"
  exit 0
fi

if [[ ! -f "$formula_path" ]]; then
  echo "formula not found: $formula_path" >&2
  exit 2
fi

python3 - "$formula_path" "$url" "$sha256" <<'PY'
from pathlib import Path
import re
import sys

formula_path = Path(sys.argv[1])
url = sys.argv[2]
sha256 = sys.argv[3]
text = formula_path.read_text()

text, url_count = re.subn(r'^\s*url\s+".*"$', f'  url "{url}"', text, count=1, flags=re.M)
text, sha_count = re.subn(r'^\s*sha256\s+".*"$', f'  sha256 "{sha256}"', text, count=1, flags=re.M)

if url_count != 1 or sha_count != 1:
    raise SystemExit(f"failed to update formula fields in {formula_path}")

formula_path.write_text(text)
PY

printf '\nUpdated formula:\n  %s\n' "$formula_path"
