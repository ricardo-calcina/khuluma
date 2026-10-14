# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repo root, if it exists.
- `CONTEXT-MAP.md` at the repo root, if it exists.
- `docs/adr/`, if it exists.

If these files do not exist, proceed silently. Do not flag their absence or suggest creating them up front.

## Layout

This is a single-context repo. Tmux Whisper is a macOS-first, inline-first dictation CLI. Tmux is the differentiated pane-targeted workflow; Raycast scripts are adapter surfaces around the CLI/runtime, and Lowkey is the native menu-bar app (the SwiftBar plugin was retired in v0.11).

Use the repo's established terms:

- `tmux-whisper` for the public command.
- `dictate` only for legacy config, state, temp, and user-local runtime paths that intentionally still use that name.
- `inline` for frontmost-app paste/send dictation.
- `tmux` for pane-targeted dictation.
- `Raycast scripts` for integration adapters; `Lowkey` for the native menu-bar app.
- `processing markers`, `state files`, and `install receipt` for runtime/integration observability.

## ADRs

If future ADRs are added under `docs/adr/`, read the ones that touch the area being changed. Surface any conflict explicitly rather than silently overriding it.
