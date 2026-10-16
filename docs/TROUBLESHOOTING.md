# Troubleshooting

Use this page for quick diagnosis and high-confidence fixes.

## 1) Run the health checks

```bash
tmux-whisper doctor
tmux-whisper status
```

- `doctor`: install/dependency/mode/runtime checks with suggested fixes
- `status`: current runtime + effective settings snapshot

## 2) Setup and config issues

Which install are you actually running?

- Use `tmux-whisper doctor`.
- Check the resolved binary path and install channel before assuming the wrong copy is broken.

Upgrade or refresh by channel:

- Homebrew stable:

```bash
brew upgrade tmux-whisper
tmux-whisper doctor
tmux-whisper status
```

- Bootstrap install:

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-nth/tmux-whisper/main/bootstrap.sh | bash -s -- --force
tmux-whisper doctor
tmux-whisper status
```

- Local clone:

```bash
git pull
./install.sh --force
tmux-whisper doctor
tmux-whisper status
```

`--force` refreshes binaries but preserves your live config, modes, and vocab.

Schema mismatch:

- Symptom in `tmux-whisper doctor`: `config schema: ... status=mismatch`
- Fix:

```bash
tmux-whisper config repair --dry-run
tmux-whisper config repair
```

Invalid TOML:

- Symptoms:
  - `tmux-whisper doctor`: `config schema: invalid`
  - `tmux-whisper status`: `headline: Config file is invalid TOML.`
- Fix:

```bash
tmux-whisper config repair --dry-run
tmux-whisper config repair
```

Missing dependencies:

- `python3` and `ffmpeg` are required.
- `swift` is required when the local `tmux-whisperd` binary needs to be built or rebuilt.
- Typical Homebrew installs:

```bash
brew install python ffmpeg
```

Parakeet backend unavailable:

- Symptoms in `tmux-whisper doctor`:
  - `tmux-whisperd binary: ... (build needed)`
  - `tmux-whisperd socket: ... (offline)`
  - `parakeet model: missing`
- Fix:
  - run `./install.sh --force`
  - run `tmux-whisper warmup`
  - verify `swift_parakeet.model_path` in `~/.config/dictate/config.toml`
  - ensure `swift` is installed if the native backend needs to rebuild
  - if you keep models outside the default location, set `swift_parakeet.model_path` explicitly

## 3) Mode configuration issues

Invalid fixed mode fallback:

- Symptom: `mode.current: <name> (invalid, fallback=auto)`
- Fix either:
  - reset to auto-detect: `tmux-whisper mode auto`
  - create missing custom mode: `tmux-whisper mode create "<name>"`

If the core modes (`base`, `code`) are missing after install drift, reinstall to seed them:

```bash
./install.sh --force
```

## 4) Vocabulary workflow issues

Accepted correction formats:

- `wrong::right`
- `wrong -> right`
- `wrong → right`

Invalid import lines:

- `tmux-whisper vocab import <file>` now reports line numbers for invalid entries (first 5).
- Preview a batch without mutating your live vocab:

```bash
tmux-whisper vocab import --dry-run <file>
```

- Clean and normalize existing vocab safely:

```bash
tmux-whisper vocab dedupe
```

This writes a timestamped backup before rewrite.

Export a clean snapshot for sharing/versioning:

```bash
tmux-whisper vocab export <file>
```

Remove entries safely:

```bash
tmux-whisper vocab rm "literal text"
tmux-whisper vocab rm --regex "pattern"
```

## 5) Integration optionality

- Lowkey and the Finder Quick Action run the CLI in a minimal environment. If custom PATH entries or env-based overrides work in your shell but not from them, put them in `~/.zshenv`.
- The Raycast scripts and the SwiftBar plugin were retired in v0.11 (Lowkey replaces them). Old copies under `~/.config/dictate/integrations/raycast` or `~/.config/swiftbar/plugins/tmux-whisper-status.0.2s.sh` can go to the Trash.
