# Khuluma working agreement

Read `README.md` for how the app works and `LOG.md` for current work, priorities and decisions. Use `LOG.md` as the internal work list; public completed changes belong in `CHANGELOG.md`. A separate specification, PRD, issue or implementation slice is not required for routine work. GitHub issues can provide external context when relevant.

Khuluma is the native macOS app in `native/`, and it is the daily required app. Documentation work must preserve source `.build/`, model files and caches, and `~/Applications/Khuluma.app`. Do not install, build, restart or release anything to validate prose. Source inspection does not establish installed-version or live health.

For implementation, make the smallest complete change and verify the affected behavior. Check with `tools/test-affected.sh` (in this shared checkout, `--paths <your files>`), not the whole suite; CI runs the full Swift suite on push. Work in the main checkout and its shared `native/.build`, not a worktree (CONTRIBUTING.md, "Validation Requirements"). Pure app logic belongs in `KhulumaCore`. Use `CONTRIBUTING.md` for validation and `docs/RELEASE_CHECKLIST.md` only when preparing an authorized release. Installation and publication are separate actions, not steps required after every task.

The app keeps its data in `~/Library/Application Support/Khuluma` and its log in `~/Library/Logs/Khuluma`. Do not commit personal settings, vocabulary, transcripts or secrets.

The bash CLI, its Homebrew formula and the identity-migration tools were retired in 2026-11 ([archived plan](docs/plans/archive/CLI_SUNSET.md)); git history is the record, so don't reintroduce compatibility shims for them. Earlier names (Tmux Whisper, Lowkey) are recorded in the [identity-rename outcome](docs/plans/archive/KHULUMA_IDENTITY_RENAME.md). Archived plans and dated name research are evidence, not an active workflow. Worktree app checks require the explicit private support/log/defaults overrides (`docs/INTEGRATIONS.md`), so another instance cannot touch the daily app's data.
