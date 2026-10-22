# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repo root, if it exists.
- `CONTEXT-MAP.md` at the repo root, if it exists.
- `docs/adr/`, if it exists.

If these files do not exist, proceed silently. Do not flag their absence or suggest creating them up front.

## Layout

This is a single-context repo. Tmux Whisper is a macOS dictation project being renamed after its app (current work: `LOG.md`; historical roadmap: `docs/archive/KHULUMA_RENAME_ROADMAP.md`). The app was called Lowkey until v0.11. Khuluma, the native menu-bar app in `tmux-whisperd/`, is the only way to dictate. The `tmux-whisper` CLI is its back end (config, vocab, history, usage, the daemon lifecycle) and transcribes audio files. The tmux flow, CLI recording, LLM post-processing, Raycast and SwiftBar were removed in v0.11.

Use the repo's established terms:

- `tmux-whisper` for the public command.
- `dictate` only for legacy config, temp and user-local runtime paths that intentionally still use that name (`~/.config/dictate`, `DICTATE_*`).
- `Khuluma` for the app; `tmux-whisperd` for the Parakeet daemon; `TmuxWhisperKit`, `KhulumaCore` and `Khuluma` for the Swift modules.
- `take` for one recording through delivery. A take goes the `native` path (daemon socket and Swift cleanup) or `falls back` to the CLI's `inline process`.
- `inline` for the CLI's pipeline that Khuluma uses (`inline process`, `inline record`, `inline cleanup`), and for the frontmost-app delivery settings (`[inline]`). `tmux` survives only as a value in old history and usage.
- `app contract` for the integer Khuluma and the CLI must agree on.
- `take markers` (processing markers) for the files that show a take is in progress; `install receipt` for install provenance.
- `Finder Quick Action` and the agent skill for the `transcribe` adapters.

## ADRs

If future ADRs are added under `docs/adr/`, read the ones that touch the area being changed. Surface any conflict explicitly rather than silently overriding it.
