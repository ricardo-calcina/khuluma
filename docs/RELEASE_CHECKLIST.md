# Release Checklist

## Pre-release

- [ ] Confirm `main` CI is green.
- [ ] Set `KHULUMA_CLI_VERSION` in `bin/khuluma` to the release tag
  version (for example, `0.11.0`), then confirm `khuluma version --json`
  reports that value before tagging.
- [ ] Run local validation:
  - [ ] `./tests/ci.sh`
  - [ ] `./install.sh --force`
  - [ ] `test -f ~/.config/khuluma/install-receipt.env`
  - [ ] `khuluma doctor`
- [ ] Confirm changelog is updated (`CHANGELOG.md`).
- [ ] Confirm `LOG.md` reflects current tasks and decisions if scope changed.
- [ ] Verify delivered-usage accounting:
  - [ ] Deliver one dictation with Khuluma.
  - [ ] Confirm `khuluma usage --json` advances the delivery and word totals without exposing transcript text, and reports its coverage start and typing-time assumption.
  - [ ] Capture `khuluma usage --json`, cancel a recording (Ctrl+Esc), then confirm the delivery and word totals did not advance.
- [ ] Verify Khuluma in the installed environment:
  - [ ] Confirm the Stats window matches `khuluma usage --json`.
  - [ ] Watch a take through recording, processing, and ready in the menu; confirm the frontmost app is not considered safe to move away from until paste/autosend completes.
  - [ ] Exercise a cancel and a controlled error path; confirm the menu returns to ready rather than retaining a stale recording or processing state.
- [ ] Rebuild Khuluma from the release commit (`tools/build-khuluma-app.sh`) and confirm `app.log` shows the matching contract and `pipeline native`.
- [ ] Run `tools/khuluma-report.sh` over the last week of takes and confirm the gates still hold.

## Tag and Publish

Complete the pre-release checks before this section. Tagging and publication are separate actions from release preparation.

- [ ] Create release tag in `khuluma` (`vX.Y.Z`).
- [ ] Push tag to origin.
- [ ] Verify GitHub tarball URL and checksum:
  - [ ] `tools/update-homebrew-formula.sh vX.Y.Z`
- [ ] Smoke-test pinned bootstrap install from the tag in a temporary `$HOME`:
  - [ ] `KHULUMA_BOOTSTRAP_REF=vX.Y.Z bash bootstrap.sh --no-sounds`

## Homebrew Update

The local tap checkout is `../homebrew-tap`; the updater defaults to its canonical formula. In worktrees, pass the exact tap path with `--formula`. These are release actions, not documentation-validation steps.

- [ ] Update `../homebrew-tap/Formula/khuluma.rb` from the tagged tarball:
  - [ ] `tools/update-homebrew-formula.sh vX.Y.Z --write --formula ../homebrew-tap/Formula/khuluma.rb`
  - [ ] Review diff in `../homebrew-tap/Formula/khuluma.rb`
- [ ] Run the tap's existing disposable macOS Homebrew QA workflow: fresh install, v0.9 upgrade and v0.10 upgrade. Require strict audit, formula tests, one package owner and unchanged profile checks.
- [ ] After published QA passes, review a targeted local install/upgrade dry-run with automatic updates and cleanup disabled; retain prior kegs and recovery material. Do not update unrelated taps or dependencies for this check.
- [ ] Validate command:
  - [ ] `khuluma --help`
  - [ ] `khuluma doctor`
- [ ] Commit/push tap repo update (`../homebrew-tap`) after formula validation passes.

## Post-release

- [ ] Record the immutable release and verification results. Public announcements require separate authorization.
- [ ] Track regressions/issues under next milestone.
