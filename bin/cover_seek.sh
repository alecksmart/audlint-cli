#!/usr/bin/env bash
# cover_seek.sh - Walk albums and standardize album art.

set -Eeuo pipefail

trap 'printf "\n\n[!] Cover seeker terminated by user.\n"; exit 1' INT

AUTO_YES=false
DRY_RUN=false

BOOTSTRAP_SOURCE="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  BOOTSTRAP_SOURCE="$(realpath "$BOOTSTRAP_SOURCE" 2>/dev/null || printf '%s' "$BOOTSTRAP_SOURCE")"
elif command -v readlink >/dev/null 2>&1; then
  LINK_TARGET="$(readlink "$BOOTSTRAP_SOURCE" 2>/dev/null || true)"
  if [[ -n "$LINK_TARGET" ]]; then
    if [[ "$LINK_TARGET" = /* ]]; then
      BOOTSTRAP_SOURCE="$LINK_TARGET"
    else
      BOOTSTRAP_SOURCE="$(cd "$(dirname "$BOOTSTRAP_SOURCE")" && pwd)/$LINK_TARGET"
    fi
  fi
fi
BOOTSTRAP_DIR="$(cd "$(dirname "$BOOTSTRAP_SOURCE")" && pwd)"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/bootstrap.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/seek.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
ui_init_colors

COVER_ALBUM_BIN="${COVER_ALBUM_BIN:-$SCRIPT_DIR/cover_album.sh}"
if [[ ! -x "$COVER_ALBUM_BIN" ]]; then
  if ! COVER_ALBUM_BIN="$(command -v cover_album.sh 2>/dev/null)"; then
    COVER_ALBUM_BIN=""
  fi
fi

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")
  $(basename "$0") -y
  $(basename "$0") --dry-run

Usage: $(basename "$0") [--dry-run] [-y|--yes]

Options:
  --dry-run  Show what would be normalized without writing files.
  -y, --yes  Skip confirmation in child album runs.
  -h, --help Show this help message.

Behavior:
  - Walks subdirectories from the current directory.
  - Runs cover_album.sh for folders that contain audio files.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  --dry-run)
    DRY_RUN=true
    ;;
  -y | --yes)
    AUTO_YES=true
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    printf 'Unknown argument: %s\n' "${1:-}" >&2
    show_help >&2
    exit 2
    ;;
  esac
  shift || true
done

[[ -n "$COVER_ALBUM_BIN" ]] || {
  printf 'Missing dependency: cover_album.sh\n' >&2
  exit 2
}

echo "${BLUE}Starting Album Art Seek...${RESET}"
echo "${BLUE}Target:${RESET} $(pwd)"
echo "------------------------------------------------"

run_album_if_present() {
  local dir="$1"
  local -a args=(--summary-only)
  if audio_has_files "$dir"; then
    echo -e "\n${BLUE}>>> ALBUM DETECTED: $dir${RESET}"
    (
      cd "$dir" || exit 2
      [[ "$DRY_RUN" == true ]] && args+=(--dry-run)
      [[ "$AUTO_YES" == true ]] && args+=(--yes)
      "$COVER_ALBUM_BIN" "${args[@]}" .
    )
    return $?
  fi
  return 1
}

walk_dir() {
  local dir="$1"
  if [[ "$dir" == "." ]]; then
    return 1
  fi
  run_album_if_present "$dir"
}

run_album_if_present "$(pwd)" || true

if ! seek_walk_dirs "." walk_dir "before-recode"; then
  exit 1
fi

echo -e "\n------------------------------------------------"
echo "${GREEN}Album-art scan complete.${RESET}"
