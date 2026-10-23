#!/usr/bin/env python3
"""Exercise the real vocabulary CLI in private profiles; retain every fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VocabularyTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="khuluma-vocabulary-"))
        self.config = self.root / "config"
        self.config.mkdir()
        (self.root / "home").mkdir()
        (self.config / "config.toml").write_text('[meta]\nconfig_version = 1\n[clean]\nenabled = true\nrepeats_level = 3\n')
        (self.config / "vocab").write_text('# Keep original comments\npn pm -> pnpm\nsource slash::src/\n')
        self.environment = {
            "HOME": str(self.root / "home"), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C",
            "KHULUMA_CONFIG_DIR": str(self.config), "KHULUMA_LIB_PATH": str(ROOT / "bin/khuluma-lib.sh"),
            "KHULUMA_INTERNAL_LIB_DIR": str(ROOT / "bin/khuluma-lib"), "XDG_DATA_HOME": str(self.root / "data"),
        }

    def command(self, *args, data=None, okay=True):
        result = subprocess.run([str(ROOT / "bin/khuluma"), *args], input=data, text=True,
                                env=self.environment, capture_output=True)
        if okay:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return result

    def snapshot(self):
        return self.command("vocab-sheet", "show", "--json")

    def save(self, snapshot, **kwargs):
        return self.command("vocab-sheet", "save", "--json", data=json.dumps(snapshot), **kwargs)

    def test_show_preserves_legacy_and_does_not_create_sheet(self):
        original = (self.config / "vocab").read_bytes()
        result = self.snapshot()
        self.assertEqual(result["document"]["words"][0], {"heard": "pn pm", "write": "pnpm"})
        self.assertFalse((self.config / "vocabulary.json").exists())
        self.assertFalse((self.config / ".config.toml.last-good").exists())
        self.assertEqual((self.config / "vocab").read_bytes(), original)

    def test_save_roundtrip_and_json_takes_precedence(self):
        snapshot = self.snapshot()
        snapshot["document"]["brands"] = [{"heard": "kaluma", "write": "Khuluma"}]
        saved = self.save(snapshot)
        self.assertEqual(saved, self.snapshot())
        (self.config / "vocab").write_text("Kaluma::WRONG\n")
        result = self.command("inline", "cleanup", "--json", data="Um, open Kaluma and PN PM.")
        self.assertEqual(result["text"], "open Khuluma and pnpm.")
        self.assertEqual((self.config / "vocabulary.json").stat().st_mode & 0o777, 0o600)

    def test_legacy_separator_precedence_matches_existing_parser(self):
        (self.config / "vocab").write_text("foo -> bar::baz\n")
        self.assertEqual(self.snapshot()["document"]["words"], [{"heard": "foo -> bar", "write": "baz"}])

    def test_custom_fillers_can_be_added_and_removed(self):
        snapshot = self.snapshot()
        snapshot["document"]["fillers"] = ["ahhh", "er"]
        self.save(snapshot)
        result = self.command("inline", "cleanup", "--json", data='Ahhh, er open pn pm. Um stays. The word "er" stays.')
        self.assertEqual(result["text"], 'open pnpm. Um stays. The word "er" stays.')

    def test_empty_fillers_keep_hesitations(self):
        snapshot = self.snapshot()
        snapshot["document"]["fillers"] = []
        self.save(snapshot)
        result = self.command("inline", "cleanup", "--json", data="Um, uh, keep this.")
        self.assertEqual(result["text"], "Um, uh, keep this.")

    def test_stale_save_cannot_overwrite_another_agent(self):
        original = self.snapshot()
        changed = json.loads(json.dumps(original))
        changed["document"]["fillers"].append("ahhh")
        self.save(changed)
        stale = self.save(original, okay=False)
        self.assertIn("changed on disk", stale.stderr)
        self.assertIn("ahhh", self.snapshot()["document"]["fillers"])

    def test_external_legacy_edit_invalidates_first_save(self):
        snapshot = self.snapshot()
        (self.config / "vocab").write_text("new::Word\n")
        self.assertIn("changed on disk", self.save(snapshot, okay=False).stderr)
        self.assertFalse((self.config / "vocabulary.json").exists())

    def test_replacement_creates_exact_recoverable_backup(self):
        saved = self.save(self.snapshot())
        previous = (self.config / "vocabulary.json").read_bytes()
        saved["document"]["fillers"].append("ahhh")
        self.save(saved)
        backups = list((self.config / "vocabulary-backups").glob("*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), previous)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)

    def test_invalid_import_preserves_saved_document(self):
        self.save(self.snapshot())
        previous = (self.config / "vocabulary.json").read_bytes()
        for data in ['{', '{"schema_version":1}', '{"schema_version":2,"fillers":[],"brands":[],"words":[]}',
                     '{"schema_version":1,"fillers":["uh","UH"],"brands":[],"words":[]}',
                     '{"schema_version":1,"fillers":["café","cafe\\u0301"],"brands":[],"words":[]}',
                     '{"schema_version":1,"fillers":[],"brands":[],"words":[],"other":[]}',
                     '{"schema_version":1,"fillers":[],"fillers":["uh"],"brands":[],"words":[]}']:
            self.command("vocab-sheet", "validate", "--json", data=data, okay=False)
            self.assertEqual((self.config / "vocabulary.json").read_bytes(), previous)

    def test_import_export_preserves_literal_replacements(self):
        snapshot = self.snapshot()
        snapshot["document"]["brands"] = [{"heard": "brand", "write": "$1\\folder"}]
        validated = self.command("vocab-sheet", "validate", "--json", data=json.dumps(snapshot["document"]))
        snapshot["document"] = validated
        self.save(snapshot)
        result = self.command("inline", "cleanup", "--json", data="brand.")
        self.assertEqual(result["text"], "$1\\folder.")

    def test_old_text_commands_do_not_silently_edit_inactive_file(self):
        self.save(self.snapshot())
        previous = (self.config / "vocab").read_bytes()
        self.command("vocab", "add", "wrong::right", okay=False)
        self.assertEqual(previous, (self.config / "vocab").read_bytes())

    def test_settings_expose_cleanup_and_repetition(self):
        for key, value in [("clean.enabled", "false"), ("clean.repeats_level", "3")]:
            result = self.command("app-settings", "set", key, value, "--json")
            self.assertEqual(result["cleanup"]["clean"], "0")
        self.command("app-settings", "set", "clean.repeats_level", "4", "--json", okay=False)

    def test_symlink_sheet_is_refused_without_writes(self):
        target = self.root / "target.json"
        target.write_text(json.dumps(self.snapshot()["document"]))
        (self.config / "vocabulary.json").symlink_to(target)
        self.command("vocab-sheet", "show", "--json", okay=False)


if __name__ == "__main__":
    unittest.main()
