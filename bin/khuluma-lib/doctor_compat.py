#!/usr/bin/env python3
"""The first-release legacy doctor JSON layout adapter."""
import json, subprocess, sys
result = subprocess.run(sys.argv[1:], stdout=subprocess.PIPE)
if result.returncode != 0:
    sys.stdout.buffer.write(result.stdout)
    raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
try:
    payload = json.loads(result.stdout)
    install = payload['install_sanity']
    for canonical, legacy in [('cli_binary', 'tmux_whisper_binary'),
                              ('daemon_source', 'tmux_whisperd_source'),
                              ('daemon_binary', 'tmux_whisperd_binary'),
                              ('daemon_socket', 'tmux_whisperd_socket')]:
        install[legacy] = install.pop(canonical)
    payload.pop('schema_version', None)
except (ValueError, KeyError, TypeError):
    sys.stdout.buffer.write(result.stdout)
else:
    print(json.dumps(payload, indent=2, sort_keys=True))
