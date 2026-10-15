# Whisper.cpp Removal Plan

This note is a follow-up plan for fully detaching `tmux-whisper` from the legacy `whisper.cpp` backend after the Swift Parakeet backend has had enough real-world soak time.

Current status:
- `swift_parakeet` is the default backend.
- `whisper.cpp` still exists as compatibility code and as a temporary fallback.
- Some tests still exercise `whisper.cpp` behavior intentionally.

This file is the checklist for the later cleanup pass.

## Preconditions

Do not remove `whisper.cpp` until all of the following are true:

- Parakeet has been used as the primary backend in daily usage for at least a short stability window.
- The local vocab/cleanup layer is strong enough that `postprocess` is optional for most coding and note-taking use.
- Cold-start behavior is acceptable, including warm-up behavior after install/update.
- No remaining live integrations depend on explicit GGML model switching.

## Removal Scope

The removal pass should eliminate:

- `whisper_cpp` backend selection and fallback behavior.
- GGML model selection UI and config semantics.
- Old `whisper.cpp` tuning knobs that no longer affect the runtime.
- Tests that only exist to preserve `whisper.cpp` compatibility.
- Documentation that presents GGML/`whisper.cpp` as an active install path.

The removal pass should preserve:

- tmux queueing, pane routing, autosend, and inline flows.
- local vocab and regex cleanup.
- optional LLM post-processing for polish/restructuring.
- the warm Swift daemon architecture and install-time best-effort warm-up.

## Code Areas To Update

### 1. Backend resolution and transcription flow

Review and simplify:

- [bin/tmux-whisper](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/bin/tmux-whisper)

Target changes:

- Remove `whisper_cpp` from `resolve_transcribe_backend`.
- Remove fallback logic from `transcribe_audio` that drops from `swift_parakeet` to `whisper_cpp`.
- Remove `transcribe_whisper_cli` and any now-unused whisper model resolution helpers.
- Keep `warmup`, daemon lifecycle, and Parakeet model resolution intact.

### 2. Config schema and generated defaults

Review and simplify:

- [config/config.toml](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/config/config.toml)
- [bin/tmux-whisper](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/bin/tmux-whisper)

Target changes:

- Remove `whisper.model`, `whisper.threads`, `whisper.beam`, `whisper.best_of`, and related compatibility keys if they are no longer used anywhere.
- Remove `tmux.model` if tmux no longer has a separate model concept.
- Keep `swift_parakeet` as the only backend section.
- Bump config schema version only if removal breaks backward compatibility in a meaningful way.

### 3. CLI surface

Review and simplify:

- [bin/tmux-whisper](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/bin/tmux-whisper)

Target changes:

- Remove `tmux-whisper model ...` commands if there is no longer a supported local model switcher.
- Remove backend wording that implies active backend choice when only Parakeet is supported.
- Keep `status`, `debug`, `doctor`, `warmup`, and mode/vocab controls centered on the Parakeet runtime.

### 4. SwiftBar and Raycast integrations

Review and simplify:

- [integrations/tmux-whisper-status.0.2s.sh](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/integrations/tmux-whisper-status.0.2s.sh)
- [integrations/raycast/tmux-whisper-inline.sh](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/integrations/raycast/tmux-whisper-inline.sh)
- [integrations/raycast/tmux-whisper-toggle.sh](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/integrations/raycast/tmux-whisper-toggle.sh)

Target changes:

- Remove any remaining model-selection affordances.
- Remove legacy backend/fallback messaging that no longer applies.
- Keep the integrations thin and delegated to the main CLI/runtime.

### 5. Tests and CI

Review and simplify:

- [tests/test_cli.sh](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/tests/test_cli.sh)
- [tests/test_regression.sh](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/tests/test_regression.sh)
- [tests/test_flow_parity.sh](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/tests/test_flow_parity.sh)
- [tests/ci.sh](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/tests/ci.sh)

Target changes:

- Remove tests that only verify `whisper.cpp` model selection, fallback, or tuning knob display.
- Replace them with Parakeet-first assertions where the user-facing behavior should remain covered.
- Keep at least one native-backend smoke path in CI.
- Keep install-time warm-up behavior covered as best-effort, not required success.

### 6. Docs

Review and simplify:

- [README.md](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/README.md)
- [CHANGELOG.md](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/CHANGELOG.md)
- [docs/TROUBLESHOOTING.md](/Users/admin/Documents/Projects/tmux-whspr/tmux-whisper/docs/TROUBLESHOOTING.md)

Target changes:

- Remove installation guidance that tells users to fetch GGML models.
- Reframe the product clearly as a Parakeet-first local dictation tool.
- Keep any migration notes short and practical.

## Suggested Execution Order

When the cleanup pass begins, do it in this order:

1. Remove backend fallback logic from the CLI.
2. Remove dead config keys and CLI commands.
3. Clean SwiftBar/Raycast surfaces.
4. Rewrite tests to Parakeet-only assumptions.
5. Update docs and changelog.
6. Run full CI and a local install smoke test.

## Validation Checklist For That Future Pass

Before merging the actual removal:

- `./tests/ci.sh`
- `./install.sh --force`
- One inline real-world dictation
- One tmux real-world dictation
- `tmux-whisper status`
- `tmux-whisper doctor`
- `tmux-whisper warmup`

## Non-Goals For The Removal Pass

Do not combine `whisper.cpp` removal with:

- a full UI rewrite,
- a large mode-system redesign,
- post-processing redesign,
- model downloader/manager work,
- or Homebrew tap updates.

Those can happen in separate follow-up changes once the backend cleanup is stable.
