#!/usr/bin/env python3
"""All-mocked build-helper control-flow gate; retains every private fixture."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).resolve().parents[1]
HASH_A = "A" * 40
HASH_B = "B" * 40
HASH_OLD = "C" * 40
NAME = "Khuluma Local Code Signing"
OLD_NAME = "Lowkey Local Code Signing"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

MOCK = r'''#!INTERPRETER
import hashlib, json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["GATE_CASE"]).resolve()
event = {"command": name, "args": args}
with (root / "events.jsonl").open("a") as stream:
    stream.write(json.dumps(event) + "\n")
settings = json.loads((root / "settings.json").read_text())
def owned(value):
    path = pathlib.Path(value)
    if not path.is_absolute():
        path = pathlib.Path.cwd() / path
    path = path.absolute()
    if root != path and root not in path.parents:
        raise SystemExit("mock refused nonfixture path: " + str(path))
    return path
def marker(path):
    value = path / "Contents/MacOS/Khuluma"
    return value.read_text() if value.exists() else ""
if name == "security":
    if args != ["find-identity", "-p", "codesigning", os.environ["KHULUMA_KEYCHAIN"]]:
        raise SystemExit("Unexpected security operation; real keychain access forbidden")
    print(settings["identities"])
elif name == "swift":
    if args and args[0] == "build":
        scratch = owned(args[args.index("--scratch-path") + 1])
        binary = scratch / "release/Khuluma"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_text("MOCK NEW KHULUMA EXECUTABLE\n")
        binary.chmod(0o700)
        if settings.get("race_on_build"):
            output = owned(os.environ["GATE_OUTPUT"])
            output.mkdir(parents=True)
            (output / "race-sentinel").write_text("UNRELATED RACE OUTPUT\n")
        if settings.get("build_failure"):
            raise SystemExit(41)
    elif args and args[0] == "-":
        body = sys.stdin.read()
        (root / "mocked-lifecycle-body.swift").write_text(body)
        if "NSWorkspace.shared.runningApplications" not in body or "ps -" in body:
            raise SystemExit("Expected latest AppKit identity matcher")
        if settings.get("lifecycle_race"):
            output = owned(os.environ["GATE_OUTPUT"])
            output.rename(output.with_name("raced-original.app"))
            output.mkdir()
            (output / "race-sentinel").write_text("UNRELATED LIFECYCLE RACE\n")
        if settings.get("lifecycle_failure"):
            raise SystemExit(42)
        print("1" if settings.get("running") else "0")
    else:
        raise SystemExit("Unexpected Swift operation; actual compilation forbidden")
elif name == "git":
    print("4242")
elif name == "plutil":
    target = owned(args[-1])
    with target.open("rb") as stream:
        data = plistlib.load(stream)
    if args[0] == "-extract":
        print(data[args[1]])
    elif args[0] != "-lint":
        raise SystemExit("Unexpected plutil arguments")
elif name == "codesign":
    target = owned(args[-1])
    if args[0] == "--force":
        if settings.get("sign_failure"):
            raise SystemExit(43)
        signer = args[args.index("--sign") + 1]
        (target / ".mock-signature.json").write_text(json.dumps({"signer": signer}))
    elif args[0] == "--verify":
        stage = "khuluma-app-build." in str(target)
        candidate = target.name == "candidate.app"
        output = str(target) == os.environ["GATE_OUTPUT"]
        if (settings.get("stage_verify_failure") and stage
                or settings.get("candidate_verify_failure") and candidate
                or settings.get("output_verify_failure") and output and marker(target).startswith("MOCK NEW")):
            raise SystemExit(44)
        if not (target / "Contents/Info.plist").is_file():
            raise SystemExit("Invalid fixture bundle")
    elif args[0] == "-dvv":
        authority = settings.get("reported_authority", "Khuluma Local Code Signing")
        print("Authority=" + authority)
    else:
        raise SystemExit("Unexpected codesign operation")
elif name == "ditto":
    source, destination = [owned(value) for value in args]
    if settings.get("copy_failure"):
        destination.mkdir(parents=True)
        (destination / "partial-copy").write_text("retained partial candidate\n")
        raise SystemExit(45)
    shutil.copytree(source, destination)
elif name in ("open", "mdimport", "lsregister"):
    for value in args:
        if value.startswith("/"):
            owned(value)
elif name == "mock-event":
    if args and (args[0] == "preflight" and settings.get("preflight_failure")
                 or args[0] == "environment-guard" and settings.get("environment_failure")):
        raise SystemExit(46)
elif name in ("ps", "osascript", "launchctl", "defaults", "tccutil", "xcrun", "xcodebuild", "service"):
    raise SystemExit("Forbidden nonmocked operation requested: " + name)
else:
    raise SystemExit("Unexpected mock command: " + name)
'''


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_bundle(path: Path, identifier: str = "com.ricardo-nth.khuluma", executable: str = "Khuluma") -> None:
    (path / "Contents/MacOS").mkdir(parents=True)
    with (path / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": executable}, stream)
    binary = path / "Contents/MacOS" / executable
    binary.write_text("MOCK ORIGINAL APP\n")
    binary.chmod(0o700)
    (path / "original-sentinel").write_text("preserve original\n")


def inspect_bundle(path: Path) -> str | None:
    if (path / "original-sentinel").is_file():
        return "original"
    if (path / "race-sentinel").is_file():
        return "race"
    binary = path / "Contents/MacOS/Khuluma"
    if binary.is_file() and binary.read_text().startswith("MOCK NEW"):
        return "new"
    return None


def main() -> int:
    source_script = SOURCE / "tools/build-khuluma-app.sh"
    source_hash = digest(source_script)
    run = Path(tempfile.mkdtemp(prefix="khuluma-app-helpers-", dir=Path(tempfile.gettempdir()).resolve())).resolve()
    run.chmod(0o700)
    template = run / "template"
    for relative in ("repo/tools", "repo/bin/khuluma-lib", "repo/native/App", "repo/assets/icons/app", "repo/assets/icons/menu-bar", "mock-bin"):
        (template / relative).mkdir(parents=True, exist_ok=True)
    (template / "repo/assets/icons/app/Khuluma.icns").write_bytes(b"MOCK ICNS RESOURCE\n")
    (template / "repo/assets/icons/app/Assets.car").write_bytes(b"MOCK CAR RESOURCE\n")
    (template / "repo/assets/icons/menu-bar/khuluma-menu-template.pdf").write_bytes(b"MOCK VECTOR PDF\n")
    shutil.copy2(source_script, template / "repo/tools/build-khuluma-app.source.sh")
    instrumentation_from = "  LSREGISTER=" + LSREGISTER
    instrumentation_to = '  LSREGISTER="$GATE_MOCK_LSREGISTER"'
    original = source_script.read_text()
    assert original.count(instrumentation_from) == 1, "absolute service seam changed; refuse unsafe harness execution"
    tested_script = template / "repo/tools/build-khuluma-app.sh"
    tested_script.write_text(original.replace(instrumentation_from, instrumentation_to))
    tested_hash = digest(tested_script)
    # Dependency seams are fixture-only. The build helper itself is byte exact.
    (template / "repo/bin/khuluma-lib/identity.sh").write_text(
        'khuluma_normalize_environment() { return 91; }\n'
        'khuluma_reject_obsolete_environment() { mock-event environment-guard "$@"; }\n')
    (template / "repo/bin/khuluma-lib/migration.sh").write_text(
        'khuluma_identity_preflight() { mock-event preflight "$@"; }\n')
    (template / "repo/bin/khuluma").write_text('KHULUMA_CLI_VERSION="fixture-0.11.0"\n')
    shutil.copy2(SOURCE / "native/App/Khuluma.entitlements", template / "repo/native/App/Khuluma.entitlements")
    mock = template / "mock-bin/mock-command"
    mock.write_text(MOCK.replace("#!INTERPRETER", "#!" + sys.executable))
    mock.chmod(0o700)
    names = ["security", "swift", "git", "plutil", "codesign", "ditto", "open", "mdimport", "lsregister",
             "mock-event", "ps", "osascript", "launchctl", "defaults", "tccutil", "xcrun", "xcodebuild", "service"]
    for name in names:
        (mock.parent / name).symlink_to("mock-command")
    # All product logic is copied verbatim except the one absolute service
    # pathname assignment above. No real service/UI API executes.
    wrapper = template / "invoke.sh"
    wrapper.write_text(
        '#!/usr/bin/env bash\nset -euo pipefail\n'
        + 'source "$GATE_REPO/tools/build-khuluma-app.sh" "$@"\n')
    wrapper.chmod(0o700)

    basic_listing = f'  1) {HASH_A} "{NAME}" (CSSMERR_TP_NOT_TRUSTED)\n     1 identities found'
    cases: list[dict] = []
    def case(name: str, *, mode: str = "preview", settings: dict | None = None,
             identity: str | None = None, existing: str | None = None, output_kind: str = "fresh",
             explicit_out: bool = True, separate_legacy: bool = False, existing_executable: str = "Khuluma",
             extra_args: tuple = (), expected: int = 0, verify=None) -> None:
        root = run / name
        root.mkdir(mode=0o700)
        shutil.copytree(template, root / "fixture", symlinks=True)
        fixture = root / "fixture"
        repo = fixture / "repo"
        home = root / "home"
        temporary = root / "tmp"
        home.mkdir(mode=0o700)
        temporary.mkdir(mode=0o700)
        daily = home / "Applications/Khuluma.app"
        output = root / "outputs/Preview.app" if mode == "preview" else daily
        if output_kind == "daily":
            output = daily
        elif output_kind == "legacy-daily":
            output = home / "Applications/Lowkey.app"
        elif output_kind == "parent-symlink":
            target = root / "original-target"
            target.mkdir()
            (root / "alias").symlink_to(target, target_is_directory=True)
            output = root / "alias/Preview.app"
        if existing:
            make_bundle(output, identifier=existing, executable=existing_executable)
        if separate_legacy:
            make_bundle(home / "Applications/Lowkey.app", identifier="com.ricardo-nth.lowkey", executable="Lowkey")
        if output_kind == "symlink":
            target = root / "original-target"
            target.mkdir()
            output.parent.mkdir(parents=True)
            output.symlink_to(target, target_is_directory=True)
        options = {"identities": basic_listing, **(settings or {})}
        (root / "settings.json").write_text(json.dumps(options, indent=2) + "\n")
        env = {
            "PATH": str(fixture / "mock-bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(home), "TMPDIR": str(temporary), "KHULUMA_TMPDIR": str(temporary),
            "KHULUMA_KEYCHAIN": str(home / "fixture.keychain-db"),
            "XDG_CONFIG_HOME": str(home / "config"), "XDG_DATA_HOME": str(home / "data"),
            "GATE_CASE": str(root), "GATE_REPO": str(repo), "GATE_OUTPUT": str(output),
            "GATE_MOCK_LSREGISTER": str(fixture / "mock-bin/lsregister"),
            "LC_ALL": "C", "LANG": "C",
        }
        args = ["/bin/bash", str(fixture / "invoke.sh")]
        if mode == "preview":
            args.append("--no-install")
        if explicit_out:
            args += ["--out", str(output)]
        if identity:
            args += ["--identity", identity]
        args += list(extra_args)
        result = subprocess.run(args, cwd=repo, env=env, text=True, capture_output=True, timeout=30)
        (root / "stdout.txt").write_text(result.stdout)
        (root / "stderr.txt").write_text(result.stderr)
        events_file = root / "events.jsonl"
        events = [json.loads(line) for line in events_file.read_text().splitlines()] if events_file.exists() else []
        observed = [event["command"] for event in events]
        errors = []
        if expected == 0 and result.returncode != 0:
            errors.append(f"expected success, got {result.returncode}")
        if expected != 0 and result.returncode == 0:
            errors.append("expected failure, got success")
        forbidden = set(observed) & {"ps", "osascript", "launchctl", "defaults", "tccutil", "xcrun", "xcodebuild", "service"}
        if forbidden:
            errors.append("forbidden operation requested: " + ", ".join(sorted(forbidden)))
        if mode == "preview":
            ui = set(observed) & {"open", "mdimport", "lsregister"}
            lifecycle = any(event["command"] == "swift" and event["args"][0] == "-" for event in events)
            preflight = any(event["command"] == "mock-event" and event["args"][0] == "preflight" for event in events)
            if ui or lifecycle or preflight:
                errors.append("preview invoked service/UI/lifecycle/preflight seam")
        if verify:
            try:
                verify(root, output, events, result)
            except AssertionError as error:
                errors.append(str(error) or "custom assertion failed")
        copied_hash = digest(repo / "tools/build-khuluma-app.sh")
        if copied_hash != tested_hash:
            errors.append("copied helper differs from instrumented template")
        if digest(repo / "tools/build-khuluma-app.source.sh") != source_hash:
            errors.append("retained original differs from hashed source")
        record = {"case": name, "passed": not errors, "exit_code": result.returncode,
                  "output_state": inspect_bundle(output), "events": len(events), "errors": errors,
                  "fixture": str(root), "tested_helper_sha256": copied_hash}
        cases.append(record)
        print(("PASS" if not errors else "FAIL") + " " + name + (": " + "; ".join(errors) if errors else ""), flush=True)

    def new_bundle(root, output, events, result):
        assert inspect_bundle(output) == "new", "new output was not published"
        data = plistlib.loads((output / "Contents/Info.plist").read_bytes())
        assert data["CFBundleIdentifier"] == "com.ricardo-nth.khuluma", "wrong bundle ID"
        assert data["CFBundleShortVersionString"] == "fixture-0.11.0", "wrong source version"
        assert data["CFBundleVersion"] == "4242", "wrong fixture build number"
        assert data["CFBundleIconFile"] == "Khuluma.icns", "app icon not declared"
        assert data["CFBundleIconName"] == "AppIcon", "adaptive icon name not declared"
        assert (output / "Contents/Resources/Khuluma.icns").read_bytes() == b"MOCK ICNS RESOURCE\n", "app icon missing or changed"
        assert (output / "Contents/Resources/Assets.car").read_bytes() == b"MOCK CAR RESOURCE\n", "adaptive icon catalog missing or changed"
        assert (output / "Contents/Resources/KhulumaMenuTemplate.pdf").read_bytes() == b"MOCK VECTOR PDF\n", "menu template missing or changed"
        signatures = [event for event in events if event["command"] == "codesign" and event["args"][0] == "--force"]
        assert len(signatures) == 1 and signatures[0]["args"][signatures[0]["args"].index("--sign") + 1] == HASH_A, "signing did not select exact hash"
        assert list((root / "tmp").glob("khuluma-app-build.*")), "build workspace was not retained"

    def rejected_before_build(root, output, events, result):
        assert not any(event["command"] == "swift" for event in events), "rejection happened after Swift seam"
        assert not output.exists() or output.is_symlink() or inspect_bundle(output) == "original", "rejected output changed"

    def original_retained(root, output, events, result):
        assert inspect_bundle(output) == "original", "original destination not retained/restored"

    def install_new(root, output, events, result):
        new_bundle(root, output, events, result)
        commands = [event["command"] for event in events]
        assert commands.count("lsregister") == 1 and commands.count("mdimport") == 1, "install did not use mocked registration/Spotlight seams"
        lifecycle = [event for event in events if event["command"] == "swift" and event["args"][0] == "-"]
        assert len(lifecycle) == 1, "install did not query the mocked supported lifecycle API"
        settings = json.loads((root / "settings.json").read_text())
        assert commands.count("open") == int(bool(settings.get("running"))), "unexpected app launch count"
        previous = [path / "previous.app" for path in output.parent.glob(".khuluma-app.*")]
        assert len(previous) == 1 and inspect_bundle(previous[0]) == "original", "verified previous app was not retained"

    def original_untouched_before_lifecycle(root, output, events, result):
        original_retained(root, output, events, result)
        assert not any(event["command"] in ("open", "lsregister", "mdimport") or event["command"] == "swift" and event["args"][0] == "-" for event in events), "pre-install failure invoked lifecycle or UI"

    def separate_legacy_retained(root, output, events, result):
        assert inspect_bundle(root / "home/Applications/Lowkey.app") == "original", "separate legacy app changed"
        assert not output.exists(), "competing new app published beside legacy app"
        assert not any(event["command"] in ("swift", "open", "lsregister", "mdimport") for event in events), "legacy admission failure reached build/lifecycle/UI"

    def restored(root, output, events, result):
        original_retained(root, output, events, result)
        transactions = list(output.parent.glob(".khuluma-app.*"))
        assert len(transactions) == 1, "missing recovery workspace"
        assert inspect_bundle(transactions[0] / "failed.app") == "new", "failed new app not retained"
        assert not (transactions[0] / "previous.app").exists(), "previous app not restored to destination"
        opened = [event for event in events if event["command"] == "open"]
        assert len(opened) == 1 and opened[0]["args"] == [str(output)], "previous running app was not the only relaunch"

    def build_race_retained(root, output, events, result):
        assert inspect_bundle(output) == "race", "unrelated raced output was overwritten"
        assert any((path / "candidate.app").exists() for path in output.parent.glob(".khuluma-app.*")), "candidate not retained after output race"

    def lifecycle_race_retained(root, output, events, result):
        assert inspect_bundle(output) == "race", "lifecycle race destination was overwritten"
        assert inspect_bundle(output.with_name("raced-original.app")) == "original", "raced original not preserved"

    def help_is_pure(root, output, events, result):
        assert not events, "help invoked a dependency/guard seam"
        assert not output.exists(), "help created an output"

    case("preview-help-with-obsolete-environment-is-pure", settings={"environment_failure": True}, extra_args=("--help",), verify=help_is_pure)
    case("preview-environment-guard-refused", settings={"environment_failure": True}, expected=1, verify=rejected_before_build)
    case("install-old-bundle-rejected", mode="install", existing="com.ricardo-nth.lowkey", expected=1, verify=rejected_before_build)
    case("install-old-executable-rejected", mode="install", existing="com.ricardo-nth.khuluma", existing_executable="Lowkey", expected=1, verify=rejected_before_build)
    case("preview-old-daily-path-rejected", output_kind="legacy-daily", expected=1, verify=rejected_before_build)
    case("preview-symlink-ancestor-rejected", output_kind="parent-symlink", expected=1, verify=rejected_before_build)
    case("preview-selfsigned-exact-name", verify=new_bundle)
    case("preview-selfsigned-exact-hash", identity=HASH_A.lower(), verify=new_bundle)
    case("preview-duplicate-same-certificate", settings={"identities": basic_listing + f'\n 2) {HASH_A} "{NAME}"'}, verify=new_bundle)
    case("preview-missing-identity", settings={"identities": "0 identities found"}, expected=1, verify=rejected_before_build)
    case("preview-ambiguous-identity", settings={"identities": basic_listing + f'\n 2) {HASH_B} "{NAME}"'}, expected=1, verify=rejected_before_build)
    case("preview-old-name-rejected", identity=OLD_NAME, expected=1, verify=rejected_before_build)
    case("preview-old-hash-rejected", identity=HASH_OLD, settings={"identities": f' 1) {HASH_OLD} "{OLD_NAME}"'}, expected=1, verify=rejected_before_build)
    case("preview-ad-hoc-rejected", identity="-", expected=1, verify=rejected_before_build)
    case("preview-needs-explicit-output", explicit_out=False, expected=1, verify=rejected_before_build)
    case("preview-daily-path-rejected", output_kind="daily", expected=1, verify=rejected_before_build)
    case("preview-existing-output-rejected", existing="com.ricardo-nth.khuluma", expected=1, verify=rejected_before_build)
    case("preview-symlink-output-rejected", output_kind="symlink", expected=1, verify=rejected_before_build)
    case("preview-sign-failure", settings={"sign_failure": True}, expected=1)
    case("preview-stage-verification-failure", settings={"stage_verify_failure": True}, expected=1)
    case("preview-legacy-authority-rejected", settings={"reported_authority": OLD_NAME}, expected=1)
    case("preview-copy-failure-retained", settings={"copy_failure": True}, expected=1)
    case("preview-candidate-verification-failure", settings={"candidate_verify_failure": True}, expected=1)
    case("preview-output-race-retained", settings={"race_on_build": True}, expected=1, verify=build_race_retained)
    case("install-existing-idle", mode="install", existing="com.ricardo-nth.khuluma", verify=install_new)
    case("install-existing-running", mode="install", existing="com.ricardo-nth.khuluma", settings={"running": True}, verify=install_new)
    case("install-separate-legacy-app-refused", mode="install", separate_legacy=True, expected=1, verify=separate_legacy_retained)
    case("install-unrelated-bundle-rejected", mode="install", existing="org.unrelated.application", expected=1, verify=original_retained)
    case("install-preflight-rejected", mode="install", settings={"preflight_failure": True}, expected=1, verify=rejected_before_build)
    case("install-sign-failure-keeps-original", mode="install", existing="com.ricardo-nth.khuluma", settings={"sign_failure": True}, expected=1, verify=original_untouched_before_lifecycle)
    case("install-stage-verify-failure-keeps-original", mode="install", existing="com.ricardo-nth.khuluma", settings={"stage_verify_failure": True}, expected=1, verify=original_untouched_before_lifecycle)
    case("install-copy-failure-keeps-original", mode="install", existing="com.ricardo-nth.khuluma", settings={"copy_failure": True}, expected=1, verify=original_untouched_before_lifecycle)
    case("install-candidate-verify-failure-keeps-original", mode="install", existing="com.ricardo-nth.khuluma", settings={"candidate_verify_failure": True}, expected=1, verify=original_untouched_before_lifecycle)
    case("install-output-verify-failure-restores-running", mode="install", existing="com.ricardo-nth.khuluma", settings={"output_verify_failure": True, "running": True}, expected=1, verify=restored)
    case("install-lifecycle-refusal-keeps-original", mode="install", existing="com.ricardo-nth.khuluma", settings={"lifecycle_failure": True}, expected=1, verify=original_retained)
    case("install-lifecycle-race-retains-unrelated", mode="install", existing="com.ricardo-nth.khuluma", settings={"lifecycle_race": True}, expected=1, verify=lifecycle_race_retained)
    current_source_hash = digest(source_script)
    report = {"helper_source": str(source_script), "helper_sha256": source_hash,
              "tested_helper_sha256": tested_hash,
              "instrumentation": {"from": instrumentation_from, "to": instrumentation_to, "replacements": 1},
              "source_unchanged_during_gate": current_source_hash == source_hash,
              "current_source_sha256": current_source_hash, "run": str(run),
              "mocked_dependencies": names + ["identity.sh", "migration.sh", "absolute lsregister pathname assignment"],
              "real_operations": ["private fixture file reads/writes/copies", "standard shell utilities", "embedded Python checks", "platform exclusive rename in private fixture directories"],
              "omissions": ["actual cryptographic signing/trust", "actual Swift compilation", "AppKit termination behavior", "actual Launch Services/Spotlight/UI", "preflight implementation"],
              "cases": cases, "passed": sum(case["passed"] for case in cases), "total": len(cases)}
    (run / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# All-mocked app build-helper gate", "", f"Result: {report['passed']}/{report['total']} cases passed.", "",
             f"Source SHA-256: `{source_hash}`", f"Source unchanged during run: `{report['source_unchanged_during_gate']}`", "",
             f"Tested private-copy SHA-256: `{tested_hash}`", "",
             "The original source is retained byte-for-byte beside each tested private copy. The only instrumentation replaces the absolute LSREGISTER pathname assignment with the owned stub pathname through `GATE_MOCK_LSREGISTER`; the literal transformation is recorded in results.json. Dependency scripts are fixture seams; all build, signing, keychain, lifecycle, service and UI operations were mocked. No real product command was run. Atomic exclusive renames used the platform syscall only within owned private fixtures. All generated artifacts remain inspectable.", "",
             "| Case | Result | Exit |", "| --- | --- | --- |"]
    lines += [f"| {entry['case']} | {'PASS' if entry['passed'] else 'FAIL'} | {entry['exit_code']} |" for entry in cases]
    lines += ["", "Coverage limits: actual cryptographic signing/trust, Swift compilation, AppKit process termination, service/UI behavior and preflight implementation were not exercised. These tests establish helper selection/guard/transaction control flow under mocked dependencies.", "",
              f"Full events, stdout/stderr and retained fixture trees: `{run}`."]
    (run / "report.md").write_text("\n".join(lines) + "\n")
    print(f"\n{report['passed']}/{report['total']} passed; evidence: {run / 'report.md'}")
    return 0 if report["passed"] == report["total"] and report["source_unchanged_during_gate"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
