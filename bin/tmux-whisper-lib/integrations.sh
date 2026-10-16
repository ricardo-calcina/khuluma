#!/usr/bin/env bash

# Install-layout helpers: read the install receipt and find the installed
# integration sources (the Finder Quick Action handler) beside the binary.

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

# Integration sources, in priority order:
#   1. <prefix>/share/tmux-whisper beside the running binary: Homebrew's
#      pkgshare, or the snapshot install.sh writes next to ~/.local/bin. This
#      is exactly what was installed.
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
