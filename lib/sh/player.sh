#!/usr/bin/env bash
# shellcheck disable=SC2094,SC2329
# Shared player-payload policy.  Callers supply LIBRARY_ROOT and MEDIA_PLAYER_PATH.

PLAYER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Player helpers are also sourced by the isolated browser transfer runner.
# Load path/stat portability there without requiring every caller to know it.
if ! declare -F path_resolve >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$PLAYER_LIB_DIR/bootstrap.sh"
fi
# shellcheck source=/dev/null
source "$PLAYER_LIB_DIR/audio.sh"

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
  local LC_ALL=C
  [[ -n "${LIBRARY_ROOT:-}" && -n "$source_path" ]] || return 1
  root_real="$(path_resolve "$LIBRARY_ROOT" 2>/dev/null || true)"
  source_real="$(path_resolve "$source_path" 2>/dev/null || true)"
  [[ -n "$root_real" && -n "$source_real" ]] || return 1
  case "$source_real" in "$root_real"/*) ;; *) return 1 ;; esac
  rel="${source_real#"$root_real"/}"
  [[ -n "$rel" && "$rel" != /* ]] || return 1
  [[ "$rel" != *[[:cntrl:]]* ]] || return 1
  printf '%s' "$rel"
}

# Print a complete Player Content inventory row for one candidate directory:
# relative path, resolved source, display artist, artist sort key, year, title,
# and title sort key. Field separators are safe because control characters in
# the validated relative path and display names are rejected.
player_content_inventory_row_from_dir() {
  local source_path="$1" root="$2" rel artist album year title artist_norm album_norm nested_dir=""
  local -a parts=()
  source_path="$(cd "$source_path" 2>/dev/null && pwd -P)"
  [[ -n "$source_path" && -n "$root" && -d "$source_path" && -r "$source_path" ]] || return 1
  case "$source_path" in "$root"/*) ;; *) return 1 ;; esac
  rel="${source_path#"$root"/}"
  [[ -n "$rel" && "$rel" != /* && "$rel" != *[[:cntrl:]]* ]] || return 1
  IFS='/' read -r -a parts <<<"$rel"
  if [[ "${#parts[@]}" == 2 && "${parts[0]}" == "_VA" ]]; then
    artist="_VA"
    album="${parts[1]}"
    if [[ "$album" =~ ^[0-9]{4}$ ]]; then
      nested_dir="$(find "$source_path" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)"
      [[ -z "$nested_dir" ]] || return 1
    fi
  elif [[ "${#parts[@]}" == 3 && "${parts[0]}" != "_VA" ]]; then
    artist="${parts[1]}"
    album="${parts[2]}"
  else
    return 1
  fi
  [[ -n "$artist" && -n "$album" && "$artist" != *[[:cntrl:]]* && "$album" != *[[:cntrl:]]* ]] || return 1

  year=0
  title="$album"
  if [[ "$album" =~ ^([0-9]{4})[[:space:]]-[[:space:]](.+)$ ]]; then
    year=$((10#${BASH_REMATCH[1]}))
    title="${BASH_REMATCH[2]}"
  fi
  artist_norm="${artist,,}"
  album_norm="${title,,}"
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$rel" "$source_path" "$artist" "$artist_norm" "$year" "$title" "$album_norm"
}

# Print the display grouping label for a validated source-library album path.
# Descendants of the top-level `_VA` namespace share its heading; other paths
# use their immediate parent. Source paths directly beneath the library root
# have no artist directory and are deliberately unavailable to the selector.
player_artist_directory_label_from_source() {
  local source_path="$1" rel parent top_level
  rel="$(player_relative_album_path_from_source "$source_path" || true)"
  [[ "$rel" == */* ]] || return 1
  top_level="${rel%%/*}"
  [[ "$top_level" == "_VA" ]] && { printf '%s' "$top_level"; return 0; }
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

player_filesystem_free_bytes() {
  local path="$1" available=""
  [[ -e "$path" && -d "$path" ]] || return 1
  available="$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4 * 1024; exit }')"
  [[ "$available" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$available"
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

# Track-only transfer helpers.  A snapshot is a private, line-oriented file of
# `relative-path US f US logical-bytes`.  Source and destination comparisons
# consume this one representation; no compatibility snapshot format exists.
player_secure_temp_create() {
  local label="$1" out_var="$2" kind="${3:-file}" candidate="${TMPDIR:-/tmp}" protected resolved db_dir fallback_ok=1
  [[ "$kind" == file || "$kind" == directory ]] || return 1
  [[ "$label" =~ ^[A-Za-z0-9_-]+$ && -n "$out_var" ]] || return 1
  resolved="$(path_resolve "$candidate" 2>/dev/null || true)"
  [[ -n "$resolved" && -d "$resolved" && -w "$resolved" ]] || { candidate=/tmp; resolved="$(path_resolve /tmp 2>/dev/null || true)"; }
  db_dir="$(path_resolve "$(dirname "${AUDL_DB_PATH:-${DB_PATH:-/nonexistent}}")" 2>/dev/null || true)"
  for protected in "${LIBRARY_ROOT:-}" "${AUDLINT_LIBRARY_ROOT:-}" "${MEDIA_PLAYER_PATH:-}" "$db_dir" "${AUDLINT_REPO_ROOT:-}" "${REPO_ROOT:-}"; do
    [[ -n "$protected" ]] || continue
    protected="$(path_resolve "$protected" 2>/dev/null || true)"
    [[ -n "$protected" ]] || continue
    case "$resolved" in "$protected"|"$protected"/*) fallback_ok=0;; esac
  done
  if ((fallback_ok == 0)) && [[ "$candidate" != /tmp ]]; then
    candidate=/tmp
    resolved="$(path_resolve /tmp 2>/dev/null || true)"
    fallback_ok=1
    for protected in "${LIBRARY_ROOT:-}" "${AUDLINT_LIBRARY_ROOT:-}" "${MEDIA_PLAYER_PATH:-}" "$db_dir" "${AUDLINT_REPO_ROOT:-}" "${REPO_ROOT:-}"; do
      [[ -n "$protected" ]] || continue
      protected="$(path_resolve "$protected" 2>/dev/null || true)"
      [[ -n "$protected" ]] || continue
      case "$resolved" in "$protected"|"$protected"/*) fallback_ok=0;; esac
    done
  fi
  [[ -n "$resolved" && -d "$resolved" && -w "$resolved" && "$fallback_ok" == 1 ]] || return 1
  local made=""
  if [[ "$kind" == directory ]]; then
    made="$(umask 077; mktemp -d "$resolved/audlint_${label}.XXXXXX" 2>/dev/null)" || return 1
    [[ -n "$made" && -d "$made" ]] || return 1
  else
    made="$(umask 077; mktemp "$resolved/audlint_${label}.XXXXXX" 2>/dev/null)" || return 1
    [[ -n "$made" && -f "$made" ]] || return 1
  fi
  printf -v "$out_var" '%s' "$made"
}

player_snapshot_path_is_eligible() {
  local relative_path="$1" component base_name
  [[ -n "$relative_path" && "$relative_path" != /* && "$relative_path" != *[[:cntrl:]]* ]] || return 1
  IFS='/' read -r -a path_parts <<<"$relative_path"
  for component in "${path_parts[@]}"; do
    [[ -n "$component" && "$component" != .* ]] || return 1
  done
  base_name="${relative_path##*/}"
  audio_name_has_track_extension "$base_name"
}

player_transfer_destination_is_safe() {
  local destination="$1" library="$2" db_dir="$3" repo="$4" system_tmp=""
  system_tmp="$(path_resolve /tmp 2>/dev/null || true)"
  case "$destination" in ""|/|/Volumes|/Users|/System|/private|/tmp|"$system_tmp"|/var|"$HOME"|"$library"|"$db_dir"|"$repo") return 1;; esac
  case "$destination" in "$library"/*|"$repo"/*) return 1;; esac
  case "$library" in "$destination"/*) return 1;; esac
  case "$db_dir" in "$destination"/*) return 1;; esac
  case "$repo" in "$destination"/*) return 1;; esac
  return 0
}

# Browser transfers own an album subtree only.  Verify its complete path before
# transfer so a later mkdir or rsync cannot be the first discovery of an
# unsafe, colliding, or unwritable destination.
player_browser_destination_preflight() {
  local player_root="$1" relative_path="$2" destination parent component
  [[ -n "$player_root" && -n "$relative_path" && "$relative_path" != /* && "$relative_path" != *[[:cntrl:]]* ]] || return 1
  IFS='/' read -r -a _player_destination_parts <<<"$relative_path"
  for component in "${_player_destination_parts[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. && "$component" != .* ]] || return 1
  done
  [[ -d "$player_root" && ! -L "$player_root" && -w "$player_root" && -x "$player_root" ]] || return 1
  parent="$player_root"
  for component in "${_player_destination_parts[@]}"; do
    parent="$parent/$component"
    if [[ -e "$parent" || -L "$parent" ]]; then
      [[ -d "$parent" && ! -L "$parent" && -w "$parent" && -x "$parent" ]] || return 1
    else
      break
    fi
  done
  destination="$player_root/$relative_path"
  [[ "$destination" == "$player_root"/* ]]
}

player_snapshot_total_bytes() {
  local snapshot="$1" relative type bytes total=0 max=9223372036854775807
  [[ -f "$snapshot" ]] || return 1
  while IFS=$'\x1f' read -r relative type bytes; do
    player_snapshot_path_is_eligible "$relative" && [[ "$type" == f && "$bytes" =~ ^[0-9]+$ ]] || return 1
    (( bytes <= max - total )) || return 1
    total=$((total + bytes))
  done <"$snapshot"
  printf '%s' "$total"
}

player_rsync_filter_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\*/\\*}"; raw="${raw//\?/\\?}"; raw="${raw//\[/\\[}"
  printf '%s' "$raw"
}

player_snapshot_compile_rules() {
  local snapshot="$1" rules_file="$2" parent_file stage relative type bytes parent escaped
  [[ -f "$snapshot" && -n "$rules_file" ]] || return 1
  player_secure_temp_create parents parent_file || return 1
  player_secure_temp_create rules stage || { rm -f "$parent_file"; return 1; }
  : >"$parent_file" && : >"$stage" || { rm -f "$parent_file" "$stage"; return 1; }
  while IFS=$'\x1f' read -r relative type bytes; do
    player_snapshot_path_is_eligible "$relative" && [[ "$type" == f && "$bytes" =~ ^[0-9]+$ ]] || { rm -f "$parent_file" "$stage"; return 1; }
    parent="${relative%/*}"
    while [[ "$parent" != "$relative" && -n "$parent" ]]; do
      printf '%s\n' "$parent" >>"$parent_file" || { rm -f "$parent_file" "$stage"; return 1; }
      [[ "$parent" == */* ]] || break
      parent="${parent%/*}"
    done
  done <"$snapshot"
  LC_ALL=C sort -u "$parent_file" | while IFS= read -r parent; do escaped="$(player_rsync_filter_escape "$parent")"; printf '+ /%s/\n' "$escaped" >>"$stage" || exit 1; done || { rm -f "$parent_file" "$stage"; return 1; }
  while IFS=$'\x1f' read -r relative type bytes; do escaped="$(player_rsync_filter_escape "$relative")"; printf '+ /%s\n' "$escaped" >>"$stage" || { rm -f "$parent_file" "$stage"; return 1; }; done <"$snapshot"
  printf '%s\n' '- *' >>"$stage" || { rm -f "$parent_file" "$stage"; return 1; }
  mv -f "$stage" "$rules_file" || { rm -f "$parent_file" "$stage"; return 1; }
  rm -f "$parent_file"
}

player_snapshot_compare() { cmp -s "$1" "$2"; }

player_destination_snapshot_build() {
  local root="$1" _owned_scope="$2" output="$3" root_real stage walk path relative bytes
  [[ -d "$root" && -n "$output" ]] || return 1
  root_real="$(path_resolve "$root" 2>/dev/null || true)"; [[ -n "$root_real" ]] || return 1
  player_secure_temp_create destination stage || return 1
  player_secure_temp_create destination_walk walk || { rm -f "$stage"; return 1; }
  : >"$stage" || { rm -f "$stage" "$walk"; return 1; }
  if ! find -P "$root_real" -mindepth 1 -print0 >"$walk" 2>/dev/null; then rm -f "$stage" "$walk"; return 1; fi
  while IFS= read -r -d '' path; do
    relative="${path#"$root_real"/}"; [[ "$path" == "$root_real"/* && "$relative" != *[[:cntrl:]]* ]] || { rm -f "$stage" "$walk"; return 1; }
    if [[ -L "$path" ]]; then printf '%s\x1fl\x1f0\n' "$relative" >>"$stage" || { rm -f "$stage" "$walk"; return 1; }
    elif [[ -d "$path" ]]; then printf '%s\x1fd\x1f0\n' "$relative" >>"$stage" || { rm -f "$stage" "$walk"; return 1; }
    elif [[ -f "$path" ]]; then bytes="$(stat_size_bytes "$path" 2>/dev/null || true)"; [[ "$bytes" =~ ^[0-9]+$ ]] || { rm -f "$stage" "$walk"; return 1; }; printf '%s\x1ff\x1f%s\n' "$relative" "$bytes" >>"$stage" || { rm -f "$stage" "$walk"; return 1; }
    else printf '%s\x1fs\x1f0\n' "$relative" >>"$stage" || { rm -f "$stage" "$walk"; return 1; }; fi
  done <"$walk"
  rm -f "$walk"
  LC_ALL=C sort "$stage" -o "$stage" || { rm -f "$stage"; return 1; }
  mv -f "$stage" "$output" || { rm -f "$stage"; return 1; }
}

player_destination_snapshot_matches() {
  local source_snapshot="$1" destination_snapshot="$2" expected actual
  player_secure_temp_create expected expected || return 1
  while IFS=$'\x1f' read -r relative type bytes; do
    player_snapshot_path_is_eligible "$relative" && [[ "$type" == f && "$bytes" =~ ^[0-9]+$ ]] || { rm -f "$expected"; return 1; }
    printf '%s\x1ff\x1f%s\n' "$relative" "$bytes" >>"$expected" || { rm -f "$expected"; return 1; }
    local parent="${relative%/*}"
    while [[ "$parent" != "$relative" && -n "$parent" ]]; do printf '%s\x1fd\x1f0\n' "$parent" >>"$expected"; [[ "$parent" == */* ]] || break; parent="${parent%/*}"; done
  done <"$source_snapshot"
  LC_ALL=C sort -u "$expected" -o "$expected" || { rm -f "$expected"; return 1; }
  cmp -s "$expected" "$destination_snapshot"; local rc=$?; rm -f "$expected"; return "$rc"
}

player_snapshot_build() {
  local root="$1" output="$2" stage walk rel bytes root_real
  root_real="$(path_resolve "$root" 2>/dev/null || true)"
  [[ -n "$root_real" && -d "$root_real" && ! -L "$root" ]] || return 1
  player_secure_temp_create snapshot_stage stage || return 1
  player_secure_temp_create snapshot_walk walk || { rm -f "$stage"; return 1; }
  : >"$stage" || { rm -f "$stage" "$walk"; return 1; }
  if ! find -P "$root_real" -mindepth 1 -print0 >"$walk" 2>/dev/null; then rm -f "$stage" "$walk"; return 1; fi
  while IFS= read -r -d '' rel; do
    rel="${rel#"$root_real"/}"; [[ "$rel" != *[[:cntrl:]]* ]] || { rm -f "$stage" "$walk"; return 1; }
    [[ -f "$root_real/$rel" && ! -L "$root_real/$rel" ]] || continue
    player_snapshot_path_is_eligible "$rel" || continue
    [[ -r "$root_real/$rel" ]] || { rm -f "$stage" "$walk"; return 1; }
    bytes="$(stat_size_bytes "$root_real/$rel" 2>/dev/null || true)"; [[ "$bytes" =~ ^[0-9]+$ ]] || { rm -f "$stage" "$walk"; return 1; }
    printf '%s\x1ff\x1f%s\n' "$rel" "$bytes" >>"$stage" || { rm -f "$stage" "$walk"; return 1; }
  done <"$walk"
  rm -f "$walk"
  LC_ALL=C sort -u "$stage" -o "$stage" || { rm -f "$stage"; return 1; }
  mv -f "$stage" "$output" || { rm -f "$stage"; return 1; }
}
player_snapshot_append_prefixed() {
  local snapshot="$1" prefix="$2" output="$3" relative type bytes
  [[ -f "$snapshot" && -n "$prefix" && -f "$output" ]] || return 1
  while IFS=$'\x1f' read -r relative type bytes; do
    player_snapshot_path_is_eligible "$relative" && [[ "$type" == f && "$bytes" =~ ^[0-9]+$ ]] || return 1
    printf '%s/%s\x1ff\x1f%s\n' "$prefix" "$relative" "$bytes" >>"$output" || return 1
  done <"$snapshot"
}
player_snapshot_matches_destination() { local snapshot="$1" dest="$2" actual; player_secure_temp_create destination_verify actual || return 1; player_destination_snapshot_build "$dest" "$dest" "$actual" && player_destination_snapshot_matches "$snapshot" "$actual"; local rc=$?; rm -f "$actual"; return "$rc"; }

player_payload_size_bytes_for_dir() {
  local snapshot="" total
  player_secure_temp_create payload_size snapshot || return 1
  if ! player_snapshot_build "$1" "$snapshot"; then rm -f "$snapshot"; return 1; fi
  total="$(player_snapshot_total_bytes "$snapshot" 2>/dev/null || true)"
  rm -f "$snapshot"
  [[ "$total" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$total"
}
