#!/usr/bin/env bash
# Shared player-payload policy.  Callers supply LIBRARY_ROOT and MEDIA_PLAYER_PATH.

player_path_component() {
  local raw="$1"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\r'/ }"
  raw="${raw//\//_}"
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$raw" ]] || raw="unknown"
  printf '%s' "$raw"
}

player_album_dest_dir() {
  local artist="$1" year="$2" album="$3" artist_dir album_dir release_dir index_dir
  artist_dir="$(player_path_component "$artist")"
  album_dir="$(player_path_component "$album")"
  if [[ "$year" =~ ^[0-9]{4}$ ]] && ((year > 0)); then release_dir="${year} - ${album_dir}"; else release_dir="$album_dir"; fi
  index_dir="$(printf '%s' "$artist_dir" | cut -c1 | tr '[:lower:]' '[:upper:]')"
  [[ "$index_dir" =~ ^[A-Z0-9]$ ]] || index_dir="_"
  printf '%s/%s/%s/%s' "$MEDIA_PLAYER_PATH" "$index_dir" "$artist_dir" "$release_dir"
}

# Print a verified path relative to the resolved library root.  It deliberately
# rejects the root itself and paths that escape it through symlinks.
player_relative_album_path_from_source() {
  local source_path="$1" root_real source_real rel
  [[ -n "${LIBRARY_ROOT:-}" && -n "$source_path" ]] || return 1
  root_real="$(path_resolve "$LIBRARY_ROOT" 2>/dev/null || true)"
  source_real="$(path_resolve "$source_path" 2>/dev/null || true)"
  [[ -n "$root_real" && -n "$source_real" ]] || return 1
  case "$source_real" in "$root_real"/*) ;; *) return 1 ;; esac
  rel="${source_real#"$root_real"/}"
  [[ -n "$rel" && "$rel" != /* && "$rel" != *$'\n'* && "$rel" != *$'\r'* ]] || return 1
  printf '%s' "$rel"
}

# Print the source-library artist directory containing a validated album path.
# Source paths directly beneath the library root have no artist directory and
# are deliberately treated as unavailable by the player-content selector.
player_artist_directory_label_from_source() {
  local source_path="$1" rel parent
  rel="$(player_relative_album_path_from_source "$source_path" || true)"
  [[ "$rel" == */* ]] || return 1
  parent="${rel%/*}"
  parent="${parent##*/}"
  [[ -n "$parent" && "$parent" != *[[:cntrl:]]* ]] || return 1
  printf '%s' "$parent"
}

player_album_dest_dir_for_source() {
  local source_path="$1" artist="$2" year="$3" album="$4" rel_path=""
  rel_path="$(player_relative_album_path_from_source "$source_path" || true)"
  if [[ -n "$rel_path" ]]; then printf '%s/%s' "$MEDIA_PLAYER_PATH" "$rel_path"; else player_album_dest_dir "$artist" "$year" "$album"; fi
}

player_payload_includes_file() {
  local file_path="$1" base_name lowered
  base_name="$(basename "$file_path")"
  case "$base_name" in .audlint_inspect_cache.json|.any2flac_truepeak_cache.tsv|.dff2flac_truepeak_cache.tsv|.sox_album_done|.sox_album_profile) return 1;; esac
  lowered="$(printf '%s' "$base_name" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in cover.jpg|cover.jpeg) return 0;; *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp|*.tif|*.tiff) return 1;; esac
  return 0
}

player_payload_size_bytes_for_dir() {
  local dir_path="$1" total_bytes=0 file_path file_bytes
  [[ -d "$dir_path" && -r "$dir_path" ]] || return 1
  while IFS= read -r -d '' file_path; do
    player_payload_includes_file "$file_path" || continue
    [[ -r "$file_path" ]] || return 1
    file_bytes="$(stat_size_bytes "$file_path" 2>/dev/null || true)"
    [[ "$file_bytes" =~ ^[0-9]+$ ]] || return 1
    total_bytes=$((total_bytes + file_bytes))
  done < <(find "$dir_path" -type f -print0 2>/dev/null)
  printf '%s' "$total_bytes"
}

player_payload_total_size_bytes_for_manifest() {
  local manifest_file="$1" total_bytes=0 artist album year source_path dest_dir dir_bytes
  [[ -f "$manifest_file" ]] || { printf '0'; return 0; }
  while IFS=$'\x1f' read -r artist album year source_path dest_dir; do
    [[ -n "$source_path" ]] || continue
    dir_bytes="$(player_payload_size_bytes_for_dir "$source_path" 2>/dev/null || true)"
    [[ "$dir_bytes" =~ ^[0-9]+$ ]] || dir_bytes=0
    total_bytes=$((total_bytes + dir_bytes))
  done < "$manifest_file"
  printf '%s' "$total_bytes"
}

player_human_size_label() {
  local bytes="${1:-0}" unit_idx=0 unit_size=1 whole frac
  local -a units=("b" "Kb" "Mb" "Gb" "Tb")
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  while ((bytes >= unit_size * 1024 && unit_idx < ${#units[@]} - 1)); do unit_size=$((unit_size * 1024)); unit_idx=$((unit_idx + 1)); done
  if ((unit_idx == 0)); then printf '%s%s' "$bytes" "${units[$unit_idx]}"; return 0; fi
  whole=$((bytes / unit_size)); frac=$((((bytes % unit_size) * 10 + unit_size / 2) / unit_size))
  if ((frac >= 10)); then whole=$((whole + 1)); frac=0; fi
  if ((whole >= 100 || frac == 0)); then printf '%s%s' "$whole" "${units[$unit_idx]}"; else printf '%s.%s%s' "$whole" "$frac" "${units[$unit_idx]}"; fi
}

# Append the exact browser transfer payload rules to the named array.
player_rsync_payload_filters() {
  local out_var="$1"; local -n out_ref="$out_var"
  out_ref+=(--exclude='.audlint_inspect_cache.json' --exclude='.any2flac_truepeak_cache.tsv' --exclude='.dff2flac_truepeak_cache.tsv' --exclude='.sox_album_done' --exclude='.sox_album_profile' --include='[cC][oO][vV][eE][rR].[jJ][pP][gG]' --include='[cC][oO][vV][eE][rR].[jJ][pP][eE][gG]' --exclude='*.[jJ][pP][gG]' --exclude='*.[jJ][pP][eE][gG]' --exclude='*.[pP][nN][gG]' --exclude='*.[gG][iI][fF]' --exclude='*.[wW][eE][bB][pP]' --exclude='*.[bB][mM][pP]' --exclude='*.[tT][iI][fF]' --exclude='*.[tT][iI][fF][fF]')
}
