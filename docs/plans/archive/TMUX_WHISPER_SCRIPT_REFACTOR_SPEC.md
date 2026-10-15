# Tmux Whisper Script Refactor Spec

> Status: Active incremental refactor
> Scope: Reduce the size and complexity of `bin/tmux-whisper` by modularizing the active runtime and removing dead compatibility paths.
> Intent: This is a planning/spec document only. No code behavior changes are proposed in this file itself.

## Summary

`bin/tmux-whisper` is now the main orchestration layer for the whole product, but it is carrying too many responsibilities in one file.

Current size after the 2026-05-11 module-deepening slice:

- `bin/tmux-whisper`: 7106 lines
- `bin/tmux-whisper-lib/`: 5235 lines across config, audio, mode, recording, integrations, history, and diagnostics modules
- `bin/dictate-lib.sh`: 471 lines

The main script currently mixes:

- bootstrap and dependency handling
- config loading and schema defaults
- backend selection, daemon lifecycle, warmup, and transcription
- mode handling, vocab handling, history, and benching
- tmux flow capture/stop/paste logic
- inline flow capture/stop/paste logic
- diagnostics and status rendering
- settings commands and CLI dispatch

That makes change review slower, raises the chance of accidental regressions, and hides the real architecture of the tool.

Progress now landed:

- `config.sh` owns config defaults, loading, schema status, and schema labels.
- `audio.sh` owns source-aware device resolution and cache policy.
- `mode.sh` owns shared mode naming, flow allowance, app detection, and prompt assembly; SwiftBar sources it rather than mirroring mode rules.
- `recording.sh` owns shared capture startup facts, retry metadata, ffmpeg-tail failure hints, and stop-signal behavior.
- `integrations.sh` owns the read-only integration adapter status surface behind `tmux-whisper integrations [--json]`.

The refactor goal is not to rewrite the product or change the CLI surface. The goal is to make the active runtime easier to understand and maintain by:

- removing legacy behavior we no longer want to preserve
- extracting clear internal modules
- consolidating duplicated flow logic
- keeping `bin/tmux-whisper` as a thin entrypoint and command router

## Refactor Stance

This project is still effectively single-user and pre-distribution.

That means this refactor should optimize for product clarity, not backward-compatibility theater.

Explicitly allowed during this effort:

- remove dead compatibility code instead of preserving it
- remove tests that only exist to keep obsolete behavior alive
- remove stale CLI/config affordances that no longer match the intended product
- simplify install/migration logic where it only exists for retired naming or backends

Explicitly not required:

- preserving `whisper.cpp` fallback behavior
- preserving old model-selection UX if Parakeet is the only supported backend
- keeping compatibility aliases purely for historical reasons
- preserving internal code structure for the sake of old commits

If a behavior is not part of the intended product going forward, the default choice should be deletion, not abstraction.

## Problem Statement

The current script is large for two different reasons:

1. Real product scope

- tmux flow
- inline flow
- local daemon runtime
- cleanup and postprocess pipeline
- diagnostics and configuration

2. Historical carry-over

- `whisper.cpp` fallback path
- GGML model resolution and tuning knobs
- backend-selection code that now mostly normalizes back to `swift_parakeet`
- tests and docs that still exercise or describe legacy paths

The refactor should address both.

If we only split files without removing the old backend compatibility layer, we will still be carrying unnecessary complexity around in smaller pieces.

## Current Script Map

Approximate responsibility groups inside `bin/tmux-whisper` today:

- `usage`, globals, bootstrap, common helpers: lines 1-1516
- backend and daemon runtime: lines 1517-2066
- mode, bench, history, postprocess pipeline support: lines 2128-3645
- audio/tmux helper utilities: lines 3646-4019
- tmux flow: lines 4020-4381
- inline flow: lines 4427-4924
- status and settings/manager commands: lines 4925-6753
- command dispatch: lines 6754-6798

High-friction hotspots:

- duplicated recording bootstrap between `start`, `inline_start`, and `inline`
- duplicated transcript lifecycle between tmux stop-processing and inline processing
- backend complexity still shaped by a removed future rather than the current product
- very large bottom-half command surface living inline with runtime flow code

## Goals

1. Make `bin/tmux-whisper` small enough to read as the product entrypoint, not the whole product.
2. Remove backend/model compatibility code that is no longer part of the intended product.
3. Reduce duplication between tmux and inline capture/transcription flow.
4. Preserve the existing user-facing tmux-first behavior.
5. Keep install/runtime behavior simple and explicit.
6. Keep the refactor reviewable in staged PRs rather than one giant rewrite.

## Non-Goals

- Rewriting the project in another language
- Reworking the Swift daemon package structure
- Redesigning tmux vs inline behavior
- Changing the mode mental model in this same pass
- Shipping a new public UX surface just because internals moved
- Building a generic plugin framework or over-abstracted shell architecture

## Design Principles

### 1. Remove before abstracting

Delete dead backend and model code before building modules around it wherever practical.

### 2. Keep Bash

This should remain a Bash CLI. The problem is concentration of responsibility, not the existence of shell.

### 3. Prefer a few coarse modules over many tiny ones

Target 6-9 meaningful internal modules, not dozens of micro-files.

### 4. Keep deterministic helpers low-level

Pure or mostly deterministic helpers belong in `bin/dictate-lib.sh` only if they are genuinely shared and stable. High-level CLI business logic should not be dumped there.

### 5. Keep runtime loading simple

The installed CLI should source sibling internal files from a predictable location. Do not depend on repository-only paths at runtime.

### 6. Keep CLI behavior stable unless simplification is intentional

The refactor should not accidentally change the active product. If something changes, it should be because the spec explicitly calls for removing legacy behavior.

## Proposed Target Architecture

### Entry Point

Keep:

- `bin/tmux-whisper`

Target responsibility:

- minimal bootstrap
- source internal modules
- parse top-level command
- dispatch to command handlers

Target size:

- roughly 800-1500 lines after the refactor is complete

### Shared Helper Library

Keep:

- `bin/dictate-lib.sh`

Target responsibility:

- deterministic text cleanup helpers
- deterministic vocab correction helpers
- deterministic model/audio resolution helpers that are genuinely shared

Do not turn this file into:

- a dumping ground for all moved functions
- a second giant script

### New Internal Module Directory

Recommended structure:

- `bin/tmux-whisper-lib/`

Recommended initial module set:

- `core.sh`
- `config.sh`
- `backend.sh`
- `recording.sh`
- `flow-tmux.sh`
- `flow-inline.sh`
- `commands-status.sh`
- `commands-settings.sh`
- `commands-content.sh`

Reason for this layout:

- it keeps modules next to the installed CLI
- `install.sh` can copy the directory alongside `tmux-whisper`
- the runtime can source files relative to the script location
- it avoids introducing a second top-level repo convention just for shell internals

## Recommended Module Responsibilities

### `bin/tmux-whisper-lib/core.sh`

Move or consolidate:

- `die`
- `need`
- `now_ms`
- `sleep_ms`
- `bool_is_on`
- path/runtime cache helpers that are generic
- logging helpers like `log_transcribe_event`

Keep this module narrow:

- basic shell/runtime primitives
- no tmux-specific or inline-specific business logic

### `bin/tmux-whisper-lib/config.sh`

Move or consolidate:

- `config_ensure`
- `config_load`
- `config_schema_status`
- `config_schema_version_label`
- `config_set`
- backend runtime cache load/write helpers
- inline session cache helpers

This module should own:

- config bootstrap
- generated shell vars from TOML
- small persistence helpers

### `bin/tmux-whisper-lib/backend.sh`

Move or consolidate:

- backend resolution
- Parakeet model/socket resolution
- daemon request helpers
- daemon lifecycle helpers
- warmup and prime helpers
- `transcribe_audio`

Expected simplification:

- remove `whisper.cpp` and fallback support first or as part of this extraction

Result:

- this module becomes a Parakeet-only runtime backend module

### `bin/tmux-whisper-lib/recording.sh`

Extract shared flow-agnostic recording helpers:

- audio source/device resolution
- ffmpeg launch helpers
- ffmpeg early-failure detection
- target capture helpers where common
- state file read/write helpers
- recording termination helper

This module should be designed so both tmux and inline flows call the same recording bootstrap helpers instead of open-coding them.

### `bin/tmux-whisper-lib/flow-tmux.sh`

Own only tmux flow behavior:

- tmux pane discovery
- tmux autosend strategy
- tmux job markers
- tmux-specific stop pipeline and paste routing
- tmux command entrypoints: `start`, `stop`, `toggle`, `cancel` as tmux-facing wrappers where appropriate

### `bin/tmux-whisper-lib/flow-inline.sh`

Own only inline behavior:

- foreground and background inline recording entrypoints
- inline state lifecycle
- osascript paste/send helpers
- stale session suppression
- inline-specific target restore behavior

### `bin/tmux-whisper-lib/commands-status.sh`

Move:

- `status`
- possibly `debug`, `doctor`, and `logs` if it remains coherent

Reason:

- these commands are large but relatively low-risk to isolate
- they mainly read runtime state and render diagnostics

### `bin/tmux-whisper-lib/commands-settings.sh`

Move:

- `set_postprocess`
- `set_keep_logs`
- `set_silence_trim`
- `set_repeats_level`
- `set_autosend`
- `set_inline_process_sound`
- `set_paste_target`
- `set_inline_send_mode`
- `manage_tmux`
- `set_llm`
- `set_budget`
- `set_device`
- `manage_keybind`
- `manage_swiftbar`
- `manage_sounds`

These are mostly command handlers and should not live beside the hot path recording logic.

### `bin/tmux-whisper-lib/commands-content.sh`

Move:

- modes
- vocab
- history
- replay
- bench
- postprocess support that is more command-facing than runtime-facing

This module may later be split again if it stays too large, but it is a reasonable first grouping.

## Legacy Code Removal Scope

This is the explicit simplification work that should happen as part of, or immediately before, the modularization effort.

### Remove `whisper.cpp` backend support

Current legacy code exists in:

- `resolve_transcribe_backend`
- `resolve_model_path`
- `transcribe_whisper_cli`
- `transcribe_audio`
- diagnostics/status/help text
- tests that still stub `whisper-cli`

Planned removal:

- remove `whisper_cpp` backend selection
- remove backend fallback from Parakeet to `whisper.cpp`
- remove `whisper-cli` dependency assumptions
- remove GGML model resolution helpers and CLI model switching if no longer needed
- remove old fallback logging and status reporting

### Remove model-selection surface that only existed for `whisper.cpp`

Likely removals:

- `tmux-whisper model ...`
- `tmux-whisper tmux model ...`
- `resolve_model_path`
- thread/beam/best_of/VAD tuning knobs if they no longer affect any supported backend

This affects:

- usage text
- config schema/load defaults
- status/debug output
- tests
- docs

### Remove stale migration/compatibility glue where safe

Candidates to re-evaluate:

- mode rename migrations in `install.sh` if they only preserve historical names no longer in live use
- old aliases in command parsing that exist only for backward compatibility
- tests whose only purpose is proving old behavior still works

The default question should be:

"Does this exist for the intended product, or only because it used to exist?"

If the answer is the latter, delete it.

## Shared Flow Consolidation Targets

The biggest maintainability win after legacy removal is consolidating duplicated logic.

### 1. Recording bootstrap

Currently duplicated across:

- `start`
- `inline_start`
- `inline`

Common work to unify:

- detect audio index
- apply config/env fallback rules
- capture target metadata
- launch ffmpeg
- verify ffmpeg is live
- compute startup metrics
- write state

Target outcome:

- one shared bootstrap path with small flow-specific hooks for target capture and state file shape

### 2. Transcript processing pipeline

Currently duplicated between tmux and inline processing paths.

Common work to unify:

- silence trim
- backend transcription
- transcript artifact cleanup
- regex filler/repeat cleanup
- optional vocab-only correction
- optional postprocess
- mode cleanup
- british spelling normalization
- bench/history recording

Flow-specific delivery should be isolated:

- tmux destination pane + paste/send
- inline clipboard + paste/send

Target outcome:

- one shared processing pipeline
- two delivery backends

### 3. Runtime observability helpers

Bench/history/status logic currently touches many parts of the script.

Consolidation target:

- standardize one runtime result structure in shell vars
- standardize bench append points
- standardize history save call sites

This will reduce subtle divergence between tmux and inline behavior.

## File-Level Impact Forecast

The future implementation will likely touch at least:

- `bin/tmux-whisper`
- `bin/dictate-lib.sh`
- `bin/tmux-whisper-lib/*.sh` new files
- `install.sh`
- `README.md`
- `docs/TROUBLESHOOTING.md`
- `CHANGELOG.md`
- `config/config.toml`
- `integrations/tmux-whisper-status.0.2s.sh`
- `tests/test_cli.sh`
- `tests/test_flow_parity.sh`
- `tests/test_regression.sh`
- `tests/test_install.sh`
- `tests/ci.sh`

Potentially touched depending on how deep the simplification goes:

- Raycast integration scripts if they reference retired command affordances
- `tests/test_lib.sh` if `dictate-lib.sh` responsibilities change

## Recommended Execution Order

### Phase 1: Remove legacy backend/model surface

Do first because it shrinks the problem before extraction.

Tasks:

- remove `whisper.cpp` fallback and backend branching
- remove model-selection command surface if unsupported in the Parakeet-only product
- remove unused config/env/status/doc references
- remove tests that preserve old backend behavior

Expected outcome:

- the remaining script reflects the real product

### Phase 2: Introduce internal module loading

Tasks:

- add `bin/tmux-whisper-lib/`
- move low-risk helpers first
- keep `bin/tmux-whisper` sourcing modules with no intended behavior change

Start with:

- `core.sh`
- `config.sh`
- `commands-status.sh`

Reason:

- these are lower-risk than the recording hot path

### Phase 3: Extract backend runtime

Tasks:

- move Parakeet daemon and warmup logic into `backend.sh`
- keep behavior the same after the legacy cleanup
- simplify status/debug to the Parakeet-only worldview

### Phase 4: Extract shared recording helpers

Tasks:

- introduce `recording.sh`
- unify ffmpeg spawn and validation logic
- unify shared startup metrics/state helpers

### Phase 5: Consolidate tmux and inline processing pipeline

Tasks:

- create one shared transcript processing path
- separate delivery adapters for tmux and inline
- preserve stale-result suppression in inline
- preserve tmux queue markers and async behavior

### Phase 6: Move command handlers out of the entrypoint

Tasks:

- move settings/content managers out of `bin/tmux-whisper`
- keep final router thin

### Phase 7: Cleanup pass

Tasks:

- delete dead helpers left behind after extraction
- simplify naming
- trim repeated comments and old notes
- tighten tests and docs around the new architecture

## PR Strategy

Do not land this as one giant refactor PR.

Recommended PR sequence:

1. `remove-whisper-cpp-compat`
2. `add-internal-shell-modules`
3. `extract-backend-runtime`
4. `extract-recording-bootstrap`
5. `unify-processing-pipeline`
6. `extract-command-surfaces`
7. `final-cleanup-and-doc-refresh`

Each PR should be independently reviewable and runnable.

## Validation Strategy

For each phase:

- run the smallest targeted tests that cover touched behavior
- then run `./tests/ci.sh`

For the whole refactor:

- `./tests/ci.sh`
- `./install.sh --force`
- one real inline dictation
- one real tmux dictation
- `tmux-whisper status`
- `tmux-whisper debug`
- `tmux-whisper doctor`
- `tmux-whisper warmup`

### Expected test simplifications

After legacy removal, test cleanup should include:

- remove `whisper-cli` stubs where no longer relevant
- remove fallback assertions like "falling back to whisper_cpp"
- remove status expectations for whisper model/tuning knobs
- add stronger Parakeet-only assertions

## Install and Runtime Requirements

The module layout must work both:

- inside the repo checkout
- after `./install.sh --force`

That means:

- `bin/tmux-whisper` should resolve sibling internal modules relative to its own path
- `install.sh` must copy the internal module directory alongside the CLI
- no module should assume repo-root working directory at runtime

## Documentation Changes Expected In The Implementation Pass

When the actual refactor lands, docs should be updated to match the simplified product.

Expected doc updates:

- README should stop presenting `whisper.cpp` as an active fallback or comparison path
- troubleshooting should focus on Parakeet daemon/model/runtime issues
- changelog should note the internal modularization and any intentional surface removals

## Risks

### Risk: behavioral drift during extraction

Mitigation:

- remove dead legacy code first
- move code with minimal edits before changing logic
- keep full CI and real dictation smoke tests in the loop

### Risk: too many modules with unclear ownership

Mitigation:

- keep coarse module boundaries
- avoid splitting until each module has a clear product responsibility

### Risk: install/runtime path breakage

Mitigation:

- choose sibling module layout under `bin/`
- validate with `./install.sh --force`

### Risk: over-preserving old behavior out of habit

Mitigation:

- use this spec’s simplification stance as the default
- require justification to keep old compatibility paths

## Definition Of Done

This refactor is complete when all of the following are true:

- `bin/tmux-whisper` is a thin entrypoint and dispatcher rather than the entire product runtime
- active runtime responsibilities are split into clear internal modules
- `whisper.cpp` compatibility/fallback code is gone
- model-selection UI/config that only served the legacy backend is gone
- duplicated recording/transcript flow logic is materially reduced
- install/runtime sourcing works in both repo and installed locations
- tests and docs reflect the simplified Parakeet-first architecture

## Default Assumptions For The Future Plan Pass

These are the assumptions the later implementation-planning pass should start from unless new evidence appears:

- the product should become Parakeet-only
- we do not need to preserve legacy backend/model compatibility
- install-time migrations should be kept only if they still serve the live local user setup
- modularization should be staged, not big-bang
- internal clarity is a priority equal to external reliability
