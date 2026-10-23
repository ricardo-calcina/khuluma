#!/usr/bin/env python3
"""Delete only Khuluma's temporary/expired audio, without adding it to Trash."""
import os
from pathlib import Path
import re
import stat
import sys
import time


def delete_audio(path, directories, temporary=False):
    target = Path(os.path.abspath(path))
    try:
        info = target.lstat()
    except FileNotFoundError:
        return
    roots = {Path(directory).resolve() for directory in directories if directory}
    if (target.parent.resolve() not in roots or not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid() or info.st_nlink != 1):
        raise ValueError('refusing audio cleanup outside an owned regular file: ' + str(target))
    name_ok = (re.fullmatch(r'khuluma-[A-Za-z0-9.-]+\.wav|khuluma-app-take\.[A-Za-z0-9]+', target.name)
               if temporary else target.suffix == '.wav')
    if temporary and target.name == 'tail.wav':
        name_ok = re.fullmatch(r'khuluma-tail-rescue\.[A-Za-z0-9]+', target.parent.name)
    if not name_ok:
        raise ValueError('refusing non-audio cleanup target: ' + str(target))
    # This is the explicit audio-lifetime policy, separate from recoverable
    # cleanup of transcripts, user files, installations and test directories.
    target.unlink()


def prune(directory, days):
    root = Path(directory)
    if not root.exists():
        return
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        raise ValueError('refusing unowned or symlink audio archive: ' + str(root))
    cutoff = time.time() - days * 86400
    for target in root.glob('*.wav'):
        if target.lstat().st_mtime <= cutoff:
            delete_audio(target, [root])


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'temporary':
            delete_audio(sys.argv[2], sys.argv[3:], temporary=True)
        elif sys.argv[1] == 'expired':
            days = int(sys.argv[3])
            if days < 0:
                raise ValueError('audio retention must be nonnegative')
            prune(sys.argv[2], days)
        else:
            raise ValueError('unknown audio cleanup operation')
    except (OSError, ValueError, IndexError) as error:
        print('khuluma: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
