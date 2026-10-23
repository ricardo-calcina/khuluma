#!/usr/bin/env python3
"""Generate (or check) Khuluma's TextPipeline parity fixtures.

Expected outputs come from running the CLI's real bash/Perl cleanup:
- stage cases call one bin/khuluma-lib.sh function on the raw input;
- pipeline cases run `bin/khuluma inline cleanup --json` against a
  scratch copy of a fixture config dir, with a scratch HOME and LC_ALL=C
  (the environment Khuluma gives the CLI).

Inputs are the hand-written cases in tests/fixtures/cleanup/cases.json plus
seeded random "token soup" cases. The result, tests/fixtures/cleanup/
expected.json, is self-contained: the Swift tests read only that file and the
fixture config dirs.

Usage: tests/gen-cleanup-fixtures.sh [--check]
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "tests", "fixtures", "cleanup")
CASES = os.path.join(FIXTURES, "cases.json")
EXPECTED = os.path.join(FIXTURES, "expected.json")
SEED = 20261009

STAGE_RUNNER = r"""
set -u
source "$1/bin/khuluma-lib.sh"
work="$2"
while IFS=$'\x1f' read -r idx fn a1 a2 _end; do
  in="$work/in/$idx"
  out="$work/out/$idx"
  case "$fn" in
    sanitize) khuluma_lib_sanitize_transcript_artifacts <"$in" >"$out" ;;
    fillers) khuluma_lib_clean_fillers "$a1" <"$in" >"$out" ;;
    repeats) khuluma_lib_clean_repeats "$a1" <"$in" >"$out" ;;
    british) khuluma_lib_normalize_british_spelling "$a1" <"$in" >"$out" ;;
    vocab) khuluma_lib_apply_vocab_corrections "$a1" <"$in" >"$out" ;;
    *) echo "unknown stage: $fn" >&2; exit 1 ;;
  esac
done <"$work/manifest"
"""

# Pieces the random cases are built from: fillers, stutters, artefacts,
# vocab triggers, US spellings, spelled acronyms, punctuation, Unicode and
# every whitespace/line-ending variant the filters treat specially.
TOKENS = [
    "um", "uh,", "Umm.", "er", "hmm", "you know", "I mean,", "actually", "actuallyish", "basically,", "like", "like,",
    "so yeah", "anyways", "to be honest", "the", "The", "THE", "the the", "go to", "go to go to", "it's", "don't don't",
    "color", "Colors", "COLOR", "cOlOr", "favorite", "analyze", "realized", "centering", "Behavior",
    "[blank audio]", "( blank_audio )", "{BLANK - AUDIO}", "[blank]", "[", "]", "(", ")",
    ",", ".", "!", "?", ";", ":", "...", " ", "  ", "\t", "\n", "\r\n", "\r", "\x0b", "\x0c",
    " ", " ", "　", "\u0085", " ", "café", "naïve", "Straße", "STRASSE",
    "K8s", "k8s", "ſo yeah", "a p i", "A.P.I", "g-p-t", "x x x", "a b c d e f g h i", "open ai",
    "OPEN  AI", "open\tai", "jason", "Jason's", "get hub", "node.js", "c++", ".net", "api", "npm", "teh",
    "\U0001F600", "é", "日本語", "foo_bar", "gpt-4", "iTerm2", "1.5", "Dr. Smith",
    "wez term", "teamux", "tmux whisper", "source slash", "at saw slash", "regards", "kind regards", "zzz",
]


def soup(rng, max_tokens=24):
    parts = []
    for _ in range(rng.randint(1, max_tokens)):
        parts.append(rng.choice(TOKENS))
        parts.append(rng.choice([" ", " ", " ", "", ", ", ". "]))
    return "".join(parts)


def long_soup(rng):
    sentences = []
    for _ in range(rng.randint(3, 14)):
        words = [rng.choice(TOKENS[:40] + ["word", "another", "text", "here", "it's", "well-known"]) for _ in range(rng.randint(2, 12))]
        sentences.append(" ".join(words) + rng.choice([".", "!", "?", ".", "..."]))
    return rng.choice([" ", "  ", " \t"]).join(sentences)


def fuzz_cases(rng):
    stage, pipeline = [], []

    def add(fn, text, *args):
        stage.append({"id": f"fuzz-{fn}-{sum(1 for c in stage if c['fn'] == fn) + 1:03d}", "fn": fn,
                      "args": list(args), "input": text})

    for _ in range(80):
        add("sanitize", soup(rng))
    for _ in range(80):
        add("fillers", soup(rng))
    for _ in range(80):
        add("repeats", soup(rng), rng.choice(["0", "1", "2", "3"]))
    for _ in range(60):
        add("british", soup(rng), rng.choice(["1", "1", "0"]))
    for _ in range(100):
        add("vocab", soup(rng), rng.choice(["cascade", "repo"]))

    words = ["so", "the", "plan", "is", "to", "ship", "it", "today", "tomorrow", "we", "can", "it's", "API",
             "test", "again", "and", "then", "done", "3", "v2", "ok"]
    for i in range(150):
        spoken = [rng.choice(words) for _ in range(rng.randint(8, 40))]
        cut = rng.randint(0, len(spoken))
        tail = spoken[max(0, cut - rng.randint(0, 6)):]
        if rng.random() < 0.3:
            tail = tail + [rng.choice(words) for _ in range(rng.randint(1, 4))]
        punct = lambda ws: "".join(w + rng.choice([" ", " ", ", ", ". ", "? ", " - "]) for w in ws).strip()
        full = punct(spoken[:rng.randint(cut, len(spoken))])
        tail_text = punct(tail)
        if rng.random() < 0.15:
            tail_text = tail_text.upper()
        if rng.random() < 0.1:
            tail_text = rng.choice(["", "  ", "\n", "\u00a0", tail_text + "\n" + tail_text])
        add("merge", full, tail_text)

    # Exercise only supported canonical environment controls.
    envs = [{}, {"KHULUMA_CLEAN": "1"}, {"KHULUMA_CLEAN": "1", "KHULUMA_REPEATS_LEVEL": "2"},
            {"KHULUMA_BRITISH_SPELLING": "0"}, {"KHULUMA_VOCAB_CLEAN": "0"}]
    for i in range(30):
        text = long_soup(rng) if rng.random() < 0.3 else soup(rng)
        pipeline.append({"id": f"fuzz-pipeline-{i + 1:03d}", "config": rng.choice(["repo", "cascade"]),
                         "env": rng.choice(envs), "input": text})
    return stage, pipeline


def config_path(name):
    return os.path.join(ROOT, "config") if name == "repo" else os.path.join(FIXTURES, "configs", name)


def prepare_config(name, dest):
    """Scratch copy of a fixture config dir."""
    shutil.copytree(config_path(name), dest, symlinks=True)


def merge_script():
    """The Python body of merge_transcript_chunks, taken from bin/khuluma."""
    with open(os.path.join(ROOT, "bin", "khuluma"), encoding="utf-8") as f:
        source = f.read()
    start = source.index("merge_transcript_chunks() {")
    body_start = source.index("<<'PYEOF'\n", start) + len("<<'PYEOF'\n")
    body_end = source.index("\nPYEOF\n", body_start)
    return source[body_start:body_end] + "\n"


def run_merge_cases(cases, work):
    """Tail-rescue merge: the CLI writes the full transcript and the tail
    transcript (newlines turned into spaces) as two lines, then merges."""
    os.makedirs(work)
    script = os.path.join(work, "merge.py")
    with open(script, "w", encoding="utf-8") as f:
        f.write(merge_script())
    results = []
    for idx, case in enumerate(cases):
        chunks = os.path.join(work, f"chunks-{idx}.txt")
        with open(chunks, "w", encoding="utf-8", newline="") as f:
            f.write(case["input"] + "\n" + case["args"][0].replace("\n", " ") + "\n")
        proc = subprocess.run([sys.executable, "-I", script, chunks], capture_output=True, check=True,
                              env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        results.append(dict(case, output=proc.stdout.decode("utf-8")))
    return results


def run_stage_cases(cases, work):
    os.makedirs(os.path.join(work, "in"))
    os.makedirs(os.path.join(work, "out"))
    with open(os.path.join(work, "manifest"), "w", encoding="utf-8", newline="") as manifest:
        for idx, case in enumerate(cases):
            with open(os.path.join(work, "in", str(idx)), "w", encoding="utf-8", newline="") as f:
                f.write(case["input"])
            args = list(case["args"]) + ["", ""]
            if case["fn"] == "vocab" or (case["fn"] == "fillers" and args[0]):
                args[0] = config_path(args[0])
            manifest.write("\x1f".join([str(idx), case["fn"], args[0], args[1], "END"]) + "\n")
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": work}
    subprocess.run(["bash", "-c", STAGE_RUNNER, "runner", ROOT, work], env=env, check=True)
    results = []
    for idx, case in enumerate(cases):
        with open(os.path.join(work, "out", str(idx)), "rb") as f:
            results.append(dict(case, output=f.read().decode("utf-8")))
    return results


def run_pipeline_cases(cases, work, recovery):
    results = []
    for idx, case in enumerate(cases):
        case_dir = os.path.join(work, f"p{idx}")
        home = os.path.join(case_dir, "home")
        cfg = os.path.join(case_dir, "config")
        os.makedirs(home)
        prepare_config(case["config"], cfg)
        env = {
            "HOME": home,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "TMPDIR": case_dir,
            "KHULUMA_TMPDIR": case_dir,
            "KHULUMA_TEST_RECOVERY_ROOT": recovery,
            "KHULUMA_LIB_PATH": os.path.join(ROOT, "bin", "khuluma-lib.sh"),
            "KHULUMA_INTERNAL_LIB_DIR": os.path.join(ROOT, "bin", "khuluma-lib"),
            "KHULUMA_CONFIG_DIR": cfg,
        }
        env.update(case["env"])
        proc = subprocess.run(
            [os.path.join(ROOT, "bin", "khuluma"), "inline", "cleanup", "--json"],
            input=case["input"].encode("utf-8"), env=env, capture_output=True)
        if proc.returncode != 0:
            sys.exit(f"{case['id']}: inline cleanup failed ({proc.returncode}): {proc.stderr.decode(errors='replace')}")
        out = json.loads(proc.stdout)
        settings = out["cleanup"]
        if settings["config_dir"] != cfg:
            sys.exit(f"{case['id']}: unexpected config_dir {settings['config_dir']!r}")
        settings["config_dir"] = "@config"
        results.append(dict(case, settings=settings, status=out["status"], raw_text=out["raw_text"],
                            text=out["text"]))
    return results


def generate():
    with open(CASES, encoding="utf-8") as f:
        cases = json.load(f)
    fuzz_stage, fuzz_pipeline = fuzz_cases(random.Random(SEED))
    stage = cases["stage"] + fuzz_stage
    pipeline = cases["pipeline"] + fuzz_pipeline
    ids = [c["id"] for c in stage + pipeline]
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    if duplicates:
        sys.exit(f"duplicate case ids: {duplicates}")
    merge = [c for c in stage if c["fn"] == "merge"]
    stage = [c for c in stage if c["fn"] != "merge"]
    # Retain generated fixtures for inspection and recoverable cleanup.
    work = os.path.realpath(tempfile.mkdtemp(prefix="khuluma-cleanup-fixtures."))
    print(f"Retained cleanup fixtures: {work}", file=sys.stderr)
    stage_results = run_stage_cases(stage, os.path.join(work, "stage"))
    stage_results += run_merge_cases(merge, os.path.join(work, "merge"))
    recovery = os.path.join(work, ".recovery")
    os.mkdir(recovery, 0o700)
    marker = os.path.join(recovery, ".khuluma-recovery-fixture")
    with open(marker, "w", encoding="utf-8") as file:
        json.dump({"schema_version": 1, "fixture_root": os.path.realpath(work)}, file)
    os.chmod(marker, 0o600)
    pipeline_results = run_pipeline_cases(pipeline, os.path.join(work, "pipeline"), recovery)
    document = {
        "generated_by": "tests/gen-cleanup-fixtures.sh (do not edit by hand)",
        "stage": stage_results,
        "pipeline": pipeline_results,
    }
    return json.dumps(document, ensure_ascii=False, indent=1) + "\n"


def main():
    check = "--check" in sys.argv[1:]
    generated = generate()
    if not check:
        with open(EXPECTED, "w", encoding="utf-8", newline="") as f:
            f.write(generated)
        print(f"wrote {os.path.relpath(EXPECTED, ROOT)}")
        return
    try:
        with open(EXPECTED, encoding="utf-8", newline="") as f:
            committed = f.read()
    except FileNotFoundError:
        sys.exit("expected.json is missing; run tests/gen-cleanup-fixtures.sh")
    if committed == generated:
        print("cleanup fixtures are up to date")
        return
    old = {c["id"]: c for c in json.loads(committed)["stage"] + json.loads(committed)["pipeline"]}
    new = {c["id"]: c for c in json.loads(generated)["stage"] + json.loads(generated)["pipeline"]}
    changed = sorted(i for i in old.keys() | new.keys() if old.get(i) != new.get(i))
    print("cleanup fixtures are stale: the bash cleanup or the cases changed.", file=sys.stderr)
    print(f"changed cases ({len(changed)}): {', '.join(changed[:20])}{' ...' if len(changed) > 20 else ''}", file=sys.stderr)
    print("Regenerate with tests/gen-cleanup-fixtures.sh, then make the Swift TextPipeline match.", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
