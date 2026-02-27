#!/usr/bin/env bash
# lyrics_seek.sh - Scan for album folders and run lyrics_album.sh.

trap 'echo -e "\n\n[!] Seeker terminated by user."; exit 1' INT

AUTO_YES=false

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

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")
  $(basename "$0") -y
  $(basename "$0") --yes

Usage: $(basename "$0") [-y|--yes]

Options:
  -y, --yes   Auto-confirm prompts for each album.
  -h, --help  Show this help message.

Behavior:
  - Scans subdirectories from the current path.
  - Runs lyrics_album.sh for folders that contain audio files.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  -y | --yes)
    AUTO_YES=true
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    printf 'Unknown argument: %s\n' "${1:-}" >&2
    show_help
    exit 2
    ;;
  esac
  shift || true
done

LYRICS_ALBUM_BIN="${LYRICS_ALBUM_BIN:-$SCRIPT_DIR/lyrics_album.sh}"
if [[ ! -x "$LYRICS_ALBUM_BIN" ]]; then
  if ! LYRICS_ALBUM_BIN="$(command -v lyrics_album.sh 2>/dev/null)"; then
    echo "${RED}Missing dependency:${RESET} lyrics_album.sh"
    exit 2
  fi
fi

echo "${BLUE}Starting Lyrics Seek...${RESET}"
echo "${BLUE}Target:${RESET} $(pwd)"
echo "------------------------------------------------"

run_album_if_present() {
  local dir="$1"
  if audio_has_files "$dir"; then
    echo -e "\n${BLUE}>>> ALBUM DETECTED: $dir${RESET}"
    (
      cd "$dir" || exit
      if [ "$AUTO_YES" = true ]; then
        "$LYRICS_ALBUM_BIN" -y
      else
        "$LYRICS_ALBUM_BIN"
      fi
    )

    RESULT=$?
    if [[ $RESULT -gt 128 ]]; then
      echo -e "\n${YELLOW}Stopping Seeker.${RESET}"
      return "$RESULT"
    fi
    return 0
  fi
  return 1
}

walk_dir() {
  local dir="$1"
  # Root "." is handled once explicitly before recursive walk.
  if [ "$dir" = "." ]; then
    return 1
  fi
  run_album_if_present "$dir"
}

# If running inside an album folder, process it first.
run_album_if_present "$(pwd)"

if ! seek_walk_dirs "." walk_dir "before-recode"; then
  exit 1
fi

echo -e "\n------------------------------------------------"
echo "${GREEN}Lyrics scan complete.${RESET}"
