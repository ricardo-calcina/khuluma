#!/usr/bin/env python3
"""Isolated Finder transaction regressions. Every fixture is retained."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('finder_transaction', PROJECT / 'bin/khuluma-lib/finder_transaction.py')
finder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(finder)
FIXTURES = Path(tempfile.mkdtemp(prefix='khuluma-finder-transaction-', dir='/private/tmp' if Path('/private/tmp').exists() else '/tmp')).resolve()
print('Finder transaction fixtures retained at ' + str(FIXTURES), flush=True)


def workflow(path, identifier, marker):
    path.mkdir(mode=0o700)
    contents = path / 'Contents'
    contents.mkdir(mode=0o700)
    for name, value in (
            ('Info.plist', {'CFBundleIdentifier': identifier}),
            ('document.wflow', {'workflowMetaData': {'workflowTypeIdentifier': 'com.apple.Automator.servicesMenu'}})):
        metadata = contents / name
        metadata.write_bytes(plistlib.dumps(value))
        metadata.chmod(0o600)
    (path / 'payload.txt').write_text(marker)
    return finder.identity(path.stat())


class Fixture:
    def __init__(self, name, originals=True):
        self.root = FIXTURES / name
        self.root.mkdir(mode=0o700)
        self.services = self.root / 'Services'
        self.services.mkdir(mode=0o700)
        self.config = self.root / 'config'
        self.config.mkdir(mode=0o755)
        self.backups = self.config / '.backups/finder'
        self.stage = self.services / (finder.STAGE_PREFIX + 'fixture')
        self.target = self.services / finder.TARGET_NAME
        self.legacy = self.services / finder.LEGACY_NAME
        self.new_claim = workflow(self.stage, finder.CANONICAL, 'new payload')
        self.old_claim = workflow(self.target, finder.CANONICAL, 'old canonical payload') if originals else None
        self.legacy_claim = workflow(self.legacy, finder.LEGACY, 'legacy payload') if originals else None

    def publish(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            finder.publish(self.stage, self.target, self.legacy, self.backups)
        return Path(output.getvalue().strip())

    def manifest(self):
        manifests = list(self.backups.glob('*/manifest.json'))
        if len(manifests) != 1:
            raise AssertionError('expected one retained manifest')
        return manifests[0]


class FinderTransactionTests(unittest.TestCase):
    def test_fresh_install_and_repeatable_rollback_retain_new_payload(self):
        fixture = Fixture('fresh', originals=False)
        manifest = fixture.publish()
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), fixture.new_claim)
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)
        finder.rollback(manifest)
        self.assertFalse(fixture.target.exists())
        self.assertEqual((manifest.parent / 'retired-new.workflow/payload.txt').read_text(), 'new payload')
        finder.rollback(manifest)

    def test_upgrade_then_rollback_restores_exact_both_prior_actions(self):
        fixture = Fixture('upgrade')
        manifest = fixture.publish()
        self.assertFalse(fixture.legacy.exists())
        finder.rollback(manifest)
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), fixture.old_claim)
        self.assertEqual(finder.owned_action(fixture.legacy, finder.LEGACY), fixture.legacy_claim)
        self.assertEqual((fixture.target / 'payload.txt').read_text(), 'old canonical payload')
        self.assertEqual((fixture.legacy / 'payload.txt').read_text(), 'legacy payload')
        finder.rollback(manifest)

    def test_stage_inode_is_durable_before_publication_and_post_publish_failure_restores(self):
        fixture = Fixture('record-before-publish')
        raw_rename = finder.rename_exclusive
        observed = []

        def inspect_record(source_fd, source, destination_fd, destination):
            if source == fixture.stage.name:
                manifest = fixture.manifest()
                record = json.loads(manifest.read_text())
                self.assertEqual(record['new_identity'], fixture.new_claim)
                self.assertEqual(len(record['moves']), 2)
                observed.append(record)
            return raw_rename(source_fd, source, destination_fd, destination)

        write = finder.write_json

        def interrupt_marker(path, record, parent_claim=None):
            if path.name == 'published.json':
                raise OSError('fixture interruption after publication')
            return write(path, record, parent_claim)

        with mock.patch.object(finder, 'rename_exclusive', inspect_record), mock.patch.object(finder, 'write_json', interrupt_marker):
            with self.assertRaisesRegex(OSError, 'fixture interruption'):
                fixture.publish()
        self.assertEqual(len(observed), 1)
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), fixture.old_claim)
        self.assertEqual(finder.owned_action(fixture.legacy, finder.LEGACY), fixture.legacy_claim)
        self.assertEqual(finder.owned_action(fixture.manifest().parent / 'retired-new.workflow', finder.CANONICAL), fixture.new_claim)

    def test_raced_empty_publication_destination_is_never_replaced(self):
        fixture = Fixture('publish-destination-race', originals=False)
        raw_rename = finder.rename_exclusive
        raced_claim = []

        def race(source_fd, source, destination_fd, destination):
            if source == fixture.stage.name:
                fixture.target.mkdir(mode=0o700)
                raced_claim.append(finder.identity(fixture.target.stat()))
            return raw_rename(source_fd, source, destination_fd, destination)

        with mock.patch.object(finder, 'rename_exclusive', race):
            with self.assertRaises((ValueError, OSError)):
                fixture.publish()
        self.assertEqual(finder.identity(fixture.target.stat()), raced_claim[0])
        self.assertEqual(finder.owned_action(fixture.stage, finder.CANONICAL), fixture.new_claim)
        self.assertEqual(list(fixture.target.iterdir()), [])

    def test_raced_empty_restoration_destination_is_never_replaced_and_can_resume(self):
        fixture = Fixture('restore-destination-race')
        manifest = fixture.publish()
        raw_rename = finder.rename_exclusive
        raced_claim = []

        def race(source_fd, source, destination_fd, destination):
            if source == finder.LEGACY_NAME and destination == finder.LEGACY_NAME:
                fixture.legacy.mkdir(mode=0o700)
                raced_claim.append(finder.identity(fixture.legacy.stat()))
            return raw_rename(source_fd, source, destination_fd, destination)

        with mock.patch.object(finder, 'rename_exclusive', race):
            with self.assertRaises(OSError):
                finder.rollback(manifest)
        self.assertEqual(finder.identity(fixture.legacy.stat()), raced_claim[0])
        self.assertEqual(finder.owned_action(manifest.parent / finder.LEGACY_NAME, finder.LEGACY), fixture.legacy_claim)
        self.assertEqual(finder.owned_action(manifest.parent / finder.TARGET_NAME, finder.CANONICAL), fixture.old_claim)
        self.assertEqual(finder.owned_action(manifest.parent / 'retired-new.workflow', finder.CANONICAL), fixture.new_claim)
        fixture.legacy.rename(fixture.root / 'retained-raced-empty.workflow')
        finder.rollback(manifest)
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), fixture.old_claim)
        self.assertEqual(finder.owned_action(fixture.legacy, finder.LEGACY), fixture.legacy_claim)

    def test_changed_target_and_missing_backup_refuse_before_retirement(self):
        fixture = Fixture('changed-target')
        manifest = fixture.publish()
        fixture.target.rename(fixture.root / 'retained-published.workflow')
        replacement = workflow(fixture.target, finder.CANONICAL, 'unrelated same-ID replacement')
        with self.assertRaises(ValueError):
            finder.rollback(manifest)
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), replacement)
        self.assertFalse((manifest.parent / 'retired-new.workflow').exists())
        missing = Fixture('missing-backup')
        manifest = missing.publish()
        (manifest.parent / finder.LEGACY_NAME).rename(missing.root / 'retained-missing-backup.workflow')
        with self.assertRaisesRegex(ValueError, 'backup missing'):
            finder.rollback(manifest)
        self.assertEqual(finder.owned_action(missing.target, finder.CANONICAL), missing.new_claim)
        self.assertFalse((manifest.parent / 'retired-new.workflow').exists())

    def test_source_swap_inside_rename_is_detected_and_unrelated_bundle_restored(self):
        fixture = Fixture('retire-source-race')
        manifest = fixture.publish()
        raw_rename = finder.rename_exclusive
        replacements = []

        def race(source_fd, source, destination_fd, destination):
            if source == finder.TARGET_NAME and destination == 'retired-new.workflow':
                fixture.target.rename(fixture.root / 'retained-published.workflow')
                replacements.append(workflow(fixture.target, finder.CANONICAL, 'raced unrelated payload'))
            return raw_rename(source_fd, source, destination_fd, destination)

        with mock.patch.object(finder, 'rename_exclusive', race):
            with self.assertRaisesRegex(ValueError, 'raced during move'):
                finder.rollback(manifest)
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), replacements[0])
        self.assertEqual((fixture.target / 'payload.txt').read_text(), 'raced unrelated payload')
        self.assertEqual(finder.owned_action(manifest.parent / finder.TARGET_NAME, finder.CANONICAL), fixture.old_claim)
        self.assertEqual(finder.owned_action(fixture.root / 'retained-published.workflow', finder.CANONICAL), fixture.new_claim)

    def test_symlink_ancestor_and_payload_and_unrelated_id_are_refused(self):
        fixture = Fixture('symlink-ancestor')
        alias = fixture.root / 'alias'
        alias.symlink_to(fixture.services, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            finder.publish(alias / fixture.stage.name, alias / finder.TARGET_NAME, alias / finder.LEGACY_NAME, fixture.backups)
        self.assertFalse(fixture.backups.exists())
        linked = Fixture('symlink-payload')
        (linked.stage / 'unexpected-link').symlink_to(linked.root)
        with self.assertRaisesRegex(ValueError, 'linked'):
            linked.publish()
        self.assertFalse(linked.backups.exists())
        unrelated = Fixture('unrelated-id', originals=False)
        workflow(unrelated.target, 'org.example.unrelated', 'retained unrelated action')
        with self.assertRaisesRegex(ValueError, 'unrelated'):
            unrelated.publish()
        self.assertEqual((unrelated.target / 'payload.txt').read_text(), 'retained unrelated action')

    def test_manifest_escape_and_pre_inode_schema_refuse_without_mutation(self):
        fixture = Fixture('manifest-escape')
        manifest = fixture.publish()
        record = json.loads(manifest.read_text())
        record['moves'][0]['to'] = str(fixture.root / 'unrelated-outside.workflow')
        manifest.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'restoration path'):
            finder.rollback(manifest)
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), fixture.new_claim)
        self.assertFalse((manifest.parent / 'retired-new.workflow').exists())
        record['schema_version'] = 1
        manifest.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'v2 inode-claimed'):
            finder.rollback(manifest)
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), fixture.new_claim)

    def test_ancestor_swapped_after_validation_cannot_redirect_a_move(self):
        fixture = Fixture('ancestor-swap', originals=False)
        decoy = fixture.root / 'decoy-Services'
        decoy.mkdir(mode=0o700)
        decoy_claim = workflow(decoy / fixture.stage.name, finder.CANONICAL, 'unrelated decoy payload')
        retained = fixture.root / 'retained-real-Services'
        raw_open = finder.os.open
        swapped = []

        def race(path, flags, mode=0o777, *, dir_fd=None):
            if path == 'Services' and dir_fd is not None and not swapped:
                fixture.services.rename(retained)
                fixture.services.symlink_to(decoy, target_is_directory=True)
                swapped.append(True)
            return raw_open(path, flags, mode, dir_fd=dir_fd)

        with mock.patch.object(finder.os, 'open', race):
            with self.assertRaises(OSError):
                finder.exclusive_move(fixture.stage, fixture.target, fixture.new_claim)
        self.assertEqual(finder.owned_action(retained / fixture.stage.name, finder.CANONICAL), fixture.new_claim)
        self.assertEqual(finder.owned_action(decoy / fixture.stage.name, finder.CANONICAL), decoy_claim)
        self.assertFalse((decoy / finder.TARGET_NAME).exists())

    def test_replaced_transaction_directory_cannot_receive_prior_actions(self):
        fixture = Fixture('transaction-directory-swap')
        retained = fixture.root / 'retained-original-record-directory'
        write = finder.write_json
        replacements = []

        def replace_after_record(path, record, parent_claim=None):
            result = write(path, record, parent_claim)
            if path.name == 'manifest.json':
                path.parent.rename(retained)
                path.parent.mkdir(mode=0o700)
                replacements.append(path.parent)
            return result

        with mock.patch.object(finder, 'write_json', replace_after_record):
            with self.assertRaisesRegex(ValueError, 'parent inode changed'):
                fixture.publish()
        self.assertEqual(finder.owned_action(fixture.target, finder.CANONICAL), fixture.old_claim)
        self.assertEqual(finder.owned_action(fixture.legacy, finder.LEGACY), fixture.legacy_claim)
        self.assertEqual(finder.owned_action(fixture.stage, finder.CANONICAL), fixture.new_claim)
        self.assertTrue((retained / 'manifest.json').is_file())
        self.assertEqual(list(replacements[0].iterdir()), [])


if __name__ == '__main__':
    unittest.main()
