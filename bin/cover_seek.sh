#!/usr/bin/env bash
# cover_seek.sh - Walk albums and standardize album art.

set -Eeuo pipefail

trap 'printf "\n\n[!] Cover seeker terminated by user.\n"; exit 1' INT

AUTO_YES=false
DRY_RUN=false
FETCH_MISSING_ART=false
ALBUM_COUNT=0
ALBUM_OK_COUNT=0
ALBUM_FAILED_COUNT=0
declare -a FAILED_SUMMARY_LINES=()

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

COVER_ALBUM_BIN="${AUDLINT_COVER_ALBUM_BIN:-${COVER_ALBUM_BIN:-$SCRIPT_DIR/cover_album.sh}}"
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

Usage: $(basename "$0") [--dry-run] [--fetch-missing-art] [-y|--yes]

Options:
  --dry-run  Show what would be normalized without writing files.
  --fetch-missing-art
             Download missing album art when no local source exists.
  -y, --yes  Skip confirmation in child album runs.
  -h, --help Show this help message.

Behavior:
  - Walks subdirectories from the current directory.
  - Runs cover_album.sh for folders that contain audio files.
  - Applies --cleanup-extra-sidecars for internal album-fix runs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  --dry-run)
    DRY_RUN=true
    ;;
  --fetch-missing-art)
    FETCH_MISSING_ART=true
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

strip_ansi_codes() {
  local esc
  esc=$'\033'
  printf '%s' "${1:-}" | sed "s/${esc}\[[0-9;]*[A-Za-z]//g"
}

cover_seek_force_child_color() {
  if [[ -n "${NO_COLOR:-}" ]]; then
    return 1
  fi
  case "${FORCE_COLOR:-${CLICOLOR_FORCE:-}}" in
  1 | true | TRUE | yes | YES) return 0 ;;
  esac
  [[ -t 1 ]]
}

colorize_summary_line() {
  local line="${1:-}"
  local color="${RESET:-}"
  case "$line" in
  *"Art: ERROR |"*) color="${RED:-}" ;;
  *"Art: WARN |"*) color="${YELLOW:-}" ;;
  *"Art: OK |"*) color="${GREEN:-}" ;;
  *"Art: DRY-RUN |"*) color="${CYAN:-}" ;;
  esac
  printf '%s%s%s' "$color" "$line" "${RESET:-}"
}

extract_art_summary_from_log() {
  local log_file="$1"
  local line=""
  local art_line=""
  while IFS= read -r line; do
    line="$(strip_ansi_codes "$line")"
    case "$line" in
    *"Art:"*)
      art_line="Art:${line#*Art:}"
      ;;
    esac
  done <"$log_file"
  printf '%s' "$art_line"
}

run_album_if_present() {
  local dir="$1"
  local -a args=(--summary-only --cleanup-extra-sidecars)
  local output_file=""
  local rc=0
  local art_summary=""
  if audio_has_files "$dir"; then
    ALBUM_COUNT=$((ALBUM_COUNT + 1))
    echo -e "\n${BLUE}>>> ALBUM DETECTED: $dir${RESET}"
    output_file="$(mktemp "${TMPDIR:-/tmp}/cover_seek_album.XXXXXX" 2>/dev/null || true)"
    (
      cd "$dir" || exit 2
      [[ "$DRY_RUN" == true ]] && args+=(--dry-run)
      [[ "$FETCH_MISSING_ART" == true ]] && args+=(--fetch-missing-art)
      [[ "$AUTO_YES" == true ]] && args+=(--yes)
      if cover_seek_force_child_color; then
        FORCE_COLOR=1 "$COVER_ALBUM_BIN" "${args[@]}" . 2>&1 | tee "$output_file"
      else
        "$COVER_ALBUM_BIN" "${args[@]}" . 2>&1 | tee "$output_file"
      fi
    ) || rc=$?
    art_summary="$(extract_art_summary_from_log "$output_file")"
    rm -f "$output_file"
    if ((rc == 0)); then
      ALBUM_OK_COUNT=$((ALBUM_OK_COUNT + 1))
    else
      ALBUM_FAILED_COUNT=$((ALBUM_FAILED_COUNT + 1))
      [[ -n "$art_summary" ]] || art_summary="Art: ERROR | album processing failed"
      FAILED_SUMMARY_LINES+=("$dir | $art_summary")
    fi
    return "$rc"
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
if ((ALBUM_FAILED_COUNT > 0)); then
  echo "${YELLOW}Album-art scan complete. albums=${ALBUM_COUNT} ok=${ALBUM_OK_COUNT} failed=${ALBUM_FAILED_COUNT}${RESET}"
  echo "${YELLOW}Failed albums:${RESET}"
  for line in "${FAILED_SUMMARY_LINES[@]}"; do
    printf '  - %s\n' "$(colorize_summary_line "$line")"
  done
else
  echo "${GREEN}Album-art scan complete. albums=${ALBUM_COUNT} ok=${ALBUM_OK_COUNT} failed=0${RESET}"
fi
