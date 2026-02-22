#!/opt/homebrew/bin/bash

ffprobe_album_meta() {
  local in="$1"
  ffprobe -v error -show_entries format_tags=album_artist,artist,album,date,genre -of default=noprint_wrappers=1 "$in" </dev/null 2>/dev/null || true
}

ffprobe_album_key() {
  local in="$1"
  local tags
  tags="$(ffprobe_album_meta "$in")"

  local artist=""
  local album_artist=""
  local album=""
  local date_tag=""
  local genre_tag=""
  local line key value
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    case "$key" in
    tag:album_artist) [[ -z "$album_artist" ]] && album_artist="$value" ;;
    tag:artist) [[ -z "$artist" ]] && artist="$value" ;;
    tag:album) [[ -z "$album" ]] && album="$value" ;;
    tag:date) [[ -z "$date_tag" ]] && date_tag="$value" ;;
    tag:genre) [[ -z "$genre_tag" ]] && genre_tag="$value" ;;
    esac
  done <<<"$tags"
  # Prefer Album Artist over Track Artist when present — avoids VA albums
  # being keyed under the first track's artist.
  [[ -n "$album_artist" ]] && artist="$album_artist"

  local parent
  local grandparent
  parent="$(basename "$(dirname "$in")")"
  grandparent="$(basename "$(dirname "$(dirname "$in")")")"

  local year="0000"
  if [[ "$date_tag" =~ ([0-9]{4}) ]]; then
    year="${BASH_REMATCH[1]}"
  elif [[ "$parent" =~ ([0-9]{4}) ]]; then
    year="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$album" ]]; then
    album="$parent"
    if [[ "$album" =~ ^[[:space:]]*[0-9]{4}[[:space:]]*-[[:space:]]*(.+)$ ]]; then
      album="${BASH_REMATCH[1]}"
    fi
  fi
  [[ -n "$artist" ]] || artist="$grandparent"
  [[ -n "$artist" && -n "$album" ]] || return 1

  printf 'ARTIST=%s\n' "$artist"
  printf 'YEAR=%s\n' "$year"
  printf 'ALBUM=%s\n' "$album"
  [[ -n "$genre_tag" ]] && printf 'GENRE=%s\n' "$genre_tag"
}
