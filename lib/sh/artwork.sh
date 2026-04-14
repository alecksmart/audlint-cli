#!/usr/bin/env bash

ARTWORK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F path_resolve >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$ARTWORK_LIB_DIR/bootstrap.sh"
fi
if ! declare -F audio_collect_files >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$ARTWORK_LIB_DIR/audio.sh"
fi
if ! declare -F has_bin >/dev/null 2>&1 && [[ -f "$ARTWORK_LIB_DIR/deps.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ARTWORK_LIB_DIR/deps.sh"
fi
if ! declare -F ui_wrap >/dev/null 2>&1 && [[ -f "$ARTWORK_LIB_DIR/ui.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ARTWORK_LIB_DIR/ui.sh"
fi

ARTWORK_LAST_STATUS=""
ARTWORK_LAST_ERROR=""
ARTWORK_LAST_SIDECAR=""
ARTWORK_LAST_SOURCE=""
ARTWORK_LAST_WIDTH=0
ARTWORK_LAST_HEIGHT=0
ARTWORK_LAST_TRACKS_TOTAL=0
ARTWORK_LAST_TRACKS_OK=0
ARTWORK_LAST_TRACKS_FAILED=0
ARTWORK_LAST_EXTRA_EMBEDS_CLEARED=0
ARTWORK_LAST_EXTRA_SIDECARS_CLEARED=0
ARTWORK_LAST_CHANGED=0
ARTWORK_LAST_CACHE_HIT=0
ARTWORK_LAST_SOURCE_FINGERPRINT=""
ARTWORK_LAST_CONFIG_FINGERPRINT=""

artwork_reset_last_result() {
  ARTWORK_LAST_STATUS=""
  ARTWORK_LAST_ERROR=""
  ARTWORK_LAST_SIDECAR=""
  ARTWORK_LAST_SOURCE=""
  ARTWORK_LAST_WIDTH=0
  ARTWORK_LAST_HEIGHT=0
  ARTWORK_LAST_TRACKS_TOTAL=0
  ARTWORK_LAST_TRACKS_OK=0
  ARTWORK_LAST_TRACKS_FAILED=0
  ARTWORK_LAST_EXTRA_EMBEDS_CLEARED=0
  ARTWORK_LAST_EXTRA_SIDECARS_CLEARED=0
  ARTWORK_LAST_CHANGED=0
  ARTWORK_LAST_CACHE_HIT=0
  ARTWORK_LAST_SOURCE_FINGERPRINT=""
  ARTWORK_LAST_CONFIG_FINGERPRINT=""
}

artwork_auto_enabled() {
  case "${AUDL_ARTWORK_AUTO:-1}" in
  0 | false | FALSE | no | NO | off | OFF) return 1 ;;
  *) return 0 ;;
  esac
}

artwork_fetch_missing_enabled() {
  case "${AUDL_ARTWORK_FETCH_MISSING:-0}" in
  1 | true | TRUE | yes | YES | on | ON) return 0 ;;
  *) return 1 ;;
  esac
}

artwork_sidecar_name() {
  printf 'cover.jpg'
}

artwork_max_dim() {
  local raw="${AUDL_ARTWORK_MAX_DIM:-600}"
  if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw >= 64)); then
    printf '%s' "$raw"
  else
    printf '600'
  fi
}

artwork_jpeg_quality() {
  local raw="${AUDL_ARTWORK_JPEG_QUALITY:-85}"
  if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw >= 2 && raw <= 31)); then
    printf '%s' "$raw"
    return 0
  fi
  if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw >= 32 && raw <= 100)); then
    if ((raw <= 33)); then
      printf '15'
    elif ((raw <= 50)); then
      printf '10'
    elif ((raw <= 70)); then
      printf '6'
    elif ((raw <= 85)); then
      printf '4'
    elif ((raw <= 92)); then
      printf '3'
    else
      printf '2'
    fi
    return 0
  fi
  printf '4'
}

artwork_fetch_user_agent() {
  printf '%s' "${AUDL_ARTWORK_FETCH_USER_AGENT:-audlint-cli/1.0 (local use; set AUDL_ARTWORK_FETCH_USER_AGENT for contact info)}"
}

artwork_trim_text() {
  printf '%s' "${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

artwork_musicbrainz_escape_query_value() {
  printf '%s' "${1:-}" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

artwork_cache_file_path() {
  local target="${1:-}"
  if [[ -d "$target" ]]; then
    printf '%s/.audlint_album_art\n' "$target"
  else
    printf '%s\n' "$target"
  fi
}

artwork_cache_get() {
  local target="$1"
  local key="$2"
  local cache_file value
  cache_file="$(artwork_cache_file_path "$target")"
  [[ -f "$cache_file" ]] || {
    printf ''
    return 0
  }
  value="$(awk -F= -v wanted="$key" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$cache_file" 2>/dev/null || true)"
  printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

artwork_write_cache() {
  local album_dir="$1"
  local cache_file
  cache_file="$(artwork_cache_file_path "$album_dir")"
  {
    printf 'STATUS=%s\n' "$ARTWORK_LAST_STATUS"
    printf 'ERROR=%s\n' "$ARTWORK_LAST_ERROR"
    printf 'SIDECAR=%s\n' "$ARTWORK_LAST_SIDECAR"
    printf 'SOURCE=%s\n' "$ARTWORK_LAST_SOURCE"
    printf 'WIDTH=%s\n' "$ARTWORK_LAST_WIDTH"
    printf 'HEIGHT=%s\n' "$ARTWORK_LAST_HEIGHT"
    printf 'TRACKS_TOTAL=%s\n' "$ARTWORK_LAST_TRACKS_TOTAL"
    printf 'TRACKS_OK=%s\n' "$ARTWORK_LAST_TRACKS_OK"
    printf 'TRACKS_FAILED=%s\n' "$ARTWORK_LAST_TRACKS_FAILED"
    printf 'EXTRA_EMBEDS_CLEARED=%s\n' "$ARTWORK_LAST_EXTRA_EMBEDS_CLEARED"
    printf 'EXTRA_SIDECARS_CLEARED=%s\n' "$ARTWORK_LAST_EXTRA_SIDECARS_CLEARED"
    printf 'SOURCE_FINGERPRINT=%s\n' "$ARTWORK_LAST_SOURCE_FINGERPRINT"
    printf 'CONFIG_FINGERPRINT=%s\n' "$ARTWORK_LAST_CONFIG_FINGERPRINT"
  } >"$cache_file"
}

artwork_color_for_status() {
  case "${1:-}" in
  error) printf '%s' "${RED:-}" ;;
  warn) printf '%s' "${YELLOW:-}" ;;
  dry-run) printf '%s' "${CYAN:-}" ;;
  *) printf '%s' "${CYAN:-}" ;;
  esac
}

artwork_status_summary_plain() {
  local status="${ARTWORK_LAST_STATUS:-unknown}"
  local status_label="${status^^}"

  if [[ "$status" == "error" ]]; then
    printf 'Art: %s | %s' "$status_label" "${ARTWORK_LAST_ERROR:-unknown failure}"
    return 0
  fi

  printf 'Art: %s | %s | JPEG %sx%s | embedded %s/%s | sidecars cleared=%s | extra embeds cleared=%s' \
    "$status_label" \
    "${ARTWORK_LAST_SIDECAR:-$(artwork_sidecar_name)}" \
    "${ARTWORK_LAST_WIDTH:-0}" \
    "${ARTWORK_LAST_HEIGHT:-0}" \
    "${ARTWORK_LAST_TRACKS_OK:-0}" \
    "${ARTWORK_LAST_TRACKS_TOTAL:-0}" \
    "${ARTWORK_LAST_EXTRA_SIDECARS_CLEARED:-0}" \
    "${ARTWORK_LAST_EXTRA_EMBEDS_CLEARED:-0}"
  if [[ -n "${ARTWORK_LAST_SOURCE:-}" ]]; then
    printf ' | source=%s' "$ARTWORK_LAST_SOURCE"
  fi
  if [[ "${ARTWORK_LAST_CACHE_HIT:-0}" == "1" ]]; then
    printf ' | cached'
  elif [[ "${ARTWORK_LAST_CHANGED:-0}" == "1" ]]; then
    printf ' | updated'
  fi
}

artwork_status_summary_colored() {
  local summary color
  summary="$(artwork_status_summary_plain)"
  color="$(artwork_color_for_status "${ARTWORK_LAST_STATUS:-}")"
  if declare -F ui_wrap >/dev/null 2>&1; then
    ui_wrap "$color" "$summary"
  else
    printf '%s%s%s' "$color" "$summary" "${RESET:-}"
  fi
}

artwork_load_last_result_from_cache() {
  local album_dir="$1"
  artwork_reset_last_result
  ARTWORK_LAST_STATUS="$(artwork_cache_get "$album_dir" "STATUS")"
  ARTWORK_LAST_ERROR="$(artwork_cache_get "$album_dir" "ERROR")"
  ARTWORK_LAST_SIDECAR="$(artwork_cache_get "$album_dir" "SIDECAR")"
  ARTWORK_LAST_SOURCE="$(artwork_cache_get "$album_dir" "SOURCE")"
  ARTWORK_LAST_WIDTH="$(artwork_cache_get "$album_dir" "WIDTH")"
  ARTWORK_LAST_HEIGHT="$(artwork_cache_get "$album_dir" "HEIGHT")"
  ARTWORK_LAST_TRACKS_TOTAL="$(artwork_cache_get "$album_dir" "TRACKS_TOTAL")"
  ARTWORK_LAST_TRACKS_OK="$(artwork_cache_get "$album_dir" "TRACKS_OK")"
  ARTWORK_LAST_TRACKS_FAILED="$(artwork_cache_get "$album_dir" "TRACKS_FAILED")"
  ARTWORK_LAST_EXTRA_EMBEDS_CLEARED="$(artwork_cache_get "$album_dir" "EXTRA_EMBEDS_CLEARED")"
  ARTWORK_LAST_EXTRA_SIDECARS_CLEARED="$(artwork_cache_get "$album_dir" "EXTRA_SIDECARS_CLEARED")"
  ARTWORK_LAST_SOURCE_FINGERPRINT="$(artwork_cache_get "$album_dir" "SOURCE_FINGERPRINT")"
  ARTWORK_LAST_CONFIG_FINGERPRINT="$(artwork_cache_get "$album_dir" "CONFIG_FINGERPRINT")"
  [[ "${ARTWORK_LAST_TRACKS_TOTAL:-}" =~ ^[0-9]+$ ]] || ARTWORK_LAST_TRACKS_TOTAL=0
  [[ "${ARTWORK_LAST_TRACKS_OK:-}" =~ ^[0-9]+$ ]] || ARTWORK_LAST_TRACKS_OK=0
  [[ "${ARTWORK_LAST_TRACKS_FAILED:-}" =~ ^[0-9]+$ ]] || ARTWORK_LAST_TRACKS_FAILED=0
  [[ "${ARTWORK_LAST_EXTRA_EMBEDS_CLEARED:-}" =~ ^[0-9]+$ ]] || ARTWORK_LAST_EXTRA_EMBEDS_CLEARED=0
  [[ "${ARTWORK_LAST_EXTRA_SIDECARS_CLEARED:-}" =~ ^[0-9]+$ ]] || ARTWORK_LAST_EXTRA_SIDECARS_CLEARED=0
  [[ "${ARTWORK_LAST_WIDTH:-}" =~ ^[0-9]+$ ]] || ARTWORK_LAST_WIDTH=0
  [[ "${ARTWORK_LAST_HEIGHT:-}" =~ ^[0-9]+$ ]] || ARTWORK_LAST_HEIGHT=0
  ARTWORK_LAST_CACHE_HIT=1
}

artwork_collect_coverlike_files() {
  local dir="$1"
  local out_var="${2:-ARTWORK_FILES}"
  local -n out_ref="$out_var"
  local had_nullglob=0
  local had_nocaseglob=0
  local candidate base lowered
  local -A seen=()
  local -a ordered=()

  out_ref=()
  shopt -q nullglob && had_nullglob=1
  shopt -q nocaseglob && had_nocaseglob=1
  shopt -s nullglob nocaseglob

  for candidate in \
    "$dir"/cover.jpg "$dir"/cover.jpeg "$dir"/cover.png "$dir"/cover.webp "$dir"/cover.bmp "$dir"/cover.gif "$dir"/cover.tif "$dir"/cover.tiff \
    "$dir"/folder.jpg "$dir"/folder.jpeg "$dir"/folder.png "$dir"/folder.webp "$dir"/folder.bmp "$dir"/folder.gif "$dir"/folder.tif "$dir"/folder.tiff \
    "$dir"/front.jpg "$dir"/front.jpeg "$dir"/front.png "$dir"/front.webp "$dir"/front.bmp "$dir"/front.gif "$dir"/front.tif "$dir"/front.tiff; do
    [[ -f "$candidate" ]] || continue
    candidate="$(path_resolve "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    [[ -n "${seen["$candidate"]+x}" ]] && continue
    seen["$candidate"]=1
    ordered+=("$candidate")
  done

  ((had_nullglob == 1)) || shopt -u nullglob
  ((had_nocaseglob == 1)) || shopt -u nocaseglob

  if ((${#ordered[@]} == 0)); then
    return 0
  fi

  local -a cover_first=()
  local -a folder_then=()
  local -a front_then=()
  local -a rest=()

  for candidate in "${ordered[@]}"; do
    base="$(basename "$candidate")"
    lowered="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    case "$lowered" in
    cover.*) cover_first+=("$candidate") ;;
    folder.*) folder_then+=("$candidate") ;;
    front.*) front_then+=("$candidate") ;;
    *) rest+=("$candidate") ;;
    esac
  done

  out_ref=("${cover_first[@]}" "${folder_then[@]}" "${front_then[@]}" "${rest[@]}")
}

artwork_probe_media_art_count() {
  local in="$1"
  local raw
  raw="$(ffprobe -v error -select_streams v -show_entries stream=index -of default=noprint_wrappers=1:nokey=0 "$in" </dev/null 2>/dev/null || true)"
  awk -F= '$1 == "index" { c += 1 } END { print c + 0 }' <<<"$raw"
}

artwork_probe_jpeg_dimensions() {
  local in="$1"
  local raw width height
  raw="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1:nokey=0 "$in" </dev/null 2>/dev/null || true)"
  width="$(awk -F= '$1 == "width" { print $2; exit }' <<<"$raw")"
  height="$(awk -F= '$1 == "height" { print $2; exit }' <<<"$raw")"
  if [[ "$width" =~ ^[0-9]+$ ]] && [[ "$height" =~ ^[0-9]+$ ]]; then
    printf '%s\t%s' "$width" "$height"
    return 0
  fi
  return 1
}

artwork_render_canonical_cover_from_image() {
  local image_path="$1"
  local out_path="$2"
  local max_dim="$3"
  local quality="$4"
  local filter
  filter="scale=w='min(${max_dim},iw)':h='min(${max_dim},ih)':force_original_aspect_ratio=decrease"
  ffmpeg -hide_banner -loglevel error -nostdin -y \
    -i "$image_path" \
    -frames:v 1 \
    -vf "$filter" \
    -q:v "$quality" \
    -pix_fmt yuvj420p \
    "$out_path" </dev/null
}

artwork_render_canonical_cover_from_embedded() {
  local media_path="$1"
  local out_path="$2"
  local max_dim="$3"
  local quality="$4"
  local filter
  filter="scale=w='min(${max_dim},iw)':h='min(${max_dim},ih)':force_original_aspect_ratio=decrease"
  ffmpeg -hide_banner -loglevel error -nostdin -y \
    -i "$media_path" \
    -map 0:v:0 \
    -frames:v 1 \
    -vf "$filter" \
    -q:v "$quality" \
    -pix_fmt yuvj420p \
    "$out_path" </dev/null
}

artwork_config_fingerprint() {
  local max_dim="$1"
  local quality="$2"
  local cleanup_extra_sidecars="${3:-0}"
  printf 'sidecar=%s|max=%s|quality=%s|cleanup_extra_sidecars=%s\n' \
    "$(artwork_sidecar_name)" "$max_dim" "$quality" "$cleanup_extra_sidecars" | cksum | awk '{print $1 "-" $2}'
}

artwork_source_fingerprint() {
  local album_dir="$1"
  local -a audio_files=()
  local -a cover_files=()
  local file sig

  audio_collect_files "$album_dir" audio_files
  artwork_collect_coverlike_files "$album_dir" cover_files

  {
    for file in "${audio_files[@]}"; do
      sig="$(audio_probe_file_stat_signature "$file" || true)"
      printf 'audio\t%s\t%s\n' "$(basename "$file")" "$sig"
    done
    for file in "${cover_files[@]}"; do
      sig="$(audio_probe_file_stat_signature "$file" || true)"
      printf 'cover\t%s\t%s\n' "$(basename "$file")" "$sig"
    done
  } | LC_ALL=C sort | cksum | awk '{print $1 "-" $2}'
}

artwork_cache_is_current() {
  local album_dir="$1"
  local src_fp="$2"
  local cfg_fp="$3"
  local status cached_src cached_cfg
  status="$(artwork_cache_get "$album_dir" "STATUS")"
  cached_src="$(artwork_cache_get "$album_dir" "SOURCE_FINGERPRINT")"
  cached_cfg="$(artwork_cache_get "$album_dir" "CONFIG_FINGERPRINT")"
  [[ "$status" == "ok" && "$src_fp" == "$cached_src" && "$cfg_fp" == "$cached_cfg" ]]
}

artwork_guess_album_identity() {
  local album_dir="$1"
  local out_artist_var="$2"
  local out_album_var="$3"
  local out_year_var="$4"
  local -n out_artist_ref="$out_artist_var"
  local -n out_album_ref="$out_album_var"
  local -n out_year_ref="$out_year_var"
  local -a audio_files=()
  local first_track=""
  local guessed_artist=""
  local guessed_album=""
  local guessed_year=""
  local album_dir_name=""
  local parent_dir_name=""

  audio_collect_files "$album_dir" audio_files
  if ((${#audio_files[@]} > 0)); then
    first_track="${audio_files[0]}"
    audio_ffprobe_meta_prime "$first_track"
    guessed_artist="$(artwork_trim_text "$(audio_probe_tag_value "$first_track" "album_artist")")"
    [[ -n "$guessed_artist" ]] || guessed_artist="$(artwork_trim_text "$(audio_probe_tag_value "$first_track" "artist")")"
    guessed_album="$(artwork_trim_text "$(audio_probe_tag_value "$first_track" "album")")"
  fi

  album_dir_name="$(basename "$album_dir")"
  if [[ "$album_dir_name" =~ ^([12][0-9]{3})[[:space:]]*-[[:space:]]*(.+)$ ]]; then
    [[ -n "$guessed_year" ]] || guessed_year="${BASH_REMATCH[1]}"
    [[ -n "$guessed_album" ]] || guessed_album="$(artwork_trim_text "${BASH_REMATCH[2]}")"
  elif [[ -z "$guessed_album" ]]; then
    guessed_album="$(artwork_trim_text "$album_dir_name")"
  fi

  parent_dir_name="$(basename "$(dirname "$album_dir")")"
  if [[ -z "$guessed_artist" && -n "$parent_dir_name" && "$parent_dir_name" != "." && "$parent_dir_name" != "/" ]]; then
    guessed_artist="$(artwork_trim_text "$parent_dir_name")"
  fi

  out_artist_ref="$guessed_artist"
  out_album_ref="$guessed_album"
  out_year_ref="$guessed_year"
}

artwork_rate_limit_musicbrainz() {
  local stamp_file="${TMPDIR:-/tmp}/audlint_artwork_musicbrainz_last_request"
  local now last delay
  now="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  if [[ -f "$stamp_file" ]]; then
    last="$(cat "$stamp_file" 2>/dev/null || printf '0')"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    delay=$((1 - (now - last)))
    if ((delay > 0)); then
      sleep "$delay"
    fi
  fi
  printf '%s\n' "$(date +%s 2>/dev/null || printf '0')" >"$stamp_file" 2>/dev/null || true
}

artwork_pick_musicbrainz_candidate() {
  local json_path="$1"
  local artist="$2"
  local album="$3"
  local year="${4:-}"
  local py_bin="${AUDL_PYTHON_BIN:-python3}"

  command -v "$py_bin" >/dev/null 2>&1 || return 1

  "$py_bin" - "$json_path" "$artist" "$album" "$year" <<'PY'
import json
import re
import sys

json_path, query_artist, query_album, query_year = sys.argv[1:5]


def norm(text: str) -> str:
    text = (text or "").casefold()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def artist_credit_name(release: dict) -> str:
    parts: list[str] = []
    for item in release.get("artist-credit") or []:
        if isinstance(item, str):
            parts.append(item)
            continue
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if isinstance(name, str) and name:
            parts.append(name)
            continue
        artist = item.get("artist") or {}
        artist_name = artist.get("name")
        if isinstance(artist_name, str) and artist_name:
            parts.append(artist_name)
    return "".join(parts)


def safe_year(value: str) -> str:
    match = re.match(r"^([12][0-9]{3})", value or "")
    return match.group(1) if match else ""


try:
    with open(json_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    sys.exit(1)

query_artist_n = norm(query_artist)
query_album_n = norm(query_album)
query_year_n = safe_year(query_year)
best = None
best_score = -1

for release in payload.get("releases") or []:
    if not isinstance(release, dict):
        continue
    release_id = str(release.get("id") or "").strip()
    if not release_id:
        continue
    title = str(release.get("title") or "")
    date = str(release.get("date") or "")
    rel_year = safe_year(date)
    rel_artist = artist_credit_name(release)
    rel_group_id = str((release.get("release-group") or {}).get("id") or "").strip()
    try:
        mb_score = int(str(release.get("score") or "0"))
    except ValueError:
        mb_score = 0

    title_n = norm(title)
    artist_n = norm(rel_artist)
    title_exact = bool(query_album_n) and title_n == query_album_n
    artist_match = bool(query_artist_n) and (
        artist_n == query_artist_n
        or query_artist_n in artist_n
        or artist_n in query_artist_n
    )
    year_match = bool(query_year_n) and rel_year == query_year_n

    score = 0
    if title_exact:
        score += 120
    elif query_album_n and (query_album_n in title_n or title_n in query_album_n):
        score += 40

    if artist_match:
        score += 80

    if year_match:
        score += 20
    elif query_year_n and rel_year and rel_year != query_year_n:
        score -= 40

    score += max(0, min(mb_score, 100)) // 5

    if title_exact and artist_match:
        score += 30

    if score > best_score:
        best_score = score
        best = (release_id, rel_group_id, title, rel_artist, rel_year, score, title_exact, artist_match)

if not best:
    sys.exit(1)

release_id, rel_group_id, title, rel_artist, rel_year, score, title_exact, artist_match = best
if not (title_exact and artist_match):
    sys.exit(2)
if query_year_n and rel_year and rel_year != query_year_n:
    sys.exit(3)

print("\t".join([release_id, rel_group_id, title, rel_artist, rel_year, str(score)]))
PY
}

artwork_try_fetch_cover_from_remote() {
  local album_dir="$1"
  local out_cover="$2"
  local max_dim="$3"
  local quality="$4"
  local artist=""
  local album=""
  local year=""
  local query=""
  local user_agent=""
  local search_json=""
  local fetched_image=""
  local release_id=""
  local release_group_id=""
  local matched_title=""
  local matched_artist=""
  local matched_year=""
  local matched_score=""
  local candidate_url=""
  local escaped_artist=""
  local escaped_album=""
  local query_with_year=""
  local query_without_year=""
  local query_freeform=""
  local active_query=""
  local -a search_queries=()
  local search_ok=0

  artwork_guess_album_identity "$album_dir" artist album year
  if [[ -z "$artist" || -z "$album" ]]; then
    ARTWORK_LAST_ERROR="missing art fetch skipped: album artist/title could not be resolved"
    return 1
  fi

  if declare -F has_bin >/dev/null 2>&1; then
    has_bin curl || {
      ARTWORK_LAST_ERROR="missing art fetch requires curl"
      return 1
    }
  fi
  if ! command -v "${AUDL_PYTHON_BIN:-python3}" >/dev/null 2>&1; then
    ARTWORK_LAST_ERROR="missing art fetch requires ${AUDL_PYTHON_BIN:-python3}"
    return 1
  fi

  escaped_artist="$(artwork_musicbrainz_escape_query_value "$artist")"
  escaped_album="$(artwork_musicbrainz_escape_query_value "$album")"
  query="release:\"${escaped_album}\" AND artist:\"${escaped_artist}\""
  if [[ -n "$year" ]]; then
    query_with_year="${query} AND date:${year}*"
    search_queries+=("$query_with_year")
  fi
  query_without_year="$query"
  query_freeform="${artist} ${album}"
  if [[ -n "$year" ]]; then
    query_freeform="${query_freeform} ${year}"
  fi
  search_queries+=("$query_without_year" "$query_freeform")
  user_agent="$(artwork_fetch_user_agent)"
  search_json="$(mktemp "${TMPDIR:-/tmp}/artwork_fetch_search.XXXXXX" 2>/dev/null || true)"
  fetched_image="$(mktemp "${TMPDIR:-/tmp}/artwork_fetch_image.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$search_json" || -z "$fetched_image" ]]; then
    rm -f "$search_json" "$fetched_image"
    ARTWORK_LAST_ERROR="missing art fetch failed: could not create temporary files"
    return 1
  fi

  for active_query in "${search_queries[@]}"; do
    [[ -n "$active_query" ]] || continue
    artwork_rate_limit_musicbrainz
    if ! curl -fsSL -A "$user_agent" --get \
      --data-urlencode "query=$active_query" \
      --data "fmt=json" \
      --data "limit=10" \
      -o "$search_json" \
      "https://musicbrainz.org/ws/2/release"; then
      continue
    fi
    if IFS=$'\t' read -r release_id release_group_id matched_title matched_artist matched_year matched_score < <(
      artwork_pick_musicbrainz_candidate "$search_json" "$artist" "$album" "$year"
    ); then
      search_ok=1
      break
    fi
  done

  if [[ "$search_ok" != "1" ]]; then
    rm -f "$search_json" "$fetched_image"
    ARTWORK_LAST_ERROR="missing art fetch found no confident MusicBrainz match for ${artist} - ${album}"
    return 1
  fi

  rm -f "$fetched_image"
  for candidate_url in \
    "https://coverartarchive.org/release/${release_id}/front-500" \
    "https://coverartarchive.org/release/${release_id}/front"; do
    fetched_image="$(mktemp "${TMPDIR:-/tmp}/artwork_fetch_image.XXXXXX" 2>/dev/null || true)"
    [[ -n "$fetched_image" ]] || continue
    if curl -fsSL -A "$user_agent" -L -o "$fetched_image" "$candidate_url" \
      && artwork_render_canonical_cover_from_image "$fetched_image" "$out_cover" "$max_dim" "$quality"; then
      rm -f "$search_json" "$fetched_image"
      ARTWORK_LAST_SOURCE="fetched:musicbrainz:release:${release_id}"
      return 0
    fi
    rm -f "$fetched_image"
  done

  if [[ -n "$release_group_id" ]]; then
    for candidate_url in \
      "https://coverartarchive.org/release-group/${release_group_id}/front-500" \
      "https://coverartarchive.org/release-group/${release_group_id}/front"; do
      fetched_image="$(mktemp "${TMPDIR:-/tmp}/artwork_fetch_image.XXXXXX" 2>/dev/null || true)"
      [[ -n "$fetched_image" ]] || continue
      if curl -fsSL -A "$user_agent" -L -o "$fetched_image" "$candidate_url" \
        && artwork_render_canonical_cover_from_image "$fetched_image" "$out_cover" "$max_dim" "$quality"; then
        rm -f "$search_json" "$fetched_image"
        ARTWORK_LAST_SOURCE="fetched:musicbrainz:release-group:${release_group_id}"
        return 0
      fi
      rm -f "$fetched_image"
    done
  fi

  rm -f "$search_json" "$fetched_image"
  ARTWORK_LAST_ERROR="missing art fetch failed: no downloadable front cover found for ${artist} - ${album}"
  return 1
}

artwork_pick_source() {
  local album_dir="$1"
  local out_cover="$2"
  local max_dim="$3"
  local quality="$4"
  local fetch_missing="${5:-0}"
  local -a cover_files=()
  local -a audio_files=()
  local candidate track count

  artwork_collect_coverlike_files "$album_dir" cover_files
  if ((${#cover_files[@]} > 0)); then
    candidate="${cover_files[0]}"
    if artwork_render_canonical_cover_from_image "$candidate" "$out_cover" "$max_dim" "$quality"; then
      ARTWORK_LAST_SOURCE="sidecar:$(basename "$candidate")"
      return 0
    fi
  fi

  audio_collect_files "$album_dir" audio_files
  for track in "${audio_files[@]}"; do
    count="$(artwork_probe_media_art_count "$track" || true)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    ((count > 0)) || continue
    if artwork_render_canonical_cover_from_embedded "$track" "$out_cover" "$max_dim" "$quality"; then
      ARTWORK_LAST_SOURCE="embedded:$(basename "$track")"
      return 0
    fi
  done

  if [[ "$fetch_missing" == "1" ]]; then
    if artwork_try_fetch_cover_from_remote "$album_dir" "$out_cover" "$max_dim" "$quality"; then
      return 0
    fi
  fi

  return 1
}

artwork_embed_cover_ffmpeg() {
  local media_path="$1"
  local cover_path="$2"
  local ext tmp_dir tmp_file
  ext="${media_path##*.}"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/artwork_embed.XXXXXX" 2>/dev/null || true)"
  [[ -n "$tmp_dir" ]] || return 1
  tmp_file="$tmp_dir/output.${ext}"
  if ffmpeg -hide_banner -loglevel error -nostdin -y \
    -i "$media_path" -i "$cover_path" \
    -map 0:a -map_metadata 0 -map 1:v:0 \
    -c:a copy -c:v mjpeg -disposition:v:0 attached_pic \
    "$tmp_file" </dev/null; then
    mv -f "$tmp_file" "$media_path"
    rm -rf "$tmp_dir"
    return 0
  fi
  rm -rf "$tmp_dir"
  return 1
}

artwork_embed_cover_for_track() {
  local media_path="$1"
  local cover_path="$2"
  local codec ext

  codec="$(audio_codec_name "$media_path" || true)"
  ext="${media_path##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

  case "$codec:$ext" in
  flac:*)
    if declare -F has_bin >/dev/null 2>&1 && has_bin metaflac; then
      if metaflac --remove --block-type=PICTURE "$media_path" >/dev/null 2>&1 \
        && metaflac --import-picture-from="$cover_path" "$media_path" >/dev/null 2>&1; then
        return 0
      fi
    fi
    artwork_embed_cover_ffmpeg "$media_path" "$cover_path"
    ;;
  mp3:*)
    if declare -F has_bin >/dev/null 2>&1 && has_bin eyeD3; then
      eyeD3 --remove-all-images "$media_path" >/dev/null 2>&1 || true
      if eyeD3 --add-image "$cover_path:FRONT_COVER" "$media_path" >/dev/null 2>&1; then
        return 0
      fi
    fi
    artwork_embed_cover_ffmpeg "$media_path" "$cover_path"
    ;;
  alac:* | aac:* | *:m4a | *:mp4)
    if declare -F has_bin >/dev/null 2>&1 && has_bin AtomicParsley; then
      if AtomicParsley "$media_path" --artwork REMOVE_ALL --artwork "$cover_path" --overWrite >/dev/null 2>&1; then
        return 0
      fi
    fi
    artwork_embed_cover_ffmpeg "$media_path" "$cover_path"
    ;;
  *)
    artwork_embed_cover_ffmpeg "$media_path" "$cover_path"
    ;;
  esac
}

artwork_remove_extra_sidecars() {
  local album_dir="$1"
  local canonical_path="$2"
  local dry_run="${3:-0}"
  local -a cover_files=()
  local file removed=0
  local canonical_real
  canonical_real="$(path_resolve "$canonical_path" 2>/dev/null || printf '%s' "$canonical_path")"
  artwork_collect_coverlike_files "$album_dir" cover_files
  for file in "${cover_files[@]}"; do
    file="$(path_resolve "$file" 2>/dev/null || printf '%s' "$file")"
    [[ "$file" == "$canonical_real" ]] && continue
    removed=$((removed + 1))
    if [[ "$dry_run" == "1" ]]; then
      continue
    fi
    rm -f "$file" >/dev/null 2>&1 || true
  done
  printf '%s' "$removed"
}

artwork_standardize_album() {
  local album_dir="$1"
  local mode="${2:-apply}"
  local cleanup_extra_sidecars="${3:-0}"
  local fetch_missing="${4:-0}"
  local dry_run=0
  local max_dim quality sidecar_name canonical_cover source_fp config_fp
  local tmp_dir normalized_cover dims width height
  local -a audio_files=()
  local track embed_count fail_name=""
  local remove_count=0

  artwork_reset_last_result
  [[ -d "$album_dir" ]] || {
    ARTWORK_LAST_STATUS="error"
    ARTWORK_LAST_ERROR="album directory not found: $album_dir"
    return 1
  }

  case "$mode" in
  dry-run) dry_run=1 ;;
  *) dry_run=0 ;;
  esac

  if declare -F has_bin >/dev/null 2>&1; then
    has_bin ffmpeg || {
      ARTWORK_LAST_STATUS="error"
      ARTWORK_LAST_ERROR="ffmpeg not found"
      return 1
    }
    has_bin ffprobe || {
      ARTWORK_LAST_STATUS="error"
      ARTWORK_LAST_ERROR="ffprobe not found"
      return 1
    }
  fi

  audio_collect_files "$album_dir" audio_files
  if ((${#audio_files[@]} == 0)); then
    ARTWORK_LAST_STATUS="error"
    ARTWORK_LAST_ERROR="no audio files found"
    return 1
  fi

  ARTWORK_LAST_TRACKS_TOTAL="${#audio_files[@]}"
  sidecar_name="$(artwork_sidecar_name)"
  canonical_cover="$album_dir/$sidecar_name"
  max_dim="$(artwork_max_dim)"
  quality="$(artwork_jpeg_quality)"
  source_fp="$(artwork_source_fingerprint "$album_dir")"
  config_fp="$(artwork_config_fingerprint "$max_dim" "$quality" "$cleanup_extra_sidecars")"

  if ((dry_run == 0)) && artwork_cache_is_current "$album_dir" "$source_fp" "$config_fp"; then
    artwork_load_last_result_from_cache "$album_dir"
    return 0
  fi

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/artwork_album.XXXXXX" 2>/dev/null || true)"
  [[ -n "$tmp_dir" ]] || {
    ARTWORK_LAST_STATUS="error"
    ARTWORK_LAST_ERROR="failed to create temporary directory"
    return 1
  }
  normalized_cover="$tmp_dir/cover.jpg"

  if ! artwork_pick_source "$album_dir" "$normalized_cover" "$max_dim" "$quality" "$fetch_missing"; then
    rm -rf "$tmp_dir"
    ARTWORK_LAST_STATUS="error"
    if [[ -z "${ARTWORK_LAST_ERROR:-}" ]]; then
      if [[ "$fetch_missing" == "1" ]]; then
        ARTWORK_LAST_ERROR="no sidecar, embedded, or fetched art source found"
      else
        ARTWORK_LAST_ERROR="no sidecar or embedded art source found"
      fi
    fi
    ARTWORK_LAST_SOURCE_FINGERPRINT="$source_fp"
    ARTWORK_LAST_CONFIG_FINGERPRINT="$config_fp"
    if ((dry_run == 0)); then
      artwork_write_cache "$album_dir"
    fi
    return 1
  fi

  dims="$(artwork_probe_jpeg_dimensions "$normalized_cover" || true)"
  IFS=$'\t' read -r width height <<<"$dims"
  [[ "$width" =~ ^[0-9]+$ ]] || width=0
  [[ "$height" =~ ^[0-9]+$ ]] || height=0
  ARTWORK_LAST_WIDTH="$width"
  ARTWORK_LAST_HEIGHT="$height"
  ARTWORK_LAST_SIDECAR="$sidecar_name"
  ARTWORK_LAST_SOURCE_FINGERPRINT="$source_fp"
  ARTWORK_LAST_CONFIG_FINGERPRINT="$config_fp"

  for track in "${audio_files[@]}"; do
    embed_count="$(artwork_probe_media_art_count "$track" || true)"
    [[ "$embed_count" =~ ^[0-9]+$ ]] || embed_count=0
    if ((embed_count > 1)); then
      ARTWORK_LAST_EXTRA_EMBEDS_CLEARED=$((ARTWORK_LAST_EXTRA_EMBEDS_CLEARED + embed_count - 1))
    fi
    if ((dry_run == 1)); then
      ARTWORK_LAST_TRACKS_OK=$((ARTWORK_LAST_TRACKS_OK + 1))
      continue
    fi
    if artwork_embed_cover_for_track "$track" "$normalized_cover"; then
      ARTWORK_LAST_TRACKS_OK=$((ARTWORK_LAST_TRACKS_OK + 1))
      continue
    fi
    ARTWORK_LAST_TRACKS_FAILED=$((ARTWORK_LAST_TRACKS_FAILED + 1))
    [[ -z "$fail_name" ]] && fail_name="$(basename "$track")"
  done

  if [[ "$cleanup_extra_sidecars" == "1" ]]; then
    remove_count="$(artwork_remove_extra_sidecars "$album_dir" "$canonical_cover" "$dry_run")"
    [[ "$remove_count" =~ ^[0-9]+$ ]] || remove_count=0
    ARTWORK_LAST_EXTRA_SIDECARS_CLEARED="$remove_count"
  fi

  if ((dry_run == 0)); then
    mkdir -p "$album_dir"
    mv -f "$normalized_cover" "$canonical_cover"
    ARTWORK_LAST_CHANGED=1
  fi

  rm -rf "$tmp_dir"

  if ((ARTWORK_LAST_TRACKS_FAILED > 0)); then
    ARTWORK_LAST_STATUS="error"
    ARTWORK_LAST_ERROR="failed to write embedded art for ${ARTWORK_LAST_TRACKS_FAILED}/${ARTWORK_LAST_TRACKS_TOTAL} track(s); first failure=${fail_name:-unknown}"
  elif ((dry_run == 1)); then
    ARTWORK_LAST_STATUS="dry-run"
  else
    ARTWORK_LAST_STATUS="ok"
  fi

  if ((dry_run == 0)); then
    ARTWORK_LAST_SOURCE_FINGERPRINT="$(artwork_source_fingerprint "$album_dir")"
    artwork_write_cache "$album_dir"
  fi

  [[ "$ARTWORK_LAST_STATUS" != "error" ]]
}

artwork_run_cover_album_postprocess() {
  local album_dir="$1"
  local default_bin="${2:-}"
  local dry_run="${3:-0}"
  local cover_bin="${AUDLINT_COVER_ALBUM_BIN:-${COVER_ALBUM_BIN:-$default_bin}}"
  local -a args=(--summary-only --yes --cleanup-extra-sidecars)
  local output=""
  local rc=0

  artwork_auto_enabled || return 0

  if [[ -z "$cover_bin" || ! -x "$cover_bin" ]]; then
    artwork_reset_last_result
    ARTWORK_LAST_STATUS="error"
    ARTWORK_LAST_ERROR="cover_album.sh not executable (${cover_bin:-missing})"
    printf '%s\n' "$(artwork_status_summary_colored)"
    return 1
  fi

  if [[ "$dry_run" == "1" ]]; then
    args+=(--dry-run)
  fi
  if artwork_fetch_missing_enabled; then
    args+=(--fetch-missing-art)
  fi

  output="$("$cover_bin" "${args[@]}" "$album_dir" 2>&1)" || rc=$?
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  return "$rc"
}
