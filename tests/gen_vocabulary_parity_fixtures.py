#!/usr/bin/env python3
"""Record what the repo CLI's `vocab-sheet show|validate|save` does for a set
of inputs, in a throwaway KHULUMA_CONFIG_DIR, so the app's native port
(VocabularyStore) can be checked against it.

    python3 tests/gen_vocabulary_parity_fixtures.py   # rewrites the fixture

Output: tests/fixtures/vocabulary-parity/cases.json. Names and shapes only;
no real vocabulary or transcript text. Run it only when the CLI's rules
change on purpose; the Swift test (VocabularyParityTests) reads the file.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests/fixtures/vocabulary-parity/cases.json"
FILLERS = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "erm"]
STALE = "0" * 64
GENERATED = {"validate-5000-entries", "validate-5001-entries", "validate-too-many-before-bad-entry", "validate-oversize"}


def doc(fillers=None, brands=None, words=None, **extra):
    d = {"schema_version": 1, "fillers": FILLERS[:] if fillers is None else fillers,
         "brands": brands or [], "words": words or []}
    d.update(extra)
    return d


def pair(heard, write):
    return {"heard": heard, "write": write}


def text(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


CASES = [
    # show
    {"name": "show-empty-folder", "op": "show"},
    {"name": "show-valid-json", "op": "show", "files": {"vocabulary.json": text(doc(
        brands=[pair("pn pm", "pnpm")], words=[pair("source slash", "src/")],
        examples=[{"said": "pn pm install", "expect": "pnpm install"}]))}},
    {"name": "show-legacy-text-arrows", "op": "show", "files": {"vocab": "# comment\npn pm -> pnpm\nsource slash::src/\n\narrow → ->\n"}},
    {"name": "show-legacy-duplicate-same", "op": "show", "files": {"vocab": "a b -> c\nA B -> c\n"}},
    {"name": "show-legacy-conflict", "op": "show", "files": {"vocab": "a b -> c\nA B -> d\n"}},
    {"name": "show-legacy-invalid-line", "op": "show", "files": {"vocab": "no separator here\n"}},
    {"name": "show-legacy-empty-side", "op": "show", "files": {"vocab": "left ->\n"}},
    {"name": "show-legacy-crlf-and-unicode", "op": "show", "files": {"vocab": "café -> coffee\r\nnaïve::naive\r\n"}},
    {"name": "show-legacy-collides-with-filler", "op": "show", "files": {"vocab": "um -> hmm\n"}},
    {"name": "show-legacy-nfc-conflict", "op": "show", "files": {"vocab": "café -> a\ncafé -> b\n"}},
    {"name": "show-legacy-too-long", "op": "show", "files": {"vocab": "x" * 201 + " -> y\n"}},
    {"name": "show-json-wins-over-legacy", "op": "show", "files": {
        "vocabulary.json": text(doc(fillers=[], words=[pair("a", "b")])), "vocab": "bad line\n"}},
    {"name": "show-invalid-json-file", "op": "show", "files": {"vocabulary.json": "{not json"}, "messageParity": False},
    {"name": "show-invalid-document", "op": "show", "files": {"vocabulary.json": text({"schema_version": 1})}},
    # validate
    {"name": "validate-valid", "op": "validate", "input": text(doc(brands=[pair("a", "b")]))},
    {"name": "validate-trims", "op": "validate", "input": text(doc(fillers=["  um  "], words=[pair(" a ", " b ")]))},
    {"name": "validate-valid-examples", "op": "validate", "input": text(doc(examples=[{"said": "x", "expect": ""}]))},
    {"name": "validate-empty-examples-dropped", "op": "validate", "input": text(doc(examples=[]))},
    {"name": "validate-not-json", "op": "validate", "input": "{nope", "messageParity": False},
    {"name": "validate-not-object", "op": "validate", "input": "[1]"},
    {"name": "validate-scalar", "op": "validate", "input": "1"},
    {"name": "validate-missing-section", "op": "validate", "input": json.dumps({"schema_version": 1, "fillers": [], "brands": []})},
    {"name": "validate-extra-field", "op": "validate", "input": json.dumps({**doc(), "extra": 1})},
    {"name": "validate-wrong-version", "op": "validate", "input": text({**doc(), "schema_version": 2})},
    {"name": "validate-float-version", "op": "validate", "input": text(doc()).replace('"schema_version": 1', '"schema_version": 1.0')},
    {"name": "validate-bool-version", "op": "validate", "input": text({**doc(), "schema_version": True})},
    {"name": "validate-string-version", "op": "validate", "input": text({**doc(), "schema_version": "1"})},
    {"name": "validate-duplicate-field", "op": "validate", "input": '{"schema_version":1,"fillers":[],"brands":[],"words":[],"words":[]}'},
    {"name": "validate-duplicate-field-nested", "op": "validate", "input": '{"schema_version":1,"fillers":[],"brands":[{"heard":"a","heard":"b","write":"c"}],"words":[]}'},
    {"name": "validate-section-not-list", "op": "validate", "input": text({**doc(), "words": {}})},
    {"name": "validate-fillers-not-list", "op": "validate", "input": text({**doc(), "fillers": "um"})},
    {"name": "validate-filler-not-string", "op": "validate", "input": text(doc(fillers=[1]))},
    {"name": "validate-filler-blank", "op": "validate", "input": text(doc(fillers=["  "]))},
    {"name": "validate-filler-null", "op": "validate", "input": text(doc(fillers=[None]))},
    {"name": "validate-entry-not-object", "op": "validate", "input": text(doc(brands=["a"]))},
    {"name": "validate-entry-missing-write", "op": "validate", "input": text(doc(words=[{"heard": "a"}]))},
    {"name": "validate-entry-extra-key", "op": "validate", "input": text(doc(words=[{"heard": "a", "write": "b", "x": "y"}]))},
    {"name": "validate-heard-control-char", "op": "validate", "input": text(doc(words=[pair("a\tb", "c")]))},
    {"name": "validate-write-newline", "op": "validate", "input": text(doc(words=[pair("a", "c\nd")]))},
    {"name": "validate-del-char", "op": "validate", "input": text(doc(words=[pair("a\u007f", "c")]))},
    {"name": "validate-term-200", "op": "validate", "input": text(doc(words=[pair("x" * 200, "y" * 200)]))},
    {"name": "validate-term-201", "op": "validate", "input": text(doc(words=[pair("x" * 201, "y")]))},
    {"name": "validate-term-200-emoji", "op": "validate", "input": text(doc(words=[pair("\U0001F600" * 200, "y")]))},
    {"name": "validate-term-201-emoji", "op": "validate", "input": text(doc(words=[pair("\U0001F600" * 201, "y")]))},
    {"name": "validate-duplicate-across-sections", "op": "validate", "input": text(doc(fillers=["a"], words=[pair("A", "b")]))},
    {"name": "validate-duplicate-after-trim", "op": "validate", "input": text(doc(brands=[pair("a", "b"), pair(" a ", "c")]))},
    {"name": "validate-duplicate-nfc", "op": "validate", "input": text(doc(words=[pair("café", "a"), pair("café", "b")]))},
    {"name": "validate-same-write-ok", "op": "validate", "input": text(doc(words=[pair("a", "x"), pair("b", "x")]))},
    {"name": "validate-5000-entries", "op": "validate", "input": text(doc(fillers=[], words=[pair(f"w{i}", "x") for i in range(5000)]))},
    {"name": "validate-5001-entries", "op": "validate", "input": text(doc(fillers=[], words=[pair(f"w{i}", "x") for i in range(5001)]))},
    {"name": "validate-too-many-before-bad-entry", "op": "validate", "input": text(doc(fillers=[], words=[pair(f"w{i}", "x") for i in range(5000)] + [{"heard": 1}]))},
    {"name": "validate-examples-not-list", "op": "validate", "input": text(doc(examples={}))},
    {"name": "validate-examples-null", "op": "validate", "input": text(doc(examples=None))},
    {"name": "validate-examples-201", "op": "validate", "input": text(doc(examples=[{"said": f"s{i}", "expect": "e"} for i in range(201)]))},
    {"name": "validate-examples-200", "op": "validate", "input": text(doc(examples=[{"said": f"s{i}", "expect": "e"} for i in range(200)]))},
    {"name": "validate-example-missing-key", "op": "validate", "input": text(doc(examples=[{"said": "a"}]))},
    {"name": "validate-example-not-object", "op": "validate", "input": text(doc(examples=["a"]))},
    {"name": "validate-example-blank-said", "op": "validate", "input": text(doc(examples=[{"said": "  ", "expect": "a"}]))},
    {"name": "validate-example-non-string", "op": "validate", "input": text(doc(examples=[{"said": 1, "expect": "a"}]))},
    {"name": "validate-example-control", "op": "validate", "input": text(doc(examples=[{"said": "a", "expect": "b\nc"}]))},
    {"name": "validate-example-2000", "op": "validate", "input": text(doc(examples=[{"said": "a" * 2000, "expect": "b" * 2000}]))},
    {"name": "validate-example-2001", "op": "validate", "input": text(doc(examples=[{"said": "a" * 2001, "expect": "b"}]))},
    {"name": "validate-example-keeps-spacing", "op": "validate", "input": text(doc(examples=[{"said": " a ", "expect": " b "}]))},
    {"name": "validate-escapes-roundtrip", "op": "validate", "input": text(doc(words=[pair('say "hi"', "back\\slash /")]))},
    {"name": "validate-oversize", "op": "validate", "input": " " * 1_048_577, "messageParity": True},
    # save
    {"name": "save-no-file-yet", "op": "save", "revision": "current", "document": doc(words=[pair("a", "b")])},
    {"name": "save-first-save-same-as-legacy", "op": "save", "revision": "current",
     "files": {"vocab": "a -> b\n"}, "document": doc(words=[pair("a", "b")])},
    {"name": "save-over-existing", "op": "save", "revision": "current",
     "files": {"vocabulary.json": text(doc(words=[pair("a", "b")]))}, "document": doc(words=[pair("a", "c")])},
    {"name": "save-identical-is-noop", "op": "save", "revision": "current",
     "files": {"vocabulary.json": text(doc(words=[pair("a", "b")]))}, "document": doc(words=[pair("a", "b")])},
    {"name": "save-identical-after-trim-is-noop", "op": "save", "revision": "current",
     "files": {"vocabulary.json": text(doc(words=[pair("a", "b")]))}, "document": doc(words=[pair(" a ", "b ")])},
    {"name": "save-stale-revision", "op": "save", "revision": STALE,
     "files": {"vocabulary.json": text(doc())}, "document": doc(words=[pair("a", "b")])},
    {"name": "save-stale-revision-no-file", "op": "save", "revision": STALE, "document": doc()},
    {"name": "save-invalid-document", "op": "save", "revision": "current", "document": {**doc(), "schema_version": 3}},
    {"name": "save-duplicate-heard", "op": "save", "revision": "current", "document": doc(words=[pair("a", "b"), pair("A", "c")])},
    {"name": "save-with-examples", "op": "save", "revision": "current",
     "document": doc(examples=[{"said": "a", "expect": "b"}], brands=[pair('q"uote', "back\\slash")])},
    {"name": "save-unicode-bytes", "op": "save", "revision": "current",
     "document": doc(words=[pair("café", "☕ ü\U0001F600")])},
    {"name": "save-empty-sections", "op": "save", "revision": "current", "document": doc(fillers=[])},
    {"name": "save-bad-legacy-blocks", "op": "save", "revision": "current",
     "files": {"vocab": "broken\n"}, "document": doc()},
    {"name": "save-request-extra-key", "op": "save-raw", "request": {"document": doc(), "revision": STALE, "x": 1}},
    {"name": "save-request-missing-revision", "op": "save-raw", "request": {"document": doc()}},
]


def run(env, args, data=None):
    return subprocess.run([str(ROOT / "bin/khuluma"), *args], input=data, text=True, env=env, capture_output=True)


def record(case):
    root = Path(tempfile.mkdtemp(prefix="khuluma-vocab-parity-"))
    config = root / "config"
    config.mkdir()
    (root / "home").mkdir()
    (config / "config.toml").write_text("[meta]\nconfig_version = 1\n[clean]\nenabled = true\nrepeats_level = 3\n")
    for name, body in case.get("files", {}).items():
        (config / name).write_bytes(body.encode("utf-8"))
    env = {"HOME": str(root / "home"), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C",
           "KHULUMA_CONFIG_DIR": str(config), "KHULUMA_LIB_PATH": str(ROOT / "bin/khuluma-lib.sh"),
           "KHULUMA_INTERNAL_LIB_DIR": str(ROOT / "bin/khuluma-lib"), "XDG_DATA_HOME": str(root / "data")}
    op = case["op"]
    if op == "show":
        result = run(env, ["vocab-sheet", "show", "--json"])
    elif op == "validate":
        result = run(env, ["vocab-sheet", "validate", "--json"], case["input"])
    else:
        if op == "save-raw":
            request = case["request"]
        else:
            revision = case["revision"]
            if revision == "current":
                shown = run(env, ["vocab-sheet", "show", "--json"])
                revision = json.loads(shown.stdout)["revision"] if shown.returncode == 0 else STALE
            request = {"document": case["document"], "revision": revision}
        result = run(env, ["vocab-sheet", "save", "--json"], json.dumps(request))
    out = {"name": case["name"], "ok": result.returncode == 0}
    if result.returncode == 0:
        value = json.loads(result.stdout)
        out["result"] = value["document"] if op in ("show", "save", "save-raw") else value
    else:
        message = result.stderr.strip()
        out["error"] = message[len("Vocabulary: "):] if message.startswith("Vocabulary: ") else message
    if not case.get("messageParity", True):
        out["messageParity"] = False
    for key in ("files", "input", "op", "document"):
        if key in case:
            out[key] = case[key]
    if op.startswith("save"):
        out["revision"] = case.get("revision", "stale" if op == "save-raw" else None)
        if op == "save-raw":
            out["request"] = case["request"]
        sheet = config / "vocabulary.json"
        out["file_after"] = sheet.read_text("utf-8") if sheet.exists() else None
        backups = sorted((config / "vocabulary-backups").glob("*.json")) if (config / "vocabulary-backups").exists() else []
        out["backups_after"] = [b.read_text("utf-8") for b in backups]
    out["op"] = op
    return out


def main():
    cases = [record(case) for case in CASES]
    # The large inputs are rebuilt by name in the Swift test (see
    # VocabularyParityTests.generatedInput); the file keeps only a marker.
    for case in cases:
        if case["name"] in GENERATED:
            case["input"] = {"generated": case["name"]}
    OUT.write_text(json.dumps(cases, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {len(cases)} cases to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
