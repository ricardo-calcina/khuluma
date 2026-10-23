#!/usr/bin/env python3
"""The opt-in ElevenLabs transport. Credentials and response bodies stay private."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

KEY_NAMES = ("ELEVENLABS_API_KEY", "ELEVEN_LABS_API_KEY")


def read_lines(path):
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return []


def exported_literal(line, name="ELEVENLABS_API_KEY"):
    match = re.fullmatch(r"\s*export\s+" + re.escape(name) + r"\s*=\s*(.*?)\s*", line)
    if not match or any(c in match[1] for c in ("$", "`", ";")):
        return None
    try:
        values = shlex.split(match[1], comments=True, posix=True)
    except ValueError:
        return None
    if len(values) == 1 and re.fullmatch(r"[A-Za-z0-9_-]+", values[0]):
        return values[0]
    return None


def private_sibling_assignment(line, rc_path, home):
    """Recognize only the conventional sibling declaration, not shell code."""
    match = re.fullmatch(r"\s*(?:export\s+)?zsh_private_env\s*=\s*(.*?)\s*", line)
    if not match:
        return None
    try:
        values = shlex.split(match[1], comments=True, posix=True)
    except ValueError:
        return False
    # ZDOTDIR denotes the directory of the rc file being inspected. HOME
    # forms are accepted only for ~/.zshrc, so lookup never follows an
    # arbitrary source path or expands an expression supplied by shell code.
    permitted = {"${ZDOTDIR:-$HOME}/.zshrc.private", "$ZDOTDIR/.zshrc.private",
                 "${ZDOTDIR}/.zshrc.private"}
    if rc_path.parent == home:
        permitted.update(("$HOME/.zshrc.private", "${HOME}/.zshrc.private"))
    return len(values) == 1 and values[0] in permitted


def credential():
    """Read exported literals and one explicitly sourced private sibling."""
    for name in KEY_NAMES:
        inherited = os.environ.get(name, "").strip()
        if inherited:
            return inherited if not any(ord(c) < 32 for c in inherited) else ""
    home = Path.home()
    candidates = []
    if os.environ.get("ZDOTDIR"):
        candidates.append(Path(os.environ["ZDOTDIR"]).expanduser() / ".zshrc")
    candidates.extend((home / ".config/zsh/.zshrc", home / ".zshrc"))
    for path in dict.fromkeys(candidates):
        found = dict.fromkeys(KEY_NAMES, "")
        private_declared = False
        for line in read_lines(path):
            for name in KEY_NAMES:
                value = exported_literal(line, name)
                if value:
                    found[name] = value
            declaration = private_sibling_assignment(line, path, home)
            if declaration is not None:
                private_declared = declaration
            try:
                words = shlex.split(line, comments=True, posix=True)
            except ValueError:
                continue
            if (private_declared and len(words) == 2 and words[0] in ("source", ".")
                    and words[1] in ("$zsh_private_env", "${zsh_private_env}")):
                for private_line in read_lines(path.parent / ".zshrc.private"):
                    for name in KEY_NAMES:
                        value = exported_literal(private_line, name)
                        if value:
                            found[name] = value
        for name in KEY_NAMES:
            if found[name]:
                return found[name]
    return ""


def transcribe(path, language):
    key = credential()
    if not key:
        raise RuntimeError("ElevenLabs API key unavailable. Export ELEVENLABS_API_KEY in your shell settings, then reload Settings.")
    if not Path(path).is_file():
        raise RuntimeError("ElevenLabs audio file is unavailable.")
    # curl's config arrives on stdin, so the key never appears in process
    # arguments, temporary files, output, or application logs. Do not expose
    # remote errors: API bodies can echo request data or contain transcripts.
    escaped = key.replace("\\", "\\\\").replace('"', '\\"')
    audio_path = str(Path(path).resolve()).replace("\\", "\\\\").replace('"', '\\"')
    args = ["curl", "--disable", "--config", "-", "--silent", "--request", "POST",
            "--url", "https://api.elevenlabs.io/v1/speech-to-text",
            "--connect-timeout", "20", "--max-time", "110",
            "--form", "model_id=scribe_v2", "--form", f'file=@"{audio_path}"',
            "--form", "tag_audio_events=false", "--write-out", "\n%{http_code}"]
    if language and language != "auto":
        args.extend(("--form-string", f"language_code={language}"))
    try:
        result = subprocess.run(args, input=f'header = "xi-api-key: {escaped}"\n',
                                text=True, capture_output=True, timeout=115, check=False)
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        raise RuntimeError("ElevenLabs request could not complete. Check your connection and retry.") from None
    if result.returncode:
        raise RuntimeError("ElevenLabs request could not complete. Check your connection and retry.")
    body, separator, status = result.stdout.rpartition("\n")
    if not separator or not re.fullmatch(r"[0-9]{3}", status):
        raise RuntimeError("ElevenLabs returned an unreadable response.")
    if status != "200":
        if status in ("401", "403"):
            raise RuntimeError(f"ElevenLabs authentication failed (HTTP {status}). Check your API key and speech-to-text access.")
        if status == "429":
            raise RuntimeError("ElevenLabs request limit reached (HTTP 429). Check account limits and retry later.")
        raise RuntimeError(f"ElevenLabs transcription failed (HTTP {status}). The recording is kept when recovery is available.")
    try:
        text = json.loads(body)["text"]
        if not isinstance(text, str):
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise RuntimeError("ElevenLabs returned an unreadable transcript.") from None
    sys.stdout.write(text)


def main():
    if sys.argv[1:] == ["available"]:
        print("true" if credential() else "false")
    elif len(sys.argv) == 4 and sys.argv[1] == "transcribe":
        transcribe(sys.argv[2], sys.argv[3])
    else:
        raise RuntimeError("Unsupported provider operation.")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
