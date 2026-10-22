# Khuluma working agreement

Read `README.md` for operation and `LOG.md` for current work, priorities and decisions. Use `LOG.md` as the internal work list; public completed changes belong in `CHANGELOG.md`. A separate specification, PRD, issue or implementation slice is not required for routine work. GitHub issues can provide external context when relevant.

Khuluma is the daily required app. Documentation work must preserve source `.build/`, model files and caches, the installed daemon tree under `~/.local/share/tmux-whisper/native/`, and `~/Applications/Khuluma.app`. Do not install, build, warm, restart or release anything to validate prose. Source inspection does not establish installed-version or live health.

For implementation, make the smallest complete change and verify the affected behavior. Pure app logic belongs in `KhulumaCore`; contract changes must keep the matching CLI and app compatible. Use `CONTRIBUTING.md` for applicable validation and the release checklist only when preparing an authorized release. Installation and publication are separate actions, not steps required after every task.

Keep defaults portable. Config/history remain under `~/.config/dictate`, sounds under `~/.local/share/sounds/dictate`, and models under `~/.local/share/tmux-whisper/models`. Do not commit personal config, transcripts or secrets.

The source and sibling `../tmux-whsper-brew-tap` are separate repositories. The formula updater still defaults to `../homebrew-tap`; use its documented `--formula` override here. Source `LOG.md` owns that pending fix. Preserve public usage, CLI contracts, troubleshooting, attribution and release history. Archived plans and dated name research are evidence, not an active workflow.
