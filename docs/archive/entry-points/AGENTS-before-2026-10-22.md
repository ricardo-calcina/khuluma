# Tmux Whisper CLI - Project Working Agreement

This project is now the single source of truth for Tmux Whisper development.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues for `ricardo-nth/tmux-whisper`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default triage label vocabulary, including `ready-for-agent` for AFK-ready implementation work. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repo. Read root domain docs and ADRs if present, and otherwise proceed silently. See `docs/agents/domain.md`.

## Source of Truth

- Primary development repo: `tmux-whisper` (project workspace)
- Homebrew tap repo: `homebrew-tap` (separate repo for formula updates)
- Legacy bare repo (`~/.dictate.git`) is retired and archived; do not use it for active development.

## Development Workflow

1. Create a feature branch in `tmux-whisper`.
2. Implement changes in this repo only.
3. Run validation:
   - `./tests/ci.sh`
4. Install to local runtime for real usage testing:
   - `./install.sh --force`
5. Merge to `main` only when stable.

## Install Channels

- Daily/personal testing: `./install.sh --force` (or bootstrap installer).
- Public stable installs: Homebrew (`ricardo-nth/tap/tmux-whisper`).

Do not require Homebrew for every development iteration.

## Release Workflow

1. Merge stable changes to `main`.
2. Update `CHANGELOG.md` with release-ready notes.
3. Tag release in `tmux-whisper` (`vX.Y.Z`).
4. Update Homebrew formula in `homebrew-tap`:
   - `url` to new tag archive
   - `sha256` to matching archive checksum
5. Validate with:
   - `brew update`
   - `brew install/upgrade ricardo-nth/tap/tmux-whisper`

## Config and Privacy Boundaries

- Keep repo defaults portable (`config/config.toml`, `config/vocab`).
- Do not commit personal machine-specific preferences or secrets.
- User-local config/runtime stays in:
  - `~/.config/dictate`
  - `~/.local/share/sounds/dictate`
  - `~/.local/share/whisper/models`

## Changelog Policy

- `CHANGELOG.md` should track:
  - current stable version,
  - notable completed changes,
  - upcoming queue/TODO.
- Keep it aligned with actual shipped behavior.
