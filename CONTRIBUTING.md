# Contributing

Thanks for contributing to Khuluma. Current product work is in [`LOG.md`](LOG.md).

## Scope and Direction

- Khuluma, the menu-bar app, is the product. The CLI is its back end and is being retired step by step, so new user-facing features belong in Khuluma.
- CLI changes should serve Khuluma, file transcription, or the phase 1 ports (`LOG.md`). Changes to the JSON contracts in `docs/CLI_CONTRACTS.md` are additive only, unless Khuluma changes with them and the app contract number goes up on both sides.
- `khuluma doctor --json` uses diagnostic schema 2 with neutral identity keys. v0.11.0 removes the old command/schema adapter and legacy environment aliases; app contract 3 and durable data formats remain unchanged. Use canonical interfaces in new callers and keep wrong-profile refusal and explicit recovery intact.
- Keep changes minimal and production-oriented. Pure logic goes in `KhulumaCore` (no AppKit) with tests; the `Khuluma` target stays a thin shell.

## Development Setup

```bash
git clone https://github.com/ricardo-calcina/khuluma.git
cd khuluma
./tests/ci.sh
./install.sh --force
tools/make-signing-identity.sh   # once
tools/build-khuluma-app.sh
```

## Work tracking

Keep current tasks, priorities and decisions in `LOG.md`; completed public release notes belong in `CHANGELOG.md`. Routine work does not require a separate spec, PRD or issue. The old rename roadmap is retained as historical context in `docs/archive/KHULUMA_RENAME_ROADMAP.md`.

## Branching and PRs

- Create feature branches from `main`.
- Keep one coherent task per branch.
- Include rationale and risk in the PR description.
- Name the affected areas: `khuluma`, `cli`, `daemon`, `transcribe`.
- Note removals and contract changes in `CHANGELOG.md`.

## Validation Requirements

Run the checks your change affects, not the whole suite. Do that with `tools/test-affected.sh`, the default for every agent and contributor:

```bash
tools/test-affected.sh --plan                     # what it would run, and why
tools/test-affected.sh                            # run it: commits not on origin/main + working tree
tools/test-affected.sh --paths <your files...>    # only these paths (use this in a shared checkout)
tools/test-affected.sh --base <ref>               # diff against another ref
```

It prints each changed file, what it chose for it and why, then each step's time. What runs for what:

| Change | Checks |
|---|---|
| Docs (`*.md`, `docs/`, `LICENSE`) | nothing |
| App UI (`native/Sources/Khuluma/**`) | debug build of the app, then the UI snapshot render into `native/.build/khuluma-snapshots` (no unit tests: no test target imports the app) |
| `KhulumaCore` | the test suites that use the changed types, found from source: declared names, every Core file that uses them, the tests that use any of those. Nothing found means all of `KhulumaCoreTests`. `KhulumaCore/Stats` changes also get the snapshot render |
| `KhulumaDaemonKit`, `khulumad` | `KhulumaDaemonKitTests`, the Core tests that use the daemon (including the bundled-daemon integration test) |
| `khuluma-cli` | its build and the file-transcription tests |
| Test files | the suites in them; a shared helper runs the tests that use it |
| Cleanup inputs (`bin/`, `config/`, `tests/fixtures/`, the fixture generators) | `tests/gen-cleanup-fixtures.sh --check`, the parity and settings suites; `./tests/ci.sh` for `bin/` |
| `tests/*.sh`, `tests/*.py`, `tools/` | that test file, or a syntax check and its own tests |
| `Package.swift`, `Package.resolved`, anything it can't place | the full suite |

It fails safe: anything it can't place widens the set, never empties it. `OVERRIDES` at the top of `tools/test_affected.py` holds the links it can't derive (for example a test that reads repo files by path). Add one there when you find another. Swift steps build into the shared `native/.build` with half the cores, at low priority (`nice`, `taskpolicy -c utility`) and a 20-minute hard timeout that stops the whole process group, so the Mac stays usable. The snapshot render runs the just-built app with private support, log and defaults overrides under `native/.build`, so it never touches the daily app's data; the previous render moves to `native/.build/khuluma-snapshots.prev` for comparison. `--snapshot` adds the render to any run, `--no-snapshot` skips it and `--jobs N` (or `KHULUMA_JOBS`) sets the parallelism.

**The full suite** is CI's job: `.github/workflows/swift.yml` runs it on every push to `main`. Run it locally (`tools/test-affected.sh --full`) only for `Package.swift` or cross-cutting changes, or before an install when CI isn't available. Compiling is most of the cost: the whole Swift test run takes about 10 s, while `swift build --build-tests` takes a minute or more. So the big saving comes from UI and docs changes, which skip building the tests.

**One checkout, one `.build`.** Work in the main checkout and share `native/.build` (~1.4 GB); SwiftPM waits if another session is building. A git worktree needs its own `.build`, so use one only when two sessions must edit the same files (`LOG.md` Decisions).

Running Swift by hand: build first with `swift build --build-tests`, then `swift test --skip-build`, which avoids "TestingMacros not found". With the Command Line Tools toolchain, add `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` to both.

**Cleanup changes** must keep the bash and Swift pipelines in step. Regenerate the fixtures with `tests/gen-cleanup-fixtures.sh`, and check that `CleanupParityTests` passes.

**Runtime changes** need a real-use check when installing or restarting the daily app is authorized. The commands below change the installed runtime; they are not required for every task or documentation edit:

```bash
./install.sh --force
tools/build-khuluma-app.sh      # waits for a take in progress, then relaunches Khuluma
khuluma doctor
tools/khuluma-report.sh         # after a few real takes
```

## Release Policy

- `main` is stable/releasable.
- Homebrew tap is updated from stable tags only.
- Do not ship personal machine-specific config defaults.

## Security and Privacy

- Never commit API keys, tokens, or private credentials.
- Keep defaults portable (`config/config.toml`, `config/vocab`).
- Do not hardcode user-specific paths or local secrets.
- Logs, usage and stats never record dictated text. Transcripts live in history, and briefly in Khuluma's pending spool until history has them.
