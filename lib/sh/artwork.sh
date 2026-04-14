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
  printf 'sidecar=%s|max=%s|quality=%s\n' "$(artwork_sidecar_name)" "$max_dim" "$quality" | cksum | awk '{print $1 "-" $2}'
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

artwork_pick_source() {
  local album_dir="$1"
  local out_cover="$2"
  local max_dim="$3"
  local quality="$4"
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
  config_fp="$(artwork_config_fingerprint "$max_dim" "$quality")"

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

  if ! artwork_pick_source "$album_dir" "$normalized_cover" "$max_dim" "$quality"; then
    rm -rf "$tmp_dir"
    ARTWORK_LAST_STATUS="error"
    ARTWORK_LAST_ERROR="no sidecar or embedded art source found"
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

  remove_count="$(artwork_remove_extra_sidecars "$album_dir" "$canonical_cover" "$dry_run")"
  [[ "$remove_count" =~ ^[0-9]+$ ]] || remove_count=0
  ARTWORK_LAST_EXTRA_SIDECARS_CLEARED="$remove_count"

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
  local -a args=(--summary-only --yes)
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

  output="$("$cover_bin" "${args[@]}" "$album_dir" 2>&1)" || rc=$?
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  return "$rc"
}
