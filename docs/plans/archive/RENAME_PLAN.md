# Branding-First Rename Plan: dictate-cli -> tmux-whisper

> **Purpose**: Rebrand the project/product as **tmux-whisper** while keeping internal implementation names mostly unchanged for now.
> This is a **public-surface rename only** plan (smaller scope, lower risk, faster to ship).

---

## Scope (This Phase)

### Rename now (public/user-facing)

- GitHub repo name: `ricardo-nth/dictate-cli` -> `ricardo-nth/tmux-whisper`
- Homebrew formula/package name: `ricardo-nth/tap/tmux-whisper`
- Primary CLI command: `tmux-whisper`
- Product name in docs/help/UI: `Tmux Whisper`
- Integration script filenames (Raycast/SwiftBar) for polish

### Keep unchanged for now (internal/low-value churn)

- `DICTATE_*` environment variables
- `dictate_lib_*` shell functions
- `bin/dictate-lib.sh` filename (internal helper)
- temp/cache/state prefixes like `/tmp/dictate-*`, `/tmp/whisper-dictate*`
- tmux buffer/internal identifiers like `whisper_dictate`
- config path: `~/.config/dictate`
- sounds path: `~/.local/share/sounds/dictate`
- repo sample sound path: `assets/sounds/dictate/`

### Explicit non-goals (this phase)

- No config directory migration (`~/.config/dictate` -> `~/.config/tmux-whisper`)
- No sound directory migration (`~/.local/share/sounds/dictate` -> `.../tmux-whisper`)
- No env var prefix migration (`DICTATE_` -> `TMUX_WHISPER_`)
- No deep internal rename of library functions/tests/temp file prefixes

---

## Naming Convention (Branding Phase)

| Context | Old | New |
|---------|-----|-----|
| Product / title case | "Dictate" | "Tmux Whisper" |
| Binary / CLI command | `dictate` | `tmux-whisper` |
| Package / repo | `dictate-cli` | `tmux-whisper` |
| Homebrew formula | `ricardo-nth/tap/dictate-cli` | `ricardo-nth/tap/tmux-whisper` |

### Intentionally deferred (still old names for now)

| Context | Keep as-is (for now) |
|---------|----------------------|
| Config directory | `~/.config/dictate/` |
| Sound directory | `~/.local/share/sounds/dictate/` |
| Env vars | `DICTATE_*` |
| Shell helper functions | `dictate_lib_*` |
| Temp/state prefixes | `/tmp/dictate-*`, `/tmp/whisper-dictate*` |

---

## Phase 1: File Renames (git mv)

Rename only user-facing entrypoints and integration filenames.

```bash
git mv bin/dictate bin/tmux-whisper
git mv integrations/dictate-status.0.2s.sh integrations/tmux-whisper-status.0.2s.sh
git mv integrations/raycast/dictate-toggle.sh integrations/raycast/tmux-whisper-toggle.sh
git mv integrations/raycast/dictate-cancel.sh integrations/raycast/tmux-whisper-cancel.sh
git mv integrations/raycast/dictate-inline.sh integrations/raycast/tmux-whisper-inline.sh
```

**Do not rename yet**:
- `bin/dictate-lib.sh`
- `assets/sounds/dictate/`

---

## Phase 2: Core CLI (`bin/tmux-whisper`)

Update **user-facing branding and command text**, while leaving internals intact.

### Change

- Help/usage examples: `dictate ...` -> `tmux-whisper ...`
- User-facing labels/messages that refer to the tool name (for example `dictate:` prefixes, install hints, doctor/debug suggestions)
- `command -v dictate` checks used to find the installed binary -> `command -v tmux-whisper`
- Install/bootstrap URLs shown to users (`ricardo-nth/dictate-cli` -> `ricardo-nth/tmux-whisper`)
- Visible plugin/script filenames in output/help (`dictate-status...` -> `tmux-whisper-status...`)

### Keep unchanged

- `DICTATE_*` vars and reads/writes
- `dictate_lib_*` calls
- `dictate_sound_path` and similar internal function names
- `/tmp/dictate-*` and `/tmp/whisper-dictate*` paths
- `~/.config/dictate` and `~/.local/share/sounds/dictate` paths
- `dictate-lib.sh` source path/name

**Rule of thumb**: If the string is visible to users in normal usage/help/docs, rename it. If it is an internal implementation identifier/path, defer it.

---

## Phase 3: Install & Bootstrap

### `install.sh` (branding-only updates)

Update install behavior and messages so users get the new command and branded integration filenames.

### Change

- Install binary as `~/.local/bin/tmux-whisper` (from `bin/tmux-whisper`)
- Installer output messages: `Installed tmux-whisper ...`, `Run: tmux-whisper debug`
- Install Raycast scripts under renamed filenames (`tmux-whisper-*.sh`)
- Install SwiftBar plugin as `tmux-whisper-status.0.2s.sh`
- Any user-facing references to repo/package name -> `tmux-whisper`

### Keep unchanged

- `DICTATE_*` installer env vars (`DICTATE_BIN_DIR`, etc.)
- Config install path default: `~/.config/dictate`
- Sounds install path default: `~/.local/share/sounds/dictate`
- Sample sounds source directory: `assets/sounds/dictate/`
- `dictate-lib.sh` installed helper filename (unless we choose to polish this later)

**No migration logic needed in this phase** because config/sounds paths are intentionally unchanged.

### `bootstrap.sh` (repo/package rename only)

### Change

- Repo slug default: `ricardo-nth/dictate-cli` -> `ricardo-nth/tmux-whisper`
- Archive/download URLs to new repo name
- User-facing bootstrap naming text (`dictate-cli-bootstrap` -> `tmux-whisper-bootstrap`) if present
- Extracted archive globs if tied to repo name (`dictate-cli-*` -> `tmux-whisper-*`)

### Keep unchanged

- `DICTATE_BOOTSTRAP_*` env var names (deferred)

---

## Phase 4: Integrations (branding-only)

Rename script files and update visible names / binary invocation. Do **not** do a deep env-var/function-prefix rewrite.

### `integrations/tmux-whisper-status.0.2s.sh` (SwiftBar)

### Change

- Binary invocation/path discovery from `dictate` -> `tmux-whisper`
- Menu/help text labels mentioning Dictate -> Tmux Whisper
- Brew install command text -> `ricardo-nth/tap/tmux-whisper`
- Plugin filename references: `dictate-status.0.2s.sh` -> `tmux-whisper-status.0.2s.sh`

### Keep unchanged

- `DICTATE_*` env vars
- `/tmp/dictate-*` and `/tmp/whisper-dictate*` marker files
- `$XDG_CONFIG_HOME/dictate` path
- cache file names like `dictate-config.cache`

### `integrations/raycast/tmux-whisper-toggle.sh`

### Change

- Raycast title/package text -> Tmux Whisper
- `command -v dictate` / binary path fallback -> `tmux-whisper`
- Script log filename only if user-facing (optional; can defer)
- `SWIFTBAR_PLUGIN_ID` to `tmux-whisper-status.0.2s.sh` (because plugin file is renamed)

### Keep unchanged

- `DICTATE_*` env vars
- `DICTATE_SOUNDS_DIR` variable name
- `~/.config/dictate` and sounds subdir `/dictate`
- `/tmp/dictate-*` and `/tmp/whisper-dictate*`

### `integrations/raycast/tmux-whisper-cancel.sh`

### Change

- Raycast title/package text -> Tmux Whisper
- `SWIFTBAR_PLUGIN_ID` to renamed plugin filename

### Keep unchanged

- temp markers (`/tmp/dictate-*`, `/tmp/whisper-dictate*`)
- sound path under `/dictate/cancel.wav`

### `integrations/raycast/tmux-whisper-inline.sh`

This file is large and shares runtime logic with the core CLI, so keep changes tightly scoped.

### Change

- Raycast title/package text -> Tmux Whisper
- `command -v dictate` / user-facing error text -> `tmux-whisper`
- `SWIFTBAR_PLUGIN_ID` to renamed plugin filename
- Any user-facing branding strings (`Dictate` -> `Tmux Whisper`)

### Keep unchanged

- `DICTATE_*` vars
- `dictate_lib_*` helper calls
- `dictate-lib.sh` lookup/source filename
- `<<DICTATE_CHUNK>>` delimiter
- temp/state/log paths (`/tmp/dictate-*`, `/tmp/whisper-dictate*`)
- config/sounds paths (`~/.config/dictate`, `/dictate/...wav`)

---

## Phase 5: Documentation & User-Facing Text

Update branding and command examples. Do **not** mechanically rewrite historical/internal names that are still valid in this phase.

### `README.md`

### Change

- Title: `# dictate-cli` -> `# tmux-whisper`
- Install/upgrade commands (`brew install/upgrade ...`) -> `tmux-whisper`
- Bootstrap URLs and `git clone` URLs -> new repo name
- Command examples (`dictate ...`) -> `tmux-whisper ...`
- Integration filenames in docs -> `tmux-whisper-*.sh`
- Prose references to product name -> Tmux Whisper

### Keep/clarify

- Config path examples may still show `~/.config/dictate` (intentional for now)
- Sounds path examples may still show `~/.local/share/sounds/dictate` (intentional for now)
- Add a short note that internal paths are temporarily unchanged during branding transition

### Other docs/files to update (branding references)

- `CHANGELOG.md` (only current/release-facing references; avoid rewriting historical env var names unless needed)
- `CONTRIBUTING.md`
- `AGENTS.md` (repo/formula references)
- `ROADMAP.md`
- `docs/RELEASE_CHECKLIST.md`
- `docs/TROUBLESHOOTING.md` (command examples)
- `.github/ISSUE_TEMPLATE/bug_report.yml`
- `.github/ISSUE_TEMPLATE/config.yml`
- `assets/sounds/README.md` (optional now; if updated, preserve runtime path note as legacy/current path)
- `tools/pad-sfx.sh` usage examples (optional cosmetic)

---

## Phase 6: Tests (minimal updates only)

Update tests only where they assert renamed binaries/script filenames or repo archive names.

### Likely impacted

- `tests/test_cli.sh` (invokes `bin/dictate`)
- `tests/test_install.sh` (installed binary + integration filenames)
- `tests/test_bootstrap.sh` (repo archive naming, installed binary assertions)
- `tests/test_flow_parity.sh` only if it hardcodes `bin/dictate` path for the CLI entrypoint

### Likely mostly unchanged

- `DICTATE_*` env var usage in tests
- `dictate_lib_*` helper tests
- tmp prefix assertions (`whisper-dictate`, `/tmp/dictate-*`)
- config/sounds path assertions (`~/.config/dictate`, `.../sounds/dictate`)

---

## Phase 7: External Repositories & Services

### GitHub Repository (recommended: rename in place)

1. Rename `ricardo-nth/dictate-cli` -> `ricardo-nth/tmux-whisper` in GitHub settings
2. Update local remote URL
3. Update hardcoded URLs in docs anyway (do not rely on redirects forever)

### Homebrew Tap (`ricardo-nth/homebrew-tap`)

Use a clean break (no compatibility shim/deprecation formula needed):

1. Delete `Formula/dictate-cli.rb`
2. Add `Formula/tmux-whisper.rb`
3. Update `desc`, `homepage`, `url`, `sha256`
4. Ensure formula installs the `tmux-whisper` binary
5. Update tap docs/install commands accordingly

Because there are effectively no external users yet, do not spend time on a deprecation/compatibility formula.

---

## Deferred Follow-Up (Phase 2 / Later Cleanup)

These are the first items to revisit after the branding release, but they are intentionally out of scope today:

1. Rebrand config/sounds paths:
   - `~/.config/dictate` -> `~/.config/tmux-whisper`
   - `~/.local/share/sounds/dictate` -> `~/.local/share/sounds/tmux-whisper`
2. Rename repo sample sounds dir:
   - `assets/sounds/dictate` -> `assets/sounds/tmux-whisper`
3. Introduce new env var prefix support (`TMUX_WHISPER_*`) and migrate off `DICTATE_*`
4. Rename `dictate_lib_*` helpers and `bin/dictate-lib.sh`
5. Rename temp/cache/state/internal identifiers (`/tmp/dictate-*`, `whisper-dictate*`, `whisper_dictate`, etc.)
6. Add migration logic (only when config/sounds path rename happens)

---

## Execution Strategy (Recommended)

```bash
git checkout -b rename/tmux-whisper-branding
```

1. Phase 1: Rename entrypoint/integration files (`git mv`)
2. Phase 2-4: Update CLI/install/bootstrap/integrations with **branding-only** edits
3. Phase 5: Update docs/help/UI text and repo/package references
4. Phase 6: Fix tests impacted by binary/script filename changes
5. Verify (`./tests/ci.sh`)
6. Rename GitHub repo + update Homebrew formula
7. Ship release notes with explicit note: brand changed, internal paths/config env names unchanged for now

---

## Verification Checklist (Branding Phase)

- [ ] `bin/tmux-whisper --help` works and uses **tmux-whisper** in usage/examples
- [ ] `bin/tmux-whisper debug` and `bin/tmux-whisper doctor` work
- [ ] Installer installs `tmux-whisper` binary successfully
- [ ] Installer still uses existing config/sounds paths (`~/.config/dictate`, `~/.local/share/sounds/dictate`) intentionally
- [ ] SwiftBar plugin installs/loads under `tmux-whisper-status.0.2s.sh`
- [ ] Raycast scripts import and run under renamed filenames
- [ ] README/docs show `tmux-whisper` commands and updated repo/tap URLs
- [ ] `./tests/ci.sh` passes

### Targeted audits (avoid false positives)

Branding references that should be gone from user-facing surfaces:

```bash
rg -n --hidden --glob '!.git' 'dictate-cli|ricardo-nth/dictate-cli|\bdictate\b' \
  README.md CONTRIBUTING.md ROADMAP.md docs/ .github/ISSUE_TEMPLATE/ \
  bin/tmux-whisper integrations/tmux-whisper-status.0.2s.sh integrations/raycast/tmux-whisper-*.sh
```

Legacy internals that should still exist (intentional in this phase):

```bash
rg -n 'DICTATE_|dictate_lib_|/tmp/(whisper-)?dictate|\.config/dictate|sounds/dictate' \
  bin/tmux-whisper bin/dictate-lib.sh integrations/ install.sh tests/
```

---

## Files Intentionally Unchanged (This Phase)

- `bin/dictate-lib.sh` (internal helper filename)
- `config/config.toml` paths under `~/.config/dictate` and `~/.local/share/sounds/dictate`
- `assets/sounds/dictate/` directory name
- Most test internals referencing `DICTATE_*` / tmp prefixes
- `.github/workflows/ci.yml` (unless branding text is later added)
