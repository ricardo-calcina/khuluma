#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bin/khuluma-lib.sh"

pass() {
  printf "PASS: %s\n" "$1"
}

fail() {
  printf "FAIL: %s\n" "$1" >&2
  exit 1
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf "Expected: [%s]\nActual:   [%s]\n" "$expected" "$actual" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf "Did not find [%s] in [%s]\n" "$needle" "$haystack" >&2
    fail "$name"
  fi
  pass "$name"
}

trim_nl() {
  tr -d '\n'
}

assert_eq "expand_path_home" "$HOME/tmp" "$(khuluma_lib_expand_path '~/tmp')"

SOUNDS_DIR="/tmp/example-sounds"
export SOUNDS_DIR
assert_eq "expand_sound_path" "/tmp/example-sounds/dictate/start.wav" "$(khuluma_lib_expand_sound_path '$SOUNDS_DIR/dictate/start.wav')"
unset SOUNDS_DIR

cleaned="$(printf '%s' 'um, I mean basically this is fine' | khuluma_lib_clean_fillers | trim_nl)"
assert_eq "clean_fillers_preserve_wording" "I mean basically this is fine" "$cleaned"
assert_eq "clean_fillers_hesitation" "I think we should keep it, but I believe it needs work." \
  "$(printf '%s' 'Um, I think we should keep it, uh but I believe it needs work.' | khuluma_lib_clean_fillers)"
assert_eq "clean_fillers_protected_text" 'The word "um", `uh`, /um/file and um.txt stay.' \
  "$(printf '%s' 'The word "um", `uh`, /um/file and um.txt stay.' | khuluma_lib_clean_fillers)"

repeats1="$(printf '%s' 'this this is is fine fine' | khuluma_lib_clean_repeats 1 | trim_nl)"
assert_eq "clean_repeats_level1" "this is fine" "$repeats1"

repeats2="$(printf '%s' 'go to go to the store' | khuluma_lib_clean_repeats 2 | trim_nl)"
assert_eq "clean_repeats_level2" "go to the store" "$repeats2"
assert_eq "clean_repeated_sentence" "Please use the existing local app. Then check the result." \
  "$(printf '%s' 'Please use the existing local app. Please use the existing local app. Then check the result.' | khuluma_lib_clean_repeats 3)"
assert_eq "clean_repeated_sentence_three_times" "Please use the existing local app." \
  "$(printf '%s' 'Please use the existing local app. please use the existing local app. Please use the existing local app.' | khuluma_lib_clean_repeats 3)"
assert_eq "clean_repeated_sentence_correction" "Please use the existing local app. Please use the newer local app." \
  "$(printf '%s' 'Please use the existing local app. Please use the newer local app.' | khuluma_lib_clean_repeats 3)"
assert_eq "clean_repeated_short_emphasis" "Do it now. Do it now." \
  "$(printf '%s' 'Do it now. Do it now.' | khuluma_lib_clean_repeats 3)"
assert_eq "clean_repeated_words_preserve_meaning" "I had had enough. It is very very good that that works." \
  "$(printf '%s' 'I had had enough. It is very very good that that works.' | khuluma_lib_clean_repeats 3)"
assert_eq "clean_repeated_sentence_opt_in" "Please use the existing local app. Please use the existing local app." \
  "$(printf '%s' 'Please use the existing local app. Please use the existing local app.' | khuluma_lib_clean_repeats 2)"

sanitized="$(printf '%s' '[blank audio] hello (blank_audio) world' | khuluma_lib_sanitize_transcript_artifacts | trim_nl)"
assert_eq "sanitize_artifacts" "hello world" "$sanitized"

british="$(printf '%s' 'Color and optimize behavior.' | khuluma_lib_normalize_british_spelling 1 | trim_nl)"
assert_eq "british_spelling" "Colour and optimise behaviour." "$british"

cfg_tmp="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$cfg_tmp"
source "$ROOT/tests/fixture_helpers.sh"
trap report_fixture_root EXIT
printf '%s\n' 'codex -> Codex' > "$cfg_tmp/vocab"
printf '%s\n' 'coreml -> CoreML' >> "$cfg_tmp/vocab"
printf '%s\n' 'qwen -> Qwen' >> "$cfg_tmp/vocab"
printf '%s\n' 'qwen three point five -> Qwen 3.5' >> "$cfg_tmp/vocab"
printf '%s\n' 'at saw slash::@src/' >> "$cfg_tmp/vocab"
printf '%s\n' 'tmux -> Tmux' >> "$cfg_tmp/vocab"
printf '%s\n' 'tmux whisper -> tmux-whisper' >> "$cfg_tmp/vocab"
# Modes are gone: a leftover modes/<name>/vocab is never read.
mkdir -p "$cfg_tmp/modes/code"
printf '%s\n' 'codex -> CODEX' 'zebra -> Zebra' > "$cfg_tmp/modes/code/vocab"
vocab_out="$(printf '%s' 'codex and tmux' | khuluma_lib_apply_vocab_corrections "$cfg_tmp" | trim_nl)"
assert_eq "vocab_corrections" "Codex and Tmux" "$vocab_out"
assert_eq "vocab_sentence_punctuation" "Codex. Codex... codex.txt codex-lock.yaml" \
  "$(printf '%s' 'codex. codex... codex.txt codex-lock.yaml' | khuluma_lib_apply_vocab_corrections "$cfg_tmp")"
vocab_spaced_out="$(printf '%s' 'c o r e m l and q w e n' | khuluma_lib_apply_vocab_corrections "$cfg_tmp" | trim_nl)"
assert_eq "vocab_spaced_acronyms" "CoreML and Qwen" "$vocab_spaced_out"
vocab_specific_phrase="$(printf '%s' 'qwen three point five is fast' | khuluma_lib_apply_vocab_corrections "$cfg_tmp" | trim_nl)"
assert_eq "vocab_specific_phrase_wins" "Qwen 3.5 is fast" "$vocab_specific_phrase"
vocab_longer_phrase="$(printf '%s' 'tmux whisper in codex' | khuluma_lib_apply_vocab_corrections "$cfg_tmp" | trim_nl)"
assert_eq "vocab_longer_phrase_first" "tmux-whisper in Codex" "$vocab_longer_phrase"
vocab_path_shortcut="$(printf '%s' 'open at saw slash components' | khuluma_lib_apply_vocab_corrections "$cfg_tmp" | trim_nl)"
assert_eq "vocab_path_shortcuts" "open @src/ components" "$vocab_path_shortcut"
vocab_no_modes="$(printf '%s' 'a zebra' | khuluma_lib_apply_vocab_corrections "$cfg_tmp" | trim_nl)"
assert_eq "vocab_ignores_modes" "a zebra" "$vocab_no_modes"

echo "All lib helper tests passed."
