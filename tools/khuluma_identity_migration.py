#!/usr/bin/env python3
"""Finite rename-v1 migration. No CLI/config loader, replay, daemon or shell eval.

The admission controller owns entry-point gates and process shutdown; this tool
verifies its current proof, refuses live writers, and only changes data paths.
It never kills a process or deletes a legacy tree. Dry-run creates no files.

Standalone inspection: --dry-run. Apply/resume/rollback require a reviewed,
active coordinator; no portable automated coordinator ships with this tool.
Do not fabricate receipts. Operator handoff and recovery procedure:
docs/INTEGRATIONS.md#identity-migration (in the canonical source checkout).

Admission receipt (owned regular 0600 JSON, lifetime <= 1 hour):
  schema_version=1, migration_version="rename-v1", state="gated",
  scope="fixture"|"live_controller", nonce=UUID, created_at/expires_at=epoch,
  controller={pid, uid, start_fingerprint}, roots={old/new_config/models/sounds},
  token_file=owned0600 nonce file,
  entrypoints=[{path, gate_sha256, backup_path, backup_sha256}],
  process_paths=[exact writer/daemon executable paths], processing_dirs=[...],
  socket_paths=[...], idle_lock_dirs=[bench/build/restart lock directories].
Each gate must match gate_bytes(nonce) exactly. Live start_fingerprint is the
current /bin/ps -p PID -o lstart= output; process-table failure refuses apply.
Fixture scope also requires fixture_root (0700), a private
.khuluma-migration-fixture nonce file, all inputs/roots inside it, and a live
fixture controller with start_fingerprint="fixture:"+nonce. Fixture mode does
not authorize any target outside that root.

Apply/resume stage data and publish cutover-staged, then release runtime/data
locks while the external gates remain active. Controlled startup uses the
pure staged helper. Resume with an owned0600 verification receipt commits:
  schema_version/migration_version/migration_id/nonce/roots/controller match,
  state="verified", created_at>=manifest.created_at, checks={cli_contract:3,
  serving_daemons:1, usage_schema:1, canonical_roots:true}.
The controller, not this data tool, owns route activation and OS/app checks.
"""
import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time
import tomllib
import uuid

VERSION = "rename-v1"
MARKER = ".khuluma-identity.json"
MANIFEST = Path(".migration/rename-v1/manifest.json")
STATE_NAMES = {"recorded-takes", "recorded-takes-history", "recorded-takes-bench"}
ACTIVE_CONFIGS = {Path("config.toml"), Path(".config.toml.last-good")}
FACTORY_MODELS = {"parakeet-tdt-0.6b-v3-coreml", "parakeet-tdt-0.6b-v2-coreml"}


class Refusal(Exception):
    pass


def require(condition):
    # Admission checks must remain active with PYTHONOPTIMIZE / python -O.
    if not condition:
        raise Refusal("admission receipt is invalid, stale, or does not prove these exact roots/gates")


def canonical(value):
    p = Path(value).expanduser()
    if not p.is_absolute() or ".." in p.parts:
        raise Refusal("paths must be absolute and must not contain '..'")
    return p.resolve(strict=False)


def owned(path, directory=None):
    """Check every existing component, including non-followed leaf links."""
    path = Path(path)
    for part in [path, *path.parents]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise Refusal(f"symlink path is not an owned migration input: {part}")
        if info.st_uid not in (0, os.getuid()):
            raise Refusal(f"migration path has an untrusted owner in its ancestors: {part}")
        # Root and system ancestors can belong to root, but the inspected leaf
        # and all descendants of a fixture/root must belong to this account.
        if part == path and info.st_uid != os.getuid():
            raise Refusal(f"migration input is not owned by this user: {part}")
    if path.exists() and directory is not None:
        kind = path.lstat().st_mode
        if (directory and not stat.S_ISDIR(kind)) or (not directory and not stat.S_ISREG(kind)):
            raise Refusal(f"expected an owned regular {'directory' if directory else 'file'}: {path}")
    return path


def checked_path(value):
    # Check before resolution so a symlink root cannot disappear into realpath.
    p = Path(value).expanduser()
    if not p.is_absolute() or ".." in p.parts:
        raise Refusal("paths must be absolute and must not contain '..'")
    # /tmp and macOS /var are system aliases; resolve those ancestors once.
    if str(p).startswith("/tmp/"):
        p = Path("/private/tmp") / p.relative_to("/tmp") if Path("/private/tmp").exists() else p
    elif str(p).startswith("/var/") and Path("/private/var").exists():
        p = Path("/private/var") / p.relative_to("/var")
    owned(p)
    return p


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def private_json(path):
    owned(path, False)
    info = path.stat()
    if info.st_mode & 0o077:
        raise Refusal(f"receipt must be private (0600): {path}")
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (ValueError, UnicodeError) as exc:
        raise Refusal(f"invalid JSON object: {path}") from exc


def atomic_json(path, value):
    durable_mkdir(path.parent)
    temporary = path.parent / ("." + path.name + "." + uuid.uuid4().hex + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    fsync_directory(path.parent)


def fsync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def durable_mkdir(path):
    missing, current = [], path
    while not current.exists():
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        owned(directory)
        directory.mkdir(mode=0o700)
        fsync_directory(directory)
        fsync_directory(directory.parent)


def exclusive_rename(source, destination, identity):
    owned(source, True)
    owned(destination)
    info = source.stat()
    if {"dev": info.st_dev, "ino": info.st_ino} != identity:
        raise Refusal("resource inode changed; no move performed")
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin" and hasattr(libc, "renamex_np"):
        call = libc.renamex_np
        call.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        result = call(os.fsencode(source), os.fsencode(destination), 0x00000004)
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        call = libc.renameat2
        call.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        result = call(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    else:
        raise Refusal("atomic exclusive directory rename is unavailable; no fallback copy/move")
    if result != 0:
        raise Refusal("exclusive resource move refused; source and raced destination retained: " + os.strerror(ctypes.get_errno()))
    moved = destination.stat()
    if {"dev": moved.st_dev, "ino": moved.st_ino} != identity:
        raise Refusal("moved resource inode does not match the recorded candidate; inspect retained paths")
    fsync_directory(source.parent)
    fsync_directory(destination.parent)


def gate_bytes(nonce):
    return ("#!/bin/sh\n# khuluma-identity-gate rename-v1 " + nonce + "\n"
            "printf '%s\\n' 'Khuluma identity migration in progress; retry after cutover.' >&2\n"
            "exit 75\n").encode()


def process_fingerprint(pid):
    try:
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid=,lstart="],
                                capture_output=True, check=True, text=True)
        parts = result.stdout.strip().split(None, 1)
        if len(parts) != 2 or int(parts[0]) != os.getuid():
            raise ValueError()
        return parts[1]
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise Refusal("cannot establish current admission-controller process identity") from exc


def admit(path, roots, idle=True):
    if path is None:
        raise Refusal("apply/resume/rollback require a verified admission receipt from an active coordinator; no writers were stopped. See docs/INTEGRATIONS.md#identity-migration; do not fabricate a receipt")
    receipt = private_json(checked_path(path))
    try:
        require(type(receipt["schema_version"]) is int and receipt["schema_version"] == 1 and receipt["migration_version"] == VERSION)
        require(receipt["state"] == "gated")
        nonce = str(uuid.UUID(receipt["nonce"]))
        require(nonce == receipt["nonce"])
        require(receipt["created_at"] <= time.time() < receipt["expires_at"])
        require(0 < receipt["expires_at"] - receipt["created_at"] <= 3600)
        controller = receipt["controller"]
        require(type(controller["uid"]) is int and controller["uid"] == os.getuid())
        require(type(controller["pid"]) is int and controller["pid"] > 0)
        os.kill(controller["pid"], 0)
        actual_roots = {k: str(checked_path(v)) for k, v in receipt["roots"].items()}
        require(actual_roots == {k: str(v) for k, v in roots.items()})
        scope = receipt["scope"]
        require(scope in ("fixture", "live_controller"))
        token = checked_path(receipt["token_file"])
        owned(token, False)
        require(not token.stat().st_mode & 0o077 and token.read_text().strip() == nonce)
        endpoints = receipt["entrypoints"]
        require(isinstance(endpoints, list) and endpoints)
        inputs = [checked_path(path), token]
        for endpoint in endpoints:
            gate, backup = checked_path(endpoint["path"]), checked_path(endpoint["backup_path"])
            owned(gate, False)
            owned(backup, False)
            require(gate != backup)
            require(gate.read_bytes() == gate_bytes(nonce))
            require(sha(gate) == endpoint["gate_sha256"] and sha(backup) == endpoint["backup_sha256"])
            inputs += [gate, backup]
        for key in ("process_paths", "processing_dirs", "socket_paths", "idle_lock_dirs"):
            require(isinstance(receipt[key], list))
            inputs += [checked_path(p) for p in receipt[key]]
        if scope == "fixture":
            fixture = checked_path(receipt["fixture_root"])
            sentinel = fixture / ".khuluma-migration-fixture"
            owned(fixture, True)
            owned(sentinel, False)
            require(not sentinel.stat().st_mode & 0o077)
            require(not fixture.stat().st_mode & 0o077)
            require(sentinel.read_text().strip() == nonce)
            require(controller["start_fingerprint"] == "fixture:" + nonce)
            require(fixture != Path.home().resolve() and fixture != Path("/"))
            require(all(p != fixture and p.is_relative_to(fixture) for p in [*roots.values(), *inputs]))
        else:
            require(controller["start_fingerprint"] == process_fingerprint(controller["pid"]))
            require(receipt["process_paths"])
        if idle:
            idle_runtime(receipt)
    except (KeyError, AssertionError, TypeError, ValueError, OSError) as exc:
        raise Refusal("admission receipt is invalid, stale, unowned, or does not prove these exact roots/gates") from exc
    return receipt


def idle_runtime(receipt):
    for value in receipt["processing_dirs"]:
        p = checked_path(value)
        if p.exists() and any(p.iterdir()):
            raise Refusal(f"processing markers remain; controller must drain takes first: {p}")
    for value in receipt["idle_lock_dirs"]:
        if checked_path(value).exists():
            raise Refusal(f"runtime lock directory remains; ownership must be resolved: {value}")
    for value in receipt["socket_paths"]:
        p = checked_path(value)
        if p.exists():
            # Even a stale socket is not migration data; its lifecycle owner
            # must retire it. No socket deletion, probe request, or PID kill.
            raise Refusal(f"socket remains; controller must stop/drain its owner: {p}")
    if receipt["scope"] == "live_controller":
        try:
            result = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True,
                                    check=True, text=True)
            for line in result.stdout.splitlines():
                columns = line.strip().split(None, 1)
                if len(columns) != 2 or int(columns[0]) in (os.getpid(), receipt["controller"]["pid"]):
                    continue
                # ps flattens argv, so shlex.split cannot recover a pathname
                # containing spaces. Conservative boundaries also catch that
                # path; an ambiguous match refuses rather than miss a writer.
                if any(re.search(r"(?:^|[\s\x27\x22])" + re.escape(p) + r"(?=$|[\s\x27\x22;])", columns[1])
                       or re.search(r"(?:^|[\s/\x27\x22])" + re.escape(Path(p).name) + r"(?=$|[\s\x27\x22;])", columns[1])
                       for p in receipt["process_paths"]):
                    raise Refusal("a recorded writer/daemon process is still running")
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raise Refusal("cannot establish writer quiescence; current runtime was not changed") from exc


def env_value(new, old, fallback):
    return os.environ.get(new) or os.environ.get(old) or str(fallback)


def resolve_roots(args):
    home = checked_path(os.environ.get("HOME", str(Path.home())))
    config = checked_path(os.environ.get("XDG_CONFIG_HOME", str(home / ".config")))
    data = checked_path(os.environ.get("XDG_DATA_HOME", str(home / ".local/share")))
    custom_config = env_value("KHULUMA_CONFIG_DIR", "DICTATE_CONFIG_DIR", "") or None
    custom_models = env_value("KHULUMA_PARAKEET_MODELS_DIR", "DICTATE_PARAKEET_MODELS_DIR", "") or None
    custom_sounds = env_value("KHULUMA_SOUNDS_DIR", "DICTATE_SOUNDS_DIR", "") or None
    values = {
        "old_config": args.old_config or custom_config or config / "dictate",
        "new_config": args.new_config or custom_config or config / "khuluma",
        "old_models": args.old_models or custom_models or data / "tmux-whisper/models",
        "new_models": args.new_models or custom_models or data / "khuluma/models",
        "old_sounds": args.old_sounds or custom_sounds or data / "sounds/dictate",
        "new_sounds": args.new_sounds or custom_sounds or data / "sounds/khuluma",
    }
    roots = {k: checked_path(v) for k, v in values.items()}
    for p in roots.values():
        owned(p, True)
        if p == Path("/") or p == home:
            raise Refusal("a migration root cannot be the home or filesystem root")
    for old, new in (("old_config", "new_config"), ("old_models", "new_models"), ("old_sounds", "new_sounds")):
        if roots[old] != roots[new] and (roots[old].is_relative_to(roots[new]) or roots[new].is_relative_to(roots[old])):
            raise Refusal("source and destination roots must not contain each other")
    state_path = roots["new_config"] / MANIFEST
    continuing = args.mode in ("resume", "rollback")
    saved = private_json(state_path) if state_path.exists() else None
    if saved and (continuing or saved.get("state") == "committed"):
        # Resume/rollback root identity comes from the recorded transaction,
        # not a model setting that may have changed after successful delivery.
        for resource, env_names in (("models", ("KHULUMA_PARAKEET_MODELS_DIR", "DICTATE_PARAKEET_MODELS_DIR")),
                                    ("sounds", ("KHULUMA_SOUNDS_DIR", "DICTATE_SOUNDS_DIR"))):
            for side in ("old", "new"):
                key = side + "_" + resource
                if not getattr(args, key) and not any(os.environ.get(name) for name in env_names):
                    roots[key] = checked_path(saved["roots"][key])
        continuing = True
    # A configured model path is explicit, unlike the blank generated default.
    # If it pins a file inside the old default model tree, preserve that whole
    # tree in place; moving it would break a deliberately old-looking override.
    config_file = env_value("KHULUMA_CONFIG_FILE", "DICTATE_CONFIG_FILE", roots["old_config"] / "config.toml")
    config_path = checked_path(config_file)
    cfg = {}
    external_config = config_path != roots["old_config"] / "config.toml"
    if config_path.exists() and not external_config and not continuing:
        try:
            with open(config_path, "rb") as handle:
                cfg = tomllib.load(handle)
        except (ValueError, UnicodeError) as exc:
            raise Refusal("invalid explicit configuration; originals preserved") from exc
    if external_config and not continuing:
        # Do not inspect an independently pinned external config just to rename
        # defaults. Its resource references remain explicit and untouched.
        roots["new_models"] = roots["old_models"]
        roots["new_sounds"] = roots["old_sounds"]
    runtime_model = env_value("KHULUMA_SWIFT_PARAKEET_MODEL_PATH", "DICTATE_SWIFT_PARAKEET_MODEL_PATH", "")
    model_path = runtime_model or cfg.get("swift_parakeet", {}).get("model_path", "")
    known_factory = (not runtime_model and model_path and any(canonical(model_path) == roots["old_models"] / name for name in FACTORY_MODELS))
    if not continuing and model_path and canonical(model_path).is_relative_to(roots["old_models"]) and not known_factory:
        roots["new_models"] = roots["old_models"]
    for event in ("start", "stop", "process", "error", "cancel"):
        value = cfg.get("audio", {}).get("sounds", {}).get(event)
        if not isinstance(value, str) or not value or "$" in value:
            continue
        default = value in (str(roots["old_sounds"] / (event + ".wav")),
                            "~/.local/share/sounds/dictate/" + event + ".wav")
        if not continuing and not default and canonical(value).is_relative_to(roots["old_sounds"]):
            roots["new_sounds"] = roots["old_sounds"]
    items = list(roots.items())
    for index, (name, path) in enumerate(items):
        for other_name, other in items[index+1:]:
            same_resource = name.split("_", 1)[1] == other_name.split("_", 1)[1]
            if same_resource and path == other:
                continue
            if path == other or path.is_relative_to(other) or other.is_relative_to(path):
                raise Refusal("config/model/sound roots must not overlap; custom paths were not moved")
    return roots


def regular_files(root, exclude_internal=False):
    if not root.exists():
        return []
    result = []
    for folder, directories, files in os.walk(root, followlinks=False):
        directories[:] = [d for d in sorted(directories) if not (exclude_internal and Path(folder) == root and d == ".migration")]
        for name in directories + files:
            owned(Path(folder) / name)
        for name in sorted(files):
            p = Path(folder) / name
            if exclude_internal and p == root / MARKER:
                continue
            kind = p.lstat().st_mode
            if not stat.S_ISREG(kind):
                if stat.S_ISSOCK(kind):
                    raise Refusal(f"socket present; quiesce its lifecycle owner first: {p}")
                raise Refusal(f"non-regular file in data root: {p}")
            result.append(p)
    return result


def validate_critical(path, relative):
    try:
        if relative == Path("config.toml"):
            with open(path, "rb") as handle:
                config = tomllib.load(handle)
            if config.get("meta", {}).get("config_version") != 1:
                raise ValueError("unsupported config schema")
        if relative == Path("usage.json"):
            payload = json.loads(path.read_bytes())
            if payload.get("schema_version") != 1:
                raise ValueError("unsupported usage schema")
            counts = payload["delivered_dictations"]
            numbers = [counts["count"], counts["by_flow"]["inline"], counts["by_flow"]["tmux"],
                       payload["processed_words"], payload["recording_duration_ms"], payload["full_elapsed_duration_ms"]]
            if not all(type(n) is int and n >= 0 for n in numbers):
                raise ValueError("malformed usage counts")
            if "recent_take_ids" in payload and not isinstance(payload["recent_take_ids"], dict):
                raise ValueError("malformed take IDs")
            if "daily" in payload:
                daily = payload["daily"]
                if not isinstance(daily, dict) or type(daily.get("baseline_count")) is not int or daily["baseline_count"] < 0 or not isinstance(daily.get("days"), dict):
                    raise ValueError("malformed daily usage")
                for day, bucket in daily["days"].items():
                    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day) or not isinstance(bucket, dict):
                        raise ValueError("malformed daily bucket")
                    for key in ("count", "inline", "tmux", "words", "recording_ms", "full_elapsed_ms", "longest_recording_ms", "most_words"):
                        if type(bucket.get(key)) is not int or bucket[key] < 0:
                            raise ValueError("malformed daily bucket counts")
        if relative == Path("vocab"):
            path.read_bytes().decode("utf-8")
        if relative.suffix == ".json" and relative.parts[0] == "history":
            if not isinstance(json.loads(path.read_bytes()), dict):
                raise ValueError("malformed history")
    except (ValueError, TypeError, KeyError, UnicodeError) as exc:
        raise Refusal(f"malformed or unsupported critical data: {path}") from exc


def rewrite(data, relative, roots, reverse=False, reference_map=None, config_reference_map=None):
    old, new = roots["old_config"], roots["new_config"]
    old_models, new_models = roots["old_models"], roots["new_models"]
    old_sounds, new_sounds = roots["old_sounds"], roots["new_sounds"]
    if reverse:
        old, new = new, old
        old_models, new_models = new_models, old_models
        old_sounds, new_sounds = new_sounds, old_sounds
    # Only known factory defaults are eligible; explicit model_path and custom
    # sound/socket values retain the exact user's choice, including old names.
    if relative in ACTIVE_CONFIGS:
        try:
            text = data.decode("utf-8")
            tomllib.loads(text)
        except (ValueError, UnicodeError):
            if relative.name == "config.toml":
                raise Refusal("invalid config; originals preserved")
            return data
        section = ""
        output = []
        old_label, new_label = ("khulumad", "tmux-whisperd") if reverse else ("tmux-whisperd", "khulumad")
        for line in text.splitlines(keepends=True):
            match = re.match(r"\s*\[([^]]+)\]", line)
            if match:
                section = match.group(1)
            match = re.match(r'(\s*([\w_]+)\s*=\s*)("(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)(.*)', line)
            if match:
                key = match.group(2)
                try:
                    value = tomllib.loads("v=" + match.group(3))["v"]
                except ValueError:
                    value = None
                replacement = None
                if section == "swift_parakeet" and key == "socket_path":
                    defaults = {str(old / (".cache/" + old_label + ".sock"))}
                    if not reverse:
                        defaults.add("~/.config/dictate/.cache/tmux-whisperd.sock")
                    if value in defaults:
                        replacement = str(new / (".cache/" + new_label + ".sock"))
                if section == "audio.sounds" and key in ("start", "stop", "process", "error", "cancel") and old_sounds != new_sounds:
                    defaults = {str(old_sounds / (key + ".wav"))}
                    if not reverse:
                        defaults.add("~/.local/share/sounds/dictate/" + key + ".wav")
                    if value in defaults:
                        replacement = str(new_sounds / (key + ".wav"))
                    elif reverse and isinstance(value, str) and value.startswith(str(old_sounds) + "/"):
                        replacement = str(new_sounds) + value[len(str(old_sounds)):]
                if reverse and section == "swift_parakeet" and key == "model_path" and old_models != new_models and isinstance(value, str) and value.startswith(str(old_models) + "/"):
                    replacement = str(new_models) + value[len(str(old_models)):]
                if not reverse and section == "swift_parakeet" and key == "model_path" and old_models != new_models and isinstance(value, str) and value:
                    for model in FACTORY_MODELS:
                        if canonical(value) == old_models / model:
                            replacement = str(new_models / model)
                prior_reference = (config_reference_map or {}).get(section + "." + key)
                if reverse and prior_reference and value == prior_reference["new"]:
                    replacement = prior_reference["old"]
                if replacement is not None:
                    newline = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
                    line = match.group(1) + json.dumps(replacement, ensure_ascii=False) + match.group(4).rstrip("\r\n") + newline
            output.append(line)
        return "".join(output).encode()
    if relative.parts[0] == "history" and relative.suffix == ".json" and old != new:
        payload = json.loads(data)
        audio = payload.get("audio")
        prefix = audio.get("debug_archive_prefix") if isinstance(audio, dict) else None
        if isinstance(prefix, str) and prefix.startswith(str(old / "history") + "/"):
            audio["debug_archive_prefix"] = (reference_map or {}).get(prefix,
                str(new / "history") + prefix[len(str(old / "history")):])
            return (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode()
    return data


def transformed_bytes(source, relative, roots, **options):
    if relative in ACTIVE_CONFIGS or (relative.parts[0] == "history" and relative.suffix == ".json"):
        original = source.read_bytes()
        transformed = rewrite(original, relative, roots, **options)
        if relative in ACTIVE_CONFIGS and not options.get("reverse"):
            try:
                before, after = tomllib.loads(original.decode()), tomllib.loads(transformed.decode())
            except (ValueError, UnicodeError):
                return transformed  # invalid last-good remains inert, never activated
            expected = {}
            swift = before.get("swift_parakeet", {})
            socket_value = swift.get("socket_path")
            if socket_value in (str(roots["old_config"] / ".cache/tmux-whisperd.sock"), "~/.config/dictate/.cache/tmux-whisperd.sock"):
                expected[("swift_parakeet", "socket_path")] = str(roots["new_config"] / ".cache/khulumad.sock")
            if roots["old_models"] != roots["new_models"] and isinstance(swift.get("model_path"), str) and swift["model_path"]:
                for name in FACTORY_MODELS:
                    if canonical(swift["model_path"]) == roots["old_models"] / name:
                        expected[("swift_parakeet", "model_path")] = str(roots["new_models"] / name)
            sounds = before.get("audio", {}).get("sounds", {})
            if roots["old_sounds"] != roots["new_sounds"]:
                for event in ("start", "stop", "process", "error", "cancel"):
                    if sounds.get(event) in (str(roots["old_sounds"] / (event + ".wav")), "~/.local/share/sounds/dictate/" + event + ".wav"):
                        expected[("audio", "sounds", event)] = str(roots["new_sounds"] / (event + ".wav"))
            for components, value in expected.items():
                current = after
                for component in components:
                    current = current.get(component) if isinstance(current, dict) else None
                if current != value:
                    raise Refusal("a factory path uses unsupported TOML syntax; originals preserved, no resource may move")
        return transformed
    return None  # opaque audio/backups/archives copy in bounded streaming chunks


def runtime_relative(relative):
    if relative.name.endswith(".lock") or relative.name == "bench.tsv.lock.d":
        return True
    return relative.parts[0] == ".cache" and relative.name not in STATE_NAMES


def tree_fingerprint(root):
    files = regular_files(root)
    digest = hashlib.sha256()
    for directory, children, _ in os.walk(root, followlinks=False):
        children.sort()
        p = Path(directory)
        info = p.stat()
        digest.update((str(p.relative_to(root)) + "\0dir\0" + str(stat.S_IMODE(info.st_mode)) + "\0" + str(info.st_mtime_ns)).encode())
    for p in files:
        info = p.stat()
        digest.update((str(p.relative_to(root)) + "\0" + sha(p) + "\0" + str(stat.S_IMODE(info.st_mode)) + "\0" + str(info.st_mtime_ns)).encode())
    return {"sha256": digest.hexdigest(), "files": len(files), "bytes": sum(p.stat().st_size for p in files)}


def nearest_parent(path):
    while not path.exists():
        path = path.parent
    return path


def plan(roots):
    old, new = roots["old_config"], roots["new_config"]
    if len(str(new / ".cache/khulumad.sock").encode("utf-8")) >= 104:
        raise Refusal("canonical socket path exceeds the macOS Unix-socket byte limit")
    entries, conflicts = [], []
    for source in regular_files(old, exclude_internal=True):
        relative = source.relative_to(old)
        validate_critical(source, relative)
        info = source.stat()
        original_hash = sha(source)
        transformed = transformed_bytes(source, relative, roots)
        expected = hashlib.sha256(transformed).hexdigest() if transformed is not None else original_hash
        destination = new / relative
        action = "preserve_in_backup" if runtime_relative(relative) else "copy"
        if old == new:
            action = "rewrite_in_place" if expected != original_hash and not runtime_relative(relative) else "preserve_custom_root"
        if destination.exists() and action == "copy":
            owned(destination, False)
            if (sha(destination) == expected and stat.S_IMODE(destination.stat().st_mode) == stat.S_IMODE(info.st_mode)
                    and destination.stat().st_mtime_ns == info.st_mtime_ns):
                action = "identical"
            elif relative.parts[0] == "history":
                action = "history_collision"
            else:
                conflicts.append(str(destination))
        entries.append({"relative": str(relative), "source": str(source), "destination": str(destination),
                        "sha256": original_hash, "target_sha256": expected, "bytes": info.st_size,
                        "mode": stat.S_IMODE(info.st_mode), "mtime_ns": info.st_mtime_ns,
                        "action": action, "state": "planned"})
    # A debug WAV and sidecars are one group. If one name collides, assign one
    # stable alternative stem to every source member, not separate hash names.
    groups = {}
    for entry in entries:
        relative = Path(entry["relative"])
        if relative.parts[0] != "history":
            continue
        name = relative.name
        suffix = ".transcribe.log" if name.endswith(".transcribe.log") else relative.suffix
        stem = name[:-len(suffix)] if suffix else name
        groups.setdefault((relative.parent, stem), []).append((entry, suffix))
    references = {}
    for (parent, stem), members in groups.items():
        if not any(entry["action"] == "history_collision" for entry, _ in members):
            continue
        suffix_hash = hashlib.sha256("".join(entry["sha256"] for entry, _ in members).encode()).hexdigest()[:12]
        references[str(old / parent / stem)] = str(new / parent / (stem + ".rename-v1-" + suffix_hash))
        for entry, suffix in members:
            destination = new / parent / (stem + ".rename-v1-" + suffix_hash + suffix)
            if destination.exists() and sha(destination) != entry["target_sha256"]:
                conflicts.append(str(destination))
            entry.update(destination=str(destination), action="copy")
    if references:
        for entry in entries:
            data = transformed_bytes(Path(entry["source"]), Path(entry["relative"]), roots, reference_map=references)
            entry["target_sha256"] = hashlib.sha256(data).hexdigest() if data is not None else entry["sha256"]
            destination = Path(entry["destination"])
            if entry["action"] in ("copy", "identical") and destination.exists() and sha(destination) != entry["target_sha256"]:
                conflicts.append(str(destination))
    config_references = {}
    for entry in entries:
        if Path(entry["relative"]) not in ACTIVE_CONFIGS or entry["sha256"] == entry["target_sha256"]:
            continue
        before = Path(entry["source"]).read_bytes()
        after = rewrite(before, Path(entry["relative"]), roots)
        original, transformed = tomllib.loads(before.decode()), tomllib.loads(after.decode())
        changes = {}
        for section, keys in (("swift_parakeet", ("socket_path", "model_path")), ("audio.sounds", ("start", "stop", "process", "error", "cancel"))):
            left, right = original, transformed
            for component in section.split("."):
                left, right = left.get(component, {}), right.get(component, {})
            for key in keys:
                if left.get(key) != right.get(key):
                    changes[section + "." + key] = {"old": left.get(key), "new": right.get(key)}
        config_references[entry["relative"]] = changes
    # Target critical files must be valid even if no corresponding legacy file.
    for target in regular_files(new, exclude_internal=True) if new != old else []:
        validate_critical(target, target.relative_to(new))
    moves = []
    for resource in ("models", "sounds"):
        source, destination = roots["old_" + resource], roots["new_" + resource]
        if source == destination or not source.exists():
            continue
        info = tree_fingerprint(source)
        if destination.exists():
            if tree_fingerprint(destination) == info:
                action = "identical"
            else:
                conflicts.append(str(destination))
                action = "conflict"
        else:
            if source.stat().st_dev != nearest_parent(destination).stat().st_dev:
                raise Refusal(f"{resource} relocation crosses volumes; no copy/download is performed")
            action = "rename"
        moves.append({"resource": resource, "source": str(source), "destination": str(destination),
                      "identity": {"dev": source.stat().st_dev, "ino": source.stat().st_ino},
                      "fingerprint": info, "action": action, "state": "planned"})
    if conflicts:
        raise Refusal("destination conflicts; nothing overwritten or summed: " + ", ".join(conflicts))
    return {"schema_version": 1, "migration_version": VERSION, "roots": {k: str(v) for k, v in roots.items()},
            "entries": entries, "moves": moves, "reference_map": references, "config_reference_map": config_references,
            "state": "dry-run", "counts": {"files": len(entries),
            "bytes": sum(e["bytes"] for e in entries), "resource_moves": sum(m["action"] == "rename" for m in moves)}}


@contextlib.contextmanager
def held_locks(roots, state_dir, data=True):
    # Admission -> old/new lifecycle (stable paths) -> last-good -> usage.
    # Kernel flocks, not pathname existence, establish ownership. Never remove
    # or rename a held inode. Apply refuses sockets/marker/mkdir lock evidence.
    paths = [state_dir / "admission.lock"]
    for category in ("lifecycle", "last_good", "usage") if data else ():
        group = []
        for key, name in (("old_config", "tmux-whisperd"), ("new_config", "khulumad")):
            root = roots[key]
            if category == "lifecycle":
                group.append(root / (".cache/" + name + ".sock.lifecycle.lock"))
            elif category == "last_good":
                group.append(root / ".config.toml.last-good.lock")
            else:
                group.append(root / "usage.json.lock")
        paths += sorted(set(group), key=str)
    descriptors = []
    try:
        for path in paths:
            owned(path)
            durable_mkdir(path.parent)
            if path.parent == state_dir and state_dir.stat().st_mode & 0o077:
                raise Refusal("migration state directory must be private (0700)")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(fd)
                raise Refusal(f"writer lock is held; no lock was removed: {path}")
            descriptors.append(fd)
        yield
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def write_copy(source, destination, mode, mtime_ns, data=None):
    owned(destination)
    durable_mkdir(destination.parent)
    if destination.exists():
        return
    temporary = destination.parent / ("." + destination.name + ".copy-" + uuid.uuid4().hex + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "wb") as handle:
        if data is None:
            with open(source, "rb") as original:
                shutil.copyfileobj(original, handle)
        else:
            handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, mode)
    os.utime(temporary, ns=(mtime_ns, mtime_ns))
    fd = os.open(temporary, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    os.link(temporary, destination)  # publish only a fully fsynced copy, no overwrite
    fsync_directory(destination.parent)
    # The owned temporary hard link remains inside private recovery material.
    # An interrupted copy leaves only that partial temp, never a partial target.


def marker_for(manifest):
    return {k: manifest[k] for k in ("schema_version", "migration_version", "migration_id", "nonce", "state")} | {"config_root": manifest["roots"]["new_config"]}


def load_manifest(path, roots):
    value = private_json(path)
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1 or value.get("migration_version") != VERSION or value.get("roots") != {k: str(v) for k, v in roots.items()}:
        raise Refusal("manifest does not describe these exact roots")
    for name in ("migration_id", "nonce"):
        try:
            if not isinstance(value[name], str) or str(uuid.UUID(value[name])) != value[name]:
                raise ValueError()
        except (KeyError, TypeError, ValueError) as exc:
            raise Refusal("manifest migration_id/nonce must be canonical UUIDs") from exc
    if value.get("state") not in ("prepared", "cutover-staged", "committed", "rolled-back") or not isinstance(value.get("entries"), list) or not isinstance(value.get("moves"), list):
        raise Refusal("unsupported manifest state or operations")
    for entry in value.get("entries", []):
        relative = Path(entry["relative"])
        if relative.is_absolute() or ".." in relative.parts or not relative.parts or relative.parts[0] in (".migration", MARKER):
            raise Refusal("manifest has an escaping relative path")
        source, destination = checked_path(entry["source"]), checked_path(entry["destination"])
        if source != roots["old_config"] / relative or not destination.is_relative_to(roots["new_config"]):
            raise Refusal("manifest entry escapes its source/destination roots")
        default_destination = roots["new_config"] / relative
        if destination != default_destination:
            suffix = ".transcribe.log" if relative.name.endswith(".transcribe.log") else relative.suffix
            stem = relative.name[:-len(suffix)] if suffix else relative.name
            if (relative.parts[0] != "history" or destination.parent != default_destination.parent
                    or not re.fullmatch(re.escape(stem) + r"\.rename-v1-[0-9a-f]{12}" + re.escape(suffix), destination.name)):
                raise Refusal("manifest destination does not match the bounded rename mapping")
        if entry["action"] not in ("copy", "identical", "preserve_in_backup", "preserve_custom_root", "rewrite_in_place"):
            raise Refusal("unsupported manifest operation")
        if entry["action"] == "rewrite_in_place" and (roots["old_config"] != roots["new_config"] or relative not in ACTIVE_CONFIGS):
            raise Refusal("in-place rewriting is limited to config defaults in the preserved custom root")
        if (type(entry.get("mode")) is not int or not 0 <= entry["mode"] <= 0o777
                or type(entry.get("mtime_ns")) is not int or type(entry.get("bytes")) is not int
                or entry["bytes"] < 0 or not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", ""))
                or not re.fullmatch(r"[0-9a-f]{64}", entry.get("target_sha256", ""))):
            raise Refusal("manifest file metadata is invalid")
    for move in value.get("moves", []):
        if move["resource"] not in ("models", "sounds") or move["source"] != str(roots["old_" + move["resource"]]) or move["destination"] != str(roots["new_" + move["resource"]]):
            raise Refusal("manifest resource move escapes its declared roots")
        if (move.get("action") not in ("rename", "identical") or not isinstance(move.get("identity"), dict)
                or any(type(move["identity"].get(k)) is not int for k in ("dev", "ino"))):
            raise Refusal("manifest resource identity is invalid")
    return value


def verify_source_snapshot(manifest, roots):
    current = {str(p.relative_to(roots["old_config"])): p for p in
               regular_files(roots["old_config"], exclude_internal=True)
               if not runtime_relative(p.relative_to(roots["old_config"]))}
    expected = {entry["relative"]: entry for entry in manifest["entries"]
                if not runtime_relative(Path(entry["relative"]))}
    if current.keys() != expected.keys():
        raise Refusal("source inventory changed since preparation; new/missing data retained, re-plan required")
    for name, path in current.items():
        entry, info = expected[name], path.stat()
        digest = sha(path)
        allowed = (entry["sha256"], entry["target_sha256"]) if entry["action"] == "rewrite_in_place" else (entry["sha256"],)
        if (digest not in allowed
                or info.st_mtime_ns != entry["mtime_ns"] or stat.S_IMODE(info.st_mode) != entry["mode"]):
            raise Refusal(f"source changed since preparation: {path}")


def finalize(args, manifest, manifest_path, roots):
    # This phase intentionally allows a new canonical daemon socket and normal
    # locks. Admission gates remain verified; old writers must stay gated.
    receipt = admit(args.admission_receipt, roots, idle=False)
    verification_path = checked_path(args.verification_receipt)
    if receipt["nonce"] != manifest["nonce"] or (receipt["scope"] == "fixture" and not verification_path.is_relative_to(checked_path(receipt["fixture_root"]))):
        raise Refusal("verification/admission proof does not belong to this migration")
    verification = private_json(verification_path)
    checks = verification.get("checks", {})
    if any(verification.get(k) != manifest.get(k) for k in ("migration_id", "nonce", "roots")) or verification.get("state") != "verified":
        raise Refusal("verification receipt does not prove this staged cutover")
    if (verification.get("schema_version") != 1 or verification.get("migration_version") != VERSION
            or verification.get("controller") != receipt["controller"]
            or not manifest["created_at"] <= verification.get("created_at", 0) <= time.time()
            or checks.get("cli_contract") != 3 or checks.get("serving_daemons") != 1
            or checks.get("usage_schema") != 1 or checks.get("canonical_roots") is not True):
        raise Refusal("controlled numeric/layout verification is incomplete or stale")
    with held_locks(roots, manifest_path.parent, data=False):
        current = load_manifest(manifest_path, roots)
        if current["state"] != "cutover-staged" or current["migration_id"] != manifest["migration_id"]:
            raise Refusal("cutover state changed before verification publication")
        manifest["state"] = "committed"
        manifest["verification"] = {"path": str(args.verification_receipt), "sha256": sha(args.verification_receipt)}
        atomic_json(manifest_path, manifest)
        atomic_json(roots["new_config"] / MARKER, marker_for(manifest))
    return {"state": "committed", "migration_id": manifest["migration_id"], "counts": manifest["counts"]}


def mutate(args, roots):
    state_dir = roots["new_config"] / MANIFEST.parent
    manifest_path = roots["new_config"] / MANIFEST
    observed_manifest = sha(manifest_path) if manifest_path.exists() else None
    if args.mode in ("apply", "resume") and manifest_path.exists():
        recorded = private_json(manifest_path)
        recorded_roots = {k: checked_path(v) for k, v in recorded["roots"].items()}
        existing = load_manifest(manifest_path, recorded_roots)
        if existing["state"] != "rolled-back" and recorded_roots != roots:
            raise Refusal("active migration roots changed; use its exact recorded paths")
        if existing["state"] == "committed":
            with held_locks(roots, state_dir, data=False):
                if sha(manifest_path) != observed_manifest:
                    raise Refusal("migration state changed before lock ownership; retry")
                existing = load_manifest(manifest_path, roots)
                marker_path = roots["new_config"] / MARKER
                marker = private_json(marker_path) if marker_path.exists() else None
                if marker != marker_for(existing):
                    if args.mode != "resume":
                        raise Refusal("commit marker publication was interrupted; use --resume under admission proof")
                    receipt = admit(args.admission_receipt, roots, idle=False)
                    if receipt["nonce"] != existing["nonce"]:
                        raise Refusal("admission nonce does not match interrupted commit")
                    if marker is not None and any(marker.get(k) != existing.get(k) for k in ("migration_id", "nonce", "migration_version")):
                        raise Refusal("unexpected marker identity; nothing overwritten")
                    verification = existing.get("verification", {})
                    evidence = checked_path(verification["path"])
                    if receipt["scope"] == "fixture" and not evidence.is_relative_to(checked_path(receipt["fixture_root"])):
                        raise Refusal("verification evidence escapes its admitted fixture")
                    owned(evidence, False)
                    if sha(evidence) != verification["sha256"]:
                        raise Refusal("committed verification evidence changed; marker not repaired")
                    atomic_json(marker_path, marker_for(existing))
                return {"state": "committed", "migration_id": existing["migration_id"], "already_complete": True}
    if args.mode == "resume" and args.verification_receipt and manifest_path.exists():
        manifest = load_manifest(manifest_path, roots)
        if manifest.get("state") != "cutover-staged":
            raise Refusal("only a staged cutover can be committed")
        return finalize(args, manifest, manifest_path, roots)
    receipt = admit(args.admission_receipt, roots)
    if args.mode == "apply" and manifest_path.exists():
        recorded = private_json(manifest_path)
        prior = load_manifest(manifest_path, {k: checked_path(v) for k, v in recorded["roots"].items()})
        if prior["state"] == "committed":
            raise Refusal("migration state changed before lock ownership; retry")
        if prior["state"] != "rolled-back":
            raise Refusal("migration already prepared; use --resume or --rollback")
    if args.mode == "apply":
        manifest = plan(roots)
        required = manifest["counts"]["bytes"] * 2 + 1024 * 1024
        if shutil.disk_usage(nearest_parent(roots["new_config"])).free < required:
            raise Refusal("insufficient free space for private snapshot and staging")
        manifest.update(migration_id=str(uuid.uuid4()), nonce=receipt["nonce"], state="prepared", created_at=time.time())
    else:
        if not manifest_path.exists():
            raise Refusal("no migration manifest; use --dry-run then --apply")
        manifest = load_manifest(manifest_path, roots)
        if manifest.get("nonce") != receipt["nonce"]:
            raise Refusal("admission nonce does not match this migration")
    fail_after = int(os.environ.get("KHULUMA_MIGRATION_TEST_FAIL_AFTER", "0")) if receipt["scope"] == "fixture" else 0
    steps = 0

    def checkpoint():
        nonlocal steps
        atomic_json(manifest_path, manifest)
        steps += 1
        if fail_after and steps == fail_after:
            raise Refusal("fixture interruption injected after durable checkpoint; use --resume")

    with held_locks(roots, state_dir):
        if (sha(manifest_path) if manifest_path.exists() else None) != observed_manifest:
            raise Refusal("migration manifest changed before lock ownership; retry with its current state")
        admit(args.admission_receipt, roots)
        if args.mode == "rollback":
            return rollback(manifest, manifest_path, roots, checkpoint)
        if args.mode == "apply":
            if manifest_path.exists():
                atomic_json(state_dir / ("previous-" + prior["migration_id"] + ".json"), prior)
            checkpoint()
        if manifest["state"] == "committed":
            return {"state": "committed", "migration_id": manifest["migration_id"], "already_complete": True}
        if manifest["state"] == "rolled-back":
            raise Refusal("migration was rolled back; use --apply for a new verified upgrade")
        verify_source_snapshot(manifest, roots)
        for entry in manifest["entries"]:
            source, destination = Path(entry["source"]), Path(entry["destination"])
            owned(source, False)
            relative = Path(entry["relative"])
            backup = state_dir / "backup" / manifest["migration_id"] / relative
            original = source
            if sha(source) != entry["sha256"]:
                if (entry["action"] == "rewrite_in_place" and sha(source) == entry["target_sha256"]
                        and backup.exists() and sha(backup) == entry["sha256"]):
                    original = backup
                else:
                    raise Refusal(f"source changed since preparation: {source}")
            write_copy(original, backup, 0o600, entry["mtime_ns"])
            if sha(backup) != entry["sha256"]:
                raise Refusal("snapshot hash mismatch; originals retained")
            if entry["action"] in ("preserve_in_backup", "preserve_custom_root"):
                entry["state"] = "preserved"
                checkpoint()
                continue
            transformed = transformed_bytes(original, relative, roots, reference_map=manifest.get("reference_map"))
            stage = state_dir / "stage" / manifest["migration_id"] / relative
            write_copy(original, stage, entry["mode"], entry["mtime_ns"], transformed)
            if sha(stage) != entry["target_sha256"]:
                raise Refusal("staged hash mismatch; originals retained")
            durable_mkdir(destination.parent)
            owned(destination)
            if entry["action"] == "rewrite_in_place" and sha(destination) == entry["sha256"]:
                os.replace(stage, destination)  # original bytes already snapshotted
                fsync_directory(destination.parent)
            elif not destination.exists():
                os.link(stage, destination)  # atomic no-overwrite publish; stage retained
                fsync_directory(destination.parent)
            if (sha(destination) != entry["target_sha256"] or stat.S_IMODE(destination.stat().st_mode) != entry["mode"]
                    or destination.stat().st_mtime_ns != entry["mtime_ns"]):
                raise Refusal(f"destination changed; nothing overwritten: {destination}")
            entry["state"] = "published"
            checkpoint()
        for move in manifest["moves"]:
            source, destination = Path(move["source"]), Path(move["destination"])
            if move["action"] == "identical":
                if tree_fingerprint(destination) != move["fingerprint"]:
                    raise Refusal("adopted resource changed")
            elif source.exists():
                if tree_fingerprint(source) != move["fingerprint"] or destination.exists():
                    raise Refusal("resource source changed or destination appeared; no overwrite")
                durable_mkdir(destination.parent)
                if source.stat().st_dev != destination.parent.stat().st_dev:
                    raise Refusal("resource move crosses volumes")
                move["state"] = "moving"
                checkpoint()
                exclusive_rename(source, destination, move["identity"])
            if not destination.exists() or tree_fingerprint(destination) != move["fingerprint"]:
                raise Refusal("resource move cannot be verified; originals/manifest retained")
            if move["action"] == "rename" and {"dev": destination.stat().st_dev, "ino": destination.stat().st_ino} != move["identity"]:
                raise Refusal("resource inode changed after move")
            move["state"] = "moved"
            checkpoint()
        verify_source_snapshot(manifest, roots)
        manifest["state"] = "cutover-staged"
        checkpoint()
        atomic_json(roots["new_config"] / MARKER, marker_for(manifest))
    # Runtime/data locks released here, while externally owned admission gates
    # remain installed, so controlled canonical startup can take normal locks.
    if args.verification_receipt:
        return finalize(args, manifest, manifest_path, roots)
    return {"state": manifest["state"], "migration_id": manifest["migration_id"], "counts": manifest["counts"]}


def rollback(manifest, manifest_path, roots, checkpoint):
    if manifest["state"] == "rolled-back":
        marker_path = roots["new_config"] / MARKER
        marker = private_json(marker_path) if marker_path.exists() else None
        if marker is not None and any(marker.get(k) != manifest.get(k) for k in ("migration_id", "nonce", "migration_version")):
            raise Refusal("unexpected rollback marker identity; nothing overwritten")
        atomic_json(marker_path, marker_for(manifest))
        return {"state": "rolled-back", "already_complete": True}
    # Snapshot the current canonical tree, including post-cutover successful
    # deliveries. Never restore the pre-cutover usage.json over current usage.
    current = regular_files(roots["new_config"], exclude_internal=True)
    original_hashes = {entry["relative"]: entry["sha256"] for entry in manifest["entries"]}
    for source in current:
        relative = source.relative_to(roots["new_config"])
        if runtime_relative(relative):
            continue
        validate_critical(source, relative)
        info = source.stat()
        backup = roots["new_config"] / MANIFEST.parent / "rollback-latest" / manifest["migration_id"] / relative
        write_copy(source, backup, 0o600, info.st_mtime_ns)
        destination = roots["old_config"] / relative
        data = transformed_bytes(source, relative, roots, reverse=True,
                                 config_reference_map=manifest.get("config_reference_map", {}).get(str(relative)))
        expected = hashlib.sha256(data).hexdigest() if data is not None else sha(source)
        needs_update = (not destination.exists() or sha(destination) != expected
                        or stat.S_IMODE(destination.stat().st_mode) != stat.S_IMODE(info.st_mode)
                        or destination.stat().st_mtime_ns != info.st_mtime_ns)
        if destination.exists() and needs_update:
            if source != destination and sha(destination) not in (expected, original_hashes.get(str(relative))):
                raise Refusal("legacy data changed after cutover; both authorities retained for reconciliation")
            original = roots["new_config"] / MANIFEST.parent / "rollback-original" / manifest["migration_id"] / relative
            write_copy(destination, original, 0o600, destination.stat().st_mtime_ns)
        if needs_update:
            staged = roots["new_config"] / MANIFEST.parent / "rollback-stage" / manifest["migration_id"] / relative
            write_copy(source, staged, stat.S_IMODE(info.st_mode), info.st_mtime_ns, data)
            if sha(staged) != expected or sha(backup) != sha(source):
                raise Refusal("rollback snapshot mismatch; latest state retained")
            durable_mkdir(destination.parent)
            owned(destination)
            os.replace(staged, destination)  # previous bytes verified in private backup
            fsync_directory(destination.parent)
    for move in reversed(manifest["moves"]):
        if move["action"] != "rename":
            continue
        source, destination = Path(move["source"]), Path(move["destination"])
        if destination.exists():
            if source.exists():
                raise Refusal("rollback resource source was recreated; both trees retained")
            durable_mkdir(source.parent)
            if source.parent.stat().st_dev != destination.stat().st_dev:
                raise Refusal("rollback resource move crosses volumes")
            exclusive_rename(destination, source, move["identity"])
        elif not source.exists():
            raise Refusal("both resource roots are missing; rollback cannot claim recovery")
        elif {"dev": source.stat().st_dev, "ino": source.stat().st_ino} != move["identity"]:
            raise Refusal("rollback source inode does not match the recorded resource")
        move["state"] = "rolled-back"
        checkpoint()
    manifest["state"] = "rolled-back"
    checkpoint()
    atomic_json(roots["new_config"] / MARKER, marker_for(manifest))
    return {"state": "rolled-back", "migration_id": manifest["migration_id"], "latest_state_preserved": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    for mode in ("dry-run", "apply", "resume", "rollback"):
        modes.add_argument("--" + mode, dest="mode", action="store_const", const=mode)
    parser.set_defaults(mode="dry-run")
    for side in ("old", "new"):
        for resource in ("config", "models", "sounds"):
            parser.add_argument("--" + side + "-" + resource)
    parser.add_argument("--admission-receipt", type=Path)
    parser.add_argument("--verification-receipt", type=Path)
    parser.add_argument("--check-staged", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if args.check_staged:
            root = checked_path(args.check_staged)
            manifest = private_json(root / MANIFEST)
            roots = {k: checked_path(v) for k, v in manifest["roots"].items()}
            if roots.get("new_config") != root:
                raise Refusal("staged manifest does not belong to this config root")
            receipt = admit(args.admission_receipt, roots, idle=False)
            marker = private_json(root / MARKER)
            if marker.get("schema_version") != 1 or marker.get("migration_version") != VERSION or manifest.get("state") != "cutover-staged" or marker.get("state") != "cutover-staged" or marker.get("config_root") != str(root) or marker.get("nonce") != receipt["nonce"] or marker.get("migration_id") != manifest["migration_id"]:
                raise Refusal("no matching staged root under this admission controller")
            result = {"state": "cutover-staged", "controlled_startup": True}
        else:
            roots = resolve_roots(args)
            state_path = roots["new_config"] / MANIFEST
            if args.mode == "dry-run" and state_path.exists():
                recorded = private_json(state_path)
                recorded_roots = {k: checked_path(v) for k, v in recorded["roots"].items()}
                manifest = load_manifest(state_path, recorded_roots)
                if manifest["state"] == "rolled-back":
                    result = plan(roots)
                else:
                    result = {"state": manifest["state"], "migration_id": manifest["migration_id"],
                              "roots": manifest["roots"], "counts": manifest["counts"], "status_only": True,
                              "resume_required": manifest["state"] != "committed"}
            else:
                result = plan(roots) if args.mode == "dry-run" else mutate(args, roots)
        print(json.dumps(result, sort_keys=True))
    except (Refusal, OSError, ValueError, KeyError) as exc:
        print("khuluma identity migration: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
