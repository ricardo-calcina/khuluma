#!/usr/bin/env python3
"""Selection logic of tools/test_affected.py: path lists in, plan out. No swift."""
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

sys.dont_write_bytecode = True  # no tools/__pycache__ in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import test_affected as ta  # noqa: E402

CORE = "native/Sources/KhulumaCore/"
CT = "native/Tests/KhulumaCoreTests/"
DT = "native/Tests/KhulumaDaemonKitTests/"
FILES = {
    CORE + "Stats/Leaf.swift": "public struct Leaf {\n  enum Failure {}\n}\n",
    CORE + "Stats/Mid.swift": "struct Mid {\n  let leaf: Leaf // Unused\n}\npublic func midHelper() {}\n",
    CORE + "Stats/Top.swift": "final class Top { var m: Mid? }\n",
    CORE + "Other/Lonely.swift": "struct Lonely {}\n",
    CORE + "Other/Generic.swift": "struct Generic { enum Failure {} }\n",
    CORE + "Other/Ext.swift": "extension String { var shout: String { self } }\n",
    "native/Sources/Khuluma/Stats/StatsSnapshot.swift": "enum StatsSnapshot { static func write() { _ = Panel() } }\n",
    "native/Sources/Khuluma/Panel.swift": "struct Panel { let t: Top? = nil }\n",
    "native/Sources/KhulumaDaemonKit/Proto.swift": "public struct Proto {}\n",
    CT + "LeafTests.swift": "import Testing\nstruct LeafTests {\n  @Test func a() { _ = Leaf() }\n}\n",
    CT + "TopTests.swift": "import Testing\n@Suite struct TopTests {\n  @Test func b() { _ = Top() }\n}\nextension MoreTopTests {\n  @Test func c() {}\n}\n",
    CT + "DaemonUse.swift": "import Testing\n@testable import KhulumaDaemonKit\nstruct DaemonUseTests { @Test func d() {} }\n",
    CT + "Fixture.swift": "struct Fixture { static func make() -> Mid { fatalError() } }\n",
    CT + "FixUser.swift": "import Testing\nstruct FixUserTests {\n  @Test func e() { _ = Fixture.make() }\n}\n",
    CT + "Orphan.swift": "struct OrphanHelper {}\n",
    CT + "Free.swift": "import Testing\n@Test func freeStanding() {}\n",
    DT + "ProtoTests.swift": "import Testing\nstruct ProtoTests { @Test func p() {} }\n",
}


def plan(*paths):
    return ta.make_plan(list(paths), ta.Repo(files=FILES))


class Selection(unittest.TestCase):
    def test_docs_run_nothing(self):
        p = plan("README.md", "docs/x.md", "native/DESIGN.md", "CHANGELOG.md")
        self.assertFalse(p.has_tests())
        self.assertEqual(ta.steps_for(p, ta.Repo(files=FILES), 2), [])

    def test_app_ui_builds_and_snapshots_only(self):
        p = plan("native/Sources/Khuluma/Panel.swift")
        self.assertEqual(p.products, {"Khuluma"})
        self.assertTrue(p.snapshot)
        self.assertFalse(p.has_tests())
        labels = [s[0] for s in ta.steps_for(p, ta.Repo(files=FILES), 2)]
        self.assertEqual(labels, ["build Khuluma", "snapshot"])

    def test_core_reverse_closure(self):
        p = plan(CORE + "Stats/Leaf.swift")
        self.assertEqual(p.test_files["KhulumaCoreTests"],
                         {CT + "LeafTests.swift", CT + "TopTests.swift", CT + "FixUser.swift"})  # Fixture → its user
        self.assertTrue(p.snapshot)  # Panel uses Top, which uses Mid -> Leaf
        self.assertEqual(p.products, {"Khuluma", "khuluma-cli"})

    def test_nested_names_do_not_propagate(self):
        p = plan(CORE + "Other/Generic.swift")
        # Leaf also nests a Failure; that must not pull Leaf's users in.
        self.assertEqual(p.full_targets, {"KhulumaCoreTests"})  # no test references Generic -> wider set
        self.assertIn("unmapped", p.reasons[0][2])

    def test_core_without_tests_widens(self):
        p = plan(CORE + "Other/Lonely.swift")
        self.assertEqual(p.full_targets, {"KhulumaCoreTests"})
        self.assertFalse(p.snapshot)

    def test_stdlib_extension_widens(self):
        self.assertEqual(plan(CORE + "Other/Ext.swift").full_targets, {"KhulumaCoreTests"})

    def test_deleted_unreadable_core_file_widens(self):
        self.assertEqual(plan(CORE + "Gone.swift").full_targets, {"KhulumaCoreTests"})

    def test_daemonkit(self):
        p = plan("native/Sources/KhulumaDaemonKit/Proto.swift")
        self.assertIn("KhulumaDaemonKitTests", p.full_targets)
        self.assertIn(CT + "DaemonUse.swift", p.test_files["KhulumaCoreTests"])
        self.assertIn("BundledDaemonIntegrationTests", p.suites["KhulumaCoreTests"])
        self.assertEqual(p.products, {"khulumad", "khuluma-cli"})

    def test_khulumad_includes_spawning_suite(self):
        p = plan("native/Sources/khulumad/main.swift")
        self.assertEqual(p.full_targets, {"KhulumaDaemonKitTests"})
        self.assertEqual(p.suites["KhulumaCoreTests"], {"BundledDaemonIntegrationTests"})

    def test_test_file_and_support_file(self):
        self.assertEqual(plan(CT + "LeafTests.swift").test_files["KhulumaCoreTests"], {CT + "LeafTests.swift"})
        self.assertEqual(plan(CT + "Fixture.swift").test_files["KhulumaCoreTests"], {CT + "FixUser.swift"})
        self.assertEqual(plan(CT + "Orphan.swift").full_targets, {"KhulumaCoreTests"})

    def test_package_and_unmapped_go_full(self):
        for path in ("native/Package.swift", ".github/workflows/swift.yml", "native/weird.txt", "foo.txt"):
            p = plan(path)
            self.assertTrue(p.swift_full, path)
            self.assertEqual(p.full_targets, set(ta.TARGETS))
            self.assertIsNone(ta.build_filter(p, ta.Repo(files=FILES)))
        self.assertIn(ta.CI_SH, plan("foo.txt").commands)

    def test_full_drops_subsets(self):
        p = plan(CT + "LeafTests.swift", "native/Package.swift")
        self.assertEqual(p.test_files["KhulumaCoreTests"], set())

    def test_cleanup_inputs(self):
        p = plan("bin/khuluma-lib.sh")
        self.assertEqual(p.commands, [ta.GEN_CHECK, ta.CI_SH])
        self.assertIn(CT + "CleanupParityTests.swift", p.test_files["KhulumaCoreTests"])
        p = plan("tests/fixtures/cleanup/expected.json")
        self.assertIn(ta.GEN_CHECK, p.commands)
        self.assertFalse(p.swift_full)
        p = plan("tests/fixtures/unknown/x.json")  # no Swift test names it, no script consumes it
        self.assertFalse(p.swift_full)
        self.assertEqual(p.commands, [ta.CI_SH])

    def test_scripts(self):
        self.assertEqual(plan("tests/test_cli.sh").commands, ["bash -n tests/test_cli.sh", "./tests/test_cli.sh"])
        self.assertEqual(plan("tests/test_vocabulary.py").commands, ["python3 tests/test_vocabulary.py"])
        self.assertIn("python3 tests/test_app_build_helpers.py", plan("tools/build-khuluma-app.sh").commands)
        self.assertEqual(plan("tools/test_affected.py").commands, [ta.SELFTEST])
        self.assertFalse(plan(".github/workflows/icons.yml").has_tests())
        self.assertEqual(plan("assets/sounds/khuluma/start.wav").suites["KhulumaCoreTests"],
                         {"SoundsAndPermissionsTests"})

    def test_union_dedupes_steps(self):
        p = plan(CORE + "Stats/Leaf.swift", "native/Sources/KhulumaDaemonKit/Proto.swift",
                 "native/Sources/Khuluma/Panel.swift")
        labels = [s[0] for s in ta.steps_for(p, ta.Repo(files=FILES), 2)]
        self.assertEqual(labels, ["build-tests", "swift test", "snapshot"])

    def test_filter_ids(self):
        repo = ta.Repo(files=FILES)
        self.assertEqual(ta.test_ids(FILES[CT + "TopTests.swift"]), ({"TopTests", "MoreTopTests"}, set(), True))
        self.assertEqual(ta.test_ids(FILES[CT + "Free.swift"]), (set(), {"freeStanding"}, True))
        p = plan(CT + "TopTests.swift", CT + "Free.swift", "native/Sources/khulumad/main.swift")
        flt = ta.build_filter(p, repo)
        import re

        def hit(name):
            return any(re.match(f, name) for f in flt)
        for ok in ("KhulumaCoreTests.TopTests/b()", "KhulumaCoreTests.MoreTopTests/c()",
                   "KhulumaCoreTests.freeStanding()", "KhulumaDaemonKitTests.ProtoTests/p()",
                   "KhulumaCoreTests.BundledDaemonIntegrationTests/x()"):
            self.assertTrue(hit(ok), ok)
        for no in ("KhulumaCoreTests.TopTestsExtra/b()", "KhulumaCoreTests.LeafTests/a()"):
            self.assertFalse(hit(no), no)

class ReviewFixes(unittest.TestCase):
    def files(self, **more):
        f = dict(FILES)
        f.update(more)
        return ta.Repo(files=f)

    # 1. top level by brace depth
    def test_indented_and_if_guarded_decls_are_top_level(self):
        src = 'import Foundation\n#if os(macOS)\n  public enum ModelRepair {\n    case a\n  }\n#endif\n'
        self.assertEqual(ta.declared(src)[0], {"ModelRepair"})
        repo = self.files(**{CORE + "Repair.swift": src,
                             CT + "ModelRepairTests.swift": "import Testing\nstruct ModelRepairTests {\n  @Test func r() { _ = ModelRepair.a }\n}\n"})
        p = ta.make_plan([CORE + "Repair.swift"], repo)
        self.assertIn(CT + "ModelRepairTests.swift", p.test_files["KhulumaCoreTests"])

    def test_braces_in_strings_and_comments_dont_count(self):
        src = ('struct A {\n  let s = "}"\n  let r = #"a "}" b"#\n  let m = """\n  }}}\n  """\n'
               '  /* } /* nested } */ */\n  // }\n}\nstruct B {}\n')
        self.assertEqual(ta.declared(src), ({"A", "B"}, False, True))

    def test_unbalanced_file_widens(self):
        repo = self.files(**{CORE + "Broken.swift": "struct Broken {\n"})
        p = ta.make_plan([CORE + "Broken.swift"], repo)
        self.assertEqual(p.full_targets, {"KhulumaCoreTests"})
        self.assertIn("can't parse", p.reasons[0][2])
        repo = self.files(**{CT + "BrokenTests.swift": "struct BrokenTests { @Test func x() {}\n"})
        self.assertEqual(ta.make_plan([CT + "BrokenTests.swift"], repo).full_targets, {"KhulumaCoreTests"})

    # 2nd review, 1: snapshot cleanup only removes what the run made; 2: sanitized env
    def sandbox(self, d):
        """Point every path the snapshot code touches into temp dir d; mock defaults."""
        d = Path(d)
        build = d / "native" / ".build"
        (build / "debug").mkdir(parents=True)
        prefs = d / "home" / "Library" / "Preferences"
        prefs.mkdir(parents=True)
        defaults_calls = []

        def fake_subprocess_run(argv, **kw):
            defaults_calls.append(argv)
            return subprocess.CompletedProcess(argv, 0)
        patches = [mock.patch.multiple(ta, NATIVE=d / "native", SNAPSHOT_DIR=build / "khuluma-snapshots",
                                       SNAPSHOT_PREV=build / "khuluma-snapshots.prev"),
                   mock.patch.object(ta, "prefs_dir", return_value=prefs),
                   mock.patch.object(ta.subprocess, "run", side_effect=fake_subprocess_run)]
        return build, prefs, defaults_calls, patches

    def test_snapshot_cleans_only_its_own_run(self):
        with tempfile.TemporaryDirectory() as d:
            build, prefs, calls, patches = self.sandbox(d)
            (build / "khuluma-snapshots").mkdir()
            (build / "khuluma-snapshots" / "old.png").write_text("x")
            (build / "khuluma-snapshot-run.keepme").mkdir()  # someone else's run dir
            (build / "khuluma-snapshot-run").mkdir()          # legacy fixed name: removed once
            (prefs / f"{ta.LEGACY_SUITE}.plist").write_text("{}")
            (prefs / "com.other.app.plist").write_text("{}")
            seen = {}

            def fake_run(argv, timeout, env):
                seen.update(argv=argv, timeout=timeout, env=env)
                Path(env["KHULUMA_SUPPORT_DIR"]).parent.joinpath("marker").write_text("m")
                (prefs / f"{env['KHULUMA_DEFAULTS_SUITE']}.plist").write_text("{}")
                Path(argv[-1], "new.png").write_text("y")
                return 0
            for p in patches:
                p.start()
            try:
                with mock.patch.object(ta, "run", side_effect=fake_run):
                    self.assertEqual(ta.run_snapshot(), 0)
            finally:
                for p in patches:
                    p.stop()
            env = seen["env"]
            run_dir = Path(env["KHULUMA_SUPPORT_DIR"]).parent
            self.assertTrue(run_dir.name.startswith("khuluma-snapshot-run."))
            self.assertEqual(run_dir.parent, build)
            self.assertFalse(run_dir.exists())
            suite = env["KHULUMA_DEFAULTS_SUITE"]
            self.assertRegex(suite, r"^com\.ricardo-nth\.khuluma\.test-affected-snapshot\.[0-9a-f]{8}$")
            self.assertIn(["defaults", "delete", suite], calls)
            self.assertIn(["defaults", "delete", ta.LEGACY_SUITE], calls)
            self.assertEqual(sorted(p.name for p in prefs.iterdir()), ["com.other.app.plist"])
            self.assertTrue((build / "khuluma-snapshot-run.keepme").exists())
            self.assertFalse((build / "khuluma-snapshot-run").exists())
            self.assertTrue((build / "khuluma-snapshots.prev" / "old.png").exists())
            self.assertEqual([p.name for p in (build / "khuluma-snapshots").iterdir()], ["new.png"])
            self.assertEqual(seen["timeout"], ta.SNAPSHOT_TIMEOUT)

    def test_snapshot_refuses_symlinked_folders(self):
        with tempfile.TemporaryDirectory() as d:
            build, prefs, calls, patches = self.sandbox(d)
            elsewhere = Path(d, "elsewhere")
            elsewhere.mkdir()
            (elsewhere / "precious").write_text("keep")
            (build / "khuluma-snapshots.prev").symlink_to(elsewhere)
            (build / "khuluma-snapshots").mkdir()
            for p in patches:
                p.start()
            try:
                with mock.patch.object(ta, "run") as r:
                    self.assertEqual(ta.run_snapshot(), 1)
                    r.assert_not_called()
            finally:
                for p in patches:
                    p.stop()
            self.assertTrue((elsewhere / "precious").exists())
            self.assertEqual(calls, [])

    def test_snapshot_env_is_sanitized(self):
        with tempfile.TemporaryDirectory() as d:
            run_dir = Path(d)
            inherited = {"PATH": "/usr/bin", "HOME": "/Users/x", "KHULUMA_CONFIG_DIR": "/Users/x/.config/khuluma",
                         "KHULUMA_USAGE_SUMMARY_FILE": "/Users/x/.config/khuluma/usage.json",
                         "KHULUMA_DAEMON_BINARY": "/x", "XDG_CONFIG_HOME": "/Users/x/.config",
                         "XDG_CACHE_HOME": "/Users/x/.cache", "ELEVENLABS_API_KEY": "secret", "ZDOTDIR": "/Users/x"}
            env = ta.snapshot_env(run_dir, "com.ricardo-nth.khuluma.t.1", base=inherited)
            self.assertEqual(env["PATH"], "/usr/bin")
            for k in ("KHULUMA_DAEMON_BINARY", "XDG_CACHE_HOME", "ELEVENLABS_API_KEY"):
                self.assertNotIn(k, env)
            for k in ("KHULUMA_SUPPORT_DIR", "KHULUMA_LOG_DIR", "KHULUMA_CONFIG_DIR", "KHULUMA_USAGE_SUMMARY_FILE",
                      "KHULUMA_DEFAULT_MODEL_DIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "SOUNDS_DIR", "ZDOTDIR"):
                self.assertTrue(env[k].startswith(str(run_dir) + "/"), k)
            for sub in ("support", "logs"):
                self.assertEqual(os.stat(run_dir / sub).st_mode & 0o777, 0o700)

    # 3. git failures
    def test_git_failure_stops_with_error(self):
        with mock.patch.object(ta, "git", side_effect=ta.GitError("no origin/main")):
            self.assertEqual(ta.main(["--plan"]), 2)
        r = subprocess.run([sys.executable, str(ta.ROOT / "tools/test_affected.py"), "--plan",
                            "--base", "no-such-ref-xyz"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("--paths", r.stderr)

    # 2nd review, 3: interpolation and base-version names
    def test_interpolation_references_count(self):
        self.assertIn("A", ta.words('struct B { let s = "x \\(A()) y" }'))
        self.assertIn("A", ta.words('let r = #"x \\#(A(f(1))) \\(Fake)"#'))
        self.assertNotIn("Fake", ta.words('let r = #"x \\(Fake)"#'))  # not an interpolation in a raw string
        self.assertIn("C", ta.words('let m = """\n  \\(g("\\(C())"))\n  """'))
        repo = self.files(**{CORE + "Stats/Uses.swift": 'struct Uses { let s = "\\(Leaf())" }\n',
                             CT + "UsesTests.swift": "import Testing\nstruct UsesTests { @Test func u() { _ = Uses() } }\n"})
        self.assertIn(CT + "UsesTests.swift", ta.make_plan([CORE + "Stats/Leaf.swift"], repo).test_files["KhulumaCoreTests"])

    def test_removed_declarations_still_reach_old_users(self):
        files = dict(FILES)
        files[CORE + "Stats/Leaf.swift"] = "public struct Leaf2 {}\n"  # Leaf renamed
        repo = ta.Repo(files=files, base_files={CORE + "Stats/Leaf.swift": FILES[CORE + "Stats/Leaf.swift"]})
        p = ta.make_plan([CORE + "Stats/Leaf.swift"], repo)
        self.assertIn(CT + "LeafTests.swift", p.test_files["KhulumaCoreTests"])
        self.assertIn("Leaf", p.reasons[0][2])

    # 4. test file that also declares helpers
    def test_test_file_with_helpers_runs_their_users(self):
        repo = self.files(**{
            CT + "VocabularyParityTests.swift": "import Testing\nstruct VocabularyParityTests {\n  @Test func v() {}\n}\n"
                                                "enum CleanupParity {\n  static let repoRoot = 1\n}\n",
            CT + "UsageParityTests.swift": "import Testing\nstruct UsageParityTests {\n  @Test func u() { _ = CleanupParity.repoRoot }\n}\n"})
        p = ta.make_plan([CT + "VocabularyParityTests.swift"], repo)
        self.assertEqual(p.test_files["KhulumaCoreTests"],
                         {CT + "VocabularyParityTests.swift", CT + "UsageParityTests.swift"})

    # 5. nested suites
    def test_nested_suites_are_found_and_checked(self):
        src = ("import Testing\nstruct Outer {\n  @Test func a() {}\n  struct Nested {\n"
               "    @Test func hidden() {}\n  }\n}\nstruct OnlyNestedHolder {\n  struct Inner {\n    @Test func x() {}\n  }\n}\n")
        self.assertEqual(ta.test_ids(src)[0], {"Outer", "Outer.Nested", "OnlyNestedHolder.Inner"})
        repo = self.files(**{CT + "NestTests.swift": src})
        p = ta.make_plan([CT + "NestTests.swift"], repo)
        flt = ta.build_filter(p, repo)
        import re
        for name in ("KhulumaCoreTests.Outer/Nested/hidden()", "KhulumaCoreTests.Outer.Nested/hidden()",
                     "KhulumaCoreTests.OnlyNestedHolder/Inner/x()"):
            self.assertTrue(any(re.match(f, name) for f in flt), name)
        listed = ["KhulumaCoreTests.Outer/a()", "KhulumaCoreTests.OnlyNestedHolder/Inner/x()"]
        missing = ta.missing_suites(p, repo, listed)
        self.assertEqual([m[2] for m in missing], ["suite Outer.Nested not listed"])
        listed.append("KhulumaCoreTests.Outer/Nested/hidden()")
        self.assertEqual(ta.missing_suites(p, repo, listed), [])

    # 6. shell/tool consumers
    def test_shell_consumers(self):
        repo = self.files(**{
            "tests/test_regression.sh": "bash tools/khuluma-report.sh\n",
            "tests/test_flow_parity.sh": "source tests/fixtures/usage_writer_v1.sh\n",
            "tests/ci.sh": "tools/khuluma-report.sh tools/other.sh\n",
            "tests/gen-cleanup-fixtures.sh": "tools/khuluma-report.sh\n"})
        p = ta.make_plan(["tools/khuluma-report.sh"], repo)
        self.assertIn("./tests/test_regression.sh", p.commands)
        self.assertNotIn(ta.CI_SH, p.commands)
        self.assertFalse(any("gen-cleanup" in c for c in p.commands))  # generators rewrite fixtures
        p = ta.make_plan(["tests/fixtures/usage_writer_v1.sh"], repo)
        self.assertEqual(p.commands, ["./tests/test_flow_parity.sh"])
        self.assertFalse(p.has_tests())
        p = ta.make_plan(["tools/lonely.sh"], repo)
        self.assertIn(ta.CI_SH, p.commands)

    # 7. process-group timeout
    def test_timeout_kills_the_group(self):
        with tempfile.TemporaryDirectory() as d:
            pidfile = Path(d, "child")
            script = f"sleep 60 & echo $! > {pidfile}; wait"
            t0 = time.monotonic()
            rc = ta.run(["bash", "-c", script], timeout=1, quiet=True)
            self.assertEqual(rc, ta.TIMED_OUT)
            self.assertLess(time.monotonic() - t0, 15)
            child = int(pidfile.read_text())
            time.sleep(0.2)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)

    def test_timeout_kills_term_ignoring_children(self):
        with tempfile.TemporaryDirectory() as d:
            pidfile = Path(d, "child")
            # The child ignores TERM; the leader exits on TERM, so only the
            # final group SIGKILL can stop the child.
            script = (f"bash -c 'trap \"\" TERM; echo $$ > {pidfile}; while :; do sleep 0.2; done' & "
                      "wait")
            rc = ta.run(["bash", "-c", script], timeout=1, quiet=True)
            self.assertEqual(rc, ta.TIMED_OUT)
            child = int(pidfile.read_text())
            for _ in range(20):
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.kill(child, signal.SIGKILL)
                self.fail("TERM-ignoring child survived")

    def test_unstartable_command_fails(self):
        self.assertEqual(ta.run(["/no/such/binary"], quiet=True), ta.NOT_STARTED)

    # 8. snapshot trigger
    def test_snapshot_only_for_ui_and_core_stats(self):
        self.assertTrue(plan("native/Sources/Khuluma/Panel.swift").snapshot)
        self.assertTrue(plan(CORE + "Stats/Leaf.swift").snapshot)
        repo = self.files(**{CORE + "Transcription/T.swift": "struct T {}\n",
                             CT + "TTests.swift": "import Testing\nstruct TTests { @Test func t() { _ = T() } }\n"})
        self.assertFalse(ta.make_plan([CORE + "Transcription/T.swift"], repo).snapshot)
        self.assertFalse(plan("native/Package.swift").snapshot)

    # 9. help text
    def test_every_flag_has_help(self):
        out = subprocess.run([sys.executable, str(ta.ROOT / "tools/test_affected.py"), "--help"],
                             capture_output=True, text=True).stdout
        for flag in ("--base", "--paths", "--plan", "--full", "--snapshot", "--no-snapshot", "--jobs"):
            line = next(l for l in out.splitlines() if l.strip().startswith(flag))
            rest = out.split(line, 1)[1].splitlines()[0] if line.strip().endswith(("REF", "...", "N")) else line
            self.assertTrue(len(line.split()) > 2 or rest.strip(), flag)


if __name__ == "__main__":
    unittest.main(verbosity=1)
