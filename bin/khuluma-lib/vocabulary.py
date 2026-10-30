#!/usr/bin/env python3
"""The app's local vocabulary document: validate, read and replace safely."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import unicodedata
import uuid

MAX_BYTES = 1_048_576
MAX_ENTRIES = 5000
DEFAULT_FILLERS = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "erm"]


MAX_EXAMPLES = 200


def validate_examples(examples):
    """Saved checks (heard text and the expected result). Cleanup ignores them."""
    if not isinstance(examples, list) or len(examples) > MAX_EXAMPLES:
        raise ValueError("examples must be a list of up to 200 entries.")
    result = []
    for example in examples:
        if not isinstance(example, dict) or set(example) != {"said", "expect"}:
            raise ValueError("Each example needs said and expect text.")
        for text in example.values():
            if not isinstance(text, str) or len(text) > 2000 or any(ord(c) < 32 or ord(c) == 127 for c in text):
                raise ValueError("Each example must be at most 2,000 characters on one line.")
        if not example["said"].strip():
            raise ValueError("Each example needs the text that was heard.")
        result.append({"said": example["said"], "expect": example["expect"]})
    return result


def validate(value):
    if not isinstance(value, dict) or set(value) - {"examples"} != {"schema_version", "fillers", "brands", "words"}:
        raise ValueError("Use schema_version, fillers, brands and words in the vocabulary JSON.")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("This vocabulary version is not supported. Use schema_version 1.")
    seen = set()
    total = 0

    def term(text):
        if not isinstance(text, str) or not text.strip() or len(text) > 200 or any(ord(c) < 32 or ord(c) == 127 for c in text):
            raise ValueError("Each word or phrase must be 1–200 characters on one line.")
        return text.strip()

    result = {"schema_version": 1, "fillers": [], "brands": [], "words": []}
    for section in ("fillers", "brands", "words"):
        if not isinstance(value[section], list):
            raise ValueError(f"{section} must be a list.")
        for entry in value[section]:
            total += 1
            if total > MAX_ENTRIES:
                raise ValueError("A vocabulary can contain up to 5,000 entries.")
            if section == "fillers":
                heard = term(entry)
                clean = heard
            else:
                if not isinstance(entry, dict) or set(entry) != {"heard", "write"}:
                    raise ValueError(f"Each {section} entry needs heard and write text.")
                heard = term(entry["heard"])
                clean = {"heard": heard, "write": term(entry["write"])}
            key = unicodedata.normalize("NFC", heard).lower()
            if key in seen:
                raise ValueError(f'“{heard}” appears more than once. Keep each heard phrase in one section.')
            seen.add(key)
            result[section].append(clean)
    examples = validate_examples(value.get("examples", []))
    if examples:
        result["examples"] = examples
    return result


def unique_fields(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"Duplicate JSON field: {key}")
        out[key] = value
    return out


def decode(raw):
    if len(raw) > MAX_BYTES:
        raise ValueError("Choose a vocabulary JSON file smaller than 1 MB.")
    return validate(json.loads(raw, object_pairs_hook=unique_fields))


def read_bounded(path):
    with path.open("rb") as file:
        raw = file.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("Choose a vocabulary JSON file smaller than 1 MB.")
    return raw


def state(root):
    sheet = root / "vocabulary.json"
    if sheet.is_symlink():
        raise ValueError("vocabulary.json must be a regular file, not a symbolic link.")
    if sheet.exists():
        raw = read_bounded(sheet)
        document = decode(raw)
        kind = b"json\0"
    else:
        legacy = root / "vocab"
        raw = read_bounded(legacy) if legacy.exists() else b""
        kind = b"text\0"
        document = {"schema_version": 1, "fillers": DEFAULT_FILLERS[:], "brands": [], "words": []}
        import re
        seen = {}
        for line in raw.decode("utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            pair = line.split("::", 1) if "::" in line else re.split(r"->|→", line, maxsplit=1)
            if len(pair) != 2 or not all(x.strip() for x in pair):
                raise ValueError("The existing vocab contains an invalid line. Correct it before opening Vocabulary.")
            heard, write = (x.strip() for x in pair)
            key = unicodedata.normalize("NFC", heard).lower()
            if key in seen:
                if seen[key] != write:
                    raise ValueError(f'Existing vocab has conflicting replacements for “{heard}”.')
                continue
            seen[key] = write
            document["words"].append({"heard": heard, "write": write})
        document = validate(document)
    return {"document": document, "revision": hashlib.sha256(kind + raw).hexdigest()}


def main():
    root = Path(sys.argv[1])
    action = sys.argv[2]
    if action == "validate":
        result = decode(sys.stdin.buffer.read(MAX_BYTES + 1))
    elif action == "show":
        result = state(root)
    elif action == "save":
        raw = sys.stdin.buffer.read(MAX_BYTES + 4096)
        if len(raw) > MAX_BYTES + 2048:
            raise ValueError("Choose a vocabulary JSON file smaller than 1 MB.")
        request = json.loads(raw, object_pairs_hook=unique_fields)
        if not isinstance(request, dict) or set(request) != {"document", "revision"}:
            raise ValueError("Save requires document and revision from vocab-sheet show --json.")
        document = validate(request["document"])
        encoded = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        if len(encoded) > MAX_BYTES:
            raise ValueError("Choose a vocabulary JSON file smaller than 1 MB.")
        root.mkdir(parents=True, exist_ok=True)
        lock = root / ".vocabulary.lock"
        if lock.is_symlink():
            raise ValueError("The vocabulary lock must not be a symbolic link.")
        with lock.open("a+b") as handle:
            os.chmod(lock, 0o600)
            fcntl.flock(handle, fcntl.LOCK_EX)
            current = state(root)
            if request.get("revision") != current["revision"]:
                raise ValueError("Vocabulary changed on disk. Reload it before saving; your draft has been kept.")
            sheet = root / "vocabulary.json"
            if current["document"] != document or not sheet.exists():
                if sheet.exists():
                    backups = root / "vocabulary-backups"
                    if backups.is_symlink():
                        raise ValueError("The vocabulary backup folder must not be a symbolic link.")
                    backups.mkdir(mode=0o700, exist_ok=True)
                    backup = backups / (str(uuid.uuid4()) + ".json")
                    with backup.open("xb") as old:
                        os.chmod(backup, 0o600)
                        old.write(sheet.read_bytes())
                        old.flush()
                        os.fsync(old.fileno())
                stage = root / (".vocabulary-" + str(uuid.uuid4()) + ".json")
                with stage.open("xb") as staged:
                    os.chmod(stage, 0o600)
                    staged.write(encoded)
                    staged.flush()
                    os.fsync(staged.fileno())
                os.replace(stage, sheet)
            result = state(root)
    else:
        raise ValueError("Use vocab-sheet show --json or vocab-sheet save --json.")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"Vocabulary: {error}", file=sys.stderr)
        sys.exit(2)
