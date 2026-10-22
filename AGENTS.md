# Khuluma working agreement

Read `README.md` for operation and `LOG.md` for current work, priorities and decisions. Use `LOG.md` as the internal work list; public completed changes belong in `CHANGELOG.md`. A separate specification, PRD, issue or implementation slice is not required for routine work. GitHub issues can provide external context when relevant.

Khuluma is the daily required app. Documentation work must preserve source `.build/`, model files and caches, the installed daemon tree under `~/.local/share/khuluma/native/`, and `~/Applications/Khuluma.app`. Do not install, build, warm, restart or release anything to validate prose. Source inspection does not establish installed-version or live health.

For implementation, make the smallest complete change and verify the affected behavior. Pure app logic belongs in `KhulumaCore`; contract changes must keep the matching CLI and app compatible. Use `CONTRIBUTING.md` for applicable validation and the release checklist only when preparing an authorized release. Installation and publication are separate actions, not steps required after every task.

Keep defaults portable. Config/history remain under `~/.config/khuluma`, sounds under `~/.local/share/sounds/khuluma`, and models under `~/.local/share/khuluma/models`. Do not commit personal config, transcripts or secrets.

The source and sibling `../homebrew-tap` are separate repositories. The formula updater defaults to `../homebrew-tap/Formula/khuluma.rb`. The canonical formula remains staged outside `Formula/` until its actual source archive and release checks pass. Preserve public usage, CLI contracts, troubleshooting, attribution and release history. Archived plans and dated name research are evidence, not an active workflow.


The approved identity migration is being implemented in an isolated worktree. `docs/KHULUMA_RENAME_PLAN.md` is the finite execution checklist. Keep installed-state claims in LOG with actual evidence. The old shared Lowkey certificate and original user data remain recovery material; canonical signing uses a distinct identity. Worktree app checks require the explicit private support/log/defaults overrides documented in the code, so another instance cannot touch the daily app's pending/recovered data.
