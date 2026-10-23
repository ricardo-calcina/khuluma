#!/usr/bin/env bash

# khuluma-shell-library-api: 1
# Shared helpers used by Khuluma CLI + integrations.

# Expand leading ~ to $HOME.
khuluma_lib_expand_path() {
  local p="${1:-}"
  if [[ "$p" == "~"* ]]; then
    p="$HOME${p:1}"
  fi
  printf "%s" "$p"
}

# Expand $SOUNDS_DIR placeholders in configured paths.
khuluma_lib_expand_sound_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 0
  p="$(khuluma_lib_expand_path "$p")"
  if [[ -n "${SOUNDS_DIR:-}" ]]; then
    p="${p//\$\{SOUNDS_DIR\}/$SOUNDS_DIR}"
    p="${p//\$SOUNDS_DIR/$SOUNDS_DIR}"
  fi
  printf "%s" "$p"
}

# Remove hesitation sounds, preserving hedges, corrections and quoted words.
khuluma_lib_clean_fillers() {
  perl -pe '
    s/(?<![\w.\/@\x27"`-])\b(?:um+|uh+|erm)\b(?![\w\/@\x27"`-]|\.[A-Za-z0-9])[,.]?\s*//gi;
    s/\s+/ /g;
    s/^ //; s/ $//;
    s/ ,/,/g; s/ \././g; s/,,/,/g;
  '
}

# Clean stutters/repeats.
# Level 0: off
# Level 1: repeated words
# Level 2: repeated 2-3 word adjacent phrases + repeated words
# Level 3: exact adjacent sentences of at least five words only
khuluma_lib_clean_repeats() {
  local level="${1:-1}"
  KHULUMA_REPEATS_LEVEL="$level" perl -pe '
    my $level = $ENV{KHULUMA_REPEATS_LEVEL} // 1;
    $level = int($level);
    my $w = qr/[A-Za-z]+(?:\x27[A-Za-z]+)*/;

    if ($level >= 3) {
      s/\s+/ /g;
      my $changed;
      do {
        $changed = 0;
        s{(^|[.!?] +)([A-Za-z0-9][^.!?\r\n]{0,2000}[.!?]) +\2(?=\s|$)}{
          my ($original, $prefix, $sentence) = ($&, $1, $2);
          my @words = ($sentence =~ /[A-Za-z0-9]+(?:\x27[A-Za-z0-9]+)*/g);
          if (@words >= 5) { $changed = 1; $prefix . $sentence } else { $original }
        }gei;
      } while ($changed);
    }
    if ($level >= 2 && $level < 3) {
      1 while s/\b($w)\s+($w)\s+($w)\b\s+\1\s+\2\s+\3\b/$1 $2 $3/gi;
      1 while s/\b($w)\s+($w)\b\s+\1\s+\2\b/$1 $2/gi;
    }
    if ($level >= 1 && $level < 3) {
      1 while s/\b($w)\b\s+\1\b/$1/gi;
    }
    s/\s+/ /g; s/^ //; s/ $//;
  '
}

# Remove known whisper placeholder artefacts (e.g. [blank audio]).
khuluma_lib_sanitize_transcript_artifacts() {
  perl -pe '
    s/\[\s*blank(?:\s*[_-]\s*|\s+)audio\s*\]//ig;
    s/\(\s*blank(?:\s*[_-]\s*|\s+)audio\s*\)//ig;
    s/\{\s*blank(?:\s*[_-]\s*|\s+)audio\s*\}//ig;
    s/\s+([,.;:!?])/$1/g;
    s/([(\[{])\s+/$1/g;
    s/\s+([)\]}])/$1/g;
    s/[ \t]{2,}/ /g;
    s/^ +//; s/ +$//;
  '
}

# Normalize common US spellings to UK spellings.
# Set KHULUMA_BRITISH_SPELLING=0 to disable.
khuluma_lib_normalize_british_spelling() {
  local enabled="${1:-1}"
  enabled="$(printf "%s" "$enabled" | tr '[:upper:]' '[:lower:]')"
  case "$enabled" in
    0|off|false|no) cat; return 0 ;;
  esac

  perl -pe '
    sub _case_match {
      my ($orig, $rep) = @_;
      return uc($rep) if $orig eq uc($orig);
      return ucfirst($rep) if $orig =~ /^[A-Z][a-z]+$/;
      return $rep;
    }

    BEGIN {
      %map = (
        "color" => "colour", "colors" => "colours", "colored" => "coloured", "coloring" => "colouring",
        "favorite" => "favourite", "favorites" => "favourites", "favorited" => "favourited", "favoriting" => "favouriting",
        "organize" => "organise", "organizes" => "organises", "organized" => "organised", "organizing" => "organising",
        "organization" => "organisation", "organizations" => "organisations",
        "optimize" => "optimise", "optimizes" => "optimises", "optimized" => "optimised", "optimizing" => "optimising",
        "optimization" => "optimisation", "optimizations" => "optimisations",
        "optimizer" => "optimiser", "optimizers" => "optimisers",
        "prioritize" => "prioritise", "prioritizes" => "prioritises", "prioritized" => "prioritised", "prioritizing" => "prioritising",
        "prioritization" => "prioritisation", "prioritizations" => "prioritisations",
        "behavior" => "behaviour", "behaviors" => "behaviours", "behavioral" => "behavioural",
        "center" => "centre", "centers" => "centres", "centered" => "centred", "centering" => "centring",
        "centralize" => "centralise", "centralizes" => "centralises", "centralized" => "centralised", "centralizing" => "centralising",
        "centralization" => "centralisation", "centralizations" => "centralisations",
        "analyze" => "analyse", "analyzes" => "analyses", "analyzed" => "analysed", "analyzing" => "analysing",
        "analyzer" => "analyser", "analyzers" => "analysers",
        "realize" => "realise", "realizes" => "realises", "realized" => "realised", "realizing" => "realising"
      );
      $re = join("|", map { quotemeta($_) } sort { length($b) <=> length($a) } keys %map);
    }

    s/\b($re)\b/_case_match($1, $map{lc($1)})/gei;
  '
}

# Apply the vocab file's corrections as a deterministic text pass.
# Usage: printf "%s" "$text" | khuluma_lib_apply_vocab_corrections [config_dir]
khuluma_lib_apply_vocab_corrections() {
  local config_dir="${1:-${KHULUMA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/khuluma}}"
  local vocab_file="$config_dir/vocab"
  local files=()

  [[ -f "$vocab_file" ]] && files+=("$vocab_file")

  if [[ "${#files[@]}" -eq 0 ]]; then
    cat
    return 0
  fi

  local files_joined=""
  local file_path
  for file_path in "${files[@]}"; do
    if [[ -z "$files_joined" ]]; then
      files_joined="$file_path"
    else
      files_joined="${files_joined}"$'\n'"$file_path"
    fi
  done

  KHULUMA_VOCAB_FILES="$files_joined" perl -CS -pe '
    BEGIN {
      my @paths = grep { defined($_) && length($_) } split(/\n/, ($ENV{KHULUMA_VOCAB_FILES} // ""));
      @rules = ();

      sub compact_spelled_acronyms {
        my ($text) = @_;
        $text =~ s{
          (?<![[:alnum:]_])
          ((?:[A-Za-z](?:[\s._-]+)){2,7}[A-Za-z])
          (?![[:alnum:]_])
        }{
          my $seq = $1;
          my @letters = ($seq =~ /([A-Za-z])/g);
          my %uniq = map { lc($_) => 1 } @letters;
          if (@letters >= 3 && @letters <= 8 && scalar(keys %uniq) > 1) {
            my $joined = join("", @letters);
            $joined = lc($joined) if $seq eq lc($seq);
            $joined = uc($joined) if $seq eq uc($seq);
            $joined;
          } else {
            $seq;
          }
        }gex;
        return $text;
      }

      sub build_rule_regex {
        my ($left) = @_;
        my @parts = grep { length($_) } split(/\s+/, $left);
        my $pattern = join("\\s+", map { quotemeta($_) } @parts);
        my $first = substr($left, 0, 1);
        my $last = substr($left, -1);
        if ($first =~ /[A-Za-z0-9_]/) {
          $pattern = "(?<![A-Za-z0-9_.-])" . $pattern;
        }
        if ($last =~ /[A-Za-z0-9_]/) {
          # A terminal full stop is punctuation; a dot followed by an
          # identifier is a filename/domain suffix and stays protected.
          $pattern .= "(?![A-Za-z0-9_-]|\\.[[:alnum:]_-])";
        }
        return qr/$pattern/i;
      }

      for my $path (@paths) {
        next unless -f $path;
        open(my $fh, "<:encoding(UTF-8)", $path) or next;
        my @path_rules = ();
        while (my $line = <$fh>) {
          chomp($line);
          $line =~ s/^\s+//;
          $line =~ s/\s+$//;
          next if $line eq "" || $line =~ /^#/;

          my ($left, $right);
          if ($line =~ /^(.*?)\s*::\s*(.*?)$/) {
            ($left, $right) = ($1, $2);
          } elsif ($line =~ /^(.*?)\s*(?:\x{2192}|->)\s*(.*?)$/) {
            ($left, $right) = ($1, $2);
          } else {
            next;
          }

          $left =~ s/^\s+//;
          $left =~ s/\s+$//;
          $right =~ s/^\s+//;
          $right =~ s/\s+$//;
          next if $left eq "" || $right eq "";

          push(@path_rules, [$left, $right]);
        }
        close($fh);

        @path_rules = sort {
          length($b->[0]) <=> length($a->[0]) || $a->[0] cmp $b->[0]
        } @path_rules;
        for my $entry (@path_rules) {
          my ($left, $right) = @$entry;
          push(@rules, [build_rule_regex($left), $right]);
        }
      }
    }

    $_ = compact_spelled_acronyms($_);
    for my $rule (@rules) {
      my ($rx, $replacement) = @$rule;
      s/$rx/$replacement/ge;
    }
    s/[ \t]{2,}/ /g;
    s/^[ \t]+//mg;
    s/[ \t]+$//mg;
  '
}
