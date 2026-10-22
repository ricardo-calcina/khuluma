#!/usr/bin/env bash

# Install-layout helpers: read the install receipt and find the installed
# integration sources (the Finder Quick Action handler) beside the binary.

integration_receipt_value() {
  local key="${1:-}"
  local receipt="${2:-$KHULUMA_CONFIG_DIR/install-receipt.env}"
  [[ -n "$key" && -r "$receipt" ]] || return 0
  khuluma_receipt_value "$key" "$receipt" "${KHULUMA_RUNNING_BINARY:-$0}"
}

integration_current_binary_path() {
  khuluma_absolute_path "${KHULUMA_RUNNING_BINARY:-$0}"
}

# Integration sources, in priority order:
#   1. <prefix>/share/khuluma beside the running binary: Homebrew's
#      pkgshare, or the snapshot install.sh writes next to ~/.local/bin. This
#      is exactly what was installed.
#   2. receipt repo_root, only when the receipt describes the running binary
#      (a stale local-install receipt must not drive a Homebrew install)
#   3. the checkout the binary is running from
integration_source_root() {
  local receipt_root receipt_bin candidate
  candidate="$(cd "$SCRIPT_DIR/../share/khuluma" 2>/dev/null && pwd || true)"
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
