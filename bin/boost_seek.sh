#!/opt/homebrew/bin/bash
# boost_seek.sh - Fixed version with File Descriptor redirection
# This ensures that boost_album.sh can still read your keyboard input.

trap 'echo -e "\n\n[!] Seeker terminated by user."; exit 1' INT

AUTO_YES=false
FAILED_SUMMARIES=()

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

BOOST_ALBUM_BIN="${BOOST_ALBUM_BIN:-$SCRIPT_DIR/boost_album.sh}"
if [[ ! -x "$BOOST_ALBUM_BIN" ]]; then
  if ! BOOST_ALBUM_BIN="$(command -v boost_album.sh 2>/dev/null)"; then
    BOOST_ALBUM_BIN=""
  fi
fi

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")
  $(basename "$0") -y

Usage: $(basename "$0") [-y]

Options:
  -y   Auto-confirm prompts for each album.
  -h   Show this help message.
EOF
}

if [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

while getopts ":yh" opt; do
  case "$opt" in
  y) AUTO_YES=true ;;
  h)
    show_help
    exit 0
    ;;
  \?)
    show_help
    exit 2
    ;;
  esac
done
shift $((OPTIND - 1))

echo "${BLUE}Starting Library-wide Seek...${RESET}"
echo "${BLUE}Target:${RESET} $(pwd)"
echo "------------------------------------------------"

run_album_if_present() {
  local dir="$1"
  if has_boost_audio_files "$dir"; then
    echo -e "\n${BLUE}>>> ALBUM DETECTED: $dir${RESET}"
    (
      cd "$dir" || exit
      if [[ -z "$BOOST_ALBUM_BIN" ]]; then
        echo "${RED}Missing dependency:${RESET} boost_album.sh"
        return 2
      fi
      if [ "$AUTO_YES" = true ]; then
        "$BOOST_ALBUM_BIN" -y
      else
        "$BOOST_ALBUM_BIN"
      fi
    )

    RESULT=$?
    if [[ $RESULT -gt 128 ]]; then
      echo -e "\n${YELLOW}Stopping Seeker.${RESET}"
      return "$RESULT"
    fi
    if [ -f "$dir/.boost_failures.txt" ]; then
      FAILED_SUMMARIES+=("$dir/.boost_failures.txt")
    fi
    return 0
  fi
  return 1
}

has_boost_audio_files() {
  local dir="$1"
  local all_files=()
  local f ext
  audio_collect_files "$dir" all_files
  for f in "${all_files[@]}"; do
    ext="${f##*.}"
    ext="${ext,,}"
    case "$ext" in
    flac | alac | m4a | wav | mp4 | mp3 | ogg | opus)
      return 0
      ;;
    esac
  done
  return 1
}

walk_dir() {
  local dir="$1"
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
echo "${GREEN}Library scan complete.${RESET}"

if [ ${#FAILED_SUMMARIES[@]} -gt 0 ]; then
  echo -e "\n${RED}Failure summary:${RESET}"
  for summary in "${FAILED_SUMMARIES[@]}"; do
    echo -e "${RED}---${RESET}"
    cat "$summary"
  done
fi
