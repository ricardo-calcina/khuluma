# Contributing

Thanks for contributing to Khuluma. Current product work is in [`LOG.md`](LOG.md).

## Scope and Direction

- Khuluma, the native macOS app in `native/`, is the product. The bash CLI was retired in 2026-11; the only command-line surface is the app's bundled `khuluma transcribe` helper (`native/Sources/khuluma-cli`).
- Keep changes minimal and production-oriented. Pure logic goes in `KhulumaCore` (no AppKit) with tests; the `Khuluma` target stays a thin shell.

## Development Setup

```bash
git clone https://github.com/ricardo-calcina/khuluma.git
cd khuluma
tools/test-affected.sh --full    # full Swift suite
tools/make-signing-identity.sh   # once
tools/build-khuluma-app.sh       # build, sign and install ~/Applications/Khuluma.app
```

## Work tracking

Keep current tasks, priorities and decisions in `LOG.md`; completed public release notes belong in `CHANGELOG.md`. Routine work does not require a separate spec, PRD or issue. The old rename roadmap is retained as historical context in `docs/archive/KHULUMA_RENAME_ROADMAP.md`.

## Branching and PRs

- Create feature branches from `main`.
- Keep one coherent task per branch.
- Include rationale and risk in the PR description.
- Name the affected areas: `app`, `daemon`, `transcribe`, `tools`.
- Note removals and user-visible changes in `CHANGELOG.md`.

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
| `tests/fixtures/` (frozen golden files) | the Swift suites that read them |
| `tests/*.py`, `tools/` | that test file, or a syntax check and its own tests |
| `Package.swift`, `Package.resolved`, anything it can't place | the full suite |

It fails safe: anything it can't place widens the set, never empties it. `OVERRIDES` at the top of `tools/test_affected.py` holds the links it can't derive (for example a test that reads repo files by path). Add one there when you find another. Swift steps build into the shared `native/.build` with half the cores, at low priority (`nice`, `taskpolicy -c utility`) and a 20-minute hard timeout that stops the whole process group, so the Mac stays usable. The snapshot render runs the just-built app with private support, log and defaults overrides under `native/.build`, so it never touches the daily app's data; the previous render moves to `native/.build/khuluma-snapshots.prev` for comparison. `--snapshot` adds the render to any run, `--no-snapshot` skips it and `--jobs N` (or `KHULUMA_JOBS`) sets the parallelism.

**The full suite** is CI's job: `.github/workflows/swift.yml` runs it on every push to `main`. Run it locally (`tools/test-affected.sh --full`) only for `Package.swift` or cross-cutting changes, or before an install when CI isn't available. Compiling is most of the cost: the whole Swift test run takes about 10 s, while `swift build --build-tests` takes a minute or more. So the big saving comes from UI and docs changes, which skip building the tests.

**One checkout, one `.build`.** Work in the main checkout and share `native/.build` (~1.4 GB); SwiftPM waits if another session is building. A git worktree needs its own `.build`, so use one only when two sessions must edit the same files (`LOG.md` Decisions).

Running Swift by hand: build first with `swift build --build-tests`, then `swift test --skip-build`, which avoids "TestingMacros not found". With the Command Line Tools toolchain, add `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` to both.

**Cleanup changes** must keep `CleanupParityTests` passing: `tests/fixtures/cleanup/expected.json` is frozen output of the retired bash cleanup, and the Swift pipeline must still match it byte for byte. Change a fixture only for a deliberate behaviour change, and say so in the commit.

**Repo tool checks:** `./tests/ci.sh` syntax-checks `tools/*.sh` and runs `tests/test_app_build_helpers.py` and `tests/test_test_affected.py`; `.github/workflows/ci.yml` runs it on every push.

**Runtime changes** need a real-use check when installing or restarting the daily app is authorized. These commands change the installed app; they are not required for every task or documentation edit:

```bash
tools/build-khuluma-app.sh      # waits for a take in progress, then relaunches Khuluma
tools/khuluma-report.sh         # after a few real takes
```

## Release Policy

- `main` is stable/releasable.
- Do not ship personal machine-specific config defaults.

## Security and Privacy

- Never commit API keys, tokens, or private credentials.
- Keep defaults portable; the app writes its own defaults on first run.
- Do not hardcode user-specific paths or local secrets.
- Logs, usage and stats never record dictated text. Transcripts live in history, and briefly in Khuluma's pending spool until history has them.
