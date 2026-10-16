# Release Checklist

## Pre-release

- [ ] Confirm `main` CI is green.
- [ ] Set `TMUX_WHISPER_CLI_VERSION` in `bin/tmux-whisper` to the release tag
  version (for example, `0.7.0`), then confirm `tmux-whisper version --json`
  reports that value before tagging.
- [ ] Run local validation:
  - [ ] `./tests/ci.sh`
  - [ ] `./install.sh --force`
  - [ ] `test -f ~/.config/dictate/install-receipt.env`
  - [ ] `tmux-whisper doctor`
- [ ] Confirm changelog is updated (`CHANGELOG.md`).
- [ ] Confirm roadmap alignment (`ROADMAP.md`) if scope changed.
- [ ] Verify delivered-usage accounting:
  - [ ] Deliver one dictation with Lowkey.
  - [ ] Confirm `tmux-whisper usage --json` advances the delivery and word totals without exposing transcript text, and reports its coverage start and typing-time assumption.
  - [ ] Capture `tmux-whisper usage --json`, cancel a recording (Ctrl+Esc), then confirm the delivery and word totals did not advance.
- [ ] Verify Lowkey in the installed environment:
  - [ ] Confirm the Stats window matches `tmux-whisper usage --json`.
  - [ ] Watch a take through recording, processing, and ready in the menu; confirm the frontmost app is not considered safe to move away from until paste/autosend completes.
  - [ ] Exercise a cancel and a controlled error path; confirm the menu returns to ready rather than retaining a stale recording or processing state.
- [ ] Rebuild Lowkey from the release commit (`tools/build-lowkey-app.sh`) and confirm `app.log` shows the matching contract and `pipeline native`.
- [ ] Run `tools/lowkey-report.sh` over the last week of takes and confirm the gates still hold.

## Tag and Publish

Complete the pre-release checks before this section. Tagging and publication are separate actions from release preparation.

- [ ] Create release tag in `tmux-whisper` (`vX.Y.Z`).
- [ ] Push tag to origin.
- [ ] Verify GitHub tarball URL and checksum:
  - [ ] `tools/update-homebrew-formula.sh vX.Y.Z`
- [ ] Smoke-test pinned bootstrap install from the tag in a temporary `$HOME`:
  - [ ] `DICTATE_BOOTSTRAP_REF=vX.Y.Z bash bootstrap.sh --no-sounds`

## Homebrew Update

- [ ] Update `homebrew-tap/Formula/tmux-whisper.rb` from the tagged tarball:
  - [ ] `tools/update-homebrew-formula.sh vX.Y.Z --write`
  - [ ] Review diff in `../homebrew-tap/Formula/tmux-whisper.rb`
- [ ] Run:
  - [ ] `git -C ../homebrew-tap status --short`
  - [ ] `brew update`
  - [ ] `brew audit --new --strict --online ricardo-nth/tap/tmux-whisper`
  - [ ] `brew install/upgrade ricardo-nth/tap/tmux-whisper`
- [ ] Validate command:
  - [ ] `tmux-whisper --help`
  - [ ] `tmux-whisper doctor`
- [ ] Commit/push tap repo update (`../homebrew-tap`) after formula validation passes.

## Post-release

- [ ] Announce release notes summary.
- [ ] Track regressions/issues under next milestone.
