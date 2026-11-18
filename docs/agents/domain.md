# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repo root, if it exists.
- `CONTEXT-MAP.md` at the repo root, if it exists.
- `docs/adr/`, if it exists.

If these files do not exist, proceed silently. Do not flag their absence or suggest creating them up front.

## Layout

This is a single-context repo. Khuluma is a native macOS dictation app (current work: `LOG.md`; [identity-rename outcome](../plans/archive/KHULUMA_IDENTITY_RENAME.md)). Everything lives in `native/`: the menu-bar app, the `khulumad` Parakeet daemon it bundles and supervises, and the bundled `khuluma` command-line helper (`khuluma transcribe`). The earlier bash CLI and its Homebrew formula were retired in 2026-11 (CHANGELOG, `docs/plans/archive/CLI_SUNSET.md`).

Use the repo's established terms:

- `Khuluma` for the app; `khulumad` for the Parakeet daemon; `khuluma` for the bundled helper command; `KhulumaDaemonKit`, `KhulumaCore` and `Khuluma` for the Swift modules.
- `KHULUMA_*` for environment overrides.
- `take` for one recording through delivery.
- `inline` for the frontmost-app delivery settings (`inline.*` in settings.json).
- `legacy import` for the one-time copy of the retired CLI's data into `~/Library/Application Support/Khuluma`.
- `Finder Quick Action` and the agent skill for the `transcribe` adapters.

## ADRs

If future ADRs are added under `docs/adr/`, read the ones that touch the area being changed. Surface any conflict explicitly rather than silently overriding it.
