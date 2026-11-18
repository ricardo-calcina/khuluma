# Release Checklist

## Pre-release

- [ ] Confirm `main` CI is green (Swift, CI and Icons workflows).
- [ ] Set `native/VERSION` to the release version (for example, `0.12.0`); the app build stamps it as `CFBundleShortVersionString`.
- [ ] Run local validation:
  - [ ] `tools/test-affected.sh --full`
  - [ ] `./tests/ci.sh`
- [ ] Confirm the changelog is updated (`CHANGELOG.md`).
- [ ] Confirm `LOG.md` reflects current tasks and decisions if scope changed.
- [ ] Verify delivered-usage accounting in the installed app:
  - [ ] Deliver one dictation; confirm Stats advances the delivery and word totals and `usage.json` holds no transcript text.
  - [ ] Cancel a recording (Ctrl+Esc); confirm the totals did not advance.
- [ ] Verify Khuluma in the installed environment:
  - [ ] Watch a take through recording, processing, and ready in the menu; confirm the frontmost app is not considered safe to move away from until paste/autosend completes.
  - [ ] Exercise a cancel and a controlled error path; confirm the menu returns to ready rather than retaining a stale recording or processing state.
  - [ ] `~/Applications/Khuluma.app/Contents/Helpers/khuluma transcribe <short file> -q` prints a transcript, and the Finder Quick Action writes `<name>.txt`.
- [ ] Rebuild Khuluma from the release commit (`tools/build-khuluma-app.sh`) and confirm `app.log` shows the matching version and commit.
- [ ] Run `tools/khuluma-report.sh` over the last week of takes and confirm the gates still hold.

## Tag and Publish

Complete the pre-release checks before this section. Tagging and publication are separate actions from release preparation, and each needs Ricardo's yes.

- [ ] Create the release tag (`vX.Y.Z`) and push it.

## Post-release

- [ ] Record the release and verification results in `LOG.md`. Public announcements require separate authorization.
- [ ] Track regressions/issues under the next milestone.
