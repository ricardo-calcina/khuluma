#!/usr/bin/env python3
"""Move exact owned cleanup targets to macOS Trash; never permanently delete."""
import json
import os
import pwd
import pathlib
import stat
import subprocess
import sys
import uuid


def recover(path, empty_directory=False):
    target = pathlib.Path(os.path.abspath(os.path.expanduser(os.fspath(path))))
    try:
        info = target.lstat()
    except FileNotFoundError:
        return
    protected = {pathlib.Path('/'), pathlib.Path.home(), pathlib.Path('/tmp'), pathlib.Path('/private/tmp')}
    if target in protected or info.st_uid != os.getuid() or stat.S_ISLNK(info.st_mode):
        raise ValueError('refusing ambiguous, unowned or symlink cleanup target: ' + str(target))
    if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
        raise ValueError('refusing non-file cleanup target: ' + str(target))
    if empty_directory and (not stat.S_ISDIR(info.st_mode) or next(target.iterdir(), None) is not None):
        raise ValueError('refusing nonempty lock directory: ' + str(target))
    fixture_recovery = os.environ.get('KHULUMA_TEST_RECOVERY_ROOT')
    if fixture_recovery:
        recovery = pathlib.Path(fixture_recovery)
        marker = recovery / '.khuluma-recovery-fixture'
        recovery_info, marker_info = recovery.lstat(), marker.lstat()
        if (not recovery.is_absolute() or stat.S_ISLNK(recovery_info.st_mode)
                or not stat.S_ISDIR(recovery_info.st_mode)
                or recovery_info.st_uid != os.getuid() or recovery_info.st_mode & 0o077
                or not stat.S_ISREG(marker_info.st_mode) or marker_info.st_uid != os.getuid()
                or marker_info.st_mode & 0o077):
            raise ValueError('untrusted fixture recovery root')
        with marker.open(encoding='utf-8') as stream:
            proof = json.load(stream)
        boundary = pathlib.Path(proof['fixture_root'])
        boundary_info = boundary.lstat()
        real_boundary = boundary.resolve()
        real_target, real_recovery = target.resolve(), recovery.resolve()
        actual_home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
        if (proof.get('schema_version') != 1 or not boundary.is_absolute()
                or not stat.S_ISDIR(boundary_info.st_mode) or stat.S_ISLNK(boundary_info.st_mode)
                or boundary_info.st_uid != os.getuid() or boundary_info.st_mode & 0o077
                or real_boundary in protected or real_boundary == actual_home
                or not real_target.is_relative_to(real_boundary) or real_target == real_boundary
                or not real_recovery.is_relative_to(real_boundary)
                or real_recovery.is_relative_to(real_target)):
            raise ValueError('cleanup target escapes fixture boundary')
        destination = recovery / (uuid.uuid4().hex + '-' + target.name)
        record = destination.with_name(destination.name + '.original.json')
        with record.open('x', encoding='utf-8') as stream:
            os.chmod(record, 0o600)
            json.dump({'schema_version': 1, 'original_path': str(target), 'recovered_path': str(destination)}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.rename(target, destination)
        return
    if not os.path.isfile('/usr/bin/trash') or not os.access('/usr/bin/trash', os.X_OK):
        raise RuntimeError('recoverable cleanup requires /usr/bin/trash; retained ' + str(target))
    subprocess.run(['/usr/bin/trash', str(target)], check=True)


if __name__ == '__main__':
    try:
        arguments = sys.argv[1:]
        empty_directory = bool(arguments and arguments[0] == '--empty-directory')
        if empty_directory:
            arguments = arguments[1:]
        for argument in arguments:
            recover(argument, empty_directory=empty_directory)
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print('khuluma: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
