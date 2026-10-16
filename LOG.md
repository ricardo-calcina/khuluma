# Log

## Now
Turn tmux-whisper into Khuluma (the app carries the name from v0.11): rename, make the app the main tool, sunset the CLI. Plan: `docs/plans/KHULUMA_RENAME_ROADMAP.md`. Phase 0: P0b tidy-up done (PRs #66–#72), pending a week of daily use with `tools/khuluma-report.sh` gates still met. Public name chosen: Khuluma (P0a). The app is renamed (#74–#76); the bundle id, signing identity and CLI names wait for phase 2.

## Next
- [x] P0 · Name check: Lowkey vs other spellings or a longer store name (roadmap P0a) · added 2026-10-15
- [ ] P1 · Before phase 2: search UKIPO and EUIPO by hand for KHULUMA; register khuluma.app · added 2026-10-17
- [ ] P1 · Khuluma app icon: the bundle has none yet (Dock, Finder, Login Items, System Settings show a blank icon); a menu-bar glyph to match · added 2026-10-17
- [ ] P1 · Drop modes, keep one vocab: modes now only pick a vocab list (the prompts died with post-processing, and the email/code profiles aren't needed with today's models). Fold the base and code vocab into the main list for filler words and brand spellings; remove `current-mode`, `modes/`, the `mode` commands and ModeResolver. Today `code` allows only the tmux flow, so code apps fall back to base and miss its vocab · added 2026-10-17
- [ ] P2 · Skip auto-send for one take: hold a key (Shift or similar, to decide) so the take pastes without pressing Enter; auto-send stays the default · added 2026-10-17
- [ ] P1 · Confirm new repo vs rename in place; join the Apple Developer Program before phase 2 · added 2026-10-15
- [ ] P2 · Stats stage 3 ideas (not committed): weeks view, wpm trend, longest take, typing_wpm config, streak line, time of day, opt-in per-app · added 2026-10-16
- [ ] P2 · Lowkey ideas parked from 3c, only with evidence: config file watcher, warm mic/pre-roll · added 2026-10-16

## Done
- 2026-10-17 · Khuluma rename step 3: roadmap, name check and CHANGELOG TODO describe Khuluma; phase 0 kept as decided · #76
- 2026-10-17 · Khuluma rename step 2: the app is Khuluma.app; scripts build-khuluma-app.sh and khuluma-report.sh; Lowkey folders migrate at launch; bundle id and signing identity kept · #75
- 2026-10-17 · Khuluma rename step 1: Swift targets Khuluma, KhulumaCore, KhulumaObjC, KhulumaCoreTests (app still Lowkey.app) · #74
- 2026-10-17 · Public name chosen: Khuluma (isiNdebele "speak"); Thumela runner-up · docs/plans/KHULUMA_NAME_CHECK.md, #67
- 2026-10-16 · Quit saves takes still queued or being transcribed to recovered/, so a Quit that runs out of time no longer loses them · #73
- 2026-10-16 · Name check (P0a): Lowkey ruled out by live LOWKEY software marks in UK/US/EU · docs/plans/KHULUMA_NAME_CHECK.md
- 2026-10-16 · P0b docs: README, ROADMAP, CONTRIBUTING, TROUBLESHOOTING (Lowkey section), domain and templates rewritten around Lowkey; pre-v0.7 changelog archived; pad-sfx.sh removed · #72
- 2026-10-16 · Lowkey's AppController split into TakePipeline, TakePersister, StatusMenu, LoginItem; menu status is a tested LowkeyCore type · #71
- 2026-10-16 · LLM post-processing, silence trim and bash chunking removed (with budget, replay, bench-matrix, mode prompts); app contract 2 · #70
- 2026-10-16 · tmux flow and CLI recording removed (start/stop/toggle, tmux, keybind, devices, watch, debug, logs); Lowkey records, the CLI is its back end · #69
- 2026-10-16 · Lowkey requires its matching CLI (app contract); rollout switches, verify and the older-CLI paths removed after the v0.10.0 gates passed · #68
- 2026-10-16 · Raycast scripts, `integrations` doctor/repair and the `swiftbar` stub removed · #66
- 2026-10-16 · Finished plans moved to docs/plans/archive/ · #65
- 2026-10-16 · P0b review done; dropping tmux flow, CLI capture, LLM post-processing, silence trim, chunking; Lowkey to require its matching CLI · roadmap P0b
- 2026-10-15 · Lowkey rename roadmap approved: phases 0–5, App Store parked · docs/plans/KHULUMA_RENAME_ROADMAP.md
