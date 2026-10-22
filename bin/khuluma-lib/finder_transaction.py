#!/usr/bin/env python3
"""Publish one owned Finder action without overwriting any raced destination.

The immutable manifest claims all bundle inodes before moving anything. Every
move is exclusive, and rollback refuses changed/missing payloads. No payload or
transaction file is deleted, including on failure.
"""
import ctypes
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import uuid

CANONICAL = 'com.ricardo-nth.khuluma.transcribe-quick-action'
LEGACY = 'com.ricardo-nth.tmux-whisper.transcribe-quick-action'
TARGET_NAME = 'Transcribe with Khuluma.workflow'
LEGACY_NAME = 'Transcribe with Tmux Whisper.workflow'
STAGE_PREFIX = '.khuluma-finder-stage.'


def present(path):
    return path.exists() or path.is_symlink()


def identity(info):
    return {'dev': info.st_dev, 'ino': info.st_ino}


def checked_path(path):
    """Check every existing ancestor before any read, mkdir or move."""
    path = Path(os.path.abspath(path))
    for entry in [*reversed(path.parents), path]:
        try:
            info = entry.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or info.st_uid not in (0, os.getuid()):
            raise ValueError('unowned or symlink Finder path: ' + str(entry))
        if entry != path and not stat.S_ISDIR(info.st_mode):
            raise ValueError('non-directory Finder ancestor: ' + str(entry))
    return path


def owned_directory(path, private=False):
    path = checked_path(path)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('unowned Finder directory: ' + str(path))
    if private and info.st_mode & 0o077:
        raise ValueError('Finder backup directory must be private: ' + str(path))
    return info


def open_directory(path):
    """Pin each ancestor: O_NOFOLLOW on only the final path is insufficient."""
    path = checked_path(path)
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in path.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            if os.fstat(descriptor).st_uid not in (0, os.getuid()):
                raise ValueError('unowned Finder ancestor: ' + str(path))
        if os.fstat(descriptor).st_uid != os.getuid():
            raise ValueError('unowned Finder directory: ' + str(path))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def unchanged_directory(path, descriptor):
    checked_path(path)
    if identity(path.lstat()) != identity(os.fstat(descriptor)):
        raise ValueError('Finder parent changed; payload retained in opened parent: ' + str(path))


def private_mkdir(path):
    path = checked_path(path)
    if not present(path):
        if not present(path.parent):
            private_mkdir(path.parent)
        else:
            owned_directory(path.parent)
        create_directory(path)
    owned_directory(path, private=True)


def create_directory(path):
    descriptor = open_directory(path.parent)
    try:
        os.mkdir(path.name, mode=0o700, dir_fd=descriptor)
        os.fsync(descriptor)
        unchanged_directory(path.parent, descriptor)
        created = os.stat(path.name, dir_fd=descriptor, follow_symlinks=False)
        if not stat.S_ISDIR(created.st_mode) or created.st_uid != os.getuid() or created.st_mode & 0o077:
            raise ValueError('new Finder directory changed: ' + str(path))
        return identity(created)
    finally:
        os.close(descriptor)


def read_owned_file(path, loader, private=False):
    path = checked_path(path)
    parent_fd = open_directory(path.parent)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        with os.fdopen(descriptor, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or (private and info.st_mode & 0o077)):
                raise ValueError('untrusted Finder metadata: ' + str(path))
            result = loader(stream)
            if identity(os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)) != identity(info):
                raise ValueError('Finder metadata changed while reading: ' + str(path))
            unchanged_directory(path.parent, parent_fd)
            return result
    finally:
        os.close(parent_fd)


def write_json(path, record, parent_claim=None):
    """Create a durable record exclusively; never truncate an older record."""
    owned_directory(path.parent, private=True)
    parent_fd = open_directory(path.parent)
    try:
        if parent_claim is not None and identity(os.fstat(parent_fd)) != parent_claim:
            raise ValueError('Finder record directory inode changed: ' + str(path.parent))
        descriptor = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(record, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(parent_fd)
        unchanged_directory(path.parent, parent_fd)
    finally:
        os.close(parent_fd)


def owned_action(path, identifier):
    info = owned_directory(path)
    # A claimed bundle cannot contain links into unrelated user data or FIFOs.
    for root, directories, files in os.walk(path, followlinks=False):
        for name in directories + files:
            entry = Path(root) / name
            child = entry.lstat()
            if child.st_uid != os.getuid() or not (stat.S_ISDIR(child.st_mode) or stat.S_ISREG(child.st_mode)):
                raise ValueError('unowned, linked or special Finder payload: ' + str(entry))
    metadata = read_owned_file(path / 'Contents/Info.plist', plistlib.load)
    if not isinstance(metadata, dict) or metadata.get('CFBundleIdentifier') != identifier:
        raise ValueError('unrelated Finder action: ' + str(path))
    document = read_owned_file(path / 'Contents/document.wflow', plistlib.load)
    workflow_metadata = document.get('workflowMetaData') if isinstance(document, dict) else None
    if (not isinstance(workflow_metadata, dict)
            or workflow_metadata.get('workflowTypeIdentifier') != 'com.apple.Automator.servicesMenu'):
        raise ValueError('invalid Finder workflow: ' + str(path))
    if identity(path.lstat()) != identity(info):
        raise ValueError('Finder action changed during validation: ' + str(path))
    return identity(info)


def rename_exclusive(source_fd, source, destination_fd, destination):
    """The platform primitive is kept separate for deterministic race fixtures."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin' and hasattr(libc, 'renameatx_np'):
        operation = libc.renameatx_np
        operation.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        result = operation(source_fd, os.fsencode(source), destination_fd, os.fsencode(destination), 0x00000004)
    elif sys.platform.startswith('linux') and hasattr(libc, 'renameat2'):
        operation = libc.renameat2
        operation.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        result = operation(source_fd, os.fsencode(source), destination_fd, os.fsencode(destination), 1)
    else:
        raise ValueError('atomic exclusive Finder rename is unavailable; payloads retained')
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def exclusive_move(source, destination, claim, source_parent_claim=None, destination_parent_claim=None):
    source, destination = checked_path(source), checked_path(destination)
    owned_directory(source.parent)
    owned_directory(destination.parent)
    source_fd = open_directory(source.parent)
    try:
        destination_fd = open_directory(destination.parent)
        try:
            for parent, descriptor in ((source.parent, source_fd), (destination.parent, destination_fd)):
                unchanged_directory(parent, descriptor)
            if ((source_parent_claim is not None and identity(os.fstat(source_fd)) != source_parent_claim)
                    or (destination_parent_claim is not None and identity(os.fstat(destination_fd)) != destination_parent_claim)):
                raise ValueError('Finder transaction parent inode changed; no move performed')
            current = os.stat(source.name, dir_fd=source_fd, follow_symlinks=False)
            if not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid() or identity(current) != claim:
                raise ValueError('Finder payload inode changed; no move performed: ' + str(source))
            rename_exclusive(source_fd, source.name, destination_fd, destination.name)
            moved = os.stat(destination.name, dir_fd=destination_fd, follow_symlinks=False)
            if identity(moved) != claim:
                # A non-cooperating writer swapped the source after our check.
                # Restore it exclusively if possible; otherwise retain it at the
                # destination. Never overwrite either entry to hide the race.
                try:
                    rename_exclusive(destination_fd, destination.name, source_fd, source.name)
                except (OSError, ValueError):
                    pass
                os.fsync(source_fd)
                os.fsync(destination_fd)
                raise ValueError('Finder source raced during move; inspect both retained paths: ' + str(source) + ', ' + str(destination))
            for parent, descriptor in ((source.parent, source_fd), (destination.parent, destination_fd)):
                os.fsync(descriptor)
                unchanged_directory(parent, descriptor)
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)


def validate_layout(stage, target, legacy, backups):
    stage, target, legacy, backups = (checked_path(path) for path in (stage, target, legacy, backups))
    if (target.name != TARGET_NAME or legacy.name != LEGACY_NAME
            or not stage.name.startswith(STAGE_PREFIX)
            or len(stage.name) <= len(STAGE_PREFIX)
            or stage.parent != target.parent or legacy.parent != target.parent):
        raise ValueError('unexpected Finder transaction layout')
    owned_directory(target.parent)
    for action in (stage, target, legacy):
        if backups == action or action in backups.parents or backups in action.parents:
            raise ValueError('overlapping Finder action and backup roots')
    return stage, target, legacy, backups


def publish(stage, target, legacy, backups):
    stage, target, legacy, backups = validate_layout(stage, target, legacy, backups)
    services_identity = identity(owned_directory(target.parent))
    new_identity = owned_action(stage, CANONICAL)
    originals = []
    for path, identifier in ((target, CANONICAL), (legacy, LEGACY)):
        if present(path):
            originals.append((path, identifier, owned_action(path, identifier)))
    private_mkdir(backups)
    transaction = backups / uuid.uuid4().hex
    transaction_identity = create_directory(transaction)
    moves = [{'from': str(path), 'to': str(transaction / path.name), 'identifier': identifier, 'identity': claim}
             for path, identifier, claim in originals]
    manifest = transaction / 'manifest.json'
    record = {'schema_version': 2, 'target': str(target), 'stage': str(stage), 'new_identity': new_identity,
              'services_identity': services_identity, 'transaction_identity': transaction_identity, 'moves': moves}
    # This immutable record and its directory entry are durable before any move.
    write_json(manifest, record, transaction_identity)
    try:
        for move in moves:
            exclusive_move(Path(move['from']), Path(move['to']), move['identity'], services_identity, transaction_identity)
        exclusive_move(stage, target, new_identity, services_identity, services_identity)
        write_json(transaction / 'published.json', {'schema_version': 2, 'new_identity': new_identity}, transaction_identity)
    except BaseException as error:
        try:
            rollback(manifest)
        except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as recovery_error:
            raise ValueError('Finder publication failed; payloads retained; recovery manifest: ' + str(manifest)
                             + '; ' + str(error) + '; rollback refused: ' + str(recovery_error)) from error
        raise
    print(manifest)


def rollback(manifest):
    manifest = checked_path(manifest)
    transaction = manifest.parent
    owned_directory(transaction, private=True)
    owned_directory(transaction.parent, private=True)
    if manifest.name != 'manifest.json' or uuid.UUID(hex=transaction.name).hex != transaction.name:
        raise ValueError('invalid Finder transaction record path')
    record = read_owned_file(manifest, json.load, private=True)
    if not isinstance(record, dict) or record.get('schema_version') != 2:
        raise ValueError('Finder rollback requires a v2 inode-claimed manifest; payloads retained for manual recovery')
    if not isinstance(record.get('target'), str) or not isinstance(record.get('stage'), str):
        raise ValueError('invalid Finder transaction paths')
    target, stage = Path(record['target']), Path(record['stage'])
    legacy = target.parent / LEGACY_NAME
    validate_layout(stage, target, legacy, transaction.parent)
    if str(target) != str(checked_path(target)) or str(stage) != str(checked_path(stage)):
        raise ValueError('noncanonical Finder transaction paths')
    new_identity = record.get('new_identity')
    services_identity = record.get('services_identity')
    transaction_identity = record.get('transaction_identity')
    moves = record.get('moves')
    if (not all(valid_identity(value) for value in (new_identity, services_identity, transaction_identity))
            or not isinstance(moves, list) or len(moves) > 2):
        raise ValueError('invalid Finder transaction ownership claims')
    if (identity(owned_directory(transaction, private=True)) != transaction_identity
            or identity(owned_directory(target.parent)) != services_identity):
        raise ValueError('Finder transaction parent inode changed; all payloads retained')
    expected = {str(target): CANONICAL, str(legacy): LEGACY}
    seen = set()
    pending = []
    for move in moves:
        if (not isinstance(move, dict) or move.get('from') not in expected
                or move['from'] in seen or move.get('identifier') != expected[move['from']]
                or not valid_identity(move.get('identity'))):
            raise ValueError('invalid Finder restoration claim')
        original = Path(move['from'])
        saved = transaction / original.name
        if move.get('to') != str(saved) or move['identity'] == new_identity:
            raise ValueError('invalid Finder restoration path')
        seen.add(move['from'])
        if present(saved):
            if owned_action(saved, move['identifier']) != move['identity']:
                raise ValueError('saved Finder payload inode changed: ' + str(saved))
            pending.append((original, saved, move))
        elif not present(original) or owned_action(original, move['identifier']) != move['identity']:
            raise ValueError('Finder backup missing or changed; current action retained: ' + str(saved))
    retired = transaction / 'retired-new.workflow'
    new_locations = []
    for path in (stage, target, retired):
        if present(path) and identity(path.lstat()) == new_identity:
            if owned_action(path, CANONICAL) != new_identity:
                raise ValueError('new Finder payload changed: ' + str(path))
            new_locations.append(path)
    if len(new_locations) != 1:
        raise ValueError('new Finder payload missing or ambiguous; all retained actions left in place')
    if present(retired) and retired not in new_locations:
        raise ValueError('Finder retirement destination is taken; all actions retained')
    # Validate every restoration destination before retiring the current action.
    # Recheck source claims at each exclusive move as another writer may race us.
    for original, saved, move in pending:
        if present(original) and not (original == target and target in new_locations):
            raise ValueError('Finder restoration path taken: ' + str(original))
    if present(target) and target not in new_locations:
        old_target = next((move for move in moves if move['from'] == str(target)), None)
        if (old_target is None or present(transaction / TARGET_NAME)
                or owned_action(target, CANONICAL) != old_target['identity']):
            raise ValueError('Finder target inode changed; current action retained: ' + str(target))
    if target in new_locations:
        exclusive_move(target, retired, new_identity, services_identity, transaction_identity)
    for original, saved, move in reversed(pending):
        if owned_action(saved, move['identifier']) != move['identity']:
            raise ValueError('saved Finder payload changed before restoration: ' + str(saved))
        exclusive_move(saved, original, move['identity'], transaction_identity, services_identity)


def valid_identity(value):
    return (isinstance(value, dict) and set(value) == {'dev', 'ino'}
            and all(type(value[key]) is int and value[key] >= 0 for key in ('dev', 'ino')))


if __name__ == '__main__':
    try:
        if len(sys.argv) == 6 and sys.argv[1] == 'publish':
            publish(*(Path(os.path.abspath(arg)) for arg in sys.argv[2:]))
        elif len(sys.argv) == 3 and sys.argv[1] == 'rollback':
            rollback(Path(os.path.abspath(sys.argv[2])))
        elif len(sys.argv) == 3 and sys.argv[1] == 'verify':
            owned_action(Path(os.path.abspath(sys.argv[2])), CANONICAL)
        else:
            raise ValueError('invalid Finder transaction request')
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print('khuluma: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
