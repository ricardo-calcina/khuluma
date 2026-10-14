#!/usr/bin/env bash

# Integration helpers report the installed adapter surface in one place so
# Raycast scripts and install receipt drift can be inspected without hunting.

integration_path_exists_label() {
  [[ -e "${1:-}" ]] && printf '%s\n' "present" || printf '%s\n' "missing"
}

integration_path_executable_label() {
  local path="${1:-}"
  if [[ ! -e "$path" ]]; then
    printf '%s\n' "missing"
  elif [[ -x "$path" ]]; then
    printf '%s\n' "executable"
  else
    printf '%s\n' "not executable"
  fi
}

integration_receipt_value() {
  local key="${1:-}"
  local receipt="${2:-$DICTATE_CONFIG_DIR/install-receipt.env}"
  [[ -n "$key" && -r "$receipt" ]] || return 0
  (
    set +u
    # shellcheck disable=SC1090
    source "$receipt" 2>/dev/null || exit 0
    case "$key" in
      installed_at) printf '%s\n' "${installed_at:-}" ;;
      install_source) printf '%s\n' "${install_source:-}" ;;
      repo_git_ref) printf '%s\n' "${repo_git_ref:-}" ;;
      repo_git_commit) printf '%s\n' "${repo_git_commit:-}" ;;
      repo_root) printf '%s\n' "${repo_root:-}" ;;
      bin_path) printf '%s\n' "${bin_path:-}" ;;
      *) ;;
    esac
  )
}

integration_current_binary_path() {
  local found=""
  found="$(command -v tmux-whisper 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
  elif [[ -x "$SCRIPT_DIR/tmux-whisper" ]]; then
    printf '%s\n' "$SCRIPT_DIR/tmux-whisper"
  else
    printf '%s\n' "$SCRIPT_DIR/tmux-whisper"
  fi
}

# Adapter sources, in priority order:
#   1. <prefix>/share/tmux-whisper beside the running binary: Homebrew's
#      pkgshare, or the snapshot install.sh writes next to ~/.local/bin. This
#      is exactly what was installed, so drift is measured against it.
#   2. receipt repo_root, only when the receipt describes the running binary
#      (a stale local-install receipt must not drive a Homebrew install)
#   3. the checkout the binary is running from
integration_source_root() {
  local receipt_root receipt_bin candidate
  candidate="$(cd "$SCRIPT_DIR/../share/tmux-whisper" 2>/dev/null && pwd || true)"
  if [[ -n "$candidate" && -d "$candidate/integrations" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  receipt_root="$(integration_receipt_value repo_root)"
  receipt_bin="$(integration_receipt_value bin_path)"
  if [[ -n "$receipt_root" && -d "$receipt_root/integrations" \
    && ( -z "$receipt_bin" || "$receipt_bin" == "$(integration_current_binary_path)" ) ]]; then
    printf '%s\n' "$receipt_root"
    return 0
  fi

  candidate="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"
  if [[ -n "$candidate" && -d "$candidate/integrations" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s\n' ""
}

integration_expected_source() {
  local source_root="$1"
  local adapter="$2"
  [[ -n "$source_root" ]] || return 0
  case "$adapter" in
    raycast-inline) printf '%s\n' "$source_root/integrations/raycast/tmux-whisper-inline.sh" ;;
    raycast-toggle) printf '%s\n' "$source_root/integrations/raycast/tmux-whisper-toggle.sh" ;;
    raycast-cancel) printf '%s\n' "$source_root/integrations/raycast/tmux-whisper-cancel.sh" ;;
    *) ;;
  esac
}

integration_adapter_source_label() {
  local adapter="$1"
  case "$adapter" in
    raycast-inline) printf '%s\n' "Raycast inline" ;;
    raycast-toggle) printf '%s\n' "Raycast tmux-toggle" ;;
    raycast-cancel) printf '%s\n' "Raycast cancel" ;;
    *) printf '%s\n' "$adapter" ;;
  esac
}

integration_adapter_state() {
  local source_root="$1"
  local adapter="$2"
  local path="$3"
  local src

  if [[ ! -f "$path" ]]; then
    printf '%s\n' "missing"
    return 0
  fi
  if [[ ! -x "$path" ]]; then
    printf '%s\n' "non-executable"
    return 0
  fi
  if [[ -z "$source_root" ]]; then
    printf '%s\n' "source-unavailable"
    return 0
  fi

  src="$(integration_expected_source "$source_root" "$adapter")"
  if [[ -z "$src" || ! -f "$src" ]]; then
    printf '%s\n' "source-missing"
    return 0
  fi
  if cmp -s "$src" "$path"; then
    printf '%s\n' "current"
  else
    printf '%s\n' "different"
  fi
}

integration_adapter_source_path_label() {
  local source_root="$1"
  local adapter="$2"
  local src
  src="$(integration_expected_source "$source_root" "$adapter")"
  if [[ -n "$src" ]]; then
    printf '%s\n' "$src"
  else
    printf '%s\n' "unavailable"
  fi
}

integration_adapter_version() {
  local path="$1"
  local version=""
  if [[ -r "$path" ]]; then
    version="$(awk -F': ' '$1 == "# tmux-whisper.adapter-version" { print $2; exit }' "$path" 2>/dev/null || true)"
  fi
  if [[ -n "$version" ]]; then
    printf '%s\n' "$version"
  else
    printf '%s\n' "unknown"
  fi
}

integration_adapter_source_version() {
  local source_root="$1"
  local adapter="$2"
  local src
  src="$(integration_expected_source "$source_root" "$adapter")"
  integration_adapter_version "$src"
}

integration_adapter_version_label() {
  local path="$1"
  local source_root="$2"
  local adapter="$3"
  local installed_version source_version
  installed_version="$(integration_adapter_version "$path")"
  source_version="$(integration_adapter_source_version "$source_root" "$adapter")"
  printf '%s\n' "$installed_version (source: $source_version)"
}

integration_check_lines() {
  local binary_path="$1"
  local receipt_path="$2"
  local raycast_inline="$3"
  local raycast_toggle="$4"
  local raycast_cancel="$5"
  local receipt_bin_path="$6"
  local source_root="$7"

  if [[ ! -x "$binary_path" ]]; then
    printf '%s\n' "issue|binary|tmux-whisper binary is not executable at $binary_path"
  fi
  if [[ ! -r "$receipt_path" ]]; then
    printf '%s\n' "warn|receipt|install receipt is missing or unreadable at $receipt_path (expected for Homebrew installs)"
  fi
  if [[ -n "$receipt_bin_path" && "$receipt_bin_path" != "$binary_path" ]]; then
    printf '%s\n' "warn|receipt|install receipt binary points at $receipt_bin_path but PATH resolves $binary_path"
  fi

  local name path adapter src label
  for name in inline tmux-toggle cancel; do
    case "$name" in
      inline) path="$raycast_inline"; adapter="raycast-inline" ;;
      tmux-toggle) path="$raycast_toggle"; adapter="raycast-toggle" ;;
      cancel) path="$raycast_cancel"; adapter="raycast-cancel" ;;
    esac
    if [[ ! -f "$path" ]]; then
      printf '%s\n' "warn|raycast|Raycast $name script is missing at $path"
    elif [[ ! -x "$path" ]]; then
      printf '%s\n' "issue|raycast|Raycast $name script is not executable at $path"
    fi
    if [[ -n "$source_root" && -f "$path" ]]; then
      src="$(integration_expected_source "$source_root" "$adapter")"
      label="$(integration_adapter_source_label "$adapter")"
      if [[ -f "$src" ]] && ! cmp -s "$src" "$path"; then
        printf '%s\n' "warn|raycast|$label script differs from source at $src"
      fi
    fi
  done

  if [[ -z "$source_root" ]]; then
    printf '%s\n' "warn|source|adapter source files were not found; run a channel refresh if repair is needed"
  fi
}

integration_issue_count() {
  local lines="$1"
  printf '%s\n' "$lines" | awk -F'|' '$1 == "issue" { count++ } END { print count + 0 }'
}

integration_warn_count() {
  local lines="$1"
  printf '%s\n' "$lines" | awk -F'|' '$1 == "warn" { count++ } END { print count + 0 }'
}

integration_emit_doctor_text() {
  local lines="$1"
  local binary_path="$2"
  local receipt_path="$3"
  local raycast_inline="$4"
  local raycast_toggle="$5"
  local raycast_cancel="$6"
  local source_root="$7"
  local issue_count warn_count
  issue_count="$(integration_issue_count "$lines")"
  warn_count="$(integration_warn_count "$lines")"

  echo "Integration doctor:"
  if [[ "$issue_count" -eq 0 ]]; then
    echo "  status: ok ($warn_count warnings)"
  else
    echo "  status: needs repair ($issue_count issues, $warn_count warnings)"
  fi
  echo "  binary: $binary_path ($(integration_path_executable_label "$binary_path"))"
  echo "  install receipt: $receipt_path ($(integration_path_exists_label "$receipt_path"))"
  echo "  source: ${source_root:-unavailable}"
  echo ""
  echo "Raycast:"
  echo "  inline: $raycast_inline ($(integration_path_executable_label "$raycast_inline"))"
  echo "  inline state: $(integration_adapter_state "$source_root" raycast-inline "$raycast_inline")"
  echo "  inline version: $(integration_adapter_version_label "$raycast_inline" "$source_root" raycast-inline)"
  echo "  inline source: $(integration_adapter_source_path_label "$source_root" raycast-inline)"
  echo "  tmux-toggle: $raycast_toggle ($(integration_path_executable_label "$raycast_toggle"))"
  echo "  tmux-toggle state: $(integration_adapter_state "$source_root" raycast-toggle "$raycast_toggle")"
  echo "  tmux-toggle version: $(integration_adapter_version_label "$raycast_toggle" "$source_root" raycast-toggle)"
  echo "  tmux-toggle source: $(integration_adapter_source_path_label "$source_root" raycast-toggle)"
  echo "  cancel: $raycast_cancel ($(integration_path_executable_label "$raycast_cancel"))"
  echo "  cancel state: $(integration_adapter_state "$source_root" raycast-cancel "$raycast_cancel")"
  echo "  cancel version: $(integration_adapter_version_label "$raycast_cancel" "$source_root" raycast-cancel)"
  echo "  cancel source: $(integration_adapter_source_path_label "$source_root" raycast-cancel)"
  echo ""
  if [[ -n "$lines" ]]; then
    echo "Findings:"
    printf '%s\n' "$lines" | while IFS='|' read -r severity component message; do
      [[ -n "$severity" ]] || continue
      echo "  - $severity/$component: $message"
    done
  else
    echo "Findings:"
    echo "  - ok: integration adapters are present and executable"
  fi
  echo ""
  echo "Next:"
  echo "  tmux-whisper integrations repair --dry-run"
  echo "  tmux-whisper integrations repair"
  echo "  ./install.sh --force  # full local refresh fallback"
}

integration_emit_repair_dry_run_text() {
  local lines="$1"
  local raycast_inline="$2"
  local raycast_toggle="$3"
  local raycast_cancel="$4"
  local source_root="$5"
  local issue_count warn_count
  issue_count="$(integration_issue_count "$lines")"
  warn_count="$(integration_warn_count "$lines")"

  echo "Integration repair dry run:"
  echo "  files changed: 0"
  echo "  source: ${source_root:-unavailable}"
  echo "  findings: $issue_count issues, $warn_count warnings"
  echo ""
  echo "Adapter-only refresh plan:"

  local src
  src="$(integration_expected_source "$source_root" raycast-inline)"
  echo "  - would install Raycast inline: ${src:-<source unavailable>} -> $raycast_inline"
  src="$(integration_expected_source "$source_root" raycast-toggle)"
  echo "  - would install Raycast tmux-toggle: ${src:-<source unavailable>} -> $raycast_toggle"
  src="$(integration_expected_source "$source_root" raycast-cancel)"
  echo "  - would install Raycast cancel: ${src:-<source unavailable>} -> $raycast_cancel"
  echo "  - would back up replaced adapters to: $(integration_backup_dir)"
  echo "  - would ensure executable bits on installed adapter scripts"
  echo ""
  if [[ -n "$lines" ]]; then
    echo "Findings to address:"
    printf '%s\n' "$lines" | while IFS='|' read -r severity component message; do
      [[ -n "$severity" ]] || continue
      echo "  - $severity/$component: $message"
    done
  else
    echo "Findings to address:"
    echo "  - ok: no adapter repair currently needed"
  fi
  echo ""
  echo "Apply with: tmux-whisper integrations repair"
  echo "Full local refresh fallback: ./install.sh --force"
}

integration_repair_one_adapter() {
  local label="$1"
  local src="$2"
  local dest="$3"
  local log_file="$4"
  local backup_stamp="$5"
  local dest_dir backup_path

  if [[ -z "$src" || ! -f "$src" ]]; then
    printf '%s\n' "failed|$label|source missing: ${src:-<source unavailable>}" >>"$log_file"
    return 1
  fi

  dest_dir="$(dirname "$dest")"
  if ! mkdir -p "$dest_dir"; then
    printf '%s\n' "failed|$label|could not create directory: $dest_dir" >>"$log_file"
    return 1
  fi

  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    if [[ -x "$dest" ]]; then
      printf '%s\n' "unchanged|$label|already current and executable: $dest" >>"$log_file"
      return 0
    fi
    if chmod +x "$dest"; then
      printf '%s\n' "changed|$label|fixed executable bit: $dest" >>"$log_file"
      return 0
    fi
    printf '%s\n' "failed|$label|could not set executable bit: $dest" >>"$log_file"
    return 1
  fi

  if [[ -e "$dest" ]]; then
    # Keep backups out of adapter directories: Raycast loads every script in
    # its folder, so an executable backup there becomes a second command.
    backup_path="$(integration_backup_dir)/$(basename "$dest").$backup_stamp"
    if ! mkdir -p "$(dirname "$backup_path")" || ! cp "$dest" "$backup_path" || ! chmod -x "$backup_path"; then
      printf '%s\n' "failed|$label|could not create backup: $backup_path" >>"$log_file"
      return 1
    fi
    if ! cp "$src" "$dest"; then
      printf '%s\n' "failed|$label|could not replace $dest from $src" >>"$log_file"
      return 1
    fi
    if ! chmod +x "$dest"; then
      printf '%s\n' "failed|$label|replaced file but could not set executable bit: $dest" >>"$log_file"
      return 1
    fi
    printf '%s\n' "changed|$label|replaced: $src -> $dest; backup: $backup_path" >>"$log_file"
    return 0
  fi

  if ! cp "$src" "$dest"; then
    printf '%s\n' "failed|$label|could not install $dest from $src" >>"$log_file"
    return 1
  fi
  if ! chmod +x "$dest"; then
    printf '%s\n' "failed|$label|installed file but could not set executable bit: $dest" >>"$log_file"
    return 1
  fi
  printf '%s\n' "changed|$label|installed: $src -> $dest" >>"$log_file"
}

integration_backup_dir() {
  printf '%s\n' "$DICTATE_CONFIG_DIR/backups/integrations"
}

integration_repair_action_count() {
  local log_file="$1"
  awk -F'|' '$1 == "changed" { count++ } END { print count + 0 }' "$log_file"
}

integration_repair_failed_count() {
  local log_file="$1"
  awk -F'|' '$1 == "failed" { count++ } END { print count + 0 }' "$log_file"
}

integration_emit_repair_text() {
  local lines="$1"
  local raycast_inline="$2"
  local raycast_toggle="$3"
  local raycast_cancel="$4"
  local source_root="$5"
  local binary_path="$6"
  local receipt_path="$7"
  local receipt_bin_path="$8"
  local issue_count warn_count backup_stamp log_file changed_count failed_count
  issue_count="$(integration_issue_count "$lines")"
  warn_count="$(integration_warn_count "$lines")"

  log_file="$(mktemp "${TMPDIR:-/tmp}/tmux-whisper-integrations-repair.XXXXXX")"
  backup_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"

  integration_repair_one_adapter "Raycast inline" \
    "$(integration_expected_source "$source_root" raycast-inline)" "$raycast_inline" "$log_file" "$backup_stamp" || true
  integration_repair_one_adapter "Raycast tmux-toggle" \
    "$(integration_expected_source "$source_root" raycast-toggle)" "$raycast_toggle" "$log_file" "$backup_stamp" || true
  integration_repair_one_adapter "Raycast cancel" \
    "$(integration_expected_source "$source_root" raycast-cancel)" "$raycast_cancel" "$log_file" "$backup_stamp" || true

  changed_count="$(integration_repair_action_count "$log_file")"
  failed_count="$(integration_repair_failed_count "$log_file")"

  local post_lines post_issues post_warnings
  post_lines="$(integration_check_lines "$binary_path" "$receipt_path" \
    "$raycast_inline" "$raycast_toggle" "$raycast_cancel" "$receipt_bin_path" "$source_root")"
  post_issues="$(integration_issue_count "$post_lines")"
  post_warnings="$(integration_warn_count "$post_lines")"

  echo "Integration repair:"
  echo "  files changed: $changed_count"
  echo "  source: ${source_root:-unavailable}"
  echo "  findings before repair: $issue_count issues, $warn_count warnings"
  echo "  findings after repair: $post_issues issues, $post_warnings warnings"
  echo ""
  echo "Adapter-only refresh:"
  while IFS='|' read -r status label message; do
    [[ -n "$status" ]] || continue
    echo "  - $status $label: $message"
  done <"$log_file"
  rm -f "$log_file"
  echo ""
  echo "Next:"
  echo "  tmux-whisper integrations doctor"
  echo "  tmux-whisper integrations repair --dry-run"

  [[ "$failed_count" -eq 0 && "$post_issues" -eq 0 ]]
}

integrations_status_json() {
  local binary_path="$1"
  local receipt_path="$2"
  local raycast_inline="$3"
  local raycast_toggle="$4"
  local raycast_cancel="$5"
  local receipt_installed_at="$6"
  local receipt_source="$7"
  local receipt_ref="$8"
  local receipt_commit="$9"
  local source_root="${10}"

  INTEGRATIONS_BINARY_PATH="$binary_path" \
  INTEGRATIONS_BINARY_EXISTS="$([[ -x "$binary_path" ]] && echo true || echo false)" \
  INTEGRATIONS_CONFIG_DIR="$DICTATE_CONFIG_DIR" \
  INTEGRATIONS_SOURCE_ROOT="$source_root" \
  INTEGRATIONS_RECEIPT_PATH="$receipt_path" \
  INTEGRATIONS_RECEIPT_EXISTS="$([[ -r "$receipt_path" ]] && echo true || echo false)" \
  INTEGRATIONS_RECEIPT_INSTALLED_AT="$receipt_installed_at" \
  INTEGRATIONS_RECEIPT_SOURCE="$receipt_source" \
  INTEGRATIONS_RECEIPT_REF="$receipt_ref" \
  INTEGRATIONS_RECEIPT_COMMIT="$receipt_commit" \
  INTEGRATIONS_RAYCAST_INLINE="$raycast_inline" \
  INTEGRATIONS_RAYCAST_INLINE_EXISTS="$([[ -f "$raycast_inline" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_INLINE_EXECUTABLE="$([[ -x "$raycast_inline" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_INLINE_STATE="$(integration_adapter_state "$source_root" raycast-inline "$raycast_inline")" \
  INTEGRATIONS_RAYCAST_INLINE_VERSION="$(integration_adapter_version "$raycast_inline")" \
  INTEGRATIONS_RAYCAST_INLINE_SOURCE="$(integration_adapter_source_path_label "$source_root" raycast-inline)" \
  INTEGRATIONS_RAYCAST_INLINE_SOURCE_VERSION="$(integration_adapter_source_version "$source_root" raycast-inline)" \
  INTEGRATIONS_RAYCAST_INLINE_SOURCE_EXISTS="$([[ -f "$(integration_expected_source "$source_root" raycast-inline)" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_TOGGLE="$raycast_toggle" \
  INTEGRATIONS_RAYCAST_TOGGLE_EXISTS="$([[ -f "$raycast_toggle" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_TOGGLE_EXECUTABLE="$([[ -x "$raycast_toggle" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_TOGGLE_STATE="$(integration_adapter_state "$source_root" raycast-toggle "$raycast_toggle")" \
  INTEGRATIONS_RAYCAST_TOGGLE_VERSION="$(integration_adapter_version "$raycast_toggle")" \
  INTEGRATIONS_RAYCAST_TOGGLE_SOURCE="$(integration_adapter_source_path_label "$source_root" raycast-toggle)" \
  INTEGRATIONS_RAYCAST_TOGGLE_SOURCE_VERSION="$(integration_adapter_source_version "$source_root" raycast-toggle)" \
  INTEGRATIONS_RAYCAST_TOGGLE_SOURCE_EXISTS="$([[ -f "$(integration_expected_source "$source_root" raycast-toggle)" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_CANCEL="$raycast_cancel" \
  INTEGRATIONS_RAYCAST_CANCEL_EXISTS="$([[ -f "$raycast_cancel" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_CANCEL_EXECUTABLE="$([[ -x "$raycast_cancel" ]] && echo true || echo false)" \
  INTEGRATIONS_RAYCAST_CANCEL_STATE="$(integration_adapter_state "$source_root" raycast-cancel "$raycast_cancel")" \
  INTEGRATIONS_RAYCAST_CANCEL_VERSION="$(integration_adapter_version "$raycast_cancel")" \
  INTEGRATIONS_RAYCAST_CANCEL_SOURCE="$(integration_adapter_source_path_label "$source_root" raycast-cancel)" \
  INTEGRATIONS_RAYCAST_CANCEL_SOURCE_VERSION="$(integration_adapter_source_version "$source_root" raycast-cancel)" \
  INTEGRATIONS_RAYCAST_CANCEL_SOURCE_EXISTS="$([[ -f "$(integration_expected_source "$source_root" raycast-cancel)" ]] && echo true || echo false)" \
  python3 - <<'PYEOF'
import json
import os

def b(name):
    return os.environ.get(name) == "true"

payload = {
    "command": "integrations",
    "binary": {
        "path": os.environ.get("INTEGRATIONS_BINARY_PATH", ""),
        "exists": b("INTEGRATIONS_BINARY_EXISTS"),
    },
    "config_dir": os.environ.get("INTEGRATIONS_CONFIG_DIR", ""),
    "source": {
        "root": os.environ.get("INTEGRATIONS_SOURCE_ROOT", ""),
    },
    "receipt": {
        "path": os.environ.get("INTEGRATIONS_RECEIPT_PATH", ""),
        "exists": b("INTEGRATIONS_RECEIPT_EXISTS"),
        "installed_at": os.environ.get("INTEGRATIONS_RECEIPT_INSTALLED_AT", ""),
        "install_source": os.environ.get("INTEGRATIONS_RECEIPT_SOURCE", ""),
        "repo_git_ref": os.environ.get("INTEGRATIONS_RECEIPT_REF", ""),
        "repo_git_commit": os.environ.get("INTEGRATIONS_RECEIPT_COMMIT", ""),
    },
    "raycast": {
        "scripts": [
            {
                "name": "inline",
                "path": os.environ.get("INTEGRATIONS_RAYCAST_INLINE", ""),
                "exists": b("INTEGRATIONS_RAYCAST_INLINE_EXISTS"),
                "executable": b("INTEGRATIONS_RAYCAST_INLINE_EXECUTABLE"),
                "state": os.environ.get("INTEGRATIONS_RAYCAST_INLINE_STATE", ""),
                "version": os.environ.get("INTEGRATIONS_RAYCAST_INLINE_VERSION", ""),
                "source_path": os.environ.get("INTEGRATIONS_RAYCAST_INLINE_SOURCE", ""),
                "source_version": os.environ.get("INTEGRATIONS_RAYCAST_INLINE_SOURCE_VERSION", ""),
                "source_exists": b("INTEGRATIONS_RAYCAST_INLINE_SOURCE_EXISTS"),
            },
            {
                "name": "tmux-toggle",
                "path": os.environ.get("INTEGRATIONS_RAYCAST_TOGGLE", ""),
                "exists": b("INTEGRATIONS_RAYCAST_TOGGLE_EXISTS"),
                "executable": b("INTEGRATIONS_RAYCAST_TOGGLE_EXECUTABLE"),
                "state": os.environ.get("INTEGRATIONS_RAYCAST_TOGGLE_STATE", ""),
                "version": os.environ.get("INTEGRATIONS_RAYCAST_TOGGLE_VERSION", ""),
                "source_path": os.environ.get("INTEGRATIONS_RAYCAST_TOGGLE_SOURCE", ""),
                "source_version": os.environ.get("INTEGRATIONS_RAYCAST_TOGGLE_SOURCE_VERSION", ""),
                "source_exists": b("INTEGRATIONS_RAYCAST_TOGGLE_SOURCE_EXISTS"),
            },
            {
                "name": "cancel",
                "path": os.environ.get("INTEGRATIONS_RAYCAST_CANCEL", ""),
                "exists": b("INTEGRATIONS_RAYCAST_CANCEL_EXISTS"),
                "executable": b("INTEGRATIONS_RAYCAST_CANCEL_EXECUTABLE"),
                "state": os.environ.get("INTEGRATIONS_RAYCAST_CANCEL_STATE", ""),
                "version": os.environ.get("INTEGRATIONS_RAYCAST_CANCEL_VERSION", ""),
                "source_path": os.environ.get("INTEGRATIONS_RAYCAST_CANCEL_SOURCE", ""),
                "source_version": os.environ.get("INTEGRATIONS_RAYCAST_CANCEL_SOURCE_VERSION", ""),
                "source_exists": b("INTEGRATIONS_RAYCAST_CANCEL_SOURCE_EXISTS"),
            },
        ],
    },
    "next": [
        "run tmux-whisper integrations doctor to diagnose adapter lifecycle drift",
        "run tmux-whisper integrations repair --dry-run to preview adapter-only refresh actions",
        "run tmux-whisper integrations repair to refresh adapter files only",
        "run ./install.sh --force for the current full local refresh fallback"
    ],
}
print(json.dumps(payload, sort_keys=True))
PYEOF
}

manage_integrations() {
  local action="${1:-status}"
  shift 2>/dev/null || true
  local json_output="0"
  local dry_run="0"
  case "$action" in
    ""|show|status|doctor) ;;
    --json)
      json_output="1"
      action="status"
      ;;
    repair) ;;
    *)
      die "usage: tmux-whisper integrations [status|doctor|repair [--dry-run]|--json]"
      ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_output="1" ;;
      --dry-run) dry_run="1" ;;
      *) die "usage: tmux-whisper integrations [status|doctor|repair [--dry-run]|--json]" ;;
    esac
    shift
  done
  if [[ "$json_output" == "1" && "$action" != "status" ]]; then
    die "usage: tmux-whisper integrations [status|--json]"
  fi

  local binary_path receipt_path
  local raycast_inline raycast_toggle raycast_cancel
  binary_path="$(integration_current_binary_path)"
  receipt_path="$DICTATE_CONFIG_DIR/install-receipt.env"
  raycast_inline="$DICTATE_CONFIG_DIR/integrations/raycast/tmux-whisper-inline.sh"
  raycast_toggle="$DICTATE_CONFIG_DIR/integrations/raycast/tmux-whisper-toggle.sh"
  raycast_cancel="$DICTATE_CONFIG_DIR/integrations/raycast/tmux-whisper-cancel.sh"

  local receipt_installed_at receipt_source receipt_ref receipt_commit
  local receipt_bin_path source_root
  receipt_installed_at="$(integration_receipt_value installed_at "$receipt_path")"
  receipt_source="$(integration_receipt_value install_source "$receipt_path")"
  receipt_ref="$(integration_receipt_value repo_git_ref "$receipt_path")"
  receipt_commit="$(integration_receipt_value repo_git_commit "$receipt_path")"
  receipt_bin_path="$(integration_receipt_value bin_path "$receipt_path")"
  source_root="$(integration_source_root)"

  if [[ "$action" == "doctor" || "$action" == "repair" ]]; then
    local findings
    findings="$(integration_check_lines "$binary_path" "$receipt_path" \
      "$raycast_inline" "$raycast_toggle" "$raycast_cancel" "$receipt_bin_path" "$source_root")"
    if [[ "$action" == "repair" ]]; then
      if [[ "$dry_run" == "1" ]]; then
        integration_emit_repair_dry_run_text "$findings" \
          "$raycast_inline" "$raycast_toggle" "$raycast_cancel" "$source_root"
      else
        integration_emit_repair_text "$findings" \
          "$raycast_inline" "$raycast_toggle" "$raycast_cancel" "$source_root" \
          "$binary_path" "$receipt_path" "$receipt_bin_path"
      fi
    else
      integration_emit_doctor_text "$findings" "$binary_path" "$receipt_path" \
        "$raycast_inline" "$raycast_toggle" "$raycast_cancel" "$source_root"
    fi
    return 0
  fi

  if [[ "$json_output" == "1" ]]; then
    integrations_status_json "$binary_path" "$receipt_path" \
      "$raycast_inline" "$raycast_toggle" "$raycast_cancel" \
      "$receipt_installed_at" "$receipt_source" "$receipt_ref" "$receipt_commit" "$source_root"
    return 0
  fi

  echo "Integrations:"
  echo "  binary: $binary_path ($(integration_path_executable_label "$binary_path"))"
  echo "  config: $DICTATE_CONFIG_DIR"
  echo "  install receipt: $receipt_path ($(integration_path_exists_label "$receipt_path"))"
  if [[ -n "$receipt_installed_at" ]]; then
    echo "  installed_at: $receipt_installed_at"
  fi
  if [[ -n "$receipt_ref" || -n "$receipt_commit" ]]; then
    echo "  installed_ref: ${receipt_ref:-unknown} ${receipt_commit:-}"
  fi
  echo "  source: ${source_root:-unavailable}"
  echo ""
  echo "Raycast:"
  echo "  inline: $raycast_inline ($(integration_path_executable_label "$raycast_inline"))"
  echo "  inline state: $(integration_adapter_state "$source_root" raycast-inline "$raycast_inline")"
  echo "  inline version: $(integration_adapter_version_label "$raycast_inline" "$source_root" raycast-inline)"
  echo "  inline source: $(integration_adapter_source_path_label "$source_root" raycast-inline)"
  echo "  tmux-toggle: $raycast_toggle ($(integration_path_executable_label "$raycast_toggle"))"
  echo "  tmux-toggle state: $(integration_adapter_state "$source_root" raycast-toggle "$raycast_toggle")"
  echo "  tmux-toggle version: $(integration_adapter_version_label "$raycast_toggle" "$source_root" raycast-toggle)"
  echo "  tmux-toggle source: $(integration_adapter_source_path_label "$source_root" raycast-toggle)"
  echo "  cancel: $raycast_cancel ($(integration_path_executable_label "$raycast_cancel"))"
  echo "  cancel state: $(integration_adapter_state "$source_root" raycast-cancel "$raycast_cancel")"
  echo "  cancel version: $(integration_adapter_version_label "$raycast_cancel" "$source_root" raycast-cancel)"
  echo "  cancel source: $(integration_adapter_source_path_label "$source_root" raycast-cancel)"
  echo ""
  echo "Next:"
  echo "  tmux-whisper integrations doctor"
  echo "  tmux-whisper integrations repair --dry-run"
  echo "  tmux-whisper integrations repair"
  echo "  ./install.sh --force  # full local refresh fallback"
}
