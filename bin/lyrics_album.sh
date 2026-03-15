#!/usr/bin/env bash
# lyrics_album.sh - Fetch/cache/embed synced lyrics for files in the current folder.

AUTO_YES=false
BACKUP_MAINTENANCE_ONLY=false

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
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/sqlite.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/lyrics.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
ui_init_colors

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")
  $(basename "$0") -y
  $(basename "$0") --yes
  $(basename "$0") --backup-maintenance-only

Usage: $(basename "$0") [-y|--yes] [-B|--backup-maintenance-only]

Options:
  -y, --yes
       Auto-confirm prompts.
  -B, --backup-maintenance-only
       Normalize/repair backup bundles for AUDL_DB_PATH and exit.
  -h, --help
       Show this help message.

Behavior:
  - Scans audio files in the current directory.
  - Fetches synced lyrics and embeds them in supported formats.
  - Caches fetch outcomes in lyrics_cache table inside AUDL_DB_PATH.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  -y | --yes)
    AUTO_YES=true
    ;;
  -B | --backup-maintenance-only)
    BACKUP_MAINTENANCE_ONLY=true
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

for bin in ffprobe sqlite3 curl jq zip unzip; do
  if ! has_bin "$bin"; then
    echo "${RED}Missing dependency:${RESET} $bin"
    exit 2
  fi
done

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

env_load_files ".env" "$SCRIPT_DIR/../.env" || true

LIBRARY_DB_DEFAULT=""
if [ -n "${AUDL_PATH:-}" ]; then
  LIBRARY_DB_DEFAULT="$AUDL_PATH/library.sqlite"
else
  LIBRARY_DB_DEFAULT="$PWD/.lyrics_cache.sqlite"
fi
LIBRARY_DB="${AUDL_DB_PATH:-$LIBRARY_DB_DEFAULT}"
LYRICS_RETRY_SECONDS=$((60 * 60 * 24 * 30 * 6))

LYRICS_LIST=".lyrics_files.tmp"
LYRICS_TMP=".lyrics_embed.tmp"
LYRICS_PLAIN_TMP=".lyrics_plain.tmp"
rm -f "$LYRICS_LIST"
rm -f "$LYRICS_TMP"
rm -f "$LYRICS_PLAIN_TMP"

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

norm_tag() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

url_encode() {
  printf "%s" "$1" | jq -sRr @uri
}

if [ "$BACKUP_MAINTENANCE_ONLY" = true ]; then
  album_quality_db_backup "$LIBRARY_DB" || {
    echo "Error: DB integrity check failed." >&2
    exit 1
  }
  lyrics_db_init "$LIBRARY_DB"
  echo "${GREEN}[BACKUP]${RESET} Backup bundles normalized: $LIBRARY_DB"
  rm -f "$LYRICS_LIST"
  rm -f "$LYRICS_TMP"
  rm -f "$LYRICS_PLAIN_TMP"
  exit 0
fi

FILES=()
audio_collect_files "." FILES

if [ ${#FILES[@]} -eq 0 ]; then
  echo "${YELLOW}No audio files found.${RESET}"
  exit 1
fi

echo "${BLUE}Lyrics Fetch & Embed (Cache)...${RESET}"
echo "--------------------------------------------------------------------------------"
echo "Target: $(pwd)"
echo "Library DB: $LIBRARY_DB"
echo "--------------------------------------------------------------------------------"

if [ "$AUTO_YES" = true ]; then
  CONFIRM="y"
  echo "Fetch and embed lyrics? (y/n): y"
else
  printf "Fetch and embed lyrics? (y/n): "
  read CONFIRM
fi
[[ "$CONFIRM" != "y" ]] && exit 0

album_quality_db_backup "$LIBRARY_DB" || {
  echo "Error: DB integrity check failed." >&2
  exit 1
}
lyrics_db_init "$LIBRARY_DB"

NOW_TS=$(date +%s)
for f in "${FILES[@]}"; do
  audio_ffprobe_meta_prime "$f"
  CODEC="$(audio_codec_name "$f" || true)"
  EXT="${f##*.}"

  SUPPORT_LYRICS=false
  if [ "$CODEC" = "flac" ] || [ "$CODEC" = "mp3" ]; then
    SUPPORT_LYRICS=true
  elif [[ "$EXT" == "m4a" || "$EXT" == "M4A" || "$EXT" == "mp4" || "$EXT" == "MP4" ]]; then
    SUPPORT_LYRICS=true
  fi
  if [ "$SUPPORT_LYRICS" = false ]; then
    echo "${YELLOW}[LYRICS]${RESET} Unsupported codec for lyrics embed; skip: $f"
    continue
  fi

  ALBUM_ARTIST="$(audio_probe_tag_value "$f" "album_artist")"
  ARTIST="$(audio_probe_tag_value "$f" "artist")"
  TITLE="$(audio_probe_tag_value "$f" "title")"
  ALBUM="$(audio_probe_tag_value "$f" "album")"
  DURATION="$(audio_probe_duration_seconds "$f")"

  if [ -n "$ALBUM_ARTIST" ]; then
    ARTIST="$ALBUM_ARTIST"
  fi

  if [ -z "$ARTIST" ] || [ -z "$TITLE" ]; then
    echo "${YELLOW}[LYRICS]${RESET} Missing tags (artist/title): $f"
    continue
  fi

  ARTIST_LC=$(norm_tag "$ARTIST")
  TITLE_LC=$(norm_tag "$TITLE")
  ALBUM_LC=$(norm_tag "$ALBUM")

  DURATION_INT=$(awk -v d="$DURATION" 'BEGIN{if (d==""||d!~/^[0-9.]+$/){print 0}else{printf "%.0f", d}}')

  HAS_LYRICS_TAG=false
  if [ "$CODEC" = "flac" ] && [ "$HAS_METAFLAC" = true ]; then
    if metaflac --show-tag=LYRICS "$f" 2>/dev/null | grep -q 'LYRICS='; then
      HAS_LYRICS_TAG=true
    fi
  elif [ "$CODEC" = "mp3" ] && [ "$HAS_EYED3" = true ]; then
    if eyeD3 --list "$f" 2>/dev/null | grep -qi 'lyrics'; then
      HAS_LYRICS_TAG=true
    fi
  else
    if [ -n "$(audio_probe_tag_value "$f" "lyrics")" ]; then
      HAS_LYRICS_TAG=true
    fi
  fi

  if [ "$HAS_LYRICS_TAG" = true ]; then
    echo "${BLUE}[LYRICS]${RESET} Tag exists; skip: $f"
    continue
  fi

  CACHE_META=$(lyrics_cache_lookup "$LIBRARY_DB" "$ARTIST_LC" "$TITLE_LC" "$ALBUM_LC" "$DURATION_INT")
  CACHE_STATUS=""
  CACHE_ATTEMPTED=0
  if [ -n "$CACHE_META" ]; then
    CACHE_STATUS=$(printf "%s" "$CACHE_META" | awk -F'|' '{print $1}')
    CACHE_ATTEMPTED=$(printf "%s" "$CACHE_META" | awk -F'|' '{print $2}')
  fi

  if [ "$CACHE_STATUS" = "not_found" ]; then
    if [ $((NOW_TS - CACHE_ATTEMPTED)) -lt "$LYRICS_RETRY_SECONDS" ]; then
      NEXT_RETRY=$((CACHE_ATTEMPTED + LYRICS_RETRY_SECONDS))
      NEXT_DATE=$(date_format_epoch "$NEXT_RETRY" "+%Y-%m-%d" 2>/dev/null || echo "later")
      echo "${BLUE}[LYRICS]${RESET} Cached not found; revisit ${NEXT_DATE}: $f"
      continue
    fi
  fi

  LYRICS_TEXT=""
  if [ "$CACHE_STATUS" = "found" ]; then
    LYRICS_TEXT=$(sqlite3 "$LIBRARY_DB" "SELECT lyrics FROM lyrics_cache WHERE artist_lc='$(sql_escape "$ARTIST_LC")' AND title_lc='$(sql_escape "$TITLE_LC")' AND album_lc='$(sql_escape "$ALBUM_LC")' AND abs(duration_int - ${DURATION_INT}) <= 2 ORDER BY updated_at DESC LIMIT 1;")
  fi

  if [ -z "$LYRICS_TEXT" ]; then
    QUERY_URL="https://lrclib.net/api/search?artist_name=$(url_encode "$ARTIST")&track_name=$(url_encode "$TITLE")"
    LYRICS_TEXT=$(curl -s "$QUERY_URL" | jq -r '.[0].syncedLyrics // empty')
    if [ -n "$LYRICS_TEXT" ]; then
      lyrics_cache_upsert "$LIBRARY_DB" "$ARTIST_LC" "$TITLE_LC" "$ALBUM_LC" "$DURATION_INT" "$f" "found" "$LYRICS_TEXT" "lrclib" "$NOW_TS" "$NOW_TS"
    else
      lyrics_cache_upsert "$LIBRARY_DB" "$ARTIST_LC" "$TITLE_LC" "$ALBUM_LC" "$DURATION_INT" "$f" "not_found" "" "lrclib" "$NOW_TS" "$NOW_TS"
      echo "${YELLOW}[LYRICS]${RESET} Not found: $f"
      continue
    fi
  fi

  printf "%s" "$LYRICS_TEXT" > "$LYRICS_TMP"
  sed 's/\[[^]]*\]//g' "$LYRICS_TMP" | sed '/^[[:space:]]*$/d' > "$LYRICS_PLAIN_TMP"

  EMBED_OK=false
  if [ "$CODEC" = "flac" ]; then
    if [ "$HAS_METAFLAC" = true ]; then
      metaflac --set-tag="LYRICS=$(cat "$LYRICS_TMP")" \
        --set-tag="UNSYNCEDLYRICS=$(cat "$LYRICS_PLAIN_TMP")" \
        "$f" >/dev/null 2>&1
      [[ $? -eq 0 ]] && EMBED_OK=true
    else
      echo "${YELLOW}[LYRICS]${RESET} metaflac missing; skip embed: $f"
    fi
  elif [ "$CODEC" = "mp3" ]; then
    if [ "$HAS_EYED3" = true ]; then
      eyeD3 --remove-all-lyrics \
        --add-lyrics "lrc:$LYRICS_TMP" \
        --add-lyrics "$LYRICS_PLAIN_TMP" \
        "$f" >/dev/null 2>&1
      [[ $? -eq 0 ]] && EMBED_OK=true
    else
      echo "${YELLOW}[LYRICS]${RESET} eyeD3 missing; skip embed: $f"
    fi
  elif [[ "$EXT" == "m4a" || "$EXT" == "M4A" || "$EXT" == "mp4" || "$EXT" == "MP4" ]]; then
    if [ "$HAS_ATOMICPARSLEY" = true ]; then
      AtomicParsley "$f" --lyrics "$(cat "$LYRICS_PLAIN_TMP")" --overWrite >/dev/null 2>&1
      [[ $? -eq 0 ]] && EMBED_OK=true
    else
      echo "${YELLOW}[LYRICS]${RESET} AtomicParsley missing; skip embed: $f"
    fi
  fi

  if [ "$EMBED_OK" = true ]; then
    echo "${GREEN}[LYRICS]${RESET} Embedded: $f"
  else
    echo "${YELLOW}[LYRICS]${RESET} Embed failed: $f"
  fi
done

rm -f "$LYRICS_LIST"
rm -f "$LYRICS_TMP"
rm -f "$LYRICS_PLAIN_TMP"
