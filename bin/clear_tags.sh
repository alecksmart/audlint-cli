#!/opt/homebrew/bin/bash
# clear_tags.sh - Clear lyrics tags and cached lyrics DB entries for files in the current folder.

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
source "$BOOTSTRAP_DIR/../lib/sh/env.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/deps.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
ui_init_colors

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")

Usage: $(basename "$0") [dir]

Options:
  -h   Show this help message.
EOF
}

if [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

while getopts ":h" opt; do
  case "$opt" in
    h) show_help; exit 0 ;;
    \?) show_help; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

TARGET_DIR="${1:-.}"
if [ ! -d "$TARGET_DIR" ]; then
  echo "${RED}Not a directory:${RESET} $TARGET_DIR"
  exit 2
fi

env_load_files ".env" "$SCRIPT_DIR/../.env" || true

LIBRARY_DB_DEFAULT=""
if [ -n "${SRC:-}" ]; then
  LIBRARY_DB_DEFAULT="$SRC/library.sqlite"
else
  LIBRARY_DB_DEFAULT="$PWD/.lyrics_cache.sqlite"
fi
LIBRARY_DB="${LIBRARY_DB:-$LIBRARY_DB_DEFAULT}"

HAS_METAFLAC=false
if has_bin metaflac; then
  HAS_METAFLAC=true
fi
HAS_EYED3=false
if has_bin eyeD3; then
  HAS_EYED3=true
fi
HAS_ATOMICPARSLEY=false
if has_bin AtomicParsley; then
  HAS_ATOMICPARSLEY=true
fi
HAS_SQLITE=false
if has_bin sqlite3; then
  HAS_SQLITE=true
fi
HAS_FFPROBE=false
if has_bin ffprobe; then
  HAS_FFPROBE=true
fi

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

norm_tag() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

FILES=()
audio_collect_files "$TARGET_DIR" FILES

if [ ${#FILES[@]} -eq 0 ]; then
  echo "${YELLOW}No audio files found.${RESET}"
  exit 1
fi

echo "${BLUE}Lyrics tag/db cleanup${RESET}"
echo "Target: $TARGET_DIR"
echo "Library DB: $LIBRARY_DB"
echo "------------------------------------------------"

TAG_CLEARED=0
DB_CLEARED=0
SIDECAR_CLEARED=0

for f in "${FILES[@]}"; do
  if [ "$HAS_FFPROBE" = true ]; then
    CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$f")
  else
    CODEC=""
  fi
  EXT="${f##*.}"

  if [ "$CODEC" = "flac" ]; then
    if [ "$HAS_METAFLAC" = true ]; then
      metaflac --remove-tag=LYRICS --remove-tag=UNSYNCEDLYRICS "$f" >/dev/null 2>&1 && TAG_CLEARED=$((TAG_CLEARED + 1))
    else
      echo "${YELLOW}[LYRICS]${RESET} metaflac missing; skip tag removal: $f"
    fi
  elif [ "$CODEC" = "mp3" ]; then
    if [ "$HAS_EYED3" = true ]; then
      eyeD3 --remove-all-lyrics \
        --remove-frame=SYLT \
        --remove-frame=USLT \
        --user-text-frame='LYRICS:' \
        --user-text-frame='UNSYNCEDLYRICS:' \
        "$f" >/dev/null 2>&1 && TAG_CLEARED=$((TAG_CLEARED + 1))
    else
      echo "${YELLOW}[LYRICS]${RESET} eyeD3 missing; skip tag removal: $f"
    fi
  elif [[ "$EXT" == "m4a" || "$EXT" == "M4A" || "$EXT" == "mp4" || "$EXT" == "MP4" ]]; then
    if [ "$HAS_ATOMICPARSLEY" = true ]; then
      AtomicParsley "$f" --lyrics "" --overWrite >/dev/null 2>&1 && TAG_CLEARED=$((TAG_CLEARED + 1))
    else
      echo "${YELLOW}[LYRICS]${RESET} AtomicParsley missing; skip tag removal: $f"
    fi
  fi

  BASE="${f%.*}"
  for sidecar in "$BASE.lrc" "$BASE.LRC" "$BASE.txt" "$BASE.TXT"; do
    if [ -f "$sidecar" ]; then
      rm -f "$sidecar" && SIDECAR_CLEARED=$((SIDECAR_CLEARED + 1))
    fi
  done

  if [ "$HAS_SQLITE" = true ] && [ -f "$LIBRARY_DB" ]; then
    ARTIST=""
    TITLE=""
    ALBUM=""
    DURATION=""
    if [ "$HAS_FFPROBE" = true ]; then
      ARTIST=$(ffprobe -v error -show_entries format_tags=album_artist -of default=noprint_wrappers=1:nokey=1 "$f")
      if [ -z "$ARTIST" ]; then
        ARTIST=$(ffprobe -v error -show_entries format_tags=artist -of default=noprint_wrappers=1:nokey=1 "$f")
      fi
      TITLE=$(ffprobe -v error -show_entries format_tags=title -of default=noprint_wrappers=1:nokey=1 "$f")
      ALBUM=$(ffprobe -v error -show_entries format_tags=album -of default=noprint_wrappers=1:nokey=1 "$f")
      DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
    fi
    if [ -z "$ARTIST" ]; then
      ARTIST=""
    fi

    if [ -n "$ARTIST" ] && [ -n "$TITLE" ]; then
      ARTIST_LC=$(norm_tag "$ARTIST")
      TITLE_LC=$(norm_tag "$TITLE")
      ALBUM_LC=$(norm_tag "$ALBUM")
      DURATION_INT=$(awk -v d="$DURATION" 'BEGIN{if (d==""||d!~/^[0-9.]+$/){print 0}else{printf "%.0f", d}}')

      sqlite3 "$LIBRARY_DB" \
        "DELETE FROM lyrics_cache WHERE artist_lc='$(sql_escape "$ARTIST_LC")' AND title_lc='$(sql_escape "$TITLE_LC")' AND album_lc='$(sql_escape "$ALBUM_LC")' AND abs(duration_int - ${DURATION_INT}) <= 2;"
      sqlite3 "$LIBRARY_DB" \
        "DELETE FROM lyrics_cache WHERE path='$(sql_escape "$f")';"
      ABS_PATH="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
      sqlite3 "$LIBRARY_DB" \
        "DELETE FROM lyrics_cache WHERE path='$(sql_escape "$ABS_PATH")';"
      DB_CLEARED=$((DB_CLEARED + 1))
    fi
  fi
done

echo "------------------------------------------------"
echo "${GREEN}Done.${RESET} Tags cleared: ${TAG_CLEARED} | Sidecars removed: ${SIDECAR_CLEARED} | DB entries cleared: ${DB_CLEARED}"
