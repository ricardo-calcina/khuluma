#!/usr/bin/env bash

# Modes were removed in v0.11: every take uses the one vocab file. These
# helpers find what an older install left behind and fold it in once.

# modes/ or current-mode is still in the config dir.
legacy_modes_present() {
  [[ -d "$DICTATE_CONFIG_DIR/modes" || -f "$DICTATE_CONFIG_DIR/current-mode" ]]
}

# Number of correction rules (wrong::right or wrong -> right) in a vocab file.
vocab_rule_count() {
  local file="${1:-}"
  [[ -f "$file" ]] || { echo 0; return 0; }
  perl -CSD -ne '
    s/^\s+//; s/\s+$//;
    next if $_ eq "" || /^#/;
    if (/^(.*?)\s*::\s*(.*?)$/ || /^(.*?)\s*(?:\x{2192}|->)\s*(.*?)$/) {
      $n++ if length($1) && length($2);
    }
    END { print(($n // 0), "\n") }
  ' "$file" 2>/dev/null || echo 0
}

# tmux-whisper migrate-modes [--dry-run]
# Appends each modes/*/vocab rule that vocab doesn't already have (same
# words, ignoring case and spacing, as the corrector matches them), then
# moves modes/ and current-mode into modes-archive/<date>-modes-removed/
# with a copy of the old vocab. Nothing is deleted; running it again does
# nothing.
migrate_modes() {
  local dry_run="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="1" ;;
      *) die "usage: tmux-whisper migrate-modes [--dry-run]" ;;
    esac
    shift
  done
  need python3

  if ! legacy_modes_present; then
    echo "Nothing to migrate: no modes/ or current-mode in $DICTATE_CONFIG_DIR."
    return 0
  fi

  MIGRATE_CONFIG_DIR="$DICTATE_CONFIG_DIR" \
  MIGRATE_DRY_RUN="$dry_run" \
  MIGRATE_STAMP="$(date '+%Y-%m-%d-%H%M%S')" \
  MIGRATE_DATE="$(date '+%Y-%m-%d')" \
  python3 - <<'PYEOF'
import os, re, shutil, sys

config_dir = os.environ["MIGRATE_CONFIG_DIR"]
dry_run = os.environ["MIGRATE_DRY_RUN"] == "1"
modes_dir = os.path.join(config_dir, "modes")
mode_file = os.path.join(config_dir, "current-mode")
vocab_path = os.path.join(config_dir, "vocab")

# The corrector's own parse (bin/dictate-lib.sh), with Perl's idea of a
# line (split on LF only) and of whitespace (\s on decoded text), which are
# narrower than Python's splitlines() and str.split().
WS = "[\t\n\x0b\x0c\r \x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]"
TRIM = re.compile(f"^{WS}+|{WS}+$")
DOUBLE_COLON = re.compile(f"^(.*?){WS}*::{WS}*(.*?)$")
ARROW = re.compile(f"^(.*?){WS}*(?:\u2192|->){WS}*(.*?)$")

def trim(text):
    return TRIM.sub("", text)

def parse(line):
    line = trim(line)
    if not line or line.startswith("#"):
        return None
    m = DOUBLE_COLON.match(line) or ARROW.match(line)
    if not m:
        return None
    left, right = trim(m.group(1)), trim(m.group(2))
    if not left or not right:
        return None
    return left, right

# The corrector matches the left side's words case-insensitively with any
# whitespace between them.
def key(left):
    return " ".join(w for w in re.split(f"{WS}+", left) if w).casefold()

# Strict UTF-8: a file the corrector can't read cleanly is reported, and
# nothing is changed, rather than rewritten with replacement characters.
def read_text(path):
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        sys.exit(f"tmux-whisper: {path} is not valid UTF-8 (byte {exc.start}); fix it, then run: tmux-whisper migrate-modes")

def read_lines(path):
    return read_text(path).split("\n")

# A symlinked modes/ or current-mode would point somewhere else once moved
# into the archive: leave those to the user.
for p in (modes_dir, mode_file):
    if os.path.islink(p):
        sys.exit(f"tmux-whisper: {p} is a symlink to {os.readlink(p)}; move it out of {config_dir} by hand (its vocab can go in with: tmux-whisper vocab import <file>)")

existing = {}
vocab_text = ""
if os.path.isfile(vocab_path):
    vocab_text = read_text(vocab_path)
    for line in vocab_text.split("\n"):
        rule = parse(line)
        if rule:
            existing.setdefault(key(rule[0]), rule[1])

mode_names = sorted(
    name for name in (os.listdir(modes_dir) if os.path.isdir(modes_dir) else [])
    if not name.startswith(".") and os.path.isdir(os.path.join(modes_dir, name))
)
blocks = []
report = []
for name in mode_names:
    path = os.path.join(modes_dir, name, "vocab")
    if not os.path.isfile(path):
        continue
    added, duplicates, conflicts = [], 0, []
    for line in read_lines(path):
        rule = parse(line)
        if not rule:
            continue
        k = key(rule[0])
        if k in existing:
            if existing[k] == rule[1]:
                duplicates += 1
            else:
                conflicts.append(f"{line.strip()} (vocab keeps {rule[0]} -> {existing[k]})")
            continue
        existing[k] = rule[1]
        added.append(line.strip())
    if added:
        blocks.append((name, added))
    report.append((name, len(added), duplicates, conflicts))

stamp = os.environ["MIGRATE_STAMP"]
archive_root = os.path.join(config_dir, "modes-archive")
archive = os.path.join(archive_root, f"{stamp}-modes-removed")
n = 2
while os.path.exists(archive):
    archive = os.path.join(archive_root, f"{stamp}-modes-removed-{n}")
    n += 1

verb = "Would add" if dry_run else "Added"
for name, added, duplicates, conflicts in report:
    print(f"{verb} {added} rule(s) from modes/{name}/vocab ({duplicates} already in vocab)")
    for conflict in conflicts:
        print(f"  skipped, vocab already corrects this differently: {conflict}")
if not report:
    print("No modes/*/vocab files to merge.")

moves = [p for p in (modes_dir, mode_file) if os.path.exists(p)]
if dry_run:
    for p in moves:
        print(f"Would move {p} to {archive}/")
    print("Dry run: nothing changed.")
    sys.exit(0)

os.makedirs(archive)
if os.path.isfile(vocab_path):
    shutil.copy2(vocab_path, os.path.join(archive, "vocab.before-migrate"))
if blocks:
    out = vocab_text
    if out and not out.endswith("\n"):
        out += "\n"
    for name, added in blocks:
        out += f"\n# From modes/{name}/vocab (merged by tmux-whisper migrate-modes, {os.environ['MIGRATE_DATE']})\n"
        out += "\n".join(added) + "\n"
    # Write through a symlinked vocab, so the link keeps working.
    target = os.path.realpath(vocab_path)
    tmp = target + ".tmp." + str(os.getpid())
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(out)
    if os.path.isfile(target):
        shutil.copymode(target, tmp)
    os.replace(tmp, target)
for p in moves:
    shutil.move(p, os.path.join(archive, os.path.basename(p)))
    print(f"Moved {p} to {archive}/")
if os.path.isfile(os.path.join(archive, "vocab.before-migrate")):
    print(f"The previous vocab is saved as {archive}/vocab.before-migrate")
print("Modes are gone: every take now uses " + vocab_path + " (tmux-whisper vocab).")
PYEOF
}
