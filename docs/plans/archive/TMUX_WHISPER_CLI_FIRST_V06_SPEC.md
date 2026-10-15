# Tmux Whisper CLI-First v0.6 Spec

> Status: Draft
> Scope: Define the next expansion track after the v0.5 hardening wave.
> Intent: Make the CLI the first-class operator product before adding any dashboard/TUI layer.

## Summary

The current app has already done the hard part of becoming operationally legible:

- `status`, `debug`, `doctor`, `history stats`, and `last` expose real runtime truth
- the CLI is now the public command language
- recent regression work has strengthened the tmux-first core without needing a UI rewrite

That changes the next-version decision.

v0.6 should not be "add a TUI because the data exists."
v0.6 should be "promote the CLI from a useful summary surface into a complete operator platform."

The branch seed for this track is intentionally small and aligned with that direction:

- `tmux-whisper history list [N] --json`
- `tmux-whisper history search <query> [N] [--json]`
- `tmux-whisper history export [N|all] [--json]`
- `tmux-whisper logs path|tail|follow|--json`
- `tmux-whisper devices --json`
- `tmux-whisper config [--json]`, `config path [--json]`, and `config get <path> [--json]`
- `tmux-whisper watch [--interval SECONDS] [--iterations N]`

That gives future watch/session tooling a stronger baseline across history, logs, devices, and config without forcing us into a dashboard first.

## Why This Is The Right Next Step

The repo now has enough operator data to build on, but the CLI still feels uneven:

- some read commands have strong JSON support
- some read commands are still human-only
- several support flows still require opening files directly or parsing ad hoc text
- the roadmap still points at a TUI before the CLI contracts are fully shaped

That is the wrong order for this product.

Tmux Whisper is a tmux-first terminal tool. The next version should deepen that identity:

- better shell composability
- better observability from the terminal
- better support/debug flows without leaving the CLI
- cleaner contracts for future integrations

## Product Decision

For v0.6:

- CLI first
- terminal first
- data-contract first

Not for v0.6:

- a dashboard as the primary milestone
- a TUI that becomes the source of truth
- visual surface work that outruns the operator CLI underneath it

If a TUI happens later, it should consume stable CLI/operator contracts, not invent a parallel product surface.

## Current Strengths To Build On

Already solid:

- tmux-first workflow identity
- JSON-capable `status`, `debug`, `doctor`, `history stats`, and `last`
- saved history and bench data as reusable operator inputs
- deterministic bash test harnesses that can cover CLI behavior safely

Still uneven:

- `history list` was text-only until this branch seed
- `logs` is useful but not structured or subcommand-oriented
- `config` is safer than before, but the next jump is workflow depth rather than basic inspectability
- bench/history/log observability exists, but the operator workflows between them are still thin

## Goals

1. Make read-only/operator commands consistently scriptable.
2. Keep common debugging and inspection loops inside the terminal.
3. Use stable CLI contracts as the base for future integrations or UI layers.
4. Improve discoverability without turning the product into a dashboard app.
5. Keep the tmux-first core stable while expanding operator depth.

## Non-Goals

- Reworking the core capture/transcribe architecture in the same pass
- Building a Bubble Tea app just because the data can support one
- Replacing shell workflows with a richer but less scriptable UI
- Turning v0.6 into a broad integration-platform release

## Proposed v0.6 Workstreams

## 1. Operator Data Parity

Bring the read surface to a more consistent standard.

Candidate slices:

- `history list [N] --json` (landed on this branch)
- `history search <query> [N] [--json]` (landed on this branch)
- `history export [N|all] [--json]` (landed on this branch)
- `logs --json` (landed on this branch)
- `logs path` (landed on this branch)
- `logs tail [stream] [--lines N] [--json]` (landed on this branch)
- `logs follow [stream] [--lines N] [--json]` (landed on this branch)
- `devices --json` (landed on this branch)
- stronger `config` inspection output for read-only use (landed on this branch)
- `bench [N] --json` and `bench export [N|all] [--json]` (landed on this branch)

Rule:

- if a command is primarily read-only and operator-facing, it should have a credible machine-readable story

## 2. Operator Workflows

Once the data contracts are stable, improve how operators move through them.

Candidate slices:

- filtered bench inspection
- bench/history cross-links from support commands
- tighter "what should I run next?" guidance between `status`, `doctor`, `logs`, and `history`

This is where the CLI starts feeling less like a bag of commands and more like a real toolset.

## 3. Live Terminal UX Without A TUI

The app can become more legible in-terminal without committing to a dashboard.

Candidate slices:

- `tmux-whisper watch [--interval SECONDS] [--iterations N]` (landed on this branch)
- compact status/watch presets (landed on this branch)
- text-first session summaries from recent history
- rolling operator views built from history + bench + runtime state

The principle is simple:

- prefer text-first live views before richer visual UI

## 4. CLI Contract Hardening

As the operator surface expands, make it easier to depend on.

Candidate slices:

- document which commands are stable for scripting
- keep JSON payload shape intentional and reviewable
- avoid silent drift between text and JSON meanings
- add focused regression coverage for new operator contracts

## Recommended Implementation Order

1. Finish JSON/read parity for the most operator-relevant commands.
2. Add the first genuinely useful export/search/tail workflows.
3. Add a text-first live `watch` surface.
4. Reassess whether a TUI is still needed after the CLI becomes genuinely first-class.

## Recommended Immediate Slices After This Branch Seed

Highest ROI next:

- filtered bench inspection
- command cross-links between `status`, `logs`, `bench`, and `history`
- compact status/watch presets that are stable enough for shell wrappers/plugins

Good follow-up after that:

- more explicit config read commands
- session-oriented summaries built from history + bench data

## Success Criteria

- An operator can answer most runtime/support questions from the CLI alone.
- Future integrations can lean on CLI contracts instead of duplicating internal logic.
- The next version feels like a stronger terminal product, not just a more stable one.
- If a TUI is still wanted later, it is clearly additive rather than foundational.
