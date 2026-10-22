#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Fixtures are deliberately retained for recovery/inspection, never deleted.
python3 - "$project_root" <<'PY'
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

sys.dont_write_bytecode = True
project = Path(sys.argv[1])
engine = project / "tools/khuluma_identity_migration.py"
spec = importlib.util.spec_from_file_location("identity_migration", engine)
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)
suite_root = Path(tempfile.mkdtemp(prefix="khuluma-mig-", dir="/private/tmp" if Path("/private/tmp").exists() else "/tmp")).resolve()
print("Identity migration fixtures retained at " + str(suite_root), flush=True)


def put(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())
    path.chmod(mode)


def put_json(path, value):
    put(path, json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n")


def inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        result[str(path.relative_to(root))] = (stat.S_IFMT(info.st_mode), info.st_mode,
            info.st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
    return result


def ledger(count=9):
    return {"schema_version": 1, "tracking_started_at": "2026-10-01T00:00:00Z",
        "delivered_dictations": {"count": count, "by_flow": {"inline": count-2, "tmux": 2}},
        "processed_words": count*8, "recording_duration_ms": count*1700,
        "full_elapsed_duration_ms": count*2200, "recent_take_ids": {"kept-take": "2026-10-22"},
        "daily": {"started_at": "2026-10-20T12:00:00Z", "baseline_count": 7,
            "days": {"2026-10-22": {"count": 2, "inline": 2, "tmux": 0, "words": 16,
            "recording_ms": 3400, "full_elapsed_ms": 4400, "longest_recording_ms": 1700, "most_words": 8}}},
        "unknown_future_field": {"kept": True}}


class Fixture:
    def __init__(self, name):
        self.root = suite_root / name
        self.root.mkdir(mode=0o700)
        self.nonce = str(uuid.uuid4())
        self.roots = {"old_config": self.root/"config/dictate", "new_config": self.root/"config/khuluma",
            "old_models": self.root/"data/tmux-whisper/models", "new_models": self.root/"data/khuluma/models",
            "old_sounds": self.root/"sounds/dictate", "new_sounds": self.root/"sounds/khuluma"}
        self.receipt = self.root / "admission.json"
        self.old = self.roots["old_config"]
        self.new = self.roots["new_config"]
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith(("KHULUMA_", "DICTATE_", "XDG_")) and k != "SOUNDS_DIR"}
        self.environment.update(HOME=str(self.root/"home"), XDG_CONFIG_HOME=str(self.root/"config"),
                                XDG_DATA_HOME=str(self.root/"data"), TMPDIR=str(self.root/"tmp"))
        config = ('# User comments and unknown keys remain.\n[meta]\nconfig_version = 1\n'
            '[swift_parakeet]\nmodel_path = ""\nmodel_version = "v3"\n'
            'socket_path = "~/.config/dictate/.cache/tmux-whisperd.sock" # keep comment\n'
            '[inline]\nautosend = false\n[custom]\nexample = "~/.config/dictate/untouched"\n'
            '[audio.sounds]\nstart = "~/.local/share/sounds/dictate/start.wav"\n')
        put(self.old/"config.toml", config)
        put(self.old/".config.toml.last-good", config)
        put(self.old/"vocab", "# ordered\nc o r e::Core\nold-name → custom\n", 0o640)
        put_json(self.old/"usage.json", ledger())
        history = {"timestamp": "2026-10-22T01:00:00Z", "raw": "fixture raw", "processed": "fixture text",
            "app": "fixture", "metrics": {"record_ms": 1700}, "unknown": False,
            "audio": {"debug_archive_prefix": str(self.old/"history/inline-debug/example")}}
        put_json(self.old/"history/2026-10-22T01-00-00.json", history)
        put(self.old/"history/inline-debug/example.wav", b"fake fixture wav")
        put(self.old/"history/inline-debug/example.meta", "session_id=kept-take\n")
        put(self.old/"history/bench.tsv", "time\tinline\tok\tfixture\n")
        for name in migration.STATE_NAMES:
            put(self.old/".cache"/name, "kept-take\n")
        put(self.old/".cache/backend-state.sh", "this must never be sourced\n")
        put(self.old/"install-receipt.env", "install_source=fixture\nrepo_root=unchanged\n")
        put(self.roots["old_models"]/"parakeet-v3/model.bin", b"fixture model bytes")
        put(self.roots["old_sounds"]/"start.wav", b"fixture custom sound bytes")
        self.timestamp = 1600000000123456789
        os.utime(self.old/"vocab", ns=(self.timestamp, self.timestamp))
        put(self.root/".khuluma-migration-fixture", self.nonce)
        put(self.root/"token", self.nonce)
        gate, backup = self.root/"bin/old-cli", self.root/"backups/old-cli"
        put(gate, migration.gate_bytes(self.nonce), 0o700)
        put(backup, "#!/bin/sh\nexit 0\n", 0o700)
        self.admission = {"schema_version": 1, "migration_version": "rename-v1", "state": "gated",
            "scope": "fixture", "fixture_root": str(self.root), "nonce": self.nonce,
            "created_at": time.time()-1, "expires_at": time.time()+1800,
            "controller": {"pid": os.getpid(), "uid": os.getuid(), "start_fingerprint": "fixture:"+self.nonce},
            "roots": {k: str(v) for k, v in self.roots.items()}, "token_file": str(self.root/"token"),
            "entrypoints": [{"path": str(gate), "backup_path": str(backup),
                "gate_sha256": migration.sha(gate), "backup_sha256": migration.sha(backup)}],
            "process_paths": [str(backup)], "processing_dirs": [str(self.root/"processing-old"), str(self.root/"processing-new")],
            "socket_paths": [str(self.root/"run/old.sock"), str(self.root/"run/new.sock")],
            "idle_lock_dirs": [str(self.old/"history/bench.tsv.lock.d")]}
        put_json(self.receipt, self.admission)

    def run(self, mode, ok=True, extra=(), gated=True, environment=None):
        command = [sys.executable, str(engine), "--"+mode]
        for key, value in self.roots.items():
            command += ["--"+key.replace("_", "-"), str(value)]
        if gated:
            command += ["--admission-receipt", str(self.receipt)]
        command += list(extra)
        result = subprocess.run(command, env=environment or self.environment, capture_output=True, text=True)
        if (result.returncode == 0) != ok:
            raise AssertionError("unexpected migration exit: " + result.stderr + result.stdout)
        return json.loads(result.stdout) if ok else result.stderr

    def manifest(self):
        return json.loads((self.new/migration.MANIFEST).read_text())

    def verification(self):
        manifest = self.manifest()
        value = {k: manifest[k] for k in ("migration_id", "nonce", "roots")}
        value.update(schema_version=1, migration_version="rename-v1", state="verified", created_at=time.time(),
            controller=self.admission["controller"], checks={"cli_contract": 3, "serving_daemons": 1,
            "usage_schema": 1, "canonical_roots": True})
        path = self.root / "verified.json"
        put_json(path, value)
        return path


class MigrationTests(unittest.TestCase):
    def test_dry_run_is_pure_and_missing_gate_refuses(self):
        fixture = Fixture("dry-run spaces 漢字")
        before = inventory(fixture.root)
        result = fixture.run("dry-run", gated=False)
        self.assertEqual(result["state"], "dry-run")
        self.assertEqual(inventory(fixture.root), before)
        self.assertIn("admission receipt", fixture.run("apply", ok=False, gated=False))
        self.assertEqual(inventory(fixture.root), before)

    def test_full_state_and_metadata_and_staged_commit(self):
        fixture = Fixture("complete")
        source_usage = (fixture.old/"usage.json").read_bytes()
        source_vocab = (fixture.old/"vocab").read_bytes()
        source_config = (fixture.old/"config.toml").read_bytes()
        model_inode = (fixture.roots["old_models"]/"parakeet-v3/model.bin").stat().st_ino
        result = fixture.run("apply")
        self.assertEqual(result["state"], "cutover-staged")
        self.assertEqual((fixture.new/"usage.json").read_bytes(), source_usage)
        self.assertEqual((fixture.new/"vocab").read_bytes(), source_vocab)
        self.assertEqual((fixture.new/"vocab").stat().st_mtime_ns, fixture.timestamp)
        self.assertEqual(stat.S_IMODE((fixture.new/"vocab").stat().st_mode), 0o640)
        self.assertEqual((fixture.old/"config.toml").read_bytes(), source_config)
        text = (fixture.new/"config.toml").read_text()
        self.assertIn('autosend = false', text)
        self.assertIn('# keep comment', text)
        self.assertIn('example = "~/.config/dictate/untouched"', text)
        self.assertIn(str(fixture.new/".cache/khulumad.sock"), text)
        self.assertFalse((fixture.new/".cache/backend-state.sh").exists())
        self.assertEqual((fixture.new/".cache/recorded-takes").read_text(), "kept-take\n")
        self.assertFalse(fixture.roots["old_models"].exists())
        self.assertEqual((fixture.roots["new_models"]/"parakeet-v3/model.bin").stat().st_ino, model_inode)
        self.assertFalse(fixture.roots["new_models"].is_symlink())
        # Controlled startup may establish the new endpoint before finalization.
        endpoint = Path(fixture.admission["socket_paths"][1])
        # A regular sentinel suffices for this phase-boundary regression: idle
        # apply rejects any endpoint evidence; staged verification ignores it.
        # No sandbox socket server or user daemon is needed for this check.
        put(endpoint, "controlled endpoint exists\n")
        checked = subprocess.run([sys.executable, str(engine), "--check-staged", str(fixture.new),
            "--admission-receipt", str(fixture.receipt)], env=fixture.environment, capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        committed = fixture.run("resume", extra=("--verification-receipt", str(fixture.verification())))
        self.assertEqual(committed["state"], "committed")
        marker = json.loads((fixture.new/migration.MARKER).read_text())
        self.assertEqual(marker["config_root"], str(fixture.new))
        self.assertEqual(stat.S_IMODE((fixture.new/migration.MANIFEST).stat().st_mode), 0o600)

    def test_interruption_resume_and_idempotent_apply(self):
        fixture = Fixture("interrupted")
        environment = dict(fixture.environment, KHULUMA_MIGRATION_TEST_FAIL_AFTER="3")
        self.assertIn("interruption", fixture.run("apply", ok=False, environment=environment))
        fixture.run("resume")
        self.assertEqual(fixture.run("resume")["state"], "cutover-staged")
        fixture.run("resume", extra=("--verification-receipt", str(fixture.verification())))
        self.assertTrue(fixture.run("apply")["already_complete"])

    def test_post_cutover_rollback_keeps_latest_usage_and_new_history(self):
        fixture = Fixture("rollback")
        fixture.run("apply")
        fixture.run("resume", extra=("--verification-receipt", str(fixture.verification())))
        put_json(fixture.new/"usage.json", ledger(10))
        put_json(fixture.new/"history/new-delivery.json", {"raw": "new fixture", "processed": "new delivery"})
        put(fixture.new/".cache/recorded-takes", "kept-take\nnew-take\n")
        result = fixture.run("rollback")
        self.assertTrue(result["latest_state_preserved"])
        self.assertEqual(json.loads((fixture.old/"usage.json").read_text()), ledger(10))
        self.assertTrue((fixture.old/"history/new-delivery.json").exists())
        self.assertIn("new-take", (fixture.old/".cache/recorded-takes").read_text())
        self.assertTrue(fixture.roots["old_models"].exists())
        self.assertFalse(fixture.roots["new_models"].exists())
        self.assertTrue(fixture.run("rollback")["already_complete"])
        # A second upgrade reuses the current ledger rather than the snapshot.
        fixture.run("apply")
        self.assertEqual(json.loads((fixture.new/"usage.json").read_text()), ledger(10))

    def test_conflicts_schema_and_unknown_fields(self):
        fixture = Fixture("conflict")
        put_json(fixture.new/"usage.json", ledger(12))
        before = inventory(fixture.root)
        self.assertIn("conflicts", fixture.run("apply", ok=False))
        self.assertEqual(inventory(fixture.root), before)
        malformed = Fixture("malformed")
        put_json(malformed.old/"usage.json", {"schema_version": 9})
        self.assertIn("unsupported critical", malformed.run("dry-run", ok=False, gated=False))
        self.assertFalse(malformed.new.exists())

    def test_gate_controller_and_lock_refusals(self):
        fixture = Fixture("gate-proof")
        gate = Path(fixture.admission["entrypoints"][0]["path"])
        put(gate, "#!/bin/sh\nexit 0\n", 0o700)
        self.assertIn("admission receipt", fixture.run("apply", ok=False))
        self.assertFalse(fixture.new.exists())
        locked = Fixture("held-lock")
        path = locked.old/"usage.json.lock"
        put(path, b"")
        with open(path, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertIn("writer lock is held", locked.run("apply", ok=False))
            self.assertEqual(path.stat().st_ino, os.fstat(lock.fileno()).st_ino)
        markers = Fixture("markers")
        put(Path(markers.admission["processing_dirs"][0])/"inline-live", "pid=123\n")
        self.assertIn("processing markers", markers.run("apply", ok=False))
        self.assertFalse(markers.new.exists())

    def test_custom_paths_and_symlinks(self):
        fixture = Fixture("custom-model")
        config = (fixture.old/"config.toml").read_text().replace('model_path = ""',
            'model_path = ' + json.dumps(str(fixture.roots["old_models"]/"parakeet-v3")))
        put(fixture.old/"config.toml", config)
        fixture.roots["new_models"] = fixture.roots["old_models"]
        fixture.admission["roots"] = {k: str(v) for k, v in fixture.roots.items()}
        put_json(fixture.receipt, fixture.admission)
        fixture.run("apply")
        self.assertTrue(fixture.roots["old_models"].exists())
        self.assertIn(str(fixture.roots["old_models"]), (fixture.new/"config.toml").read_text())
        symlink = Fixture("symlink")
        (symlink.root/"external-link").symlink_to(symlink.old, target_is_directory=True)
        symlink.roots["old_config"] = symlink.root/"external-link"
        self.assertIn("symlink", symlink.run("dry-run", ok=False, gated=False))

    def test_history_collision_keeps_sidecar_group_and_reference(self):
        fixture = Fixture("history-groups")
        put(fixture.new/"history/inline-debug/example.wav", b"different existing recording")
        fixture.run("apply")
        manifest = fixture.manifest()
        alternate = [e for e in manifest["entries"] if e["relative"] == "history/inline-debug/example.wav"][0]
        wav = Path(alternate["destination"])
        self.assertEqual(wav.read_bytes(), b"fake fixture wav")
        self.assertTrue(wav.with_suffix(".meta").exists())
        self.assertEqual((fixture.new/"history/inline-debug/example.wav").read_bytes(), b"different existing recording")
        history = json.loads((fixture.new/"history/2026-10-22T01-00-00.json").read_text())
        self.assertEqual(history["audio"]["debug_archive_prefix"], str(wav.with_suffix("")))
        self.assertEqual(history["raw"], "fixture raw")

    def test_source_drift_and_overlong_paths_refuse(self):
        fixture = Fixture("drift")
        environment = dict(fixture.environment, KHULUMA_MIGRATION_TEST_FAIL_AFTER="1")
        fixture.run("apply", ok=False, environment=environment)
        put(fixture.old/"vocab", "new rule::must be preserved\n")
        self.assertIn("source changed", fixture.run("resume", ok=False))
        self.assertEqual((fixture.old/"vocab").read_text(), "new rule::must be preserved\n")
        overlong = Fixture("long-root")
        overlong.roots["new_config"] = overlong.root/("x"*100)
        self.assertIn("socket path", overlong.run("dry-run", ok=False, gated=False))

    def test_added_source_inventory_is_not_silently_lost_on_resume(self):
        fixture = Fixture("added-source")
        environment = dict(fixture.environment, KHULUMA_MIGRATION_TEST_FAIL_AFTER="1")
        fixture.run("apply", ok=False, environment=environment)
        put_json(fixture.old/"history/new-while-paused.json", {"raw": "fixture addition", "processed": "kept"})
        self.assertIn("source inventory changed", fixture.run("resume", ok=False))
        self.assertTrue((fixture.old/"history/new-while-paused.json").exists())
        self.assertFalse((fixture.new/migration.MARKER).exists())

    def test_commit_marker_interruption_can_resume_after_startup(self):
        fixture = Fixture("marker-repair")
        fixture.run("apply")
        fixture.run("resume", extra=("--verification-receipt", str(fixture.verification())))
        marker = fixture.new/migration.MARKER
        marker.rename(fixture.root/"retained-committed-marker.json")
        put(Path(fixture.admission["socket_paths"][1]), "canonical endpoint evidence\n")
        self.assertIn("use --resume", fixture.run("apply", ok=False))
        self.assertTrue(fixture.run("resume")["already_complete"])
        self.assertEqual(json.loads(marker.read_text())["state"], "committed")
        # A committed re-run is a pure no-op even with an endpoint present.
        self.assertTrue(fixture.run("apply", gated=False)["already_complete"])

    def test_optimized_python_cannot_bypass_gate_and_overlapping_roots_refuse(self):
        fixture = Fixture("optimized-proof")
        gate = Path(fixture.admission["entrypoints"][0]["path"])
        put(gate, "#!/bin/sh\nexit 0\n", 0o700)
        environment = dict(fixture.environment, PYTHONOPTIMIZE="1")
        self.assertIn("admission receipt", fixture.run("apply", ok=False, environment=environment))
        self.assertFalse(fixture.new.exists())
        overlap = Fixture("overlap")
        overlap.roots["new_models"] = overlap.old
        self.assertIn("overlap", overlap.run("dry-run", ok=False, gated=False))

    def test_diverged_legacy_rollback_refuses_to_choose_totals(self):
        fixture = Fixture("diverged")
        fixture.run("apply")
        put_json(fixture.old/"usage.json", ledger(11))
        put_json(fixture.new/"usage.json", ledger(12))
        self.assertIn("both authorities retained", fixture.run("rollback", ok=False))
        self.assertEqual(json.loads((fixture.old/"usage.json").read_text()), ledger(11))
        self.assertEqual(json.loads((fixture.new/"usage.json").read_text()), ledger(12))

    def test_shared_custom_config_root_rewrites_and_rolls_back_factory_paths(self):
        fixture = Fixture("same-config-root")
        original = (fixture.old/"config.toml").read_bytes()
        fixture.new = fixture.old
        fixture.roots["new_config"] = fixture.old
        fixture.admission["roots"] = {k: str(v) for k, v in fixture.roots.items()}
        put_json(fixture.receipt, fixture.admission)
        fixture.run("apply")
        self.assertIn(str(fixture.roots["new_sounds"]/"start.wav"), (fixture.old/"config.toml").read_text())
        self.assertIn(str(fixture.old/".cache/khulumad.sock"), (fixture.old/"config.toml").read_text())
        fixture.run("resume")
        fixture.run("rollback")
        self.assertEqual((fixture.old/"config.toml").read_bytes(), original)

    def test_manifest_escape_and_fifo_receipt_are_rejected(self):
        fixture = Fixture("manifest-escape")
        fixture.run("apply", ok=False, environment=dict(fixture.environment, KHULUMA_MIGRATION_TEST_FAIL_AFTER="1"))
        manifest = fixture.manifest()
        manifest["migration_id"] = "../../../../escaped-recovery"
        put_json(fixture.new/migration.MANIFEST, manifest)
        self.assertIn("canonical UUID", fixture.run("resume", ok=False))
        self.assertFalse((fixture.root/"escaped-recovery").exists())
        fifo = Fixture("fifo-proof")
        fifo.receipt = fifo.root/"receipt-fifo"
        os.mkfifo(fifo.receipt, 0o600)
        self.assertIn("regular", fifo.run("apply", ok=False))
        self.assertFalse(fifo.new.exists())

    def test_exclusive_resource_move_and_missing_resource_rollback(self):
        fixture = Fixture("exclusive-move")
        source, target = fixture.roots["old_models"], fixture.roots["new_models"]
        target.mkdir(parents=True, mode=0o700)
        identity = {"dev": source.stat().st_dev, "ino": source.stat().st_ino}
        with self.assertRaises(migration.Refusal):
            migration.exclusive_rename(source, target, identity)
        self.assertTrue(source.exists())
        self.assertTrue(target.exists())
        missing = Fixture("missing-resource")
        missing.run("apply")
        missing.roots["new_models"].rename(missing.root/"retained-models")
        self.assertIn("both resource roots are missing", missing.run("rollback", ok=False))
        self.assertTrue((missing.root/"retained-models").exists())

    def test_rollback_marker_repair_and_identical_metadata_conflict(self):
        fixture = Fixture("rollback-marker")
        fixture.run("apply")
        fixture.run("rollback")
        marker = fixture.new/migration.MARKER
        previous = json.loads(marker.read_text())
        previous["state"] = "committed"
        put_json(marker, previous)
        self.assertTrue(fixture.run("rollback")["already_complete"])
        self.assertEqual(json.loads(marker.read_text())["state"], "rolled-back")
        conflict = Fixture("metadata-conflict")
        put(conflict.new/"vocab", (conflict.old/"vocab").read_bytes(), 0o640)
        self.assertIn("conflicts", conflict.run("dry-run", ok=False, gated=False))

    def test_xdg_symlink_root_is_rejected(self):
        fixture = Fixture("xdg-symlink")
        (fixture.root/"xdg-alias").symlink_to(fixture.root/"config", target_is_directory=True)
        environment = dict(fixture.environment, XDG_CONFIG_HOME=str(fixture.root/"xdg-alias"))
        self.assertIn("symlink", fixture.run("dry-run", ok=False, gated=False, environment=environment))

    def test_relative_writer_command_is_not_reported_idle(self):
        fixture = Fixture("relative-writer")
        receipt = dict(fixture.admission, scope="live_controller")
        receipt["process_paths"] = [str(fixture.root/"source with spaces/bin/tmux-whisper")]
        snapshot = subprocess.CompletedProcess([], 0, "424242 /bin/bash ./bin/tmux-whisper inline record\n", "")
        with mock.patch.object(migration.subprocess, "run", return_value=snapshot):
            with self.assertRaises(migration.Refusal):
                migration.idle_runtime(receipt)

    def test_cross_volume_and_space_preflights_leave_sources_intact(self):
        fixture = Fixture("space-volume")
        before = inventory(fixture.root)
        fake_parent = mock.Mock()
        fake_parent.stat.return_value.st_dev = fixture.roots["old_models"].stat().st_dev + 1
        with mock.patch.object(migration, "nearest_parent", return_value=fake_parent):
            with self.assertRaises(migration.Refusal):
                migration.plan(fixture.roots)
        args = mock.Mock(mode="apply", admission_receipt=fixture.receipt, verification_receipt=None)
        with mock.patch.object(migration.shutil, "disk_usage", return_value=mock.Mock(free=0)):
            with self.assertRaises(migration.Refusal):
                migration.mutate(args, fixture.roots)
        self.assertEqual(inventory(fixture.root), before)

    def test_canonical_empty_override_preserves_nonempty_legacy_alias(self):
        with mock.patch.dict(os.environ, {"KHULUMA_CONFIG_DIR": "", "DICTATE_CONFIG_DIR": "/fixture/old-pin"}):
            self.assertEqual(migration.env_value("KHULUMA_CONFIG_DIR", "DICTATE_CONFIG_DIR", "/fixture/default"), "/fixture/old-pin")

    def test_archived_configs_and_opaque_audio_are_not_rewritten_or_buffered(self):
        fixture = Fixture("opaque-archives")
        put(fixture.old/"modes-archive/old/config.toml", "historical invalid TOML remains raw\n")
        original_read = Path.read_bytes
        def bounded_read(path):
            if path.suffix == ".wav":
                raise AssertionError("opaque WAV should be hashed/copied in chunks")
            return original_read(path)
        with mock.patch.object(Path, "read_bytes", bounded_read):
            migration.plan(fixture.roots)
        fixture.run("apply")
        self.assertEqual((fixture.new/"modes-archive/old/config.toml").read_text(), "historical invalid TOML remains raw\n")

    def test_independent_config_file_keeps_its_resource_references(self):
        fixture = Fixture("independent-config")
        config = fixture.old/"custom-user.toml"
        put(config, (fixture.old/"config.toml").read_bytes())
        fixture.roots["new_models"] = fixture.roots["old_models"]
        fixture.roots["new_sounds"] = fixture.roots["old_sounds"]
        fixture.admission["roots"] = {k: str(v) for k, v in fixture.roots.items()}
        put_json(fixture.receipt, fixture.admission)
        environment = dict(fixture.environment, KHULUMA_CONFIG_FILE=str(config))
        original = config.read_bytes()
        fixture.run("apply", environment=environment)
        self.assertEqual(config.read_bytes(), original)
        self.assertTrue(fixture.roots["old_models"].exists())
        self.assertTrue(fixture.roots["old_sounds"].exists())

    def test_recognized_factory_model_and_literal_tilde_socket_migrate(self):
        fixture = Fixture("factory-model")
        model = "parakeet-tdt-0.6b-v3-coreml"
        (fixture.roots["old_models"]/"parakeet-v3").rename(fixture.roots["old_models"]/model)
        original = (fixture.old/"config.toml").read_text().replace('model_path = ""',
            "model_path = " + json.dumps(str(fixture.roots["old_models"]/model)))
        put(fixture.old/"config.toml", original)
        put(fixture.old/".config.toml.last-good", original)
        preview = fixture.run("dry-run", gated=False)
        self.assertEqual(preview["roots"]["new_models"], str(fixture.roots["new_models"]))
        fixture.run("apply")
        parsed = migration.tomllib.loads((fixture.new/"config.toml").read_text())
        self.assertEqual(parsed["swift_parakeet"]["model_path"], str(fixture.roots["new_models"]/model))
        self.assertEqual(parsed["swift_parakeet"]["socket_path"], str(fixture.new/".cache/khulumad.sock"))
        self.assertEqual(parsed["swift_parakeet"]["model_version"], "v3")
        self.assertTrue((fixture.roots["new_models"]/model/"model.bin").exists())
        fixture.run("rollback")
        self.assertEqual((fixture.old/"config.toml").read_text(), original)

    def test_unsupported_toml_factory_syntax_refuses_before_resource_move(self):
        fixture = Fixture("triple-quoted")
        text = (fixture.old/"config.toml").read_text().replace('start = "~/.local/share/sounds/dictate/start.wav"',
            "start = '''~/.local/share/sounds/dictate/start.wav'''")
        put(fixture.old/"config.toml", text)
        self.assertIn("unsupported TOML syntax", fixture.run("apply", ok=False))
        self.assertTrue(fixture.roots["old_sounds"].exists())
        self.assertFalse(fixture.roots["new_sounds"].exists())

    def test_resource_adoption_compares_modes_and_empty_directories(self):
        fixture = Fixture("resource-metadata")
        import shutil
        shutil.copytree(fixture.roots["old_models"], fixture.roots["new_models"], copy_function=shutil.copy2)
        (fixture.roots["new_models"]/"empty-extra").mkdir(mode=0o700)
        self.assertIn("conflicts", fixture.run("dry-run", ok=False, gated=False))


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
