# Log

## Now
Turn tmux-whisper into Lowkey: rename, make the app the main tool, sunset the CLI. Plan: `docs/plans/LOWKEY_RENAME_ROADMAP.md`. Phase 0: P0b tidy-up done (PRs #66–#72), pending a week of daily use with `tools/lowkey-report.sh` gates still met. Next: the name check (P0a).

## Next
- [ ] P0 · Name check: Lowkey vs other spellings or a longer store name (roadmap P0a) · added 2026-10-15
- [ ] P1 · Confirm new repo vs rename in place; join the Apple Developer Program before phase 2 · added 2026-10-15
- [ ] P2 · Stats stage 3 ideas (not committed): weeks view, wpm trend, longest take, typing_wpm config, streak line, time of day, opt-in per-app · added 2026-10-16
- [ ] P2 · Lowkey ideas parked from 3c, only with evidence: config file watcher, warm mic/pre-roll · added 2026-10-16

## Done
- 2026-10-16 · P0b docs: README, ROADMAP, CONTRIBUTING, TROUBLESHOOTING (Lowkey section), domain and templates rewritten around Lowkey; pre-v0.7 changelog archived; pad-sfx.sh removed · #72
- 2026-10-16 · Lowkey's AppController split into TakePipeline, TakePersister, StatusMenu, LoginItem; menu status is a tested LowkeyCore type · #71
- 2026-10-16 · LLM post-processing, silence trim and bash chunking removed (with budget, replay, bench-matrix, mode prompts); app contract 2 · #70
- 2026-10-16 · tmux flow and CLI recording removed (start/stop/toggle, tmux, keybind, devices, watch, debug, logs); Lowkey records, the CLI is its back end · #69
- 2026-10-16 · Lowkey requires its matching CLI (app contract); rollout switches, verify and the older-CLI paths removed after the v0.10.0 gates passed · #68
- 2026-10-16 · Raycast scripts, `integrations` doctor/repair and the `swiftbar` stub removed · #66
- 2026-10-16 · Finished plans moved to docs/plans/archive/ · #65
- 2026-10-16 · P0b review done; dropping tmux flow, CLI capture, LLM post-processing, silence trim, chunking; Lowkey to require its matching CLI · roadmap P0b
- 2026-10-15 · Lowkey rename roadmap approved: phases 0–5, App Store parked · docs/plans/LOWKEY_RENAME_ROADMAP.md
