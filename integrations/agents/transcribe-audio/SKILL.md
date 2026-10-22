---
name: transcribe-audio
description: Transcribe audio or video files (voice memos, dictaphone recordings, meeting audio, .m4a/.mp3/.wav/.aac/.flac/.ogg/.opus/.mp4/.mov) to text locally with the user's `khuluma transcribe` command (Parakeet, offline, model already installed). Use whenever the user gives an audio file or asks to transcribe, read, summarise, or turn a recording into notes, an SOP, tasks, or code. Do not install or download Whisper or any other speech model.
---

# Transcribe audio

The user has a local, offline speech-to-text CLI with a warm Parakeet model. Use it for any audio file instead of installing Whisper, pip packages, or calling a cloud API.

## Command

```bash
khuluma transcribe "<file>" -q                  # transcript on stdout, nothing else
khuluma transcribe "<file>" -q --format json    # {file, text, audio_duration_ms, processing_ms, model, engine}
khuluma transcribe "<a>" "<b>" -q --format json # one JSON object per line
khuluma transcribe "<file>" -q -o /tmp/memo.txt # write to a file instead
```

- Always quote paths; recordings often live on external volumes (e.g. `/Volumes/...`) or have spaces.
- `-q` keeps progress messages off stderr. stdout contains only the transcript (or JSON).
- Any format ffmpeg reads works, including video files (the audio track is used). The original file is never modified.
- Output is the raw transcript with punctuation. No speaker labels or timestamps yet.
- Speed: roughly 60x real time once warm (a 10-minute memo takes about 10-15 s). The first call after a reboot can take ~30 s to load the model, or a few minutes if the daemon has to be rebuilt. Use a generous timeout (10 min) for long recordings.
- Don't write `.txt` files next to the recording (`--beside`) unless the user asks: it may be on the recorder's own storage.

## Errors

The command exits non-zero with a `khuluma: ...` message on stderr:

- `not a readable file` - check the path; external volumes may be unmounted.
- `Parakeet daemon unavailable: ...` - run `khuluma warmup`, then retry. If it still fails, show the user the log path from the message rather than switching to another model.
- `no speech detected` - the recording is silent or too quiet; tell the user.
- `command not found: khuluma` - it lives in `~/.local/bin` or `/opt/homebrew/bin`; try the full path.

## After transcribing

Work from the transcript the user asked for (SOP, notes, tasks, code). Transcripts of spoken ideas are rambly: keep the user's intent and specifics (names, numbers, steps), drop filler, and ask about anything ambiguous instead of guessing. Mention the recording length if it's useful context.
