#!/usr/bin/env python3
"""Run only the checks a change affects (local default for agents).

CI (.github/workflows/swift.yml) still runs the full Swift suite on push.
Fail safe: anything unmapped or uncertain widens the set, never empties it.

    tools/test-affected.sh                 # vs origin/main merge-base + working tree
    tools/test-affected.sh --paths a b     # exactly these paths (shared checkout)
    tools/test-affected.sh --plan          # print the plan, run nothing

Every step runs in its own process group at low priority (nice -n 10,
taskpolicy -c utility) with a hard timeout; on timeout the whole group is
killed (TERM, then KILL after 10 s) and the step fails.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
CORE_SRC = "native/Sources/KhulumaCore/"
CORE_STATS = "native/Sources/KhulumaCore/Stats/"
APP_SRC = "native/Sources/Khuluma/"
TEST_DIR = "native/Tests/"
CORE_T = "KhulumaCoreTests"
DK_T = "KhulumaDaemonKitTests"
TARGETS = (CORE_T, DK_T)
PRODUCTS = ("Khuluma", "khulumad", "khuluma-cli")
SNAPSHOT_DIR = NATIVE / ".build" / "khuluma-snapshots"
SNAPSHOT_PREV = NATIVE / ".build" / "khuluma-snapshots.prev"
PLUGIN_DIR = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
STEP_TIMEOUT = 1200
SNAPSHOT_TIMEOUT = 300
GEN_CHECK = "tests/gen-cleanup-fixtures.sh --check"
CI_SH = "./tests/ci.sh"
SELFTEST = "python3 tests/test_test_affected.py"

# Cases derivation can't see. glob -> {"suites": {target: [suite types]},
# "files": {target: [test files]}, "commands": [...], "products": [...]}.
OVERRIDES: dict[str, dict] = {
    # BundledDaemonIntegrationTests spawns the built khulumad next to the
    # test bundle, so daemon code reaches it without any name reference.
    "native/Sources/khulumad/**": {"suites": {CORE_T: ["BundledDaemonIntegrationTests"]}},
    "native/Sources/KhulumaDaemonKit/**": {"suites": {CORE_T: ["BundledDaemonIntegrationTests"]}},
    # khuluma-cli's main.swift is glue over FileTranscriber/FileTranscribeCommand.
    "native/Sources/khuluma-cli/**": {"files": {CORE_T: ["native/Tests/KhulumaCoreTests/FileTranscriptionTests.swift"]}},
    # SoundsAndPermissionsTests lists assets/sounds/khuluma by #filePath.
    "assets/sounds/**": {"suites": {CORE_T: ["SoundsAndPermissionsTests"]}},
    # Repo files read by #filePath from the Swift tests.
    "tests/fixtures/cleanup/**": {"files": {CORE_T: ["native/Tests/KhulumaCoreTests/CleanupParityTests.swift",
                                                     "native/Tests/KhulumaCoreTests/SettingsTests.swift"]},
                                  "commands": [GEN_CHECK]},
    "tests/fixtures/settings/**": {"files": {CORE_T: ["native/Tests/KhulumaCoreTests/SettingsTests.swift"]}},
    "tests/fixtures/vocabulary-parity/**": {"files": {CORE_T: ["native/Tests/KhulumaCoreTests/VocabularyParityTests.swift"]}},
    "tests/fixtures/usage-parity/**": {"files": {CORE_T: ["native/Tests/KhulumaCoreTests/UsageParityTests.swift"]}},
}

PARITY_FILES = [f"native/Tests/KhulumaCoreTests/{n}.swift"
                for n in ("CleanupParityTests", "VocabularyParityTests", "UsageParityTests", "SettingsTests")]

# Extending these says nothing about which Khuluma code uses the new members.
STDLIB = {"String", "Substring", "Character", "Array", "Dictionary", "Set", "Optional", "Int", "Double",
          "Float", "Bool", "Data", "URL", "Date", "TimeInterval", "Collection", "Sequence", "FileManager",
          "ProcessInfo", "Bundle", "UserDefaults", "Process", "FileHandle", "Result", "Error", "Comparable",
          "Equatable", "Hashable", "Codable", "CGFloat", "NSString", "JSONDecoder", "JSONEncoder"}

DECL_RE = re.compile(
    r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*"
    r"((?:(?:public|internal|package|private|fileprivate|final|open|indirect|nonisolated|static|"
    r"nonisolated\(unsafe\))\s+)*)"
    r"(struct|class|enum|protocol|actor|typealias|extension|func|let|var)\s+([A-Za-z_][\w.]*)")
TYPE_KINDS = ("struct", "class", "enum", "actor", "extension")
TEST_RE = re.compile(r"@Test\b")
SUITE_RE = re.compile(r"@Suite\b")


@dataclass
class Plan:
    swift_full: bool = False
    full_targets: set = field(default_factory=set)
    test_files: dict = field(default_factory=lambda: {t: set() for t in TARGETS})
    suites: dict = field(default_factory=lambda: {t: set() for t in TARGETS})
    products: set = field(default_factory=set)
    snapshot: bool = False
    commands: list = field(default_factory=list)
    reasons: list = field(default_factory=list)  # (path, category, reason)

    def cmd(self, c: str) -> None:
        if c not in self.commands:
            self.commands.append(c)

    def has_tests(self) -> bool:
        return self.swift_full or bool(self.full_targets) or any(self.test_files.values()) or any(self.suites.values())


class GitError(Exception):
    pass


# ---------- source reading ----------

class Repo:
    """File access; tests swap in a dict of path -> text."""

    def __init__(self, root: Path = ROOT, base: str | None = None, files: dict | None = None,
                 base_files: dict | None = None):
        self.root, self.base, self.files, self.base_files = root, base, files, base_files

    def read_base(self, path: str) -> str | None:
        """The file as it was at the base (merge-base, --base, or HEAD with --paths)."""
        if self.files is not None:
            return (self.base_files or {}).get(path)
        r = subprocess.run(["git", "-C", str(self.root), "show", f"{self.base or 'HEAD'}:{path}"],
                           capture_output=True, text=True)
        return r.stdout if r.returncode == 0 else None

    def own_names(self, path: str) -> tuple[set[str], bool, bool]:
        """declared() of the current file, plus names its base version declared,
        so removed or renamed declarations still reach their old users."""
        cur = self.read(path)
        names, stdlib, ok = declared(cur or "")
        old = self.read_base(path)
        if old is not None and old != cur:
            n2, s2, ok2 = declared(old)
            names, stdlib, ok = names | n2, stdlib or s2, ok and ok2
        return names, stdlib, ok

    def list(self, prefix: str, suffixes=(".swift",)) -> list[str]:
        if self.files is not None:
            return sorted(p for p in self.files if p.startswith(prefix) and p.endswith(suffixes))
        d = self.root / prefix
        if not d.is_dir():
            return []
        return sorted(str(p.relative_to(self.root)) for p in d.rglob("*") if p.is_file() and p.name.endswith(suffixes))

    def glob(self, pattern: str) -> list[str]:
        if self.files is not None:
            return sorted(p for p in self.files if fnmatch.fnmatch(p, pattern) and "/" not in p[len("tests/"):])
        return sorted(str(p.relative_to(self.root)) for p in self.root.glob(pattern))

    def read(self, path: str) -> str | None:
        if self.files is not None:
            return self.files.get(path)
        p = self.root / path
        if p.is_file():
            return p.read_text(errors="replace")
        for ref in filter(None, (self.base, "HEAD")):
            r = subprocess.run(["git", "-C", str(self.root), "show", f"{ref}:{path}"],
                               capture_output=True, text=True)
            if r.returncode == 0:
                return r.stdout
        return None


# ---------- Swift scanning ----------

STRING_OPEN = re.compile(r'(#*)("""|")')


def clean(text: str) -> str:
    """Drop comments (// and nested /* */) and blank string literal contents
    ("…", \"\"\"…\"\"\", #"…"#, ##\"\"\"…\"\"\"##), keeping newlines so lines line up.
    Code inside interpolations (\\( … ), or \\#( … ) in raw strings) is kept, so
    `"\\(A())"` still references A."""
    out: list[str] = []
    _code(text, 0, out, in_interp=False)
    return "".join(out)


def _code(text: str, i: int, out: list[str], in_interp: bool) -> int:
    """Copy code from i; inside an interpolation, stop after its closing paren."""
    n, parens = len(text), 0
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if text[i] == "\n":
                        out.append("\n")
                    i += 1
            continue
        m = STRING_OPEN.match(text, i) if c in '#"' else None
        if m:
            i = _string(text, m, out)
            continue
        if in_interp:
            if c == "(":
                parens += 1
            elif c == ")":
                if parens == 0:
                    out.append(")")
                    return i + 1
                parens -= 1
        out.append(c)
        i += 1
    return i


def _string(text: str, m: re.Match, out: list[str]) -> int:
    hashes, quote = m.group(1), m.group(2)
    close, escape = quote + hashes, "\\" + hashes
    n, j = len(text), m.end()
    out.append('"')
    while j < n:
        if text.startswith(escape, j):
            k = j + len(escape)
            if text.startswith("(", k):
                out.append(" (")
                j = _code(text, k + 1, out, in_interp=True)
                out.append(" ")
                continue
            j = k + 1  # other escape: skip the escaped character
            continue
        if text.startswith(close, j):
            break
        if text[j] == "\n":
            out.append("\n")
        j += 1
    out.append('"')
    return j + len(close)


def scan(text: str):
    """Yield (line, depth at line start) over cleaned text; None if braces don't balance."""
    lines, depth = [], 0
    for line in clean(text).split("\n"):
        lines.append((line, depth))
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth < 0:
                    return None
    return lines if depth == 0 else None


def declared(text: str) -> tuple[set[str], bool, bool]:
    """(top-level names a file declares, extends a stdlib type, parsed ok).

    Top level = brace depth 0, however indented (#if blocks don't count).
    Nested types and members are left out: generic names (Failure,
    CodingKeys, State) would match the whole module, and uses spell or infer
    them through the outer type.
    """
    lines = scan(text)
    if lines is None:
        return set(), False, False
    names, stdlib = set(), False
    for line, depth in lines:
        m = DECL_RE.match(line)
        if not m or depth:
            continue
        mods, kind, name = m.groups()
        if "private" in mods.split() or "fileprivate" in mods.split():
            continue
        name = name.split(".")[0]
        if kind == "extension" and name in STDLIB:
            stdlib = True
            continue
        names.add(name)
    return names, stdlib, True


def words(text: str) -> set[str]:
    return set(re.findall(r"[A-Za-z_]\w*", clean(text)))


def refs(text: str, names: set[str]) -> set[str]:
    return words(text) & names if names else set()


def test_ids(text: str) -> tuple[set[str], set[str], bool]:
    """(suite paths like Outer or Outer.Nested, free @Test funcs, parsed ok).

    A suite is any type (or extension) whose braces directly hold an @Test.
    """
    lines = scan(text)
    if lines is None:
        return set(), set(), False
    suites, free = set(), set()
    stack: list[tuple[str, int]] = []  # (type path, depth inside its braces)
    pending: tuple[str, int] | None = None
    free_test = False
    for line, depth in lines:
        m = DECL_RE.match(line)
        if m and m.group(2) in TYPE_KINDS:
            kind, name = m.group(2), m.group(3)
            outer = stack[-1][0] if stack and kind != "extension" else ""
            pending = ((outer + "." if outer else "") + name, depth)
            if SUITE_RE.search(line):
                suites.add(pending[0])
        if m and m.group(2) == "func" and depth == 0 and (free_test or TEST_RE.search(line)):
            free.add(m.group(3))
        if line.strip() and not line.strip().startswith("@"):
            free_test = False
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == "{":
                depth += 1
                if pending and pending[1] == depth - 1:
                    stack.append((pending[0], depth))
                    pending = None
            elif ch == "}":
                if stack and stack[-1][1] == depth:
                    stack.pop()
                depth -= 1
            elif line.startswith("@Test", i) and not line[i + 5:i + 6].isalnum():
                if stack and stack[-1][1] == depth:
                    suites.add(stack[-1][0])
                elif depth == 0:
                    free_test = True
            i += 1
    return suites, free, True


# ---------- classification ----------

def core_closure(repo: Repo, path: str) -> tuple[set[str], list[str], str | None]:
    """Names reachable from a changed Core file, the Core files involved, and a widen reason."""
    text = repo.read(path)
    if text is None:
        return set(), [], "can't read the file or its base version"
    names, stdlib, ok = repo.own_names(path)
    if not ok:
        return set(), [], "braces don't balance, can't parse"
    widen = "extends a stdlib type" if stdlib else None
    files = {f: repo.read(f) or "" for f in repo.list(CORE_SRC)}
    seen = {path}
    changed = True
    while changed:
        changed = False
        for f, t in files.items():
            if f in seen or not refs(t, names):
                continue
            seen.add(f)
            new, w, ok = declared(t)
            if not ok:
                widen = widen or f"{Path(f).name} can't be parsed"
            if w:
                widen = widen or f"{Path(f).name} extends a stdlib type"
            if not new <= names:
                names |= new
                changed = True
    return names, sorted(seen - {path}), widen


def tests_referencing(repo: Repo, target: str, names: set[str], extra_re: str | None = None) -> list[str]:
    out = []
    for f in repo.list(f"{TEST_DIR}{target}/"):
        t = repo.read(f) or ""
        if refs(t, names) or (extra_re and re.search(extra_re, t, re.M)):
            out.append(f)
    return out


def expand_support(repo: Repo, target: str, files) -> set[str]:
    """Swap test support files (no suites) for the test files that use them."""
    out, todo, seen = set(), list(files), set()
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        text = repo.read(f) or ""
        s, fr, ok = test_ids(text)
        if s or fr or not ok:
            out.add(f)  # unparseable files reach the fail-safe check and widen there
        else:
            todo += [u for u in tests_referencing(repo, target, declared(text)[0]) if u != f]
    return out


def shell_consumers(repo: Repo, path: str) -> list[str]:
    """tests/test_*.sh and tests/test_*.py that mention the file's name or path."""
    needles = {Path(path).name, path}
    if path.startswith("tests/fixtures/"):
        sub = path.split("/")[2]
        needles |= {f"fixtures/{sub}"} if "/" in path[len("tests/fixtures/"):] else set()
    out = []
    for f in repo.glob("tests/test_*.sh") + repo.glob("tests/test_*.py"):
        if f in (path, "tests/test_test_affected.py"):  # the self-test quotes paths as sample data
            continue
        t = repo.read(f) or ""
        if any(n in t for n in needles):
            out.append(f)
    return out


def script_cmd(f: str) -> str:
    return f"python3 {f}" if f.endswith(".py") else f"./{f}"


def short(names, n=4) -> str:
    names = sorted(names)
    return ", ".join(names[:n]) + (", …" if len(names) > n else "")


def stem(p: str) -> str:
    return Path(p).stem


def glob_match(path: str, pat: str) -> bool:
    if pat.endswith("/**"):
        return path.startswith(pat[:-2])
    return fnmatch.fnmatch(path, pat)


def is_doc(path: str) -> bool:
    name = Path(path).name
    return path.endswith(".md") or path.startswith("docs/") or name == "LICENSE" or name.startswith("CHANGELOG")


def classify(path: str, plan: Plan, repo: Repo) -> bool:
    """Add the path's checks to the plan. Returns False when nothing maps it."""
    def why(cat, reason, mapped=True):
        plan.reasons.append((path, cat, reason))
        return mapped

    if is_doc(path):
        return why("docs", "nothing")

    if path.startswith(APP_SRC):
        plan.products.add("Khuluma")
        plan.snapshot = True
        return why("app UI", "build Khuluma + snapshots (no test target imports Khuluma)")

    if path.startswith(CORE_SRC):
        plan.products |= {"Khuluma", "khuluma-cli"}
        if path.startswith(CORE_STATS):
            plan.snapshot = True
        names, files, widen = core_closure(repo, path)
        own = repo.own_names(path)[0]
        msg = f"declares {short(own)}" if own else "declares nothing top-level"
        if files:
            msg += "; used by " + short([Path(f).name for f in files])
        if widen:
            plan.full_targets.add(CORE_T)
            return why("core", f"{msg}; {widen} → all {CORE_T}")
        tests = sorted(expand_support(repo, CORE_T, tests_referencing(repo, CORE_T, names)))
        if not tests:
            plan.full_targets.add(CORE_T)
            return why("core", msg + f"; no test references → unmapped → wider set (all {CORE_T})")
        plan.test_files[CORE_T].update(tests)
        return why("core", msg + f"; tests: {short([stem(t) for t in tests], 6)}")

    if path.startswith("native/Sources/KhulumaObjC/"):
        plan.full_targets.add(CORE_T)
        plan.products.add("Khuluma")
        return why("objc", f"all {CORE_T} + build Khuluma")

    if path.startswith("native/Sources/KhulumaDaemonKit/"):
        plan.full_targets.add(DK_T)
        plan.products |= {"khulumad", "khuluma-cli"}
        own, _, ok = repo.own_names(path)
        if not ok:
            plan.full_targets.add(CORE_T)
            return why("daemonkit", f"can't parse → all {DK_T} + all {CORE_T}")
        tests = sorted(expand_support(repo, CORE_T, tests_referencing(
            repo, CORE_T, own, r"^\s*(@testable\s+)?import\s+KhulumaDaemonKit\b")))
        plan.test_files[CORE_T].update(tests)
        return why("daemonkit", f"declares {short(own)}; all {DK_T}; core tests: {short([stem(t) for t in tests], 6)}")

    if path.startswith("native/Sources/khulumad/"):
        plan.full_targets.add(DK_T)
        plan.products.add("khulumad")
        return why("khulumad", f"build khulumad + {DK_T} + BundledDaemonIntegrationTests (spawns the binary)")

    if path.startswith("native/Sources/khuluma-cli/"):
        plan.products.add("khuluma-cli")
        own = declared(repo.read(path) or "")[0]
        tests = sorted(expand_support(repo, CORE_T, tests_referencing(repo, CORE_T, own)))
        plan.test_files[CORE_T].update(tests)
        extra = sorted({stem(t) for t in tests} - {"FileTranscriptionTests"})
        return why("cli", "build khuluma-cli + FileTranscriptionTests" + (f", {short(extra)}" if extra else ""))

    if path.startswith(TEST_DIR):
        parts = path.split("/")
        target = parts[2] if len(parts) > 3 else None
        if target not in TARGETS:
            plan.swift_full = True
            return why("tests", "unknown test target → full Swift suite")
        text = repo.read(path)
        if text is None:  # deleted test file: nothing left to run there, but the target must still build
            plan.full_targets.add(target)
            return why("tests", f"deleted → all {target}")
        suites, free, ok = test_ids(text)
        own, _, ok2 = repo.own_names(path)
        if not (ok and ok2):
            plan.full_targets.add(target)
            return why("tests", f"braces don't balance, can't parse → all {target}")
        users = sorted(expand_support(repo, target, [f for f in tests_referencing(repo, target, own) if f != path]))
        if suites or free:
            plan.test_files[target].add(path)
            plan.test_files[target].update(users)
            extra = f"; its declarations are used by {short([stem(u) for u in users], 6)}" if users else ""
            return why("tests", f"suites: {short(suites | free)}{extra}")
        if not users:
            plan.full_targets.add(target)
            return why("test support", f"declares {short(own)}; no users → all {target}")
        plan.test_files[target].update(users)
        return why("test support", f"declares {short(own)}; used by {short([stem(u) for u in users], 6)}")

    if path in ("native/Package.swift", "native/Package.resolved", ".github/workflows/swift.yml") or path.startswith("native/"):
        plan.swift_full = True
        return why("package", "full Swift suite + all products")

    # Cleanup/vocabulary/usage parity inputs.
    if path.startswith("bin/"):
        plan.cmd(GEN_CHECK)
        plan.test_files[CORE_T].update(PARITY_FILES)
        plan.cmd(CI_SH)
        return why("cli cleanup", "fixtures --check + parity tests + tests/ci.sh")
    if path.startswith("config/"):
        plan.cmd(GEN_CHECK)
        plan.test_files[CORE_T].update(PARITY_FILES)
        return why("config", "fixtures --check + parity tests")
    if path in ("tests/gen-cleanup-fixtures.sh", "tests/gen_cleanup_fixtures.py"):
        plan.cmd(GEN_CHECK)
        plan.test_files[CORE_T].add(PARITY_FILES[0])
        return why("fixture gen", "fixtures --check + CleanupParityTests")
    gens = {"tests/gen_usage_parity_fixtures.py": "UsageParityTests",
            "tests/gen_vocabulary_parity_fixtures.py": "VocabularyParityTests",
            "tests/gen-settings-fixtures.sh": "SettingsTests"}
    if path in gens:
        plan.test_files[CORE_T].add(f"native/Tests/KhulumaCoreTests/{gens[path]}.swift")
        if path.endswith(".sh"):
            plan.cmd(f"bash -n {path}")
        return why("fixture gen", gens[path])
    if path.startswith("tests/fixtures/"):
        if any(glob_match(path, p) for p in OVERRIDES):
            return why("fixtures", "Swift readers (override map)")
        rest = path[len("tests/fixtures/"):]
        key = "tests/fixtures/" + (rest.split("/")[0] + "/" if "/" in rest else rest)
        readers = tests_referencing_text(repo, key)
        if readers:
            plan.test_files[CORE_T].update(readers)
            return why("fixtures", f"Swift readers: {short([stem(r) for r in readers])}")
        return why("fixtures", "no Swift test reads it", mapped=False)
    if path == "tests/fixture_helpers.sh":
        plan.cmd(CI_SH)
        return why("shell tests", "shared helper → tests/ci.sh")
    if re.fullmatch(r"tests/[^/]+\.sh", path):
        if path == "tests/ci.sh":
            plan.cmd(CI_SH)
        else:
            plan.cmd(f"bash -n {path}")
            plan.cmd(f"./{path}")
        return why("shell tests", "run it")
    if re.fullmatch(r"tests/[^/]+\.py", path):
        plan.cmd(f"python3 {path}")
        return why("python tests", "run it")
    if path in ("tools/test_affected.py", "tools/test-affected.sh"):
        plan.cmd(SELFTEST)
        if path.endswith(".sh"):
            plan.cmd(f"bash -n {path}")
        return why("tools", "self-test")
    if re.fullmatch(r"tools/[^/]+\.sh", path):
        plan.cmd(f"bash -n {path}")
        if path == "tools/build-khuluma-app.sh":
            plan.cmd("python3 tests/test_app_build_helpers.py")
        return why("tools", "syntax check", mapped=False)
    if path.startswith("assets/icons/") or path == ".github/workflows/icons.yml":
        return why("assets", "checked by CI (icons.yml)")
    if path.startswith("assets/sounds/"):
        return why("assets", "SoundsAndPermissionsTests (override map)")
    if path.startswith(".github/") or path.startswith("assets/"):
        return why("ci/assets", "checked by CI")
    if path.startswith("tools/"):
        return why("tools", "no direct check", mapped=False)
    plan.swift_full = True
    return why("other", "unmapped → wider set (full Swift suite)", mapped=False)


def tests_referencing_text(repo: Repo, needle: str) -> list[str]:
    return [f for t in TARGETS for f in repo.list(f"{TEST_DIR}{t}/") if needle in (repo.read(f) or "")]


def apply_overrides(path: str, plan: Plan) -> None:
    for pat, o in OVERRIDES.items():
        if not glob_match(path, pat):
            continue
        for t, ss in o.get("suites", {}).items():
            plan.suites[t].update(ss)
        for t, fs in o.get("files", {}).items():
            plan.test_files[t].update(fs)
        for c in o.get("commands", []):
            plan.cmd(c)
        plan.products.update(o.get("products", []))


def make_plan(paths: list[str], repo: Repo) -> Plan:
    plan = Plan()
    for p in paths:
        mapped = classify(p, plan, repo)
        apply_overrides(p, plan)
        if not p.startswith("native/") and not is_doc(p):
            users = shell_consumers(repo, p)
            for u in users:
                plan.cmd(script_cmd(u))
            if users:
                plan.reasons.append((p, "consumers", short([Path(u).name for u in users], 6)))
            elif not mapped:
                plan.cmd(CI_SH)
                plan.reasons.append((p, "consumers", "none found → tests/ci.sh"))
    if plan.swift_full:
        plan.full_targets = set(TARGETS)
        plan.products = set(PRODUCTS)
    for t in plan.full_targets:
        plan.test_files[t].clear()
        plan.suites[t].clear()
    return plan


# ---------- running ----------

def jobs(arg: int | None) -> int:
    if arg:
        return arg
    if os.environ.get("KHULUMA_JOBS"):
        return int(os.environ["KHULUMA_JOBS"])
    return max(2, (os.cpu_count() or 4) // 2)


def low_priority() -> list[str]:
    pre = ["nice", "-n", "10"]
    if shutil.which("taskpolicy"):
        pre += ["taskpolicy", "-c", "utility"]
    return pre


def swift(args: list[str], n: int) -> list[str]:
    flags = ["--package-path", "native", "--jobs", str(n)]
    if os.path.isdir(PLUGIN_DIR):
        flags += ["-Xswiftc", "-plugin-path", "-Xswiftc", PLUGIN_DIR]
    return low_priority() + ["swift"] + args + flags


TIMED_OUT = -1000
NOT_STARTED = 127


def run(argv, timeout: int = STEP_TIMEOUT, env=None, capture: bool = False, quiet: bool = False):
    """Run in its own process group; kill the group on timeout.

    Returns rc (or (rc, stdout) when capture). TIMED_OUT on timeout,
    NOT_STARTED if the command can't be started."""
    if not quiet:
        print("$ " + show(argv), flush=True)
    try:
        p = subprocess.Popen(argv, cwd=ROOT, env=env, start_new_session=True, text=True,
                             stdout=subprocess.PIPE if capture else None)
    except OSError as e:
        print(f"  ! can't start {argv[0]}: {e}")
        return (NOT_STARTED, "") if capture else NOT_STARTED
    try:
        out, _ = p.communicate(timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        print(f"  ! timed out after {timeout}s, stopping the process group")
        # TERM the group, give the leader 10 s, then KILL the group regardless:
        # children that ignore TERM or outlive the leader must not survive.
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        out, rc = "", TIMED_OUT
    return (rc, out or "") if capture else rc


def show(argv) -> str:
    return " ".join(a if re.fullmatch(r"[\w./=:@%+,-]+", a) else "'" + a.replace("'", "'\\''") + "'" for a in argv)


def anchor(target: str, suite_path: str) -> str:
    # Nested suites: Outer.Nested may be listed as Outer.Nested/ or Outer/Nested/.
    return rf"^{re.escape(target)}\." + r"[./]".join(map(re.escape, suite_path.split("."))) + "/"


def file_patterns(repo: Repo, target: str, f: str) -> list[str]:
    """Filters for a test file: every suite, nested ones too (their listed id may be
    Outer/Nested/ or Outer.Nested/), plus free @Test functions."""
    suites, free, _ = test_ids(repo.read(f) or "")
    return [anchor(target, s) for s in sorted(suites)] + [rf"^{re.escape(target)}\.{re.escape(fn)}\(" for fn in sorted(free)]


def build_filter(plan: Plan, repo: Repo) -> list[str] | None:
    """One small anchored regex per suite (passed as repeated --filter), or None for all.

    Not one big alternation: `swift test --filter '^T.(A(/|$)|B(/|$)|…)'` over
    ~70 suites took 42 s against 4.6 s for 70 separate --filter flags.
    """
    if set(plan.full_targets) == set(TARGETS):
        return None
    out = []
    for t in TARGETS:
        if t in plan.full_targets:
            out.append(rf"^{re.escape(t)}\.")
            continue
        out += [p for f in sorted(plan.test_files[t]) for p in file_patterns(repo, t, f)]
        out += [anchor(t, s) for s in sorted(plan.suites[t])]
    return list(dict.fromkeys(out))


def filter_args(flt: list[str] | None) -> list[str]:
    return [x for f in (flt or []) for x in ("--filter", f)]


def missing_suites(plan: Plan, repo: Repo, listed: list[str]) -> list[tuple[str, str, str]]:
    """(target, what, why) for every expected suite or test function absent from `swift test list`."""
    out = []
    for t in TARGETS:
        if t in plan.full_targets:
            continue
        for f in sorted(plan.test_files[t]):
            suites, free, ok = test_ids(repo.read(f) or "")
            if not ok:
                out.append((t, f, "can't parse"))
                continue
            if not suites and not free:
                out.append((t, f, "no suites found"))
            for s in sorted(suites):
                if not any(re.match(anchor(t, s), l) for l in listed):
                    out.append((t, f, f"suite {s} not listed"))
            for fn in sorted(free):
                if not any(l.startswith(f"{t}.{fn}(") for l in listed):
                    out.append((t, f, f"test {fn}() not listed"))
        for s in sorted(plan.suites[t]):
            if not any(re.match(anchor(t, s), l) for l in listed):
                out.append((t, f"suite {s}", "not listed"))
    return out


def run_tests(plan: Plan, repo: Repo, flt: list[str] | None, n: int) -> int:
    if flt is not None:
        argv = swift(["test", "list", "--skip-build"], n)
        print("$ " + show(argv) + "  (fail-safe check)", flush=True)
        rc, out = run(argv, capture=True, quiet=True)
        if rc != 0:
            print(f"  ! swift test list failed ({rc}) → full Swift suite")
            plan.full_targets = set(TARGETS)
            flt, listed = None, []
        else:
            listed = out.splitlines()
            for t, what, reason in missing_suites(plan, repo, listed):
                print(f"  ! {what}: {reason} → all {t}")
                plan.full_targets.add(t)
            flt = build_filter(plan, repo)
        if flt is not None:
            count = sum(1 for l in listed if any(re.match(p, l) for p in flt))
            print(f"  {count} tests selected of {len(listed)}")
    return run(swift(["test", "--skip-build"] + filter_args(flt), n))


# Environment the app reads (grep of KhulumaCore + Khuluma for ProcessInfo /
# environment keys, Nov 2026): KHULUMA_SUPPORT_DIR, KHULUMA_LOG_DIR,
# KHULUMA_DEFAULTS_SUITE (AppRuntimePaths); KHULUMA_DEFAULT_MODEL_DIR,
# XDG_DATA_HOME, SOUNDS_DIR (AppRuntimePaths, AppSettings); KHULUMA_CONFIG_DIR,
# XDG_CONFIG_HOME, KHULUMA_USAGE_SUMMARY_FILE (LegacyImport.source);
# KHULUMA_KEEP_LOGS, KHULUMA_DAEMON_BINARY (dropped); ZDOTDIR and
# ELEVENLABS_API_KEY / ELEVEN_LABS_API_KEY (ScribeCredential; dropped / pointed
# at the run dir). Every inherited KHULUMA_* and XDG_* is removed first.
DROP_ENV = ("ELEVENLABS_API_KEY", "ELEVEN_LABS_API_KEY", "ZDOTDIR", "SOUNDS_DIR")
LEGACY_RUN = "khuluma-snapshot-run"
LEGACY_SUITE = "com.ricardo-nth.khuluma.test-affected-snapshot"


def prefs_dir() -> Path:
    return Path.home() / "Library" / "Preferences"


def owned_real(path: Path, kind: str = "dir") -> bool:
    """True if path exists, isn't a symlink, is the right kind and is ours."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    import stat as st_mod
    ok_kind = st_mod.S_ISDIR(st.st_mode) if kind == "dir" else st_mod.S_ISREG(st.st_mode)
    return ok_kind and st.st_uid == os.getuid()


class UnsafePath(Exception):
    pass


def check_safe(path: Path, must_exist: bool = False) -> None:
    """Refuse symlinks and paths we don't own (absent is fine unless must_exist)."""
    if not os.path.lexists(path):
        if must_exist:
            raise UnsafePath(f"{path} doesn't exist")
        return
    if not owned_real(path):
        raise UnsafePath(f"{path} is a symlink, not a directory, or not owned by you")


def remove_suite(suite: str) -> None:
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    plist = prefs_dir() / f"{suite}.plist"
    if owned_real(plist, "file"):
        plist.unlink()


def cleanup_legacy(build: Path) -> None:
    """Leftovers from the fixed names earlier versions used."""
    old = build / LEGACY_RUN
    if owned_real(old):
        shutil.rmtree(old)
    if os.path.lexists(prefs_dir() / f"{LEGACY_SUITE}.plist"):
        remove_suite(LEGACY_SUITE)


def snapshot_env(run_dir: Path, suite: str, base: dict | None = None) -> dict:
    """Private overrides (AppRuntimePaths.isolationIssue), all inside run_dir,
    so a broken snapshot branch in main.swift can't fall through to real data."""
    for sub in ("support", "logs", "data", "sounds", "models", "config", "zdot"):
        (run_dir / sub).mkdir(mode=0o700)
    env = {k: v for k, v in (os.environ if base is None else base).items()
           if not k.startswith(("KHULUMA_", "XDG_")) and k not in DROP_ENV}
    env.update({
        "KHULUMA_SUPPORT_DIR": str(run_dir / "support"),
        "KHULUMA_LOG_DIR": str(run_dir / "logs"),
        "KHULUMA_DEFAULTS_SUITE": suite,
        "KHULUMA_DEFAULT_MODEL_DIR": str(run_dir / "models"),
        "KHULUMA_CONFIG_DIR": str(run_dir / "config"),
        "KHULUMA_USAGE_SUMMARY_FILE": str(run_dir / "config" / "usage.json"),
        "XDG_DATA_HOME": str(run_dir / "data"),
        "XDG_CONFIG_HOME": str(run_dir / "config"),
        "SOUNDS_DIR": str(run_dir / "sounds"),
        "ZDOTDIR": str(run_dir / "zdot"),
    })
    return env


def run_snapshot() -> int:
    import tempfile
    import uuid
    build = NATIVE / ".build"
    binary = build / "debug" / "Khuluma"
    try:
        check_safe(build, must_exist=True)
        check_safe(SNAPSHOT_DIR)
        check_safe(SNAPSHOT_PREV)
    except UnsafePath as e:
        print(f"  ! refusing to touch snapshot folders: {e}")
        return 1
    cleanup_legacy(build)
    if os.path.lexists(SNAPSHOT_DIR):
        if os.path.lexists(SNAPSHOT_PREV):
            shutil.rmtree(SNAPSHOT_PREV)
        SNAPSHOT_DIR.rename(SNAPSHOT_PREV)
    SNAPSHOT_DIR.mkdir()
    run_dir = Path(tempfile.mkdtemp(prefix="khuluma-snapshot-run.", dir=build))  # 0700, ours
    suite = f"{LEGACY_SUITE}.{uuid.uuid4().hex[:8]}"
    try:
        env = snapshot_env(run_dir, suite)
        rc = run(low_priority() + [str(binary), "-KhulumaStatsSnapshot", str(SNAPSHOT_DIR)],
                 timeout=SNAPSHOT_TIMEOUT, env=env)
    finally:
        remove_suite(suite)
        shutil.rmtree(run_dir, ignore_errors=True)
    files = sorted(p.name for p in SNAPSHOT_DIR.iterdir())
    print(f"  {len(files)} files in {SNAPSHOT_DIR}")
    if SNAPSHOT_PREV.exists():
        print(f"  previous render: {SNAPSHOT_PREV}")
    return rc if files else (rc or 1)


# ---------- changed paths ----------

def git(*args) -> list[str]:
    r = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise GitError(f"git {' '.join(args)} failed: {r.stderr.strip() or r.returncode}")
    return r.stdout.splitlines()


def changed_paths(base: str | None) -> tuple[list[str], str]:
    ref = base or "origin/main"
    mb = git("merge-base", "HEAD", ref)[0]
    out = set(git("diff", "--name-only", "--no-renames", f"{mb}..HEAD"))
    out |= set(git("diff", "--name-only", "--no-renames", "HEAD"))
    out |= set(git("ls-files", "--others", "--exclude-standard"))
    return sorted(p for p in out if p), mb


def norm(p: str) -> str:
    a = Path(p) if os.path.isabs(p) else (Path.cwd() / p)
    try:
        return str(a.resolve().relative_to(ROOT))
    except ValueError:
        return p  # already repo-relative (or outside: classified as unmapped)


# ---------- main ----------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", metavar="REF",
                    help="diff against the merge-base with REF instead of origin/main (working tree still included)")
    ap.add_argument("--paths", nargs="+", metavar="P",
                    help="check exactly these paths and ignore git (use in the shared checkout); also after --")
    ap.add_argument("--plan", "--dry-run", dest="plan", action="store_true",
                    help="print the plan and reasons, run nothing")
    ap.add_argument("--full", action="store_true", help="run the full Swift suite and build every product")
    ap.add_argument("--snapshot", action="store_true",
                    help="also render the UI snapshots (automatic for app UI and KhulumaCore/Stats changes)")
    ap.add_argument("--no-snapshot", action="store_true", help="never render the UI snapshots (wins over --snapshot)")
    ap.add_argument("--jobs", type=int, metavar="N",
                    help="SwiftPM build jobs (default: $KHULUMA_JOBS, else max(2, cpus/2))")
    ap.add_argument("rest", nargs="*", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    n = jobs(a.jobs)

    explicit = (a.paths or []) + a.rest
    try:
        if explicit:
            paths = sorted({norm(p) if (Path.cwd() / p).exists() or os.path.isabs(p) else p for p in explicit})
            # Base for deleted files and old declarations: HEAD, or --base's merge-base.
            base_ref = git("merge-base", "HEAD", a.base)[0] if a.base else "HEAD"
            where = "given paths"
        else:
            paths, base_ref = changed_paths(a.base)
            where = f"vs {a.base or 'origin/main'} + working tree"
    except (GitError, IndexError) as e:
        print(f"error: can't work out the changed files: {e}\n"
              "Pass --base <ref> (e.g. --base HEAD) or --paths <files>.", file=sys.stderr)
        return 2
    repo = Repo(base=base_ref)
    if a.full:
        plan = make_plan([], repo)
        plan.swift_full = True
        plan.full_targets, plan.products = set(TARGETS), set(PRODUCTS)
        plan.reasons.append(("--full", "forced", "full Swift suite"))
    else:
        plan = make_plan(paths, repo)
    if a.snapshot:
        plan.snapshot = True
    if a.no_snapshot:
        plan.snapshot = False

    print(f"changed ({len(paths)}, {where}):")
    w = max([len(p) for p, _, _ in plan.reasons] + [10]) + 2
    for p, cat, reason in plan.reasons:
        print(f"  {p.ljust(w)}{cat} → {reason}")
    steps = steps_for(plan, repo, n)
    print("plan:" if steps else "plan: nothing to run")
    for i, (label, argv, reason) in enumerate(steps, 1):
        if isinstance(argv, tuple) and argv[0] == "TEST":
            desc = show(["swift", "test", "--skip-build"] + filter_args(argv[1]))
        elif isinstance(argv, tuple):
            desc = f"native/.build/debug/Khuluma -KhulumaStatsSnapshot {SNAPSHOT_DIR.relative_to(ROOT)}"
        else:
            desc = show(argv[argv.index("swift"):]) if "swift" in argv else argv[-1]
        print(f"  {i}. {desc}" + (f"  ({reason})" if reason else ""))
    if a.plan or not steps:
        return 0

    results, failed = [], False
    for label, argv, _ in steps:
        t0 = time.monotonic()
        if failed and label in ("swift test", "snapshot"):
            results.append((label, "skipped", 0.0))
            continue
        if isinstance(argv, tuple) and argv[0] == "TEST":
            rc = run_tests(plan, repo, argv[1], n)
        elif isinstance(argv, tuple):
            rc = run_snapshot()
        else:
            rc = run(argv)
        dt = time.monotonic() - t0
        res = "ok" if rc == 0 else "timed out" if rc == TIMED_OUT else "not started" if rc == NOT_STARTED else f"FAIL ({rc})"
        results.append((label, res, dt))
        failed |= rc != 0 and label.startswith("build")
    print("\nsummary:")
    for label, res, dt in results:
        print(f"  {label[:48].ljust(50)}{res.ljust(12)}{dt:7.1f}s")
    print(f"  {'total'.ljust(62)}{sum(r[2] for r in results):7.1f}s")
    return 1 if any(r[1] not in ("ok", "skipped") for r in results) else 0


def steps_for(plan: Plan, repo: Repo, n: int) -> list[tuple[str, object, str]]:
    """(label, argv or marker tuple, why)."""
    steps = []
    if plan.has_tests():
        steps.append(("build-tests", swift(["build", "--build-tests"], n),
                      "needed by tests; builds every product too"))
        flt = build_filter(plan, repo)
        steps.append(("swift test", ("TEST", flt), "selected tests" if flt else "full Swift suite"))
    else:
        for p in PRODUCTS:
            if p in plan.products:
                steps.append((f"build {p}", swift(["build", "--product", p], n), "changed code reaches it"))
    if plan.snapshot:
        if not plan.has_tests() and "Khuluma" not in plan.products:
            steps.append(("build Khuluma", swift(["build", "--product", "Khuluma"], n), "needed by the snapshot"))
        steps.append(("snapshot", ("SNAPSHOT",), f"isolated render into {SNAPSHOT_DIR.relative_to(ROOT)}"))
    for c in plan.commands:
        steps.append((c, low_priority() + ["bash", "-c", c], ""))
    return steps


if __name__ == "__main__":
    sys.exit(main())
