#!/usr/bin/env bash
# audlint-maintain.sh - Maintenance control window for audlint task/cron actions.

set -Eeuo pipefail

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
source "$BOOTSTRAP_DIR/../lib/sh/sqlite.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/player.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"

AUDLINT_TASK_BIN="${AUDLINT_TASK_BIN:-$SCRIPT_DIR/audlint-task.sh}"
AUDLINT_TASK_MAX_ALBUMS="${AUDL_TASK_MAX_ALBUMS:-30}"
AUDLINT_TASK_MAX_TIME_SEC="${AUDL_TASK_MAX_TIME_SEC:-0}"
AUDLINT_TASK_LOG="${AUDL_TASK_LOG_PATH:-$HOME/audlint-task.log}"
AUDLINT_LIBRARY_ROOT="${AUDLINT_LIBRARY_ROOT:-${LIBRARY_ROOT:-${AUDL_PATH:-}}}"
AUDLINT_CRON_INTERVAL_MIN="${AUDL_CRON_INTERVAL_MIN:-20}"
AUDLINT_BOOST_SEEK_BIN="${AUDLINT_BOOST_SEEK_BIN:-$SCRIPT_DIR/boost_seek.sh}"
AUDLINT_COVER_SEEK_BIN="${AUDLINT_COVER_SEEK_BIN:-$SCRIPT_DIR/cover_seek.sh}"
MEDIA_PLAYER_PATH="${AUDL_MEDIA_PLAYER_PATH:-}"
AUDL_DB_PATH="${AUDL_DB_PATH:-${AUDL_PATH:+${AUDL_PATH}/library.sqlite}}"
AUDL_DB_PATH="${AUDL_DB_PATH:-}"
RSYNC_BIN="${RSYNC_BIN:-rsync}"
SYNC_BIN="${SYNC_BIN:-sync}"
NO_COLOR="${NO_COLOR:-}"
USE_COLOR=false
C_RESET=""
C_TITLE=""
C_LABEL=""
C_VALUE=""
C_ACTION=""
C_RESULT=""
C_SELECT=""
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  USE_COLOR=true
  C_RESET=$'\033[0m'
  C_TITLE=$'\033[1;36m'
  C_LABEL=$'\033[1;37m'
  C_VALUE=$'\033[0;36m'
  C_ACTION=$'\033[1;33m'
  C_RESULT=$'\033[1;32m'
  C_SELECT=$'\033[1;31m'
fi

CRON_BLOCK_BEGIN="# >>> audlint-cli maintain >>>"
CRON_BLOCK_END="# <<< audlint-cli maintain <<<"
paint() {
  local color="$1"
  local text="$2"
  if [[ "$USE_COLOR" == true ]]; then
    printf '%s%s%s' "$color" "$text" "$C_RESET"
  else
    printf '%s' "$text"
  fi
}

virtwin_set_right_hint() {
  local text="$1"
  [[ "${VIRTWIN_TITLE_ROW:-}" =~ ^[0-9]+$ ]] || return 0
  [[ "${VIRTWIN_TERM_COLS:-}" =~ ^[0-9]+$ ]] || return 0
  local row cols plain col rendered hint_width hint_start body_row clear_start
  row="$VIRTWIN_TITLE_ROW"
  cols="$VIRTWIN_TERM_COLS"
  plain="${text//$'\n'/ }"
  plain="${plain//$'\r'/ }"
  (( ${#plain} > 0 )) || return 0
  # A normal virtual-window title is short; reserve 24 columns for it so the
  # full live status remains readable on ordinary terminals.  Small windows
  # split their single title row evenly and clip the status safely.
  if ((cols > 48)); then hint_width=$((cols - 24)); else hint_width=$((cols / 2)); fi
  ((hint_width > 0)) || return 0
  if ((${#plain} > hint_width)); then
    if ((hint_width == 1)); then plain="${plain:0:1}"; else plain="${plain:0:$((hint_width - 1))}…"; fi
  fi
  hint_start=$((cols - hint_width + 1))
  col=$(( cols - ${#plain} + 1 ))
  rendered="$(paint "$C_RESULT" "$plain")"
  body_row=$((row + 3))
  clear_start="$hint_start"
  if [[ "${virtwin_right_hint_row:-}" == "$row" && "${virtwin_right_hint_start:-}" =~ ^[0-9]+$ ]]; then
    clear_start="$virtwin_right_hint_start"
  fi
  # Clear from the previous reserved right field, never from column one, then
  # redraw and leave the cursor at the selector's scroll-region origin.
  printf '\033[%s;%sH\033[K\033[%s;%sH%s\033[%s;1H' "$row" "$clear_start" "$row" "$col" "$rendered" "$body_row"
  virtwin_right_hint_row="$row"
  virtwin_right_hint_start="$hint_start"
}

pause_with_result() {
  local result="$1"
  local _key=""
  tty_print_text $'\n'
  tty_print_line "$(paint "$C_RESULT" "$result")"
  ui_prompt_key "[any key Continue] > " _key 1 0 || true
  exit 0
}

shell_quote_sh() {
  local raw="$1" quote="'" escape="\\"
  raw="${raw//$quote/$quote$escape$quote$quote}"
  printf "'%s'" "$raw"
}

int_ge() {
  local raw="$1"
  local min="$2"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  ((raw >= min))
}

player_attached() {
  [[ -n "$MEDIA_PLAYER_PATH" && -d "$MEDIA_PLAYER_PATH" && -w "$MEDIA_PLAYER_PATH" ]]
}

player_content_db_available() {
  [[ -n "$AUDL_DB_PATH" && -f "$AUDL_DB_PATH" && -r "$AUDL_DB_PATH" && -w "$AUDL_DB_PATH" && -w "$(dirname "$AUDL_DB_PATH")" ]] || return 1
  album_quality_db_init "$AUDL_DB_PATH"
}

player_content_status_title() {
  local selected="$1" total="$2" sizing_pending="${3:-0}" sizing_total="${4:-0}" card="not mounted" sized=0
  [[ -n "$MEDIA_PLAYER_PATH" && -d "$MEDIA_PLAYER_PATH" ]] && card="mounted"
  if [[ "$sizing_pending" =~ ^[0-9]+$ && "$sizing_total" =~ ^[0-9]+$ ]] && ((sizing_pending > 0)); then
    sized=$((sizing_total - sizing_pending))
    printf 'SD: %s | Selected: %s | Total: sizing… (%s/%s albums)' "$card" "$selected" "$sized" "$sizing_total"
    return 0
  fi
  printf 'SD: %s | Selected: %s | Total: %s' "$card" "$selected" "$(player_human_size_label "$total")"
}

player_content_term_lines() {
  if declare -F term_lines_value >/dev/null 2>&1; then term_lines_value; else printf '%s' "${LINES:-24}"; fi
}

player_content_term_cols() {
  if declare -F term_cols_value >/dev/null 2>&1; then term_cols_value; else printf '%s' "${COLUMNS:-100}"; fi
}

player_content_read_selector_key() {
  # The selector owns one raw TTY session.  A short probe distinguishes a
  # terminal CSI arrow from Escape; a bare Escape then waits for its jump
  # letter without depending on the old 50 ms per-read raw-mode teardown.
  local out_var="$1" tty_fd="$2" timeout_sec="${3:-0.1}" read_key="" rest=""
  IFS= read -r -t "$timeout_sec" -n 1 -u "$tty_fd" read_key 2>/dev/null || true
  if [[ "$read_key" == $'\e' ]]; then
    IFS= read -r -t 0.05 -n 1 -u "$tty_fd" rest 2>/dev/null || true
    if [[ "$rest" == "[" || "$rest" == "O" ]]; then
      IFS= read -r -t 0.05 -n 1 -u "$tty_fd" rest 2>/dev/null || true
      case "$rest" in
        A) read_key="up" ;;
        B) read_key="down" ;;
        *) read_key="" ;;
      esac
    elif [[ "$rest" =~ ^[A-Za-z]$ ]]; then
      read_key="jump:${rest}"
    elif [[ -z "$rest" ]]; then
      # Human-paced Escape-letter input is intentionally allowed to take a
      # second.  A bare Escape is harmless after this bounded wait.
      IFS= read -r -t 1.05 -n 1 -u "$tty_fd" rest 2>/dev/null || true
      if [[ "$rest" =~ ^[A-Za-z]$ ]]; then
        read_key="jump:${rest}"
      else
        read_key=""
      fi
    else
      read_key=""
    fi
  fi
  printf -v "$out_var" '%s' "$read_key"
}

player_content_selector_write_row() {
  local row="$1" text="$2"
  printf '\033[%s;1H\033[2K%s' "$row" "$text"
}

player_content_selector_clean_label() {
  local raw="$1" width="$2" suffix="…"
  raw="${raw//$'\r'/ }"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\e'/}"
  [[ "$width" =~ ^[0-9]+$ ]] || width=1
  ((width > 0)) || { printf ''; return 0; }
  if ((${#raw} > width)); then
    if ((width == 1)); then
      raw="${raw:0:1}"
    else
      raw="${raw:0:$((width - 1))}${suffix}"
    fi
  fi
  printf '%s' "$raw"
}

player_content_selector_restore_terminal() {
  if [[ "${selector_active:-false}" == true && -n "${selector_fd:-}" && -n "${selector_state:-}" ]]; then
    stty "$selector_state" 0<&"$selector_fd" 2>/dev/null || true
  fi
  selector_active=false
  printf '\033[?25h'
}

player_content_selector_cleanup() {
  player_content_selector_restore_terminal
  [[ "${selector_scroll_region_active:-false}" == true ]] && printf '\033[;r'
  [[ -n "${selector_fd:-}" ]] && tty_close_input_fd "$selector_fd"
  selector_fd=""
}

player_content_selector_enter_raw() {
  [[ -n "${selector_fd:-}" && -n "${selector_state:-}" ]] || return 1
  if ! stty -echo -icanon min 1 time 0 0<&"$selector_fd" 2>/dev/null; then
    player_content_selector_restore_terminal
    return 1
  fi
  selector_active=true
  printf '\033[?25l'
}

player_content_selector_jump() {
  local letter="${1,,}" current="$2" current_identity="" idx candidate=-1 next_group=0 normalized
  [[ "$current" =~ ^[0-9]+$ && "$current" -lt ${#artist_norms[@]} ]] && current_identity="${artist_norms[$current],,}"
  for ((idx=0; idx<${#artists[@]}; idx++)); do
    normalized="${artist_norms[$idx],,}"
    ((idx == 0)) || [[ "$normalized" != "${artist_norms[$((idx - 1))],,}" ]] || continue
    [[ "${normalized:0:1}" == "$letter" ]] || continue
    if ((next_group == 1)); then
      printf '%s' "$idx"
      return 0
    fi
    ((candidate < 0)) && candidate="$idx"
    [[ "$normalized" == "$current_identity" ]] && next_group=1
  done
  ((candidate >= 0)) && printf '%s' "$candidate"
  return 0
}

player_content_selector_row_before() {
  local left="$1" right="$2"
  if [[ "${artist_norms[$left]}" != "${artist_norms[$right]}" ]]; then
    [[ "${artist_norms[$left]}" < "${artist_norms[$right]}" ]]
  elif ((years[left] != years[right])); then
    ((years[left] < years[right]))
  elif [[ "${album_norms[$left]}" != "${album_norms[$right]}" ]]; then
    [[ "${album_norms[$left]}" < "${album_norms[$right]}" ]]
  else
    ((left < right))
  fi
}

player_content_selector_sort_rows() {
  local count width start middle finish left right array_name ordered_idx
  local -a row_order=() merged_order=()
  count="${#artists[@]}"
  for ((left=0; left<count; left++)); do row_order[$left]="$left"; done
  for ((width=1; width<count; width=$((width * 2)))); do
    merged_order=()
    for ((start=0; start<count; start=$((start + width * 2)))); do
      middle=$((start + width)); ((middle > count)) && middle="$count"
      finish=$((start + width * 2)); ((finish > count)) && finish="$count"
      left="$start"; right="$middle"
      while ((left < middle && right < finish)); do
        if player_content_selector_row_before "${row_order[$left]}" "${row_order[$right]}"; then
          merged_order+=("${row_order[$left]}"); left=$((left + 1))
        else
          merged_order+=("${row_order[$right]}"); right=$((right + 1))
        fi
      done
      while ((left < middle)); do merged_order+=("${row_order[$left]}"); left=$((left + 1)); done
      while ((right < finish)); do merged_order+=("${row_order[$right]}"); right=$((right + 1)); done
    done
    row_order=("${merged_order[@]}")
  done
  for array_name in artist_lcs artist_norms album_lcs album_norms years artists albums sources checked sizes available; do
    local -n selector_rows="$array_name"
    local -a selector_snapshot=("${selector_rows[@]}")
    selector_rows=()
    for ordered_idx in "${row_order[@]}"; do selector_rows+=("${selector_snapshot[$ordered_idx]}"); done
  done
}

player_content_size_at() {
  local index="$1" bytes=""
  [[ "${sizes[$index]:--1}" == "-1" ]] || return 0
  if bytes="$(player_payload_size_bytes_for_dir "${sources[$index]}" 2>/dev/null)" && [[ "$bytes" =~ ^[0-9]+$ ]]; then
    sizes[$index]="$bytes"
  else
    sizes[$index]=0
    available[$index]=0
  fi
  sizing_pending=$((sizing_pending - 1))
  [[ "${checked[$index]}" == 1 ]] && total=$((total + sizes[index]))
  return 0
}

player_content_size_batch() {
  local batch_size="${1:-4}" index
  while ((batch_size > 0 && sizing_cursor < ${#artists[@]})); do
    index="$sizing_cursor"
    sizing_cursor=$((sizing_cursor + 1))
    [[ "${sizes[$index]}" == "-1" ]] || continue
    player_content_size_at "$index"
    batch_size=$((batch_size - 1))
  done
  return 0
}

player_content_filter_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\*/\\*}"; raw="${raw//\?/\\?}"; raw="${raw//\[/\\[}"
  printf '%s' "$raw"
}

player_content_safe_destination() {
  local destination="$1" library="$2" db_dir="$3" repo="$4" system_tmp="" system_root="/"
  system_tmp="$(path_resolve "${system_root}tmp" 2>/dev/null || true)"
  case "$destination" in ""|/|/Volumes|/Users|/System|/private|/tmp|"$system_tmp"|/var|"$HOME"|"$library"|"$db_dir"|"$repo") return 1;; esac
  case "$destination" in "$library"/*|"$repo"/*) return 1;; esac
  case "$library" in "$destination"/*) return 1;; esac
  case "$db_dir" in "$destination"/*) return 1;; esac
  case "$repo" in "$destination"/*) return 1;; esac
  return 0
}

player_content_sync() {
  local selected_count="$1" total_bytes="$2"
  local library_real player_real db_real db_dir_real repo_real row artist_lc album_lc year_int artist album source_path rel escaped prefix refreshed_bytes=0 source_bytes=0
  library_real="$(path_resolve "$AUDLINT_LIBRARY_ROOT" 2>/dev/null || true)"
  player_real="$(path_resolve "$MEDIA_PLAYER_PATH" 2>/dev/null || true)"
  db_real="$(path_resolve "$AUDL_DB_PATH" 2>/dev/null || true)"
  db_dir_real="$(path_resolve "$(dirname "$AUDL_DB_PATH")" 2>/dev/null || true)"
  repo_real="$(path_resolve "$REPO_ROOT" 2>/dev/null || true)"
  [[ -n "$library_real" && -d "$library_real" && -r "$library_real" ]] || { printf 'Sync failed: library root is not a readable directory.\n'; return 1; }
  [[ -n "$player_real" && -d "$player_real" && -w "$player_real" ]] || { printf 'Sync failed: player path is not a writable mounted directory.\n'; return 1; }
  player_content_safe_destination "$player_real" "$library_real" "$db_dir_real" "$repo_real" || { printf 'Sync failed: unsafe player destination.\n'; return 1; }
  command -v "$RSYNC_BIN" >/dev/null 2>&1 || { printf 'Sync failed: rsync not found (%s).\n' "$RSYNC_BIN"; return 1; }
  command -v "$SYNC_BIN" >/dev/null 2>&1 || { printf 'Sync failed: sync command not found (%s).\n' "$SYNC_BIN"; return 1; }

  local manifest
  manifest="$(mktemp "${TMPDIR:-/tmp}/audlint_player_manifest.XXXXXX" 2>/dev/null || true)"
  [[ -n "$manifest" ]] || { printf 'Sync failed: unable to create manifest.\n'; return 1; }
  local -a rsync_args=(-av --delete --delete-excluded --itemize-changes) parent_rules=() selected_rules=()
  # Directory rules make only the checked source-relative albums traversable;
  # shared payload filters then retain exactly the browser transfer payload.
  while IFS=$'\x1f' read -r artist_lc album_lc year_int artist album source_path; do
    source_path="$(path_resolve "$source_path" 2>/dev/null || true)"
    [[ -n "$source_path" && -d "$source_path" && -r "$source_path" ]] || { rm -f "$manifest"; printf 'Sync failed: selected source is unreadable.\n'; return 1; }
    rel="$(LIBRARY_ROOT="$library_real" player_relative_album_path_from_source "$source_path" || true)"
    [[ -n "$rel" ]] || { rm -f "$manifest"; printf 'Sync failed: selected source escapes library root.\n'; return 1; }
    source_bytes="$(player_payload_size_bytes_for_dir "$source_path" 2>/dev/null || true)"
    [[ "$source_bytes" =~ ^[0-9]+$ ]] || { rm -f "$manifest"; printf 'Sync failed: selected source payload cannot be sized.\n'; return 1; }
    refreshed_bytes=$((refreshed_bytes + source_bytes))
    escaped="$(player_content_filter_escape "$rel")"
    prefix=""
    IFS='/' read -r -a _pcs_parts <<< "$escaped"
    local _pcs_part
    for _pcs_part in "${_pcs_parts[@]}"; do prefix="${prefix:+$prefix/}${_pcs_part}"; parent_rules+=("--include=/${prefix}/"); done
    selected_rules+=("--include=/${escaped}/***")
    printf '%s\x1f%s\n' "$source_path" "$rel" >>"$manifest"
  done < <(sqlite3 -separator $'\x1f' -noheader "$AUDL_DB_PATH" "SELECT pcs.artist_lc,pcs.album_lc,pcs.year_int,aq.artist,aq.album,aq.source_path FROM player_content_selection pcs LEFT JOIN album_quality aq ON aq.artist_lc=pcs.artist_lc AND aq.album_lc=pcs.album_lc AND aq.year_int=pcs.year_int ORDER BY aq.artist_norm,aq.album_norm,aq.year_int,aq.id;" 2>/dev/null)
  local manifest_count expected_count
  manifest_count="$(wc -l <"$manifest" | tr -d '[:space:]')"
  expected_count="$(sqlite3 -noheader "$AUDL_DB_PATH" "SELECT COUNT(*) FROM player_content_selection;" 2>/dev/null || true)"
  [[ "$expected_count" =~ ^[0-9]+$ && "$manifest_count" =~ ^[0-9]+$ && "$manifest_count" == "$expected_count" ]] || { rm -f "$manifest"; printf 'Sync failed: selected identity no longer resolves exactly once.\n'; return 1; }
  selected_count="$expected_count"
  total_bytes="$refreshed_bytes"
  rsync_args+=("${parent_rules[@]}")
  player_rsync_payload_filters rsync_args
  rsync_args+=("${selected_rules[@]}")
  rsync_args+=(--exclude='*')
  printf '\nDestination: %s\nSelected: %s album(s), %s\nAll player content not in this selection will be deleted.\n[y synchronize, any other key cancel] > ' "$player_real" "$selected_count" "$(player_human_size_label "$total_bytes")"
  local confirm=""; tty_read_key confirm 1 || confirm="n"; printf '\n'
  if [[ "${confirm,,}" != "y" ]]; then rm -f "$manifest"; printf 'Synchronization cancelled.\n'; return 0; fi
  printf 'Synchronizing player...\n'
  if "$RSYNC_BIN" "${rsync_args[@]}" "$library_real"/ "$player_real"/ && "$SYNC_BIN"; then
    rm -f "$manifest"; printf 'Synchronization completed: %s album(s).\n' "$selected_count"; return 0
  fi
  rm -f "$manifest"; printf 'Synchronization failed; selection was preserved.\n'; return 1
}

player_content_creator() {
  player_content_db_available || pause_with_result "Player Content Creator unavailable: database is missing, unreadable, or read-only."
  player_content_selection_cleanup_stale "$AUDL_DB_PATH" || pause_with_result "Player Content Creator unavailable: cannot update database."
  local -a artist_lcs=() artist_norms=() album_lcs=() album_norms=() years=() artists=() albums=() sources=() checked=() sizes=() available=()
  local -a selector_drawn=()
  local row artist_lc artist_norm album_lc album_norm year_int artist album source_path is_checked directory_artist total=0 selected=0 cursor=0 offset=0 key idx sizing_pending=0 sizing_cursor=0
  local selector_fd="" selector_state="" selector_active=false selector_footer="" selector_body_title="" selector_status="" selector_needs_status=true selector_cols=0 selector_scroll_region_active=false done=false
  while IFS=$'\x1f' read -r artist_lc artist_norm album_lc album_norm year_int artist album source_path is_checked; do
    [[ -n "$artist_lc$album_lc$year_int" ]] || continue
    directory_artist=""
    if [[ -d "$source_path" && -r "$source_path" ]]; then
      directory_artist="$(LIBRARY_ROOT="$AUDLINT_LIBRARY_ROOT" player_artist_directory_label_from_source "$source_path" || true)"
    fi
    if [[ -n "$directory_artist" ]]; then
      artist="$directory_artist"
      artist_norm="${directory_artist,,}"
    fi
    artist_lcs+=("$artist_lc"); artist_norms+=("$artist_norm"); album_lcs+=("$album_lc"); album_norms+=("$album_norm"); years+=("$year_int"); artists+=("$artist"); albums+=("$album"); sources+=("$source_path"); checked+=("$is_checked")
    if [[ -n "$directory_artist" && -d "$source_path" && -r "$source_path" ]]; then sizes+=(-1); available+=(1); sizing_pending=$((sizing_pending + 1)); else sizes+=(0); available+=(0); fi
    [[ "$is_checked" == 1 ]] && selected=$((selected + 1))
  done < <(sqlite3 -separator $'\x1f' -noheader "$AUDL_DB_PATH" "SELECT aq.artist_lc,aq.artist_norm,aq.album_lc,aq.album_norm,aq.year_int,aq.artist,aq.album,aq.source_path,CASE WHEN pcs.artist_lc IS NULL THEN 0 ELSE 1 END FROM album_quality aq LEFT JOIN player_content_selection pcs ON pcs.artist_lc=aq.artist_lc AND pcs.album_lc=aq.album_lc AND pcs.year_int=aq.year_int WHERE COALESCE(aq.source_path,'')<>'' OR pcs.artist_lc IS NOT NULL ORDER BY aq.artist_norm,aq.album_norm,aq.year_int,aq.id;" 2>/dev/null)
  player_content_selector_sort_rows
  if ! tty_open_input_fd selector_fd; then
    pause_with_result "Player Content Creator unavailable: no terminal input is available."
  fi
  selector_state="$(stty -g 0<&"$selector_fd" 2>/dev/null || true)"
  if [[ -z "$selector_state" ]]; then
    tty_close_input_fd "$selector_fd"
    printf 'Player Content Creator unavailable: terminal input cannot enter raw mode.\n'
    return 0
  fi
  local initial_lines initial_cols initial_list_top initial_list_bottom
  initial_lines="$(player_content_term_lines)"; [[ "$initial_lines" =~ ^[0-9]+$ ]] || initial_lines=0
  initial_cols="$(player_content_term_cols)"; [[ "$initial_cols" =~ ^[0-9]+$ ]] || initial_cols=0
  initial_list_top=$(( ${VIRTWIN_TITLE_ROW:-6} + 3 ))
  initial_list_bottom=$((initial_lines - 2))
  if ((initial_cols < 20 || initial_list_bottom - initial_list_top + 1 < 2)); then
    tty_close_input_fd "$selector_fd"
    printf 'Player Content Creator unavailable: terminal is too short (need at least 12 rows and 20 columns).\n'
    return 0
  fi
  if ! player_content_selector_enter_raw; then
    tty_close_input_fd "$selector_fd"
    printf 'Player Content Creator unavailable: terminal input cannot enter raw mode.\n'
    return 0
  fi
  trap 'player_content_selector_cleanup' EXIT
  trap 'player_content_selector_cleanup; exit 130' HUP INT TERM
  while [[ "$done" == false ]]; do
    local lines cols list_top list_bottom footer_row body_title_row list_height list_row render_row="" desired="" previous_artist="" position=0 rendered=0 status="" visible=false
    lines="$(player_content_term_lines)"; [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
    cols="$(player_content_term_cols)"; [[ "$cols" =~ ^[0-9]+$ ]] || cols=100
    # virtwin starts its scroll region three rows below its title.  Its title
    # row is passed to this child, so the fixed canvas never touches the main
    # screen header or scrolls the virtual window.
    list_top=$(( ${VIRTWIN_TITLE_ROW:-6} + 3 ))
    list_bottom=$((lines - 2))
    footer_row=$((lines - 1))
    body_title_row=$((list_top - 1))
    list_height=$((list_bottom - list_top + 1))
    if ((cols < 20 || list_height < 2)); then
      player_content_selector_restore_terminal
      printf 'Player Content Creator unavailable: terminal is too short (need at least 12 rows and 20 columns).\n'
      done=true
      continue
    fi
    if [[ "$selector_cols" != "$cols" ]]; then
      selector_cols="$cols"
      selector_needs_status=true
    fi
    if [[ "${VIRTWIN_COMPACT_TOP:-0}" == "1" ]]; then
      printf '\033[%s;%sr\033[%s;1H' "$list_top" "$list_bottom" "$list_top"
      selector_scroll_region_active=true
    fi

    # Keep the selected album inside the physical canvas.  Artist headings
    # consume rows too, unlike the reverted album-count viewport.
    if (( ${#artists[@]} > 0 )); then
      while true; do
        visible=false; rendered=0; previous_artist=""
        ((offset > 0)) && previous_artist="${artists[$((offset - 1))]:-}"
        for ((idx=offset; idx<${#artists[@]} && rendered<list_height; idx++)); do
          if [[ "${artists[$idx]}" != "$previous_artist" ]]; then
            previous_artist="${artists[$idx]}"
            rendered=$((rendered + 1))
            ((rendered > list_height)) && break
          fi
          rendered=$((rendered + 1))
          if [[ "$idx" == "$cursor" ]] && ((rendered <= list_height)); then visible=true; break; fi
        done
        [[ "$visible" == true ]] && break
        if ((cursor < offset)); then offset="$cursor"; else offset=$((offset + 1)); fi
      done
    fi

    status="$(player_content_status_title "$selected" "$total" "$sizing_pending" "${#artists[@]}")"
    if [[ "$selector_needs_status" == true || "$status" != "$selector_status" ]]; then
      VIRTWIN_TITLE_ROW="${VIRTWIN_TITLE_ROW:-6}" VIRTWIN_TERM_COLS="$cols" virtwin_set_right_hint "$status"
      selector_status="$status"
      selector_needs_status=false
    fi
    desired="$(paint "$C_TITLE" "$(player_content_selector_clean_label 'Player Content Creator' "$cols")")"
    if [[ "$selector_body_title" != "$desired" ]]; then
      player_content_selector_write_row "$body_title_row" "$desired"
      selector_body_title="$desired"
    fi

    rendered=0; previous_artist=""
    ((offset > 0)) && previous_artist="${artists[$((offset - 1))]:-}"
    for ((idx=offset; idx<${#artists[@]} && rendered<list_height; idx++)); do
      if [[ "${artists[$idx]}" != "$previous_artist" ]] && ((rendered < list_height)); then
        previous_artist="${artists[$idx]}"
        desired="$(paint "$C_LABEL" "$(player_content_selector_clean_label "$previous_artist" "$cols")")"
        [[ "${selector_drawn[$rendered]:-__unpainted__}" == "$desired" ]] || player_content_selector_write_row "$((list_top + rendered))" "$desired"
        selector_drawn[$rendered]="$desired"
        rendered=$((rendered + 1))
      fi
      ((rendered >= list_height)) && break
      render_row="  [${checked[$idx]/0/ }] ${years[$idx]} - $(player_content_selector_clean_label "${albums[$idx]}" "$cols")"
      [[ "${checked[$idx]}" == 1 ]] && render_row="  [x] ${years[$idx]} - $(player_content_selector_clean_label "${albums[$idx]}" "$cols")"
      if [[ "${available[$idx]}" != 1 ]]; then
        local unavailable_suffix=" [unavailable]" unavailable_room=0
        unavailable_room=$((cols - ${#unavailable_suffix}))
        render_row="$(player_content_selector_clean_label "$render_row" "$unavailable_room")$(paint "$C_SELECT" "$unavailable_suffix")"
      else
        render_row="$(player_content_selector_clean_label "$render_row" "$cols")"
      fi
      [[ "$idx" == "$cursor" ]] && render_row="$(paint "$C_ACTION" ">")${render_row:1}"
      [[ "${selector_drawn[$rendered]:-__unpainted__}" == "$render_row" ]] || player_content_selector_write_row "$((list_top + rendered))" "$render_row"
      selector_drawn[$rendered]="$render_row"
      rendered=$((rendered + 1))
    done
    while ((rendered < list_height)); do
      if [[ "${selector_drawn[$rendered]+set}" != set || "${selector_drawn[$rendered]}" != "" ]]; then
        player_content_selector_write_row "$((list_top + rendered))" ""
      fi
      selector_drawn[$rendered]=""
      rendered=$((rendered + 1))
    done
    (( ${#artists[@]} > 0 )) && position=$((cursor + 1))
    desired="$(paint "$C_ACTION" "$(player_content_selector_clean_label "Up/Down move | Space toggle | Esc+letter jump | w synchronize | q quit | ${position} of ${#artists[@]}" "$cols")")"
    if [[ "$selector_footer" != "$desired" ]]; then
      player_content_selector_write_row "$footer_row" "$desired"
      selector_footer="$desired"
    fi

    player_content_read_selector_key key "$selector_fd" 0.1
    if [[ -z "$key" ]]; then
      ((sizing_pending > 0)) && player_content_size_batch 1
      continue
    fi
    case "$key" in
      up) ((cursor > 0)) && cursor=$((cursor - 1));;
      down) ((cursor + 1 < ${#artists[@]})) && cursor=$((cursor + 1));;
      ' ') if [[ "${checked[$cursor]}" == 1 ]]; then player_content_selection_toggle "$AUDL_DB_PATH" "${artist_lcs[$cursor]}" "${album_lcs[$cursor]}" "${years[$cursor]}" 0 && { checked[$cursor]=0; [[ "${sizes[cursor]:-0}" == "-1" ]] || total=$((total - sizes[cursor])); selected=$((selected - 1)); }; elif [[ "${available[$cursor]:-0}" == 1 ]]; then player_content_size_at "$cursor"; [[ "${available[$cursor]}" == 1 ]] && player_content_selection_toggle "$AUDL_DB_PATH" "${artist_lcs[$cursor]}" "${album_lcs[$cursor]}" "${years[$cursor]}" 1 && { checked[$cursor]=1; selected=$((selected + 1)); total=$((total + sizes[cursor])); }; fi;;
      jump:*) idx="$(player_content_selector_jump "${key#jump:}" "$cursor")"; [[ "$idx" =~ ^[0-9]+$ ]] && cursor="$idx" ;;
      w) player_content_selector_restore_terminal; printf '\033[%s;1H' "$list_top"; player_content_sync "$selected" "$total" || true; printf '[any key Continue] > '; tty_read_key key 1 || true; player_content_selector_enter_raw || { printf 'Player Content Creator unavailable: terminal input cannot enter raw mode.\n'; done=true; }; selector_drawn=(); selector_footer=""; selector_body_title=""; selector_needs_status=true;;
      q) done=true;;
    esac
  done
  trap - EXIT HUP INT TERM
  player_content_selector_cleanup
  return 0
}

read_crontab_raw() {
  crontab -l 2>/dev/null || true
}

strip_managed_cron_block() {
  awk -v begin="$CRON_BLOCK_BEGIN" -v end="$CRON_BLOCK_END" '
    $0 == begin { in_block=1; next }
    $0 == end { in_block=0; next }
    in_block == 0 { print }
  '
}

cron_is_installed() {
  command -v crontab >/dev/null 2>&1 || return 1
  local current
  current="$(read_crontab_raw)"
  grep -Fqx "$CRON_BLOCK_BEGIN" <<<"$current" && grep -Fqx "$CRON_BLOCK_END" <<<"$current"
}

cron_schedule_for_interval() {
  local interval="$1"
  if ! int_ge "$interval" 1; then
    return 1
  fi
  if ((interval < 60)); then
    printf '*/%s * * * *' "$interval"
    return 0
  fi
  if ((interval == 60)); then
    printf '0 * * * *'
    return 0
  fi
  if ((interval == 1440)); then
    printf '0 0 * * *'
    return 0
  fi
  if ((interval > 60 && interval < 1440 && interval % 60 == 0)); then
    printf '0 */%s * * *' "$((interval / 60))"
    return 0
  fi
  return 1
}

cron_max_time_for_interval() {
  local interval_min="$1"
  if int_ge "$AUDLINT_TASK_MAX_TIME_SEC" 1; then
    printf '%s' "$AUDLINT_TASK_MAX_TIME_SEC"
    return 0
  fi
  if ! int_ge "$interval_min" 1; then
    printf '0'
    return 0
  fi
  local interval_sec
  interval_sec=$((interval_min * 60))
  if ((interval_sec > 120)); then
    printf '%s' "$((interval_sec - 120))"
  else
    printf '%s' "$interval_sec"
  fi
}

render_managed_cron_block() {
  local schedule="$1"
  local cron_max_time="$2"
  local task_q root_q log_q
  task_q="$(shell_quote_sh "$AUDLINT_TASK_BIN")"
  root_q="$(shell_quote_sh "$AUDLINT_LIBRARY_ROOT")"
  log_q="$(shell_quote_sh "$AUDLINT_TASK_LOG")"
  printf '%s\n' "$CRON_BLOCK_BEGIN"
  printf '%s PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ; %s --max-albums %s --max-time %s %s >> %s 2>&1\n' \
    "$schedule" "$task_q" "$AUDLINT_TASK_MAX_ALBUMS" "$cron_max_time" "$root_q" "$log_q"
  printf '%s\n' "$CRON_BLOCK_END"
}

install_cron_block() {
  if ! command -v crontab >/dev/null 2>&1; then
    pause_with_result "Install failed: crontab binary not found."
  fi
  if [[ ! -x "$AUDLINT_TASK_BIN" ]]; then
    pause_with_result "Install failed: task runner not executable ($AUDLINT_TASK_BIN)."
  fi
  if [[ -z "$AUDLINT_LIBRARY_ROOT" || ! -d "$AUDLINT_LIBRARY_ROOT" ]]; then
    pause_with_result "Install failed: AUDLINT_LIBRARY_ROOT is missing or invalid."
  fi
  if ! int_ge "$AUDLINT_TASK_MAX_ALBUMS" 1; then
    pause_with_result "Install failed: AUDL_TASK_MAX_ALBUMS must be >= 1."
  fi

  local schedule
  if ! schedule="$(cron_schedule_for_interval "$AUDLINT_CRON_INTERVAL_MIN")"; then
    pause_with_result "Install failed: unsupported AUDL_CRON_INTERVAL_MIN ($AUDLINT_CRON_INTERVAL_MIN)."
  fi

  local cron_max_time
  cron_max_time="$(cron_max_time_for_interval "$AUDLINT_CRON_INTERVAL_MIN")"
  if ! int_ge "$cron_max_time" 1; then
    pause_with_result "Install failed: invalid cron max-time ($cron_max_time)."
  fi

  local current stripped block new_crontab
  current="$(read_crontab_raw)"
  stripped="$(printf '%s\n' "$current" | strip_managed_cron_block)"
  block="$(render_managed_cron_block "$schedule" "$cron_max_time")"
  if [[ -n "$stripped" ]]; then
    new_crontab="$(printf '%s\n%s\n' "$stripped" "$block")"
  else
    new_crontab="$(printf '%s\n' "$block")"
  fi

  if printf '%s\n' "$new_crontab" | crontab -; then
    pause_with_result "Cron installed."
  fi
  pause_with_result "Install failed: unable to write crontab."
}

uninstall_cron_block() {
  if ! command -v crontab >/dev/null 2>&1; then
    pause_with_result "Uninstall failed: crontab binary not found."
  fi
  local current stripped
  current="$(read_crontab_raw)"
  stripped="$(printf '%s\n' "$current" | strip_managed_cron_block)"
  if printf '%s\n' "$stripped" | crontab -; then
    pause_with_result "Cron uninstalled."
  fi
  pause_with_result "Uninstall failed: unable to write crontab."
}

run_manual_maintain_once() {
  if [[ ! -x "$AUDLINT_TASK_BIN" ]]; then
    pause_with_result "Run failed: task runner not executable ($AUDLINT_TASK_BIN)."
  fi
  if [[ -z "$AUDLINT_LIBRARY_ROOT" || ! -d "$AUDLINT_LIBRARY_ROOT" ]]; then
    pause_with_result "Run failed: AUDLINT_LIBRARY_ROOT is missing or invalid."
  fi
  if ! int_ge "$AUDLINT_TASK_MAX_ALBUMS" 1; then
    pause_with_result "Run failed: AUDL_TASK_MAX_ALBUMS must be >= 1."
  fi

  local task_log_dir
  task_log_dir="$(dirname "$AUDLINT_TASK_LOG")"
  if [[ ! -d "$task_log_dir" || ! -w "$task_log_dir" ]]; then
    pause_with_result "Run failed: log directory unavailable ($task_log_dir)."
  fi

  local -a cmd
  cmd=("$AUDLINT_TASK_BIN" "--max-albums" "$AUDLINT_TASK_MAX_ALBUMS")
  if int_ge "$AUDLINT_TASK_MAX_TIME_SEC" 1; then
    cmd+=("--max-time" "$AUDLINT_TASK_MAX_TIME_SEC")
  fi
  cmd+=("$AUDLINT_LIBRARY_ROOT")

  printf 'Running maintenance task...\n\n'
  local cmd_rc=0
  if [[ "$USE_COLOR" == true && -z "$NO_COLOR" ]]; then
    FORCE_COLOR=1 "${cmd[@]}" 2>&1 | tee -a "$AUDLINT_TASK_LOG" || cmd_rc=${PIPESTATUS[0]}
  else
    "${cmd[@]}" 2>&1 | tee -a "$AUDLINT_TASK_LOG" || cmd_rc=${PIPESTATUS[0]}
  fi
  if ((cmd_rc == 0)); then
    pause_with_result "Maintenance run completed."
  fi
  pause_with_result "Maintenance run failed."
}

view_task_log() {
  if [[ ! -f "$AUDLINT_TASK_LOG" || ! -r "$AUDLINT_TASK_LOG" ]]; then
    pause_with_result "No log yet: $AUDLINT_TASK_LOG"
  fi
  printf 'Task log (live): %s\n' "$AUDLINT_TASK_LOG"
  printf -- '-----------\n'
  printf '[any key Stop live view] >\n\n'

  if ! command -v tail >/dev/null 2>&1; then
    cat "$AUDLINT_TASK_LOG"
    pause_with_result "Live log unavailable: tail command not found."
  fi

  virtwin_set_right_hint "[any key Stop]"
  tail -n 120 -F "$AUDLINT_TASK_LOG" &
  local tail_pid=$!
  local _key=""
  if declare -f tty_read_key >/dev/null 2>&1; then
    tty_read_key _key 1 || true
  else
    IFS= read -r -n 1 -s _key </dev/tty || true
  fi
  kill "$tail_pid" >/dev/null 2>&1 || true
  wait "$tail_pid" 2>/dev/null || true
  printf '\n%s\n' "$(paint "$C_RESULT" "Live log stopped.")"
  exit 0
}

run_boost_gain_for_dir() {
  local selected_dir="$1"
  if [[ ! -x "$AUDLINT_BOOST_SEEK_BIN" ]]; then
    pause_with_result "Boost failed: boost_seek not executable ($AUDLINT_BOOST_SEEK_BIN)."
  fi

  printf 'Boost Gain target: %s\n' "$selected_dir"
  printf -- '-----------\n'
  local rc=0
  (
    cd "$selected_dir" || exit 2
    "$AUDLINT_BOOST_SEEK_BIN" -y
  ) || rc=$?

  if ((rc == 0)); then
    pause_with_result "Boost gain completed."
  fi
  pause_with_result "Boost gain failed (exit $rc)."
}

run_album_art_for_dir() {
  local selected_dir="$1"
  local dry_run="${2:-0}"
  if [[ ! -x "$AUDLINT_COVER_SEEK_BIN" ]]; then
    pause_with_result "Album art failed: cover_seek not executable ($AUDLINT_COVER_SEEK_BIN)."
  fi

  printf 'Album Art target: %s\n' "$selected_dir"
  printf -- '-----------\n'
  local rc=0
  (
    cd "$selected_dir" || exit 2
    if [[ "$dry_run" == "1" ]]; then
      "$AUDLINT_COVER_SEEK_BIN" --dry-run --yes --fetch-missing-art
    else
      "$AUDLINT_COVER_SEEK_BIN" --yes --fetch-missing-art
    fi
  ) || rc=$?

  if ((rc == 0)); then
    if [[ "$dry_run" == "1" ]]; then
      pause_with_result "Album art dry run completed."
    fi
    pause_with_result "Album art completed."
  fi
  pause_with_result "Album art failed (exit $rc)."
}

confirm_clear_player_files_prompt() {
  local prompt_text='Clear all player files? [y Clear, n Cancel] > '
  local choice=""
  ui_prompt_key "$prompt_text" choice 1 1 || choice="n"
  [[ "${choice,,}" == "y" ]]
}

clear_player_files() {
  if ! player_attached; then
    pause_with_result "Clear skipped: AUDL_MEDIA_PLAYER_PATH is missing or not writable."
  fi

  local resolved_path=""
  resolved_path="$(path_resolve "$MEDIA_PLAYER_PATH" 2>/dev/null || printf '%s' "$MEDIA_PLAYER_PATH")"
  case "$resolved_path" in
  "" | "/" | "/Volumes" | "/Users" | "/System" | "/private" | "/tmp" | "$HOME")
    pause_with_result "Clear failed: unsafe player path ($resolved_path)."
    ;;
  esac

  if ! confirm_clear_player_files_prompt; then
    pause_with_result "Player clear cancelled."
  fi

  local before_count=0
  before_count="$(find "$MEDIA_PLAYER_PATH" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "$before_count" =~ ^[0-9]+$ ]] || before_count=0

  if ! find "$MEDIA_PLAYER_PATH" -mindepth 1 -exec rm -rf -- {} + 2>/dev/null; then
    pause_with_result "Player clear failed: could not remove all files."
  fi

  local after_count=0
  after_count="$(find "$MEDIA_PLAYER_PATH" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "$after_count" =~ ^[0-9]+$ ]] || after_count=0

  pause_with_result "Player cleared. items_before=$before_count items_remaining=$after_count"
}

print_boost_choice_grid() {
  local dirs_var="$1"
  local count="$2"
  local keys_var="${3:-}"
  local -n dirs_ref="$dirs_var"
  local -a _empty_keys=()
  local use_custom_keys=false
  local max_cols line_len idx key base plain display_fragment
  max_cols="${VIRTWIN_TERM_COLS:-${COLUMNS:-120}}"
  [[ "$max_cols" =~ ^[0-9]+$ ]] || max_cols=120
  (( max_cols < 40 )) && max_cols=40
  line_len=0

  if [[ -n "$keys_var" ]]; then
    use_custom_keys=true
  else
    keys_var="_empty_keys"
  fi
  local -n keys_ref="$keys_var"

  for ((idx=0; idx<count; idx++)); do
    if [[ "$use_custom_keys" == true ]]; then
      key="${keys_ref[$idx]}"
    else
      key="$(menu_choice_label "$((idx + 1))")"
    fi
    base="$(basename "${dirs_ref[$idx]}")"
    plain="[$key] $base"
    display_fragment="$(paint "$C_SELECT" "[$key]") $(paint "$C_VALUE" "$base")"

    if ((line_len > 0 && line_len + 2 + ${#plain} > max_cols)); then
      printf '\n'
      line_len=0
    fi
    if ((line_len > 0)); then
      printf '  '
      line_len=$((line_len + 2))
    fi
    printf '%s' "$display_fragment"
    line_len=$((line_len + ${#plain}))
  done
  printf '\n'
}

choice_key_is_reserved() {
  local key="${1:-}"
  local reserved_csv="${2:-}"
  local item=""
  key="${key,,}"
  IFS=',' read -r -a _reserved_items <<<"$reserved_csv"
  for item in "${_reserved_items[@]}"; do
    item="${item,,}"
    [[ -n "$item" ]] || continue
    if [[ "$key" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

build_choice_keys_skipping_reserved() {
  local count="$1"
  local out_var="$2"
  local reserved_csv="${3:-}"
  local -n out_ref="$out_var"
  local candidate_idx=1
  local candidate_key=""

  out_ref=()
  while ((${#out_ref[@]} < count && candidate_idx <= 35)); do
    candidate_key="$(menu_choice_label "$candidate_idx")"
    if ! choice_key_is_reserved "$candidate_key" "$reserved_csv"; then
      out_ref+=("$candidate_key")
    fi
    candidate_idx=$((candidate_idx + 1))
  done
}

boost_gain_page() {
  if [[ -z "$AUDLINT_LIBRARY_ROOT" || ! -d "$AUDLINT_LIBRARY_ROOT" ]]; then
    pause_with_result "Boost failed: AUDLINT_LIBRARY_ROOT is missing or invalid."
  fi

  local -a dirs=()
  while IFS= read -r -d '' dir; do
    dirs+=("$dir")
  done < <(find "$AUDLINT_LIBRARY_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | LC_ALL=C sort -z)

  if ((${#dirs[@]} == 0)); then
    pause_with_result "Boost skipped: no directories under library root."
  fi

  # Clear current viewport so the action prompt from the parent menu doesn't
  # remain on screen above the boost page.
  printf '\033[2J\033[H'
  printf '%s\n' "$(paint "$C_TITLE" "Boost Gain")"
  printf -- '%s\n' "$(paint "$C_TITLE" "-----------")"
  printf '%s %s\n\n' "$(paint "$C_LABEL" "Library Root:")" "$(paint "$C_VALUE" "$AUDLINT_LIBRARY_ROOT")"

  local max_choices=34
  local show_count="${#dirs[@]}"
  if ((show_count > max_choices)); then
    show_count="$max_choices"
  fi

  local -a picked=()
  local -a picked_keys=()
  local idx
  for ((idx=0; idx<show_count; idx++)); do
    picked+=("${dirs[$idx]}")
  done
  build_choice_keys_skipping_reserved "$show_count" picked_keys "q"
  print_boost_choice_grid picked "$show_count" picked_keys
  if ((${#dirs[@]} > max_choices)); then
    printf '\nShowing first %d directories (of %d).\n' "$max_choices" "${#dirs[@]}"
  fi
  printf '%s %s\n' "$(paint "$C_SELECT" "[q]")" "$(paint "$C_LABEL" "Cancel")"

  local sel=""
  ui_prompt_key "select directory > " sel 1 1 || sel="q"
  sel="${sel,,}"

  if [[ "$sel" == "q" ]]; then
    return 0
  fi

  local sel_idx=""
  for ((sel_idx=0; sel_idx<show_count; sel_idx++)); do
    if [[ "${picked_keys[$sel_idx]}" == "$sel" ]]; then
      break
    fi
  done
  if ((sel_idx >= show_count)); then
    return 0
  fi
  if ((sel_idx < 0 || sel_idx >= show_count)); then
    return 0
  fi

  run_boost_gain_for_dir "${picked[$sel_idx]}"
}

album_art_page() {
  if [[ -z "$AUDLINT_LIBRARY_ROOT" || ! -d "$AUDLINT_LIBRARY_ROOT" ]]; then
    pause_with_result "Album art failed: AUDLINT_LIBRARY_ROOT is missing or invalid."
  fi
  local -a dirs=()
  while IFS= read -r -d '' dir; do
    dirs+=("$dir")
  done < <(find "$AUDLINT_LIBRARY_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | LC_ALL=C sort -z)

  printf '\033[2J\033[H'
  printf '%s\n' "$(paint "$C_TITLE" "Album Art")"
  printf -- '%s\n' "$(paint "$C_TITLE" "---------")"
  printf '%s %s\n\n' "$(paint "$C_LABEL" "Library Root:")" "$(paint "$C_VALUE" "$AUDLINT_LIBRARY_ROOT")"
  printf 'Walkthrough:\n'
  printf '  - keeps one canonical cover.jpg sidecar per album\n'
  printf '  - normalizes art to JPEG at the configured max dimension\n'
  printf '  - clears extra embedded pictures and re-embeds one consistent cover per track\n'
  printf '  - fetches missing art automatically when no local source exists\n'
  printf '\n'
  printf '%s\n' "$(hint_button d "Dry Run Library Root")"
  printf '%s\n' "$(hint_button r "Run Library Root")"
  if ((${#dirs[@]} > 0)); then
    printf '\n'
    local max_choices=32
    local show_count="${#dirs[@]}"
    if ((show_count > max_choices)); then
      show_count="$max_choices"
    fi
    local -a picked=()
    local -a picked_keys=()
    local idx
    for ((idx=0; idx<show_count; idx++)); do
      picked+=("${dirs[$idx]}")
    done
    build_choice_keys_skipping_reserved "$show_count" picked_keys "d,q,r"
    print_boost_choice_grid picked "$show_count" picked_keys
    if ((${#dirs[@]} > max_choices)); then
      printf '\nShowing first %d directories (of %d).\n' "$max_choices" "${#dirs[@]}"
    fi
    printf '\nSelect a directory key to run only that subtree.\n'
  fi
  printf '%s\n' "$(hint_button q "Back")"
  printf '\n'

  local sel=""
  ui_prompt_key "choice > " sel 1 1 || sel="q"
  sel="${sel,,}"

  case "$sel" in
  q)
    return 0
    ;;
  d)
    run_album_art_for_dir "$AUDLINT_LIBRARY_ROOT" 1
    ;;
  r)
    run_album_art_for_dir "$AUDLINT_LIBRARY_ROOT" 0
    ;;
  *)
    local max_sel="${#dirs[@]}"
    local -a picked_keys=()
    if ((max_sel > 32)); then
      max_sel=32
    fi
    build_choice_keys_skipping_reserved "$max_sel" picked_keys "d,q,r"
    local sel_idx=""
    for ((sel_idx=0; sel_idx<max_sel; sel_idx++)); do
      if [[ "${picked_keys[$sel_idx]}" == "$sel" ]]; then
        break
      fi
    done
    if ((sel_idx >= max_sel)); then
      return 0
    fi
    if ((sel_idx < 0 || sel_idx >= max_sel)); then
      return 0
    fi
    run_album_art_for_dir "${dirs[$sel_idx]}" 0
    ;;
  esac
}

print_menu() {
  local cron_state="$1"
  local player_ready="$2"
  printf '%s\n' "$(paint "$C_TITLE" "Maintenance")"
  printf -- '%s\n' "$(paint "$C_TITLE" "-----------")"
  printf '%s %s\n' "$(paint "$C_LABEL" "Task:")" "$(paint "$C_VALUE" "$AUDLINT_TASK_BIN")"
  printf '%s %s\n' "$(paint "$C_LABEL" "Library Root:")" "$(paint "$C_VALUE" "${AUDLINT_LIBRARY_ROOT:--}")"
  printf '%s %s\n' "$(paint "$C_LABEL" "Cron interval:")" "$(paint "$C_VALUE" "${AUDLINT_CRON_INTERVAL_MIN} min")"
  if [[ "$player_ready" == "yes" ]]; then
    printf '%s %s\n' "$(paint "$C_LABEL" "Player Path:")" "$(paint "$C_VALUE" "$MEDIA_PLAYER_PATH")"
  fi
  printf '\n'
  if [[ "$cron_state" == "installed" ]]; then
    printf '%s\n' "$(hint_button u "Uninstall Cron")"
  else
    printf '%s\n' "$(hint_button m "Run Maintenance")"
    printf '%s\n' "$(hint_button i "Install Cron")"
  fi
  if [[ "$player_ready" == "yes" ]]; then
    printf '%s\n' "$(hint_button t "Clear Player Files")"
  fi
  if [[ -n "$AUDL_DB_PATH" ]]; then
    printf '%s\n' "$(hint_button c "Player Content Creator")"
  fi
  printf '%s\n' "$(hint_button a "Album Art")"
  printf '%s\n' "$(hint_button b "Boost Gain")"
  printf '%s\n' "$(hint_button l "View Log")"
  printf '%s\n' "$(hint_button q "Exit to Main Window")"
  printf '\n'
}

main() {
  while true; do
    local cron_state="stopped"
    local player_ready="no"
    if cron_is_installed; then
      cron_state="installed"
    fi
    if player_attached; then
      player_ready="yes"
    fi

    print_menu "$cron_state" "$player_ready"
    local key=""
    ui_prompt_key "choice > " key 1 0 || key="q"

    case "${key,,}" in
    m)
      if [[ "$cron_state" == "installed" ]]; then
        pause_with_result "Run skipped: cron is installed."
      fi
      run_manual_maintain_once
      ;;
    i)
      if [[ "$cron_state" == "installed" ]]; then
        pause_with_result "Install skipped: cron already installed."
      fi
      install_cron_block
      ;;
    u)
      if [[ "$cron_state" != "installed" ]]; then
        pause_with_result "Uninstall skipped: cron is not installed."
      fi
      uninstall_cron_block
      ;;
    a)
      album_art_page
      ;;
    b)
      boost_gain_page
      ;;
    c)
      if [[ -z "$AUDL_DB_PATH" ]]; then
        pause_with_result "Player Content Creator unavailable: AUDL_DB_PATH is not set."
      fi
      player_content_creator
      ;;
    t)
      if [[ "$player_ready" != "yes" ]]; then
        pause_with_result "Clear skipped: player is not attached."
      fi
      clear_player_files
      ;;
    l)
      view_task_log
      ;;
    q)
      exit 0
      ;;
    *)
      pause_with_result "Unknown action."
      ;;
    esac
  done
}

main "$@"
