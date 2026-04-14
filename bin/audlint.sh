#!/usr/bin/env bash
# audlint.sh - Interactive browser for AUDL_DB_PATH.album_quality

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
source "$BOOTSTRAP_DIR/../lib/sh/env.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/deps.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/table.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/sqlite.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/virtwin.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/profile.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/rich.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/secure_backup.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true

PAGE_SIZE=15
PAGE=1
CLASS_FILTER="all"
CODEC_FILTER="all"
PROFILE_FILTER="all"
SORT_KEY="checked"
SORT_DIR="desc"
INTERACTIVE="auto"
DB_PATH="${AUDL_DB_PATH:-}"
ACTIVE_VIEW="default"
SEARCH_QUERY=""
NO_COLOR="${NO_COLOR:-}"
USE_COLOR=false
ROW_ACTION_MODE=""
ROW_ACTION_ROWS_RAW_SNAPSHOT=""
QUIT_CONFIRM_MODE=0
ACTION_MESSAGE=""
DB_WRITABLE=true
DB_STATUS_LABEL=""
AUDLINT_TERMINAL_CLEANUP_ACTIVE=0
AUDLINT_TERMINAL_CLEANUP_DONE=0
SYNC_LC_ON_STARTUP="${LIBRARY_BROWSER_SYNC_LC_ON_STARTUP:-0}"
AUDLINT_CRON_INTERVAL_MIN="${AUDL_CRON_INTERVAL_MIN:-20}"
HAS_FTS_SEARCH=0
KEYSET_ENABLED="${LIBRARY_BROWSER_KEYSET_ON:-1}"
SYNC_MUSIC_BIN="${SYNC_MUSIC_BIN:-${REPO_ROOT:-}/bin/sync_music.sh}"
AUDLINT_TASK_BIN="${AUDLINT_TASK_BIN:-${REPO_ROOT:-}/bin/audlint-task.sh}"
AUDLINT_TASK_MAX_ALBUMS="${AUDL_TASK_MAX_ALBUMS:-30}"
AUDLINT_TASK_MAX_TIME_SEC="${AUDL_TASK_MAX_TIME_SEC:-0}"
AUDLINT_TASK_LOG="${AUDL_TASK_LOG_PATH:-$HOME/audlint-task.log}"
AUDLINT_MAINTAIN_BIN="${AUDLINT_MAINTAIN_BIN:-${REPO_ROOT:-}/bin/audlint-maintain.sh}"
AUDLINT_VALUE_BIN="${AUDLINT_VALUE_BIN:-${REPO_ROOT:-}/bin/audlint-value.sh}"
AUDLINT_ANALYZE_BIN="${AUDLINT_ANALYZE_BIN:-${REPO_ROOT:-}/bin/audlint-analyze.sh}"
QTY_COMPARE_BIN="${QTY_COMPARE_BIN:-${REPO_ROOT:-}/bin/qty_compare.sh}"
PYTHON_BIN="${AUDL_PYTHON_BIN:-python3}"
AUDL_HIDE_SUPPORT_GREETER="${AUDL_HIDE_SUPPORT_GREETER:-0}"
CRON_BLOCK_BEGIN="# >>> audlint-cli maintain >>>"
CRON_BLOCK_END="# <<< audlint-cli maintain <<<"
# Discovery cache path mirrors audlint-task.sh resolution.
AUDLINT_TASK_DISCOVERY_CACHE_FILE="${AUDLINT_TASK_DISCOVERY_CACHE_FILE:-${AUDL_CACHE_PATH:-}}"
if [[ -z "$AUDLINT_TASK_DISCOVERY_CACHE_FILE" ]]; then
  _audlint_cache_db="${DB_PATH:-}"
  if [[ -z "$_audlint_cache_db" && -n "${AUDL_PATH:-}" ]]; then
    _audlint_cache_db="$AUDL_PATH/library.sqlite"
  fi
  if [[ -n "$_audlint_cache_db" ]]; then
    _audlint_cache_db="$(env_expand_value "$_audlint_cache_db")"
    _audlint_cache_db_dir="$(dirname "$_audlint_cache_db")"
    _audlint_cache_db_base="$(basename "$_audlint_cache_db")"
    AUDLINT_TASK_DISCOVERY_CACHE_FILE="${_audlint_cache_db_dir}/.audlint_task_last_discovery_${_audlint_cache_db_base}"
    unset _audlint_cache_db_dir _audlint_cache_db_base
  else
    AUDLINT_TASK_DISCOVERY_CACHE_FILE="${TMPDIR:-/tmp}/audlint_task_last_discovery"
  fi
  unset _audlint_cache_db
else
  AUDLINT_TASK_DISCOVERY_CACHE_FILE="$(env_expand_value "$AUDLINT_TASK_DISCOVERY_CACHE_FILE")"
fi
LIBRARY_ROOT="${LIBRARY_ROOT:-${AUDL_PATH:-}}"
MEDIA_PLAYER_PATH="${AUDL_MEDIA_PLAYER_PATH:-}"
SYNC_DEST="${AUDL_SYNC_DEST:-}"
RSYNC_BIN="${RSYNC_BIN:-rsync}"
SYNC_BIN="${SYNC_BIN:-sync}"
ANY2FLAC_BIN="${ANY2FLAC_BIN:-${REPO_ROOT:-}/bin/any2flac.sh}"
LYRICS_SEEK_BIN="${LYRICS_SEEK_BIN:-${REPO_ROOT:-}/bin/lyrics_seek.sh}"
PENDING_NAV=""
HAS_COL_ARTIST_NORM=0
HAS_COL_ALBUM_NORM=0
HAS_COL_GRADE_RANK=0
HAS_COL_CHECKED_SORT=0
HAS_COL_CODEC_NORM=0
HAS_COL_PROFILE_NORM=0
HAS_COL_LAST_RECODED_AT=0
HAS_COL_HAS_LYRICS=0
HAS_INDEX_CONTRACT=0
KEYSET_CHECKED_SQL_EXPR="COALESCE(last_checked_at,0)"
KEYSET_ARTIST_SQL_EXPR="COALESCE(artist_lc,'')"
KEYSET_ALBUM_SQL_EXPR="COALESCE(album_lc,'')"
CURSOR_FIRST_CHECKED=""
CURSOR_FIRST_ARTIST=""
CURSOR_FIRST_ALBUM=""
CURSOR_FIRST_YEAR=""
CURSOR_FIRST_ID=""
CURSOR_LAST_CHECKED=""
CURSOR_LAST_ARTIST=""
CURSOR_LAST_ALBUM=""
CURSOR_LAST_YEAR=""
CURSOR_LAST_ID=""
ROW_RAW_SEP=$'\x1f'
COUNT_CACHE_KEY=""
COUNT_CACHE_VALUE=""
COUNT_CACHE_VALID=0
COUNT_CACHE_GRADE_S=0
COUNT_CACHE_GRADE_A=0
COUNT_CACHE_GRADE_B=0
COUNT_CACHE_GRADE_C=0
COUNT_CACHE_GRADE_F=0
COUNT_CACHE_QUEUE=0
ALBUM_ANALYSIS_ID=""

FILTER_REPLACE_ONLY=0
FILTER_UPSCALED_ONLY=0
FILTER_MIXED_ONLY=0
FILTER_REPLACE_OR_UPSCALED=0
FILTER_RARITY_ONLY=0

TABLE_LABELS=("ARTIST" "YEAR" "ALBUM" "DR" "GRADE" "CODEC" "BITRATE" "PROFILE" "RECODE" "FAIL" "LAST CHECKED")
TABLE_WIDTHS=(20 6 24 6 5 8 9 9 22 10 18)
TABLE_SORT_KEYS=("artist" "year" "album" "dr" "grade" "codec" "" "curr" "" "fail" "checked")
TABLE_SELECT_SQL=(
  "artist"
  "CASE WHEN year_int=0 THEN '-' ELSE CAST(year_int AS TEXT) END"
  "album"
  "CASE WHEN dynamic_range_score IS NULL THEN '-' WHEN dynamic_range_score = CAST(dynamic_range_score AS INTEGER) THEN CAST(CAST(dynamic_range_score AS INTEGER) AS TEXT) ELSE printf('%.1f', dynamic_range_score) END"
  "COALESCE(quality_grade,'-')"
  "COALESCE(NULLIF(codec,''),'-')"
  "COALESCE(NULLIF(bitrate,''),'-')"
  "COALESCE(NULLIF(current_quality,''),'-')"
  "CASE WHEN COALESCE(scan_failed,0)=1 THEN COALESCE(NULLIF(notes,''),NULLIF(recode_recommendation,''),'-') ELSE COALESCE(NULLIF(recode_recommendation,''),'-') END"
  "CASE WHEN scan_failed=1 THEN 'Y' ELSE '-' END"
  "CASE WHEN last_checked_at IS NULL OR last_checked_at=0 THEN '-' ELSE strftime('%Y-%m-%d %H:%M', last_checked_at,'unixepoch','localtime') END"
)

if [[ -t 1 && -z "$NO_COLOR" ]]; then
  USE_COLOR=true
fi

show_help() {
  cat <<'EOF_HELP'
Quick use:
  audlint.sh
  audlint.sh --view grade
  audlint.sh --view replace
  audlint.sh --view replace-or-upscaled
  audlint.sh --view rarities
  audlint.sh --class c-f --sort grade --asc

Usage:
  audlint.sh [options]

Options:
  --view <name>              Preset: default|grade|replace|replace-or-upscaled|codecs|profiles|encodings|upscaled-replace|encode|scan-failed|rarities
  --class <all|s-b|c-f>      Filter by grade class (default: all)
  --sort <key>               Sort key: checked|score|dr|grade|artist|album|year|replace|fail|curr|codec (default: checked)
  --asc                      Sort ascending
  --desc                     Sort descending (default)
  --search <text>            Case-insensitive artist/album search (%...% fuzzy-like)
  --codec <name|all|unknown> Filter by one codec value (default: all)
  --profile <name|all|unknown> Filter by one profile value (default: all)
  --help-profiles             Show accepted profile filter forms and special values
  --page-size <n>            Rows per page (default: 15)
  --page <n>                 Start page (default: 1)
  --db <path>                Override AUDL_DB_PATH
  --album-id <id>            Print dedicated album analysis page for one row id and exit
  --interactive              Force interactive paging
  --no-interactive           Disable interactive paging
  --help                     Show this help

Interactive keys:
  0 = last checked (default)
  1 = year sort (newest first)
  2 = dynamic-range sort (DR high first)
  3 = grade sort (worst grade first)
  4 = codec inventory + choose single codec filter
  5 = profile inventory + choose single profile filter
      selector keys use 0-9 then a-z (10=a, 11=b, ...)
  6 = scan failed first
  e = show recode queue (needs_recode=Y)
  R = show rarities only
  f = FLAC recode + boost for selected row(s) (recode view only)
  l = lyrics seek + embed for selected row(s)
  i = inspect selected album (single row) in dedicated analysis page
  t = transfer selected albums to media player (when AUDL_MEDIA_PLAYER_PATH is writable)
  c = clear all filters/search/sort and reset to primary view
  r = mark rows as rarity (hidden from normal views)
  u = unmark rarity on selected rows
  x = delete rows from current page (1,7-9 syntax)
  a = sort ascending
  d = sort descending
  / = search artist/album (blank clears)
  n = next page
  p = previous page
  q = quit
EOF_HELP
}

show_help_profiles() {
  profile_print_help
  printf '\n'
  printf 'audlint profile filter values:\n'
  printf '  all      clear filter\n'
  printf '  unknown  match empty/unknown profile rows\n'
  printf '  <profile> fuzzy profile form (normalized to canonical before matching)\n'
}

resolve_library_db_path() {
  local raw="$1"
  if [[ -z "$raw" && -n "${AUDL_PATH:-}" ]]; then
    raw="$AUDL_PATH/library.sqlite"
  fi
  [[ -n "$raw" ]] || return 1
  env_expand_value "$raw"
}

detect_album_quality_columns() {
  local db="$1"
  local cols
  cols="$(sqlite3 -separator $'\t' -noheader "$db" "PRAGMA table_info(album_quality);" 2>/dev/null || true)"
  [[ -n "$cols" ]] || return 0
  local _cid _name
  while IFS=$'\t' read -r _cid _name _; do
    case "$_name" in
    artist_norm) HAS_COL_ARTIST_NORM=1 ;;
    album_norm) HAS_COL_ALBUM_NORM=1 ;;
    grade_rank) HAS_COL_GRADE_RANK=1 ;;
    checked_sort) HAS_COL_CHECKED_SORT=1 ;;
    codec_norm) HAS_COL_CODEC_NORM=1 ;;
    profile_norm) HAS_COL_PROFILE_NORM=1 ;;
    last_recoded_at) HAS_COL_LAST_RECODED_AT=1 ;;
    has_lyrics) HAS_COL_HAS_LYRICS=1 ;;
    esac
  done <<< "$cols"
}

refresh_sort_key_exprs() {
  if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_CHECKED_SORT" == "1" ]]; then
    KEYSET_CHECKED_SQL_EXPR="checked_sort"
  else
    KEYSET_CHECKED_SQL_EXPR="COALESCE(last_checked_at,0)"
  fi
  if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_ARTIST_NORM" == "1" ]]; then
    KEYSET_ARTIST_SQL_EXPR="artist_norm"
  else
    KEYSET_ARTIST_SQL_EXPR="COALESCE(artist_lc,'')"
  fi
  if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_ALBUM_NORM" == "1" ]]; then
    KEYSET_ALBUM_SQL_EXPR="album_norm"
  else
    KEYSET_ALBUM_SQL_EXPR="COALESCE(album_lc,'')"
  fi
}

codec_norm_expr_sql() {
  if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_CODEC_NORM" == "1" ]]; then
    printf 'codec_norm'
  else
    printf "LOWER(TRIM(COALESCE(codec,'')))"
  fi
}

profile_norm_expr_sql() {
  if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_PROFILE_NORM" == "1" ]]; then
    printf 'profile_norm'
  else
    printf "LOWER(TRIM(COALESCE(current_quality,'')))"
  fi
}

encode_lossy_exclusion_clause_sql() {
  local codec_expr
  codec_expr="$(codec_norm_expr_sql)"
  printf "(%s NOT IN ('mp2','mp3','aac','vorbis','opus','ac3','eac3','dca','dts','wma','wmav1','wmav2','wmavoice','amr_nb','amr_wb','gsm','g722','g723_1','g726','g729','qcelp','cook','ra_144','ra_288','atrac1','atrac3','atrac3al','atrac3p','speex','nellymoser','qdm2','alaw','mulaw') AND %s NOT LIKE 'adpcm_%%')" "$codec_expr" "$codec_expr"
}

encode_dts_replacement_clause_sql() {
  local codec_expr
  codec_expr="$(codec_norm_expr_sql)"
  printf "(COALESCE(needs_replacement,0)=1 AND %s IN ('dts','dca'))" "$codec_expr"
}

lower_text() {
  local raw="$1"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
}

upper_text() {
  local raw="$1"
  printf '%s' "$raw" | tr '[:lower:]' '[:upper:]'
}

title_case_words() {
  local raw="$1"
  raw="$(normalize_search_query "$raw")"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }
  local titled=""
  titled="$(
    printf '%s' "$raw" | awk '{
      for (i = 1; i <= NF; i++) {
        word = tolower($i)
        $i = toupper(substr(word,1,1)) substr(word,2)
      }
      print
    }'
  )"
  printf '%s' "$titled"
}

normalize_class_filter() {
  local raw="$1"
  raw="$(lower_text "$raw")"
  case "$raw" in
  all) printf 'all\n' ;;
  s-b | sb) printf 's-b\n' ;;
  c-f | cf) printf 'c-f\n' ;;
  *) return 1 ;;
  esac
}

normalize_sort_key() {
  local raw="$1"
  raw="$(lower_text "$raw")"
  case "$raw" in
  checked | last | last_checked | last_checked_at) printf 'checked\n' ;;
  score | quality_score) printf 'score\n' ;;
  dr | dynamic_range | dynamic-range | dynamicrange | dynamic_range_score) printf 'dr\n' ;;
  grade | quality_grade) printf 'grade\n' ;;
  artist | artist_lc) printf 'artist\n' ;;
  album | album_lc) printf 'album\n' ;;
  year | year_int) printf 'year\n' ;;
  replace | replacement | needs_replacement) printf 'replace\n' ;;
  fail | failed | scan_failed) printf 'fail\n' ;;
  curr | current | profile | current_quality) printf 'curr\n' ;;
  codec) printf 'codec\n' ;;
  *) return 1 ;;
  esac
}

normalize_view_key() {
  local raw="$1"
  raw="$(lower_text "$raw")"
  case "$raw" in
  default) printf 'default\n' ;;
  grade | grades | grade-first | grade_first) printf 'grade_first\n' ;;
  replace | replace_queue | queue | replace-or-upscaled | replace_or_upscaled) printf 'replace_queue\n' ;;
  codecs | codec | codec_inventory) printf 'codec_inventory\n' ;;
  encodings | encoding | encoding_inventory | profile | profiles) printf 'encoding_inventory\n' ;;
  upscaled-replace | upscaled_replace | upscaled | upscaledreplace) printf 'upscaled_replace\n' ;;
  encode | enc | encode_only | upscaled-only | upscaled_only) printf 'encode_only\n' ;;
  scan-failed | scan_failed | failed | mixed-first | mixed_first | mixed) printf 'scan_failed\n' ;;
  rarity | rarities | rarity-only | rarity_only) printf 'rarity_only\n' ;;
  *) return 1 ;;
  esac
}

normalize_search_query() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g')"
  printf '%s' "$raw"
}

normalize_codec_filter() {
  local raw="$1"
  raw="$(normalize_search_query "$raw")"
  raw="$(lower_text "$raw")"
  if [[ -z "$raw" || "$raw" == "all" ]]; then
    printf 'all\n'
    return 0
  fi
  if [[ "$raw" == "unknown" || "$raw" == "~unknown" ]]; then
    printf '~unknown\n'
    return 0
  fi
  printf '%s\n' "$raw"
}

normalize_profile_filter() {
  local raw="$1"
  local normalized=""
  raw="$(normalize_search_query "$raw")"
  raw="$(lower_text "$raw")"
  if [[ -z "$raw" || "$raw" == "all" ]]; then
    printf 'all\n'
    return 0
  fi
  if [[ "$raw" == "unknown" || "$raw" == "~unknown" ]]; then
    printf '~unknown\n'
    return 0
  fi
  normalized="$(profile_normalize "$raw" || true)"
  if [[ -n "$normalized" ]]; then
    printf '%s\n' "$(lower_text "$normalized")"
    return 0
  fi
  printf '%s\n' "$raw"
}

codec_filter_label() {
  case "$1" in
  all) printf 'all' ;;
  ~unknown) printf 'unknown' ;;
  *) printf '%s' "$1" ;;
  esac
}

profile_filter_label() {
  case "$1" in
  all) printf 'all' ;;
  ~unknown) printf 'unknown' ;;
  *) printf '%s' "$1" ;;
  esac
}

sql_eq_escape() {
  printf '%s' "$1" | sed -e "s/'/''/g"
}

term_cols_value() {
  local cols="${COLUMNS:-}"
  if [[ "$cols" =~ ^[0-9]+$ ]] && ((cols > 0)); then
    printf '%s' "$cols"
    return 0
  fi
  if command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || true)"
    if [[ "$cols" =~ ^[0-9]+$ ]] && ((cols > 0)); then
      printf '%s' "$cols"
      return 0
    fi
  fi
  printf '80'
}

term_lines_value() {
  local lines="${LINES:-}"
  if [[ "$lines" =~ ^[0-9]+$ ]] && ((lines > 0)); then
    printf '%s' "$lines"
    return 0
  fi
  if command -v tput >/dev/null 2>&1; then
    lines="$(tput lines 2>/dev/null || true)"
    if [[ "$lines" =~ ^[0-9]+$ ]] && ((lines > 0)); then
      printf '%s' "$lines"
      return 0
    fi
  fi
  printf '24'
}

screen_clear_safe() {
  local tty_fd=""
  tty_open_output_fd tty_fd || return 0
  printf '\033[H\033[2J\033[3J' 1>&"$tty_fd" 2>/dev/null || true
  tty_close_output_fd "$tty_fd"
}

screen_reset_terminal_safe() {
  local tty_fd=""
  tty_open_output_fd tty_fd || return 0
  printf '\r\033[0m\033[?25h\033[;r' 1>&"$tty_fd" 2>/dev/null || true
  tty_close_output_fd "$tty_fd"
}

audlint_terminal_exit_cleanup() {
  [[ "${AUDLINT_TERMINAL_CLEANUP_DONE:-0}" == "1" ]] && return 0
  AUDLINT_TERMINAL_CLEANUP_DONE=1
  tty_ensure_line_mode
  if [[ "${AUDLINT_TERMINAL_CLEANUP_ACTIVE:-0}" == "1" ]]; then
    screen_reset_terminal_safe
    screen_clear_safe
  fi
  return 0
}

audlint_signal_exit() {
  local exit_code="$1"
  audlint_terminal_exit_cleanup
  trap - EXIT INT TERM
  exit "$exit_code"
}

trap 'audlint_terminal_exit_cleanup' EXIT
trap 'audlint_signal_exit 130' INT
trap 'audlint_signal_exit 143' TERM

sql_like_escape() {
  printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/''/g" -e 's/%/\\%/g' -e 's/_/\\_/g'
}

search_clause_like_for_query() {
  local raw="$1"
  raw="$(normalize_search_query "$raw")"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }

  local lowered titled uppered
  local escaped_lc fuzzy_lc compact_lc
  local escaped_raw fuzzy_raw compact_raw
  local escaped_lower_raw fuzzy_lower_raw compact_lower_raw
  local escaped_titled_raw fuzzy_titled_raw compact_titled_raw
  local escaped_uppered_raw fuzzy_uppered_raw compact_uppered_raw
  lowered="$(lower_text "$raw")"
  titled="$(title_case_words "$lowered")"
  uppered="$(upper_text "$lowered")"
  escaped_lc="$(sql_like_escape "$lowered")"
  fuzzy_lc="%${escaped_lc// /%}%"
  compact_lc="$(printf '%s' "$escaped_lc" | tr -d ' ')"

  escaped_raw="$(sql_like_escape "$raw")"
  fuzzy_raw="%${escaped_raw// /%}%"
  compact_raw="$(printf '%s' "$escaped_raw" | tr -d ' ')"

  escaped_lower_raw="$(sql_like_escape "$lowered")"
  fuzzy_lower_raw="%${escaped_lower_raw// /%}%"
  compact_lower_raw="$(printf '%s' "$escaped_lower_raw" | tr -d ' ')"

  escaped_titled_raw="$(sql_like_escape "$titled")"
  fuzzy_titled_raw="%${escaped_titled_raw// /%}%"
  compact_titled_raw="$(printf '%s' "$escaped_titled_raw" | tr -d ' ')"

  escaped_uppered_raw="$(sql_like_escape "$uppered")"
  fuzzy_uppered_raw="%${escaped_uppered_raw// /%}%"
  compact_uppered_raw="$(printf '%s' "$escaped_uppered_raw" | tr -d ' ')"

  local haystack_lc haystack_raw artist_lc_expr album_lc_expr
  artist_lc_expr="COALESCE(artist_lc,'')"
  album_lc_expr="COALESCE(album_lc,'')"
  if [[ "$HAS_COL_ARTIST_NORM" == "1" ]]; then
    artist_lc_expr="COALESCE(NULLIF(artist_norm,''),COALESCE(artist_lc,''))"
  fi
  if [[ "$HAS_COL_ALBUM_NORM" == "1" ]]; then
    album_lc_expr="COALESCE(NULLIF(album_norm,''),COALESCE(album_lc,''))"
  fi
  haystack_lc="(${artist_lc_expr} || ' ' || ${album_lc_expr})"
  haystack_raw="(COALESCE(artist,'') || ' ' || COALESCE(album,''))"
  printf "((%s LIKE '%s' ESCAPE '\\\\' OR REPLACE(%s,' ','') LIKE '%%%s%%' ESCAPE '\\\\') OR (%s LIKE '%s' ESCAPE '\\\\' OR REPLACE(%s,' ','') LIKE '%%%s%%' ESCAPE '\\\\' OR %s LIKE '%s' ESCAPE '\\\\' OR REPLACE(%s,' ','') LIKE '%%%s%%' ESCAPE '\\\\' OR %s LIKE '%s' ESCAPE '\\\\' OR REPLACE(%s,' ','') LIKE '%%%s%%' ESCAPE '\\\\' OR %s LIKE '%s' ESCAPE '\\\\' OR REPLACE(%s,' ','') LIKE '%%%s%%' ESCAPE '\\\\'))" \
    "$haystack_lc" "$fuzzy_lc" "$haystack_lc" "$compact_lc" \
    "$haystack_raw" "$fuzzy_raw" "$haystack_raw" "$compact_raw" \
    "$haystack_raw" "$fuzzy_lower_raw" "$haystack_raw" "$compact_lower_raw" \
    "$haystack_raw" "$fuzzy_titled_raw" "$haystack_raw" "$compact_titled_raw" \
    "$haystack_raw" "$fuzzy_uppered_raw" "$haystack_raw" "$compact_uppered_raw"
}

search_fts5_query_for_input() {
  local raw="$1"
  raw="$(normalize_search_query "$raw")"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }

  local tokens=()
  local token
  local digit_buf=""
  for token in $raw; do
    [[ -n "$token" ]] || continue
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      digit_buf+="$token"
      continue
    fi
    if [[ -n "$digit_buf" ]]; then
      tokens+=("$digit_buf")
      digit_buf=""
    fi
    tokens+=("$token")
  done
  if [[ -n "$digit_buf" ]]; then
    tokens+=("$digit_buf")
  fi
  ((${#tokens[@]} > 0)) || {
    printf ''
    return 0
  }

  local terms=()
  local esc
  for token in "${tokens[@]}"; do
    esc="${token//\"/\"\"}"
    terms+=("\"${esc}\"*")
  done
  printf '%s' "$(IFS=' AND '; echo "${terms[*]}")"
}

search_clause_for_query() {
  local raw="$1"
  raw="$(normalize_search_query "$raw")"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }

  if [[ "$HAS_FTS_SEARCH" == "1" ]]; then
    local fts_query escaped_fts like_clause
    fts_query="$(search_fts5_query_for_input "$raw")"
    if [[ -n "$fts_query" ]]; then
      escaped_fts="$(sql_escape "$fts_query")"
      like_clause="$(search_clause_like_for_query "$raw")"
      printf "(id IN (SELECT rowid FROM album_quality_fts WHERE album_quality_fts MATCH '%s') OR (NOT EXISTS (SELECT 1 FROM album_quality_fts WHERE album_quality_fts MATCH '%s' LIMIT 1) AND (%s)))" "$escaped_fts" "$escaped_fts" "$like_clause"
      return 0
    fi
  fi

  search_clause_like_for_query "$raw"
}

browser_dash_space_compact_expr_sql() {
  local expr="$1"
  printf "REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(%s,' ',''),'-',''),char(8208),''),char(8209),''),char(8210),''),char(8211),''),char(8212),''),char(8213),'')" "$expr"
}

browser_artist_group_expr_sql() {
  local ref="${1:-aq}"
  local base_expr
  if [[ "$HAS_COL_ARTIST_NORM" == "1" ]]; then
    base_expr="COALESCE(NULLIF(${ref}.artist_norm,''),NULLIF(${ref}.artist_lc,''),LOWER(TRIM(COALESCE(${ref}.artist,''))), '')"
  else
    base_expr="COALESCE(NULLIF(${ref}.artist_lc,''),LOWER(TRIM(COALESCE(${ref}.artist,''))), '')"
  fi
  browser_dash_space_compact_expr_sql "$base_expr"
}

browser_album_group_expr_sql() {
  local ref="${1:-aq}"
  if [[ "$HAS_COL_ALBUM_NORM" == "1" ]]; then
    printf "COALESCE(NULLIF(%s.album_norm,''),NULLIF(%s.album_lc,''),LOWER(TRIM(COALESCE(%s.album,''))), '')" "$ref" "$ref" "$ref"
  else
    printf "COALESCE(NULLIF(%s.album_lc,''),LOWER(TRIM(COALESCE(%s.album,''))), '')" "$ref" "$ref"
  fi
}

browser_artist_hyphen_pref_expr_sql() {
  local ref="${1:-aq}"
  local artist_expr
  artist_expr="COALESCE(${ref}.artist,'')"
  printf "CASE WHEN INSTR(%s,'-')>0 OR INSTR(%s,char(8208))>0 OR INSTR(%s,char(8209))>0 OR INSTR(%s,char(8210))>0 OR INSTR(%s,char(8211))>0 OR INSTR(%s,char(8212))>0 OR INSTR(%s,char(8213))>0 THEN 0 ELSE 1 END" \
    "$artist_expr" "$artist_expr" "$artist_expr" "$artist_expr" "$artist_expr" "$artist_expr" "$artist_expr"
}

browser_checked_sort_expr_sql() {
  local ref="${1:-aq}"
  if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_CHECKED_SORT" == "1" ]]; then
    printf "COALESCE(%s.checked_sort,COALESCE(%s.last_checked_at,0))" "$ref" "$ref"
  else
    printf "COALESCE(%s.last_checked_at,0)" "$ref"
  fi
}

browser_search_dedupe_clause_sql() {
  local include_codec_filter="${1:-yes}"
  local include_profile_filter="${2:-yes}"
  local normalized_query inner_where
  normalized_query="$(normalize_search_query "$SEARCH_QUERY")"
  [[ -n "$normalized_query" ]] || {
    printf ''
    return 0
  }

  inner_where="$(build_where_sql "$include_codec_filter" "$include_profile_filter" "no")"
  [[ -n "$inner_where" ]] || inner_where="WHERE 1=1"

  printf "aq.id = (SELECT dedupe.id FROM album_quality AS dedupe %s AND %s=%s AND %s=%s AND COALESCE(dedupe.year_int,0)=COALESCE(aq.year_int,0) ORDER BY %s ASC, %s DESC, dedupe.id DESC LIMIT 1)" \
    "$inner_where" \
    "$(browser_artist_group_expr_sql "dedupe")" "$(browser_artist_group_expr_sql "aq")" \
    "$(browser_album_group_expr_sql "dedupe")" "$(browser_album_group_expr_sql "aq")" \
    "$(browser_artist_hyphen_pref_expr_sql "dedupe")" \
    "$(browser_checked_sort_expr_sql "dedupe")"
}

style_sorted_cell() {
  local value="$1"
  local esc
  esc="$(rich_escape "$value")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[bold cyan]%s[/]' "$esc"
}

build_table_headers() {
  local labels=("${TABLE_LABELS[@]}")
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$(IFS=,; echo "${labels[*]}")"
    return
  fi

  local gradient=("#ff8c00" "#ff9800" "#ffa500" "#ffb300" "#ffc107" "#ffca28" "#ffd54f" "#ffe082" "#ffecb3" "#fff1c2" "#fff7d6" "#fffbe3")
  local sort_label styled=()
  sort_label="$(sort_header_label_for_key "$SORT_KEY" || true)"

  local idx label style
  for idx in "${!labels[@]}"; do
    label="${labels[$idx]}"
    if [[ -n "$sort_label" && "$label" == "$sort_label" ]]; then
      style="[bold #4da3ff]${label}[/]"
    else
      style="[bold ${gradient[$idx]}]${label}[/]"
    fi
    styled+=("$style")
  done

  printf '%s' "$(IFS=,; echo "${styled[*]}")"
}

print_status_line() {
  local view="$1"
  local class="$2"
  local sort_key="$3"
  local sort_dir="$4"
  local page="$5"
  local total_pages="$6"
  local total_rows="$7"
  local queue_rows="$8"
  local next_run="$9"
  local db_status="${10}"
  local grade_stats="${11:-}"
  local lhs_plain rhs_plain
  lhs_plain="Audlint-CLI"
  rhs_plain="$(printf 'page=%s/%s | total=%s | pending=%s | next_run=%s' "$page" "$total_pages" "$total_rows" "$queue_rows" "$next_run")"
  if [[ -n "$db_status" ]]; then
    rhs_plain="$rhs_plain | [$db_status]"
  fi
  if [[ -n "$grade_stats" && "$AUDL_HIDE_SUPPORT_GREETER" != "1" ]]; then
    rhs_plain="$rhs_plain >>> Grade Stats: $grade_stats >>> Slava Ukraini!"
  elif [[ -n "$grade_stats" ]]; then
    rhs_plain="$rhs_plain >>> Grade Stats: $grade_stats"
  fi

  if [[ "$USE_COLOR" != true ]]; then
    printf '%s | %s\n' "$lhs_plain" "$rhs_plain"
    return
  fi

  local seg1 seg3 seg4 seg5 seg6 seg7 seg8_sep seg8_stats seg8_salute_sep seg8_salute_a seg8_salute_b rhs_color
  seg1="$(color_text_hex "#ff8c00" "$lhs_plain" bold)"
  seg3="$(color_text_hex "#ffc24a" "page=$page/$total_pages" bold)"
  seg4="$(color_text_hex "#ffd46b" "total=$total_rows" bold)"
  seg5="$(color_text_hex "#ffe18b" "pending=$queue_rows" bold)"
  seg6="$(color_text_hex "#fff0b3" "next_run=$next_run" bold)"
  seg7=""
  seg8_sep=""
  seg8_stats=""
  seg8_salute_sep=""
  seg8_salute_a=""
  seg8_salute_b=""
  if [[ -n "$db_status" ]]; then
    seg7="$(color_text_hex "#ff5252" "[$db_status]" bold)"
  fi
  if [[ -n "$grade_stats" ]]; then
    seg8_sep="$(color_text_hex "#4da3ff" ">>>" bold)"
    seg8_stats="$(color_text_hex "#8f959e" " Grade Stats: $grade_stats")"
    if [[ "$AUDL_HIDE_SUPPORT_GREETER" != "1" ]]; then
      seg8_salute_sep="$(color_text_hex "#ff8c00" " >>>" bold)"
      seg8_salute_a="$(color_text_hex "#4da3ff" " Slava" bold)"
      seg8_salute_b="$(color_text_hex "#ffd46b" " Ukraini!" bold)"
    fi
  fi
  rhs_color="$(printf '%b | %b | %b | %b' "$seg3" "$seg4" "$seg5" "$seg6")"
  if [[ -n "$seg7" ]]; then
    rhs_color="$(printf '%b | %b' "$rhs_color" "$seg7")"
  fi
  if [[ -n "$seg8_sep" ]]; then
    rhs_color="$(printf '%b %b%b%b%b%b' "$rhs_color" "$seg8_sep" "$seg8_stats" "$seg8_salute_sep" "$seg8_salute_a" "$seg8_salute_b")"
  fi
  printf '%b | %b\n' "$seg1" "$rhs_color"
}

print_filter_status_line() {
  local codec_label="$1"
  local profile_label="$2"
  local sort_dir_label="$3"
  local search_label="$4"
  local line_text
  line_text="$(printf 'codec filter: %s | profile filter: %s | sort: %s | search: %s' "$codec_label" "$profile_label" "$sort_dir_label" "$search_label")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s\n' "$line_text"
    return
  fi
  printf '%b\n' "$(color_text_hex "#c8ffb0" "$line_text")"
}

sort_header_label_for_key() {
  local key="$1"
  local idx
  for idx in "${!TABLE_SORT_KEYS[@]}"; do
    if [[ "${TABLE_SORT_KEYS[$idx]}" == "$key" ]]; then
      printf '%s' "${TABLE_LABELS[$idx]}"
      return 0
    fi
  done
  case "$key" in
  score | replace) printf '' ;;
  *) return 1 ;;
  esac
}

sort_column_index_for_key() {
  local key="$1"
  local idx
  for idx in "${!TABLE_SORT_KEYS[@]}"; do
    if [[ "${TABLE_SORT_KEYS[$idx]}" == "$key" ]]; then
      printf '%s' "$idx"
      return 0
    fi
  done
  return 1
}

table_widths_csv() {
  local include_row="${1:-no}"
  local joined
  joined="$(IFS=,; echo "${TABLE_WIDTHS[*]}")"
  if [[ "$include_row" == "yes" ]]; then
    printf '4,%s' "$joined"
    return
  fi
  printf '%s' "$joined"
}

table_select_sql_block() {
  local idx
  local album_select_sql
  local recode_marker_sql="''"
  local lyrics_marker_sql="''"
  album_select_sql="album"
  # notes may contain Rich markup-special characters (e.g. "[mjpeg @ ...]").
  # Escape [ → \[ when rendering with color so Rich doesn't swallow them.
  local notes_sql="notes"
  if [[ "$USE_COLOR" == true ]]; then
    notes_sql="replace(notes,'[','\[')"
  fi
  local recode_col_sql="CASE WHEN COALESCE(scan_failed,0)=1 THEN COALESCE(NULLIF(${notes_sql},''),NULLIF(recode_recommendation,''),'-') ELSE COALESCE(NULLIF(recode_recommendation,''),'-') END"

  if [[ "$HAS_COL_LAST_RECODED_AT" == "1" ]]; then
    if [[ "$USE_COLOR" == true ]]; then
      recode_marker_sql="CASE WHEN COALESCE(last_recoded_at,0)>0 THEN '[green]*[/]' ELSE '' END"
    else
      recode_marker_sql="CASE WHEN COALESCE(last_recoded_at,0)>0 THEN '*' ELSE '' END"
    fi
  fi
  if [[ "$HAS_COL_HAS_LYRICS" == "1" ]]; then
    if [[ "$USE_COLOR" == true ]]; then
      lyrics_marker_sql="CASE WHEN COALESCE(has_lyrics,0)>0 THEN '[#ff69b4]*[/]' ELSE '' END"
    else
      lyrics_marker_sql="CASE WHEN COALESCE(has_lyrics,0)>0 THEN '*' ELSE '' END"
    fi
  fi

  if [[ "$HAS_COL_LAST_RECODED_AT" == "1" || "$HAS_COL_HAS_LYRICS" == "1" ]]; then
    album_select_sql="album || $recode_marker_sql || $lyrics_marker_sql"
  fi
  for idx in "${!TABLE_SELECT_SQL[@]}"; do
    local select_sql="${TABLE_SELECT_SQL[$idx]}"
    if ((idx == 2)); then
      select_sql="$album_select_sql"
    fi
    if ((idx == 8)); then
      select_sql="$recode_col_sql"
    fi
    if ((idx == 0)); then
      printf '         %s' "$select_sql"
    else
      printf ',\n         %s' "$select_sql"
    fi
  done
}

reverse_sort_dir() {
  if [[ "$1" == "ASC" ]]; then
    printf 'DESC'
  else
    printf 'ASC'
  fi
}

keyset_checked_enabled_for_state() {
  if [[ "$KEYSET_ENABLED" != "1" ]]; then
    return 1
  fi
  if [[ "$SORT_KEY" != "checked" ]]; then
    return 1
  fi
  return 0
}

build_checked_seek_condition() {
  local direction="$1"
  local checked_raw="$2"
  local artist_raw="$3"
  local album_raw="$4"
  local year_raw="$5"
  local id_raw="$6"
  local sort_dir_sql="$7"
  local artist_tie_dir_sql="$8"

  local checked_sql year_sql id_sql
  checked_sql="$(sql_num_or_null "$checked_raw")"
  [[ "$checked_sql" == "NULL" ]] && checked_sql=0
  year_sql="$(sql_num_or_null "$year_raw")"
  [[ "$year_sql" == "NULL" ]] && year_sql=0
  id_sql="$(sql_num_or_null "$id_raw")"
  [[ "$id_sql" == "NULL" ]] && id_sql=0

  local artist_esc album_esc
  artist_esc="$(sql_escape "$artist_raw")"
  album_esc="$(sql_escape "$album_raw")"

  local op_main op_artist op_album op_year op_id
  if [[ "$direction" == "next" ]]; then
    if [[ "$sort_dir_sql" == "DESC" ]]; then
      op_main="<"
    else
      op_main=">"
    fi
    if [[ "$artist_tie_dir_sql" == "ASC" ]]; then
      op_artist=">"
    else
      op_artist="<"
    fi
    op_album=">"
    op_year=">"
    op_id=">"
  else
    if [[ "$sort_dir_sql" == "DESC" ]]; then
      op_main=">"
    else
      op_main="<"
    fi
    if [[ "$artist_tie_dir_sql" == "ASC" ]]; then
      op_artist="<"
    else
      op_artist=">"
    fi
    op_album="<"
    op_year="<"
    op_id="<"
  fi

  printf "((%s %s %s) OR (%s=%s AND %s %s '%s') OR (%s=%s AND %s='%s' AND %s %s '%s') OR (%s=%s AND %s='%s' AND %s='%s' AND year_int %s %s) OR (%s=%s AND %s='%s' AND %s='%s' AND year_int=%s AND id %s %s))" \
    "$KEYSET_CHECKED_SQL_EXPR" "$op_main" "$checked_sql" \
    "$KEYSET_CHECKED_SQL_EXPR" "$checked_sql" "$KEYSET_ARTIST_SQL_EXPR" "$op_artist" "$artist_esc" \
    "$KEYSET_CHECKED_SQL_EXPR" "$checked_sql" "$KEYSET_ARTIST_SQL_EXPR" "$artist_esc" "$KEYSET_ALBUM_SQL_EXPR" "$op_album" "$album_esc" \
    "$KEYSET_CHECKED_SQL_EXPR" "$checked_sql" "$KEYSET_ARTIST_SQL_EXPR" "$artist_esc" "$KEYSET_ALBUM_SQL_EXPR" "$album_esc" "$op_year" "$year_sql" \
    "$KEYSET_CHECKED_SQL_EXPR" "$checked_sql" "$KEYSET_ARTIST_SQL_EXPR" "$artist_esc" "$KEYSET_ALBUM_SQL_EXPR" "$album_esc" "$year_sql" "$op_id" "$id_sql"
}

fetch_rows_raw() {
  local where_sql="$1"
  local order_sql="$2"
  local limit_sql="$3"
  local row_select_sql
  local keyset_checked_transport_sql
  local keyset_artist_transport_sql
  local keyset_album_transport_sql
  row_select_sql="$(table_select_sql_block)"
  keyset_checked_transport_sql="COALESCE(${KEYSET_CHECKED_SQL_EXPR},0)"
  keyset_artist_transport_sql="COALESCE(${KEYSET_ARTIST_SQL_EXPR},'')"
  keyset_album_transport_sql="COALESCE(${KEYSET_ALBUM_SQL_EXPR},'')"
  sqlite3 -separator "$ROW_RAW_SEP" -noheader "$DB_PATH" \
    "SELECT
${row_select_sql},
         ${keyset_checked_transport_sql},
         ${keyset_artist_transport_sql},
         ${keyset_album_transport_sql},
         COALESCE(year_int,0),
         id,
         COALESCE(needs_recode,0),
         COALESCE(album,''),
         COALESCE(source_path,'')
       FROM album_quality AS aq
       $where_sql
       $order_sql
       $limit_sql;" 2>/dev/null || true
}

reverse_lines() {
  local raw="$1"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }
  local lines=()
  local line i
  while IFS= read -r line; do
    lines+=("$line")
  done <<< "$raw"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    printf '%s\n' "${lines[$i]}"
  done
}

parse_rows_raw() {
  local raw="$1"
  local out=()
  local c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 c18
  CURSOR_FIRST_CHECKED=""
  CURSOR_FIRST_ARTIST=""
  CURSOR_FIRST_ALBUM=""
  CURSOR_FIRST_YEAR=""
  CURSOR_FIRST_ID=""
  CURSOR_LAST_CHECKED=""
  CURSOR_LAST_ARTIST=""
  CURSOR_LAST_ALBUM=""
  CURSOR_LAST_YEAR=""
  CURSOR_LAST_ID=""
  local seen_first=0

  while IFS="$ROW_RAW_SEP" read -r c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 c18; do
    [[ -n "$c0$c1$c2$c3$c4$c5$c6$c7$c8$c9$c10$c11$c12$c13$c14$c15$c16$c17$c18" ]] || continue
    out+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$c0" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")")
    if ((seen_first == 0)); then
      CURSOR_FIRST_CHECKED="$c11"
      CURSOR_FIRST_ARTIST="$c12"
      CURSOR_FIRST_ALBUM="$c13"
      CURSOR_FIRST_YEAR="$c14"
      CURSOR_FIRST_ID="$c15"
      seen_first=1
    fi
    CURSOR_LAST_CHECKED="$c11"
    CURSOR_LAST_ARTIST="$c12"
    CURSOR_LAST_ALBUM="$c13"
    CURSOR_LAST_YEAR="$c14"
    CURSOR_LAST_ID="$c15"
  done <<< "$raw"

  if ((${#out[@]} == 0)); then
    printf ''
    return 0
  fi
  printf '%s\n' "${out[@]}"
}

decorate_rows_for_sort_column() {
  local rows="$1"
  local sort_key="$2"
  local col_idx
  col_idx="$(sort_column_index_for_key "$sort_key" || true)"
  if [[ "$USE_COLOR" != true || -z "$rows" || -z "$col_idx" ]]; then
    printf '%s' "$rows"
    return
  fi

  local out=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local cols=()
    IFS=$'\t' read -r -a cols <<< "$line"
    if ((col_idx < ${#cols[@]})); then
      cols[$col_idx]="$(style_sorted_cell "${cols[$col_idx]}")"
    fi
    out+=("$(IFS=$'\t'; echo "${cols[*]}")")
  done <<< "$rows"

  ((${#out[@]} > 0)) || {
    printf ''
    return 0
  }
  printf '%s\n' "${out[@]}"
}

grade_rank_expr() {
  printf "CASE quality_grade WHEN 'F' THEN 1 WHEN 'C' THEN 2 WHEN 'B' THEN 3 WHEN 'A' THEN 4 WHEN 'S' THEN 5 ELSE 6 END"
}

sort_expr_for_key() {
  case "$1" in
  checked)
    if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_CHECKED_SORT" == "1" ]]; then
      printf 'checked_sort'
    else
      printf 'COALESCE(last_checked_at,0)'
    fi
    ;;
  score) printf 'COALESCE(dynamic_range_score,9999)' ;;
  dr) printf 'COALESCE(dynamic_range_score,-9999)' ;;
  grade)
    if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_GRADE_RANK" == "1" ]]; then
      printf 'grade_rank'
    else
      grade_rank_expr
    fi
    ;;
  artist)
    if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_ARTIST_NORM" == "1" ]]; then
      printf 'artist_norm'
    else
      printf "COALESCE(artist_lc,'')"
    fi
    ;;
  album)
    if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_ALBUM_NORM" == "1" ]]; then
      printf 'album_norm'
    else
      printf "COALESCE(album_lc,'')"
    fi
    ;;
  year) printf 'COALESCE(year_int,0)' ;;
  replace) printf 'COALESCE(needs_replacement,0)' ;;
  fail) printf 'COALESCE(scan_failed,0)' ;;
  curr)
    local curr_raw curr_sr curr_bit curr_sr_num curr_bit_num
    curr_raw="COALESCE(current_quality,'')"
    curr_sr="TRIM(CASE WHEN INSTR($curr_raw,'/')>0 THEN SUBSTR($curr_raw,1,INSTR($curr_raw,'/')-1) ELSE '' END)"
    curr_bit="LOWER(TRIM(CASE WHEN INSTR($curr_raw,'/')>0 THEN SUBSTR($curr_raw,INSTR($curr_raw,'/')+1) ELSE '' END))"
    curr_sr_num="CASE WHEN $curr_sr GLOB '[0-9]*' OR $curr_sr GLOB '[0-9]*.[0-9]*' THEN CAST($curr_sr AS REAL) ELSE 0 END"
    curr_bit_num="CASE WHEN $curr_bit='64f' THEN 640 WHEN $curr_bit='32f' THEN 320 WHEN $curr_bit GLOB '[0-9][0-9]*' THEN CAST($curr_bit AS INTEGER)*10 ELSE 0 END"
    printf '((%s) * 1000.0 + (%s))' "$curr_bit_num" "$curr_sr_num"
    ;;
  codec)
    if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_CODEC_NORM" == "1" ]]; then
      printf 'codec_norm'
    else
      printf "COALESCE(NULLIF(codec,''),'~unknown')"
    fi
    ;;
  *) return 1 ;;
  esac
}

sort_tie_break_for_key() {
  case "$1" in
  grade)
    printf ', COALESCE(dynamic_range_score,9999) ASC'
    ;;
  replace)
    printf ', %s ASC, COALESCE(dynamic_range_score,9999) ASC' "$(grade_rank_expr)"
    ;;
  fail)
    printf ', %s ASC, COALESCE(dynamic_range_score,9999) ASC' "$(grade_rank_expr)"
    ;;
  *)
    printf ''
    ;;
  esac
}

class_clause_for_value() {
  case "$1" in
  all) printf '' ;;
  s-b) printf "quality_grade IN ('S','A','B')" ;;
  c-f) printf "quality_grade IN ('C','F')" ;;
  *) return 1 ;;
  esac
}

build_where_sql() {
  local include_codec_filter="${1:-yes}"
  local include_profile_filter="${2:-yes}"
  local include_search_dedupe="${3:-yes}"
  local clauses=()
  local class_clause=""
  class_clause="$(class_clause_for_value "$CLASS_FILTER" || true)"
  if [[ -n "$class_clause" ]]; then
    clauses+=("$class_clause")
  fi
  if [[ "$FILTER_RARITY_ONLY" == "1" ]]; then
    clauses+=("rarity=1")
  else
    clauses+=("rarity=0")
  fi
  if [[ "$FILTER_REPLACE_OR_UPSCALED" == "1" ]]; then
    clauses+=("(needs_replacement=1 OR needs_recode=1)")
  else
    if [[ "$FILTER_REPLACE_ONLY" == "1" ]]; then
      clauses+=("needs_replacement=1")
    fi
    if [[ "$FILTER_UPSCALED_ONLY" == "1" ]]; then
      if [[ "$ACTIVE_VIEW" == "encode_only" ]]; then
        clauses+=("(needs_recode=1 OR $(encode_dts_replacement_clause_sql))")
      else
        clauses+=("needs_recode=1")
      fi
    fi
  fi
  if [[ "$FILTER_MIXED_ONLY" == "1" ]]; then
    clauses+=("scan_failed=1")
  fi
  if [[ "$ACTIVE_VIEW" == "encode_only" && "$HAS_COL_LAST_RECODED_AT" == "1" ]]; then
    clauses+=("(last_recoded_at IS NULL OR last_recoded_at=0)")
  fi
  if [[ "$ACTIVE_VIEW" == "encode_only" ]]; then
    clauses+=("scan_failed=0")
    clauses+=("(($(encode_lossy_exclusion_clause_sql)) OR ($(encode_dts_replacement_clause_sql)))")
  fi
  local search_clause=""
  search_clause="$(search_clause_for_query "$SEARCH_QUERY")"
  if [[ -n "$search_clause" ]]; then
    clauses+=("$search_clause")
  fi
  if [[ "$include_codec_filter" == "yes" && "$CODEC_FILTER" != "all" ]]; then
    if [[ "$CODEC_FILTER" == "~unknown" ]]; then
      if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_CODEC_NORM" == "1" ]]; then
        clauses+=("codec_norm=''")
      else
        clauses+=("NULLIF(TRIM(COALESCE(codec,'')),'') IS NULL")
      fi
    else
      local escaped_codec
      escaped_codec="$(sql_eq_escape "$CODEC_FILTER")"
      if [[ "$HAS_COL_CODEC_NORM" == "1" ]]; then
        clauses+=("codec_norm='$escaped_codec'")
      else
        clauses+=("LOWER(TRIM(COALESCE(codec,'')))='$escaped_codec'")
      fi
    fi
  fi
  if [[ "$include_profile_filter" == "yes" && "$PROFILE_FILTER" != "all" ]]; then
    if [[ "$PROFILE_FILTER" == "~unknown" ]]; then
      if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_PROFILE_NORM" == "1" ]]; then
        clauses+=("profile_norm=''")
      else
        clauses+=("NULLIF(TRIM(COALESCE(current_quality,'')),'') IS NULL")
      fi
    else
      local escaped_profile
      escaped_profile="$(sql_eq_escape "$PROFILE_FILTER")"
      if [[ "$HAS_COL_PROFILE_NORM" == "1" ]]; then
        clauses+=("profile_norm='$escaped_profile'")
      else
        clauses+=("LOWER(TRIM(COALESCE(current_quality,'')))='$escaped_profile'")
      fi
    fi
  fi
  if [[ "$include_search_dedupe" == "yes" ]]; then
    local search_dedupe_clause=""
    search_dedupe_clause="$(browser_search_dedupe_clause_sql "$include_codec_filter" "$include_profile_filter")"
    if [[ -n "$search_dedupe_clause" ]]; then
      clauses+=("$search_dedupe_clause")
    fi
  fi

  if ((${#clauses[@]} == 0)); then
    printf ''
    return 0
  fi

  local where_sql="WHERE"
  local clause
  for clause in "${clauses[@]}"; do
    if [[ "$where_sql" == "WHERE" ]]; then
      where_sql+=" $clause"
    else
      where_sql+=" AND $clause"
    fi
  done
  printf '%s' "$where_sql"
}

view_title_for_key() {
  case "$1" in
  default) printf 'default' ;;
  grade_first) printf 'grades' ;;
  replace_queue) printf 'replace-or-upscaled' ;;
  codec_inventory) printf 'codecs' ;;
  encoding_inventory) printf 'profiles' ;;
  upscaled_replace) printf 'upscaled+replace' ;;
  encode_only) printf 'encode' ;;
  scan_failed) printf 'scan-failed' ;;
  rarity_only) printf 'rarities' ;;
  custom) printf 'custom' ;;
  *) printf '%s' "$1" ;;
  esac
}

apply_view_preset() {
  local view="$1"
  case "$view" in
  default)
    ACTIVE_VIEW="default"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=0
    FILTER_MIXED_ONLY=0
    FILTER_REPLACE_OR_UPSCALED=0
    FILTER_RARITY_ONLY=0
    CODEC_FILTER="all"
    PROFILE_FILTER="all"
    CLASS_FILTER="all"
    SORT_KEY="checked"
    SORT_DIR="desc"
    ;;
  grade_first)
    ACTIVE_VIEW="grade_first"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=0
    FILTER_MIXED_ONLY=0
    FILTER_REPLACE_OR_UPSCALED=0
    FILTER_RARITY_ONLY=0
    CLASS_FILTER="all"
    SORT_KEY="grade"
    SORT_DIR="asc"
    ;;
  replace_queue)
    ACTIVE_VIEW="replace_queue"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=0
    FILTER_MIXED_ONLY=0
    FILTER_REPLACE_OR_UPSCALED=1
    FILTER_RARITY_ONLY=0
    CLASS_FILTER="all"
    SORT_KEY="grade"
    SORT_DIR="asc"
    ;;
  codec_inventory)
    ACTIVE_VIEW="codec_inventory"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=0
    FILTER_MIXED_ONLY=0
    FILTER_REPLACE_OR_UPSCALED=0
    FILTER_RARITY_ONLY=0
    CLASS_FILTER="all"
    SORT_KEY="codec"
    SORT_DIR="asc"
    ;;
  encoding_inventory)
    ACTIVE_VIEW="encoding_inventory"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=0
    FILTER_MIXED_ONLY=0
    FILTER_REPLACE_OR_UPSCALED=0
    FILTER_RARITY_ONLY=0
    CLASS_FILTER="all"
    SORT_KEY="curr"
    SORT_DIR="desc"
    ;;
  upscaled_replace)
    apply_view_preset replace_queue
    ;;
  encode_only)
    ACTIVE_VIEW="encode_only"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=1
    FILTER_MIXED_ONLY=0
    FILTER_REPLACE_OR_UPSCALED=0
    FILTER_RARITY_ONLY=0
    CLASS_FILTER="all"
    SORT_KEY="checked"
    SORT_DIR="desc"
    ;;
  scan_failed)
    ACTIVE_VIEW="scan_failed"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=0
    FILTER_MIXED_ONLY=1
    FILTER_REPLACE_OR_UPSCALED=0
    FILTER_RARITY_ONLY=0
    CLASS_FILTER="all"
    SORT_KEY="checked"
    SORT_DIR="desc"
    ;;
  rarity_only)
    ACTIVE_VIEW="rarity_only"
    FILTER_REPLACE_ONLY=0
    FILTER_UPSCALED_ONLY=0
    FILTER_MIXED_ONLY=0
    FILTER_REPLACE_OR_UPSCALED=0
    FILTER_RARITY_ONLY=1
    CLASS_FILTER="all"
    SORT_KEY="checked"
    SORT_DIR="desc"
    ;;
  *)
    return 1
    ;;
  esac
}

reset_primary_state() {
  apply_view_preset default
  SEARCH_QUERY=""
  PAGE=1
  ROW_ACTION_MODE=""
  ACTION_MESSAGE=""
}

count_cache_key_for_state() {
  local key
  key="$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$CLASS_FILTER" \
    "$FILTER_RARITY_ONLY" \
    "$FILTER_REPLACE_ONLY" \
    "$FILTER_UPSCALED_ONLY" \
    "$FILTER_MIXED_ONLY" \
    "$FILTER_REPLACE_OR_UPSCALED" \
    "$CODEC_FILTER" \
    "$PROFILE_FILTER" \
    "$SEARCH_QUERY" \
    "$HAS_FTS_SEARCH" \
    "$DB_PATH")"
  printf '%s' "$key"
}

invalidate_count_cache() {
  COUNT_CACHE_KEY=""
  COUNT_CACHE_VALUE=""
  COUNT_CACHE_VALID=0
  COUNT_CACHE_GRADE_S=0
  COUNT_CACHE_GRADE_A=0
  COUNT_CACHE_GRADE_B=0
  COUNT_CACHE_GRADE_C=0
  COUNT_CACHE_GRADE_F=0
  COUNT_CACHE_QUEUE=0
}

grade_pct_int() {
  local count="${1:-0}"
  local total="${2:-0}"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  if ((total <= 0)); then
    printf '0'
    return 0
  fi
  printf '%s' $(((count * 100 + total / 2) / total))
}

format_grade_stats_plain() {
  local total="$1"
  local s_cnt="$2"
  local a_cnt="$3"
  local b_cnt="$4"
  local c_cnt="$5"
  local f_cnt="$6"
  local s_pct a_pct b_pct c_pct f_pct
  s_pct="$(grade_pct_int "$s_cnt" "$total")"
  a_pct="$(grade_pct_int "$a_cnt" "$total")"
  b_pct="$(grade_pct_int "$b_cnt" "$total")"
  c_pct="$(grade_pct_int "$c_cnt" "$total")"
  f_pct="$(grade_pct_int "$f_cnt" "$total")"
  printf '[S %s%%] [A %s%%] [B %s%%] [C %s%%] [F %s%%]' \
    "$s_pct" "$a_pct" "$b_pct" "$c_pct" "$f_pct"
}

read_crontab_raw() {
  crontab -l 2>/dev/null || true
}

managed_cron_schedule() {
  command -v crontab >/dev/null 2>&1 || return 1
  local current schedule
  current="$(read_crontab_raw)"
  schedule="$(
    awk -v begin="$CRON_BLOCK_BEGIN" -v end="$CRON_BLOCK_END" '
      $0 == begin { in_block=1; next }
      $0 == end { in_block=0; next }
      in_block == 1 && $0 !~ /^[[:space:]]*#/ && NF >= 5 {
        print $1 " " $2 " " $3 " " $4 " " $5
        exit
      }
    ' <<< "$current"
  )"
  [[ -n "$schedule" ]] || return 1
  printf '%s' "$schedule"
}

cron_next_run_hhmm() {
  local schedule="$1"
  local minute hour day_of_month month day_of_week
  read -r minute hour day_of_month month day_of_week <<< "$schedule"
  if [[ "$day_of_month $month $day_of_week" != "* * *" ]]; then
    return 1
  fi

  local now_hour_raw now_min_raw
  now_hour_raw="$(date +%H 2>/dev/null || true)"
  now_min_raw="$(date +%M 2>/dev/null || true)"
  if [[ ! "$now_hour_raw" =~ ^[0-9]{2}$ || ! "$now_min_raw" =~ ^[0-9]{2}$ ]]; then
    return 1
  fi
  local now_hour now_min
  now_hour=$((10#$now_hour_raw))
  now_min=$((10#$now_min_raw))

  if [[ "$minute" =~ ^\*/([0-9]+)$ && "$hour" == "*" ]]; then
    local step_min next_min next_hour
    step_min="${BASH_REMATCH[1]}"
    if ((step_min < 1 || step_min > 59)); then
      return 1
    fi
    next_min=$((((now_min / step_min) + 1) * step_min))
    next_hour=$now_hour
    if ((next_min >= 60)); then
      next_min=0
      next_hour=$(((next_hour + 1) % 24))
    fi
    printf '%02d:%02d' "$next_hour" "$next_min"
    return 0
  fi

  if [[ "$minute" == "0" && "$hour" == "*" ]]; then
    printf '%02d:00' "$(((now_hour + 1) % 24))"
    return 0
  fi

  if [[ "$minute" =~ ^0$ && "$hour" =~ ^\*/([0-9]+)$ ]]; then
    local step_hour next_hour candidate
    step_hour="${BASH_REMATCH[1]}"
    if ((step_hour < 1 || step_hour > 23)); then
      return 1
    fi
    next_hour=-1
    for ((candidate = 0; candidate < 24; candidate += step_hour)); do
      if ((candidate > now_hour)); then
        next_hour=$candidate
        break
      fi
    done
    if ((next_hour < 0)); then
      next_hour=0
    fi
    printf '%02d:00' "$next_hour"
    return 0
  fi

  if [[ "$minute $hour" == "0 0" ]]; then
    printf '00:00'
    return 0
  fi

  return 1
}

next_run_hhmm_from_interval() {
  local interval="$AUDLINT_CRON_INTERVAL_MIN"
  if [[ ! "$interval" =~ ^[0-9]+$ || "$interval" -lt 1 || "$interval" -gt 720 ]]; then
    interval=20
  fi
  local now_epoch interval_sec next_epoch label
  now_epoch="$(date +%s 2>/dev/null || echo 0)"
  if [[ ! "$now_epoch" =~ ^[0-9]+$ || "$now_epoch" -le 0 ]]; then
    printf '--:--'
    return 0
  fi
  interval_sec=$((interval * 60))
  next_epoch=$((((now_epoch + interval_sec - 1) / interval_sec) * interval_sec))
  label="$(date_format_epoch "$next_epoch" "+%H:%M" 2>/dev/null || true)"
  [[ -n "$label" ]] || label="--:--"
  printf '%s' "$label"
}

next_run_hhmm() {
  local schedule label
  if schedule="$(managed_cron_schedule)"; then
    label="$(cron_next_run_hhmm "$schedule" 2>/dev/null || true)"
    if [[ -n "$label" ]]; then
      printf '%s' "$label"
      return 0
    fi
    next_run_hhmm_from_interval
    return 0
  fi
  printf 'manual'
}

show_flac_action() {
  [[ "$ACTIVE_VIEW" == "encode_only" && "$FILTER_UPSCALED_ONLY" == "1" ]]
}

show_transfer_action() {
  [[ -n "$MEDIA_PLAYER_PATH" && -d "$MEDIA_PLAYER_PATH" && -w "$MEDIA_PLAYER_PATH" ]]
}

show_sync_action() {
  [[ -n "$SYNC_DEST" && -d "$SYNC_DEST" && -w "$SYNC_DEST" ]]
}

show_lyrics_action() {
  command_ref_available "$LYRICS_SEEK_BIN"
}

print_nav_line() {
  local show_flac=0
  local show_transfer=0
  local -a nav_buttons=()
  if show_flac_action; then
    show_flac=1
  fi
  if show_transfer_action; then
    show_transfer=1
  fi
  nav_buttons=(
    "$(view_button 0 Last default)"
    "$(view_button 1 Year __sort_year__ "$([[ "$SORT_KEY" == "year" ]] && printf 1 || printf 0)")"
    "$(view_button 2 DR __sort_dr__ "$([[ "$SORT_KEY" == "dr" ]] && printf 1 || printf 0)")"
    "$(view_button 3 Grade __sort_grade__ "$([[ "$SORT_KEY" == "grade" ]] && printf 1 || printf 0)")"
    "$(view_button 4 Codec codec_inventory "$([[ "$CODEC_FILTER" != "all" ]] && printf 1 || printf 0)")"
    "$(view_button 5 Profile encoding_inventory "$([[ "$PROFILE_FILTER" != "all" ]] && printf 1 || printf 0)")"
    "$(view_button 6 ScanFail scan_failed)"
    "$(view_button e Recode encode_only)"
    "$(view_button R Rare rarity_only)"
    "$(nav_separator)"
    "$(hint_button a Asc)"
    "$(hint_button d Desc)"
    "$(nav_separator)"
    "$(hint_button c 'Clear Filters')"
  )
  print_hint_buttons_line "${nav_buttons[@]}"
  local -a hint_buttons=()
  if [[ "$FILTER_RARITY_ONLY" == "1" ]]; then
    hint_buttons=(
      "$(hint_button / Search)"
      "$(hint_button r MarkRare)"
      "$(hint_button u Unmark)"
      "$(hint_button n Next)"
      "$(hint_button p Prev)"
      "$(hint_button x Delete)"
    )
  else
    hint_buttons=(
      "$(hint_button / Search)"
      "$(hint_button r MarkRare)"
      "$(hint_button n Next)"
      "$(hint_button p Prev)"
      "$(hint_button x Delete)"
    )
  fi
  if show_sync_action; then
    hint_buttons+=("$(hint_button s Sync)")
  fi
  if ((show_flac == 1)); then
    hint_buttons+=("$(hint_button f FLAC 1)")
  fi
  if ((show_transfer == 1)); then
    hint_buttons+=("$(hint_button t Transfer)")
  fi
  hint_buttons+=("$(hint_button l Lyrics)")
  hint_buttons+=("$(hint_button i Inspect)")
  if [[ -n "$LIBRARY_ROOT" && -x "$AUDLINT_TASK_BIN" && -x "$AUDLINT_MAINTAIN_BIN" ]]; then
    hint_buttons+=("$(hint_button m Maintain)")
    hint_buttons+=("$(hint_button L Log)")
    hint_buttons+=("$(hint_button P Purge)")
  fi
  hint_buttons+=("$(hint_button q Quit)")
  print_hint_buttons_line "${hint_buttons[@]}"
}

audlint_prompt_key() {
  local prompt="$1"
  local out_var="$2"
  local silent="${3:-0}"
  local pad_top="${4:-1}"
  ui_prompt_key "$prompt" "$out_var" "$silent" "$pad_top"
}

audlint_prompt_line() {
  local prompt="$1"
  local out_var="$2"
  local pad_top="${3:-1}"
  ui_prompt_line "$prompt" "$out_var" "$pad_top"
}

prepend_row_numbers() {
  local rows="$1"
  [[ -n "$rows" ]] || {
    printf ''
    return 0
  }
  local out=()
  local line idx=1 row_idx
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    row_idx="$idx"
    if [[ "$USE_COLOR" == true ]]; then
      row_idx="$(printf '[bold red]%s[/]' "$idx")"
    fi
    out+=("$(printf '%s\t%s' "$row_idx" "$line")")
    idx=$((idx + 1))
  done <<< "$rows"
  if ((${#out[@]} == 0)); then
    printf ''
    return 0
  fi
  printf '%s\n' "${out[@]}"
}

prepend_row_labels() {
  local rows="$1"
  shift || true
  local labels=("$@")
  [[ -n "$rows" ]] || {
    printf ''
    return 0
  }
  local out=()
  local line idx=0 label row_idx
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    label="${labels[$idx]:-}"
    row_idx="$label"
    if [[ -n "$row_idx" && "$USE_COLOR" == true && "$row_idx" != *"["* ]]; then
      row_idx="$(printf '[bold red]%s[/]' "$row_idx")"
    fi
    out+=("$(printf '%s\t%s' "$row_idx" "$line")")
    idx=$((idx + 1))
  done <<< "$rows"
  if ((${#out[@]} == 0)); then
    printf ''
    return 0
  fi
  printf '%s\n' "${out[@]}"
}

inspect_row_is_selectable() {
  local needs_recode="$1"
  local fail_flag="$2"
  local recode_hint="$3"
  [[ "$needs_recode" =~ ^[0-9]+$ ]] || needs_recode=0
  if ((needs_recode == 1)); then
    return 1
  fi
  if [[ "$fail_flag" == "Y" ]]; then
    return 1
  fi
  local recode_lc
  recode_lc="$(lower_text "$recode_hint")"
  if [[ "$recode_lc" == *"pending rescan"* ]]; then
    return 1
  fi
  return 0
}

parse_delete_selection() {
  local raw="$1"
  local max_idx="$2"
  local compact
  local compact_lc
  compact="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [[ -n "$compact" ]] || {
    printf ''
    return 0
  }
  [[ "$max_idx" =~ ^[0-9]+$ ]] || return 1
  compact_lc="$(printf '%s' "$compact" | tr '[:upper:]' '[:lower:]')"

  local -A seen=()
  local token token_lc start end i
  local out=()
  local parts=()
  if [[ "$compact_lc" == "a" || "$compact_lc" == "all" ]]; then
    for ((i = 1; i <= max_idx; i++)); do
      out+=("$i")
    done
    printf '%s' "${out[*]}"
    return 0
  fi
  IFS=',' read -r -a parts <<< "$compact"
  for token in "${parts[@]}"; do
    [[ -n "$token" ]] || return 1
    token_lc="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
    if [[ "$token_lc" == "a" || "$token_lc" == "all" ]]; then
      out=()
      for ((i = 1; i <= max_idx; i++)); do
        out+=("$i")
      done
      printf '%s' "${out[*]}"
      return 0
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      start="$token"
      end="$token"
    elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if ((start > end)); then
        local tmp="$start"
        start="$end"
        end="$tmp"
      fi
    else
      return 1
    fi
    if ((start < 1 || end > max_idx)); then
      return 1
    fi
    for ((i = start; i <= end; i++)); do
      if [[ -z "${seen[$i]:-}" ]]; then
        seen[$i]=1
        out+=("$i")
      fi
    done
  done

  printf '%s' "${out[*]}"
}

row_selection_options_hint() {
  printf '2, 4, 7-9, [a All in view]'
}

row_action_selection_hint_for_mode() {
  case "$1" in
  album_analysis) printf '' ;;
  *) row_selection_options_hint ;;
  esac
}

format_row_action_prompt() {
  local action_label="$1"
  local selection_hint="${2:-}"
  if [[ -n "$selection_hint" ]]; then
    printf '%s (%s; blank=cancel) > ' "$action_label" "$selection_hint"
  else
    printf '%s (blank=cancel) > ' "$action_label"
  fi
}

row_action_prompt_for_mode() {
  local action_label="select rows"
  local selection_hint=""
  case "$1" in
  delete) action_label="delete rows" ;;
  mark_rarity) action_label="mark as rarity" ;;
  unmark_rarity) action_label="unmark rarity" ;;
  recode_flac) action_label="select rows for FLAC recode" ;;
  lyrics_seek) action_label="select rows for lyrics seek" ;;
  album_analysis) action_label="inspect one row (single selection)" ;;
  transfer) action_label="transfer rows to player" ;;
  esac
  selection_hint="$(row_action_selection_hint_for_mode "$1")"
  format_row_action_prompt "$action_label" "$selection_hint"
}

prime_row_action_snapshot() {
  local rows_raw="${1-}"
  ROW_ACTION_ROWS_RAW_SNAPSHOT="$rows_raw"
}

extract_target_profile_from_recode() {
  local recode="$1"
  local candidate="" target=""
  candidate="$(printf '%s\n' "$recode" | grep -Eio '[0-9]+([.][0-9]+)?(k(hz)?)?[/:-][0-9]{1,3}f?' | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    target="$(profile_normalize "$candidate" || true)"
  fi
  printf '%s' "$target"
}

is_dts_codec_value() {
  local codec
  codec="$(lower_text "${1:-}")"
  case "$codec" in
  dts | dca) return 0 ;;
  *) return 1 ;;
  esac
}

normalize_replacement_target_profile() {
  local raw="$1"
  local normalized="" sr="" bits="" target_bits=""
  normalized="$(profile_normalize "$raw" || true)"
  [[ -n "$normalized" ]] || return 1
  sr="${normalized%%/*}"
  bits="${normalized#*/}"
  [[ "$sr" =~ ^[0-9]+$ ]] || return 1
  case "$bits" in
  16) target_bits="16" ;;
  24 | 32 | 32f | 64 | 64f) target_bits="24" ;;
  *)
    if [[ "$bits" =~ ^[0-9]+$ ]]; then
      if ((bits >= 24)); then
        target_bits="24"
      else
        target_bits="16"
      fi
    else
      return 1
    fi
    ;;
  esac
  printf '%s/%s' "$sr" "$target_bits"
}

resolve_recode_target_profile() {
  local recode="$1"
  local codec="$2"
  local current_quality="$3"
  local recode_source_profile="$4"
  local needs_replace="${5:-0}"
  local target=""

  target="$(extract_target_profile_from_recode "$recode")"
  if [[ -n "$target" ]]; then
    printf '%s' "$target"
    return 0
  fi

  [[ "$needs_replace" =~ ^[0-9]+$ ]] || needs_replace=0
  if ((needs_replace != 1)); then
    return 1
  fi
  is_dts_codec_value "$codec" || return 1

  target="$(normalize_replacement_target_profile "$recode_source_profile" || true)"
  if [[ -z "$target" ]]; then
    target="$(normalize_replacement_target_profile "$current_quality" || true)"
  fi
  [[ -n "$target" ]] || return 1
  printf '%s' "$target"
}

delete_and_requeue_album_for_scan() {
  local row_id="$1"
  local artist="$2"
  local year="$3"
  local album="$4"
  local source_path="$5"
  [[ "$row_id" =~ ^[0-9]+$ ]] || return 1
  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0

  local now artist_lc album_lc
  now="$(date +%s)"
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"

  sqlite3 "$DB_PATH" \
    "BEGIN;
     UPDATE album_quality
     SET
       needs_recode=0,
       recode_recommendation='Pending rescan',
       recode_source_profile=CASE
         WHEN COALESCE(current_quality,'') != '' THEN current_quality
         ELSE recode_source_profile
       END,
       last_checked_at=0,
       checked_sort=0,
       scan_failed=0,
       last_recoded_at=$now
     WHERE id=$row_id;
     INSERT INTO scan_roadmap (
       artist, artist_lc, album, album_lc, year_int, source_path, album_mtime, scan_kind, enqueued_at
     ) VALUES (
       '$(sql_escape "$artist")',
       '$(sql_escape "$artist_lc")',
       '$(sql_escape "$album")',
       '$(sql_escape "$album_lc")',
       $year,
       '$(sql_escape "$source_path")',
       $now,
       'changed',
       $now
     )
     ON CONFLICT(artist_lc, album_lc, year_int) DO UPDATE SET
       artist=excluded.artist,
       album=excluded.album,
       source_path=excluded.source_path,
       album_mtime=excluded.album_mtime,
       scan_kind=excluded.scan_kind,
       enqueued_at=excluded.enqueued_at;
     COMMIT;" >/dev/null 2>&1
}

flac_recode_manifest_fields_for_row_id() {
  local row_id="$1"
  [[ "$row_id" =~ ^[0-9]+$ ]] || {
    ACTION_MESSAGE="Invalid row id: $row_id"
    return 1
  }

  local row row_artist row_album row_year row_source_path row_recode row_needs_recode row_needs_replace
  local row_codec row_current_quality row_recode_source_profile row_last_recoded
  row="$(
    sqlite3 -separator $'\t' -noheader "$DB_PATH" \
      "SELECT
         artist,
         album,
         COALESCE(year_int,0),
         COALESCE(source_path,''),
         COALESCE(recode_recommendation,''),
         COALESCE(needs_recode,0),
         COALESCE(needs_replacement,0),
         COALESCE(codec,''),
         COALESCE(current_quality,''),
         COALESCE(recode_source_profile,''),
         COALESCE(last_recoded_at,0)
       FROM album_quality
       WHERE id=$row_id
       LIMIT 1;" 2>/dev/null || true
  )"
  if [[ -z "$row" ]]; then
    ACTION_MESSAGE="Row not found for FLAC action."
    return 1
  fi
  IFS=$'\t' read -r row_artist row_album row_year row_source_path row_recode row_needs_recode row_needs_replace row_codec row_current_quality row_recode_source_profile row_last_recoded <<< "$row"
  [[ "$row_needs_recode" =~ ^[0-9]+$ ]] || row_needs_recode=0
  [[ "$row_needs_replace" =~ ^[0-9]+$ ]] || row_needs_replace=0
  [[ "$row_last_recoded" =~ ^[0-9]+$ ]] || row_last_recoded=0

  local dts_replace_actionable=0
  if ((row_needs_replace == 1)) && is_dts_codec_value "$row_codec"; then
    dts_replace_actionable=1
  fi
  if ((row_needs_recode != 1 && dts_replace_actionable != 1)); then
    ACTION_MESSAGE="Selected row is not actionable (needs_recode != Y and no DTS replacement)."
    return 1
  fi
  if ((HAS_COL_LAST_RECODED_AT == 1)) && ((row_last_recoded > 0)); then
    local recode_date
    recode_date="$(awk -v t="$row_last_recoded" 'BEGIN{printf strftime("%Y-%m-%d",t+0)}')"
    ACTION_MESSAGE="Already recoded on ${recode_date} (green star). Clear last_recoded_at in DB to re-encode."
    return 1
  fi
  if [[ -z "$row_source_path" || ! -d "$row_source_path" ]]; then
    ACTION_MESSAGE="Album path not found for selected row: $row_source_path"
    return 1
  fi

  local target_profile allow_lossy_source=0
  target_profile="$(resolve_recode_target_profile "$row_recode" "$row_codec" "$row_current_quality" "$row_recode_source_profile" "$row_needs_replace" || true)"
  if [[ -z "$target_profile" ]]; then
    ACTION_MESSAGE="Unable to determine target profile for recode recommendation."
    return 1
  fi
  if ((dts_replace_actionable == 1 && row_needs_recode != 1)); then
    allow_lossy_source=1
  fi

  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
    "$row_artist" "$row_album" "$row_year" "$row_source_path" "$target_profile" "$allow_lossy_source"
}

inspect_album_row_snapshot_for_id() {
  local row_id="$1"
  local row_sep=$'\x1f'
  [[ "$row_id" =~ ^[0-9]+$ ]] || {
    printf ''
    return 1
  }
  sqlite3 -separator "$row_sep" -noheader "$DB_PATH" \
    "SELECT
       id,
       COALESCE(artist,''),
       COALESCE(album,''),
       COALESCE(year_int,0),
       COALESCE(source_path,''),
       COALESCE(quality_grade,'-'),
       COALESCE(dynamic_range_score,''),
       COALESCE(genre_profile,'standard')
     FROM album_quality
     WHERE id=$row_id
     LIMIT 1;" 2>/dev/null || true
}

inspect_remove_cache_files_for_source_path() {
  local source_path="$1"
  local removed_count=0
  local inspect_cache_path=""
  if [[ -n "$source_path" ]]; then
    inspect_cache_path="$source_path/.audlint_inspect_cache.json"
    if [[ -f "$inspect_cache_path" ]]; then
      rm -f "$inspect_cache_path" >/dev/null 2>&1 || true
      removed_count=$((removed_count + 1))
    fi
  fi
  printf '%s' "$removed_count"
}

inspect_confirm_full_remove_prompt() {
  local choice=""
  if ! audlint_prompt_key 'Full remove album? [y Remove, n Cancel] > ' choice 0 1; then
    return 1
  fi
  [[ "$choice" == "y" ]]
}

inspect_full_remove_album_for_row_id() {
  local row_id="$1"
  [[ "$row_id" =~ ^[0-9]+$ ]] || {
    ACTION_MESSAGE="Inspect remove failed: invalid row id."
    return 1
  }
  if [[ "$DB_WRITABLE" != true ]]; then
    ACTION_MESSAGE="Inspect remove unavailable: DB is read-only."
    return 1
  fi

  local row_sep=$'\x1f'
  local row_data=""
  row_data="$(inspect_album_row_snapshot_for_id "$row_id")"
  if [[ -z "$row_data" ]]; then
    ACTION_MESSAGE="Inspect remove failed: row not found (id=$row_id)."
    return 1
  fi

  local rid artist album year source_path old_grade old_dr genre_profile
  IFS="$row_sep" read -r rid artist album year source_path old_grade old_dr genre_profile <<< "$row_data"
  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0

  if ! inspect_confirm_full_remove_prompt; then
    ACTION_MESSAGE="Inspect remove cancelled for $artist - $album."
    return 0
  fi

  if [[ -n "$source_path" && -d "$source_path" ]]; then
    if declare -F secure_backup_album_tracks_once >/dev/null 2>&1; then
      if ! secure_backup_album_tracks_once "$source_path" "audlint inspect full remove"; then
        ACTION_MESSAGE="${SECURE_BACKUP_LAST_ERROR:-Inspect remove failed: secure backup step failed.}"
        return 1
      fi
    fi
  fi

  local removed_caches=0
  removed_caches="$(inspect_remove_cache_files_for_source_path "$source_path")"

  if [[ -n "$source_path" && -d "$source_path" ]]; then
    if ! rm -rf "$source_path"; then
      ACTION_MESSAGE="Inspect remove failed: could not remove source path ($source_path)."
      return 1
    fi
  fi

  local artist_lc album_lc
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"
  if ! sqlite3 "$DB_PATH" \
    "BEGIN;
     DELETE FROM album_quality WHERE id=$rid;
     DELETE FROM scan_roadmap
      WHERE source_path='$(sql_escape "$source_path")'
         OR (artist_lc='$(sql_escape "$artist_lc")' AND album_lc='$(sql_escape "$album_lc")' AND year_int=$year);
     COMMIT;" >/dev/null 2>&1; then
    ACTION_MESSAGE="Inspect remove failed: DB delete transaction failed."
    return 1
  fi

  invalidate_count_cache
  ACTION_MESSAGE="Removed fully: $artist - $album (disk + DB). Caches removed=$removed_caches."
  return 0
}

inspect_clear_db_cache_and_queue_row_id() {
  local row_id="$1"
  [[ "$row_id" =~ ^[0-9]+$ ]] || {
    ACTION_MESSAGE="Inspect clear failed: invalid row id."
    return 1
  }
  if [[ "$DB_WRITABLE" != true ]]; then
    ACTION_MESSAGE="Inspect clear unavailable: DB is read-only."
    return 1
  fi

  local row_sep=$'\x1f'
  local row_data=""
  row_data="$(inspect_album_row_snapshot_for_id "$row_id")"
  if [[ -z "$row_data" ]]; then
    ACTION_MESSAGE="Inspect clear failed: row not found (id=$row_id)."
    return 1
  fi

  local rid artist album year source_path old_grade old_dr genre_profile
  IFS="$row_sep" read -r rid artist album year source_path old_grade old_dr genre_profile <<< "$row_data"
  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0
  if [[ -z "$source_path" ]]; then
    ACTION_MESSAGE="Inspect clear failed: source_path is empty for row id=$row_id."
    return 1
  fi

  local removed_caches=0
  removed_caches="$(inspect_remove_cache_files_for_source_path "$source_path")"
  local artist_lc album_lc
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"
  if ! sqlite3 "$DB_PATH" \
    "BEGIN;
     INSERT INTO scan_roadmap (
       artist, artist_lc, album, album_lc, year_int, source_path, album_mtime, scan_kind, enqueued_at
     ) VALUES (
       '$(sql_escape "$artist")',
       '$(sql_escape "$artist_lc")',
       '$(sql_escape "$album")',
       '$(sql_escape "$album_lc")',
       $year,
       '$(sql_escape "$source_path")',
       0,
       'new',
       0
     )
     ON CONFLICT(artist_lc, album_lc, year_int) DO UPDATE SET
       artist=excluded.artist,
       album=excluded.album,
       source_path=excluded.source_path,
       album_mtime=excluded.album_mtime,
       scan_kind=excluded.scan_kind,
       enqueued_at=excluded.enqueued_at;
     DELETE FROM album_quality WHERE id=$rid;
     COMMIT;" >/dev/null 2>&1; then
    ACTION_MESSAGE="Inspect clear failed: DB queue/delete transaction failed."
    return 1
  fi

  invalidate_count_cache
  ACTION_MESSAGE="Cleared DB + cache for $artist - $album; queued for maintenance reprocess. Caches removed=$removed_caches."
  return 0
}

normalize_prompt_path_input() {
  local p="$1"
  p="$(normalize_search_query "$p")"
  case "$p" in
  \"*\")
    if ((${#p} >= 2)); then
      p="${p:1:${#p}-2}"
    fi
    ;;
  \'*\')
    if ((${#p} >= 2)); then
      p="${p:1:${#p}-2}"
    fi
    ;;
  esac
  # Accept shell-escaped path fragments commonly pasted in terminals.
  p="${p//\\ / }"
  p="${p//\\,/,}"
  p="${p//\\(/(}"
  p="${p//\\)/)}"
  p="${p//\\[/[}"
  p="${p//\\]/]}"
  printf '%s' "$p"
}

inspect_prompt_compare_target_path() {
  local out_var="$1"
  local raw=""
  local normalized=""

  while true; do
    if ! audlint_prompt_line "compare with album 2 abs path (blank=cancel) > " raw 1; then
      printf -v "$out_var" '%s' ""
      return 1
    fi
    normalized="$(normalize_prompt_path_input "$raw")"
    if [[ -z "$normalized" ]]; then
      printf -v "$out_var" '%s' ""
      return 0
    fi
    if [[ "$normalized" != /* ]]; then
      tty_print_line "Path must be absolute."
      continue
    fi
    if [[ ! -d "$normalized" ]]; then
      tty_print_line "Directory not found: $normalized"
      continue
    fi
    normalized="$(cd "$normalized" >/dev/null 2>&1 && pwd)"
    printf -v "$out_var" '%s' "$normalized"
    return 0
  done
}

inspect_compare_album_for_row_id() {
  local row_id="$1"
  [[ "$row_id" =~ ^[0-9]+$ ]] || {
    ACTION_MESSAGE="Inspect compare failed: invalid row id."
    return 1
  }

  local row_sep=$'\x1f'
  local row_data=""
  row_data="$(inspect_album_row_snapshot_for_id "$row_id")"
  if [[ -z "$row_data" ]]; then
    ACTION_MESSAGE="Inspect compare failed: row not found (id=$row_id)."
    return 1
  fi

  local rid artist album year source_path _old_grade _old_dr _genre_profile
  IFS="$row_sep" read -r rid artist album year source_path _old_grade _old_dr _genre_profile <<< "$row_data"
  if [[ -z "$source_path" || ! -d "$source_path" ]]; then
    ACTION_MESSAGE="Inspect compare unavailable: source path missing for $artist - $album."
    return 1
  fi
  if ! command_ref_available "$QTY_COMPARE_BIN"; then
    ACTION_MESSAGE="Inspect compare unavailable: qty_compare.sh not found ($QTY_COMPARE_BIN)."
    return 1
  fi

  local compare_target=""
  if ! inspect_prompt_compare_target_path compare_target; then
    ACTION_MESSAGE="Inspect compare cancelled for $artist - $album."
    return 0
  fi
  if [[ -z "$compare_target" ]]; then
    ACTION_MESSAGE="Inspect compare cancelled for $artist - $album."
    return 0
  fi

  if ! VIRTWIN_TITLE_PLAIN=1 VIRTWIN_RIGHT_TITLE='[q Quit]' virtwin_run_command 0 "$(term_lines_value)" "$(term_cols_value)" "Compare View" \
    "$QTY_COMPARE_BIN" "$source_path" "$compare_target"; then
    ACTION_MESSAGE="Inspect compare failed for $artist - $album."
    return 1
  fi

  ACTION_MESSAGE="Inspect compare closed for $artist - $album."
  return 0
}

inspect_load_score_meta() {
  local meta_file="$1"
  [[ -n "$meta_file" && -f "$meta_file" ]] || return 1
  command_ref_available "$PYTHON_BIN" || return 1
  "$PYTHON_BIN" - "$meta_file" <<'PY'
import json
import pathlib
import sys

meta_path = pathlib.Path(sys.argv[1])
try:
    payload = json.loads(meta_path.read_text(encoding="utf-8", errors="replace"))
except Exception:
    payload = {}

dr_rounded = payload.get("album_mean_dr_rounded")
album_class = payload.get("album_class")
db_dr_rounded = payload.get("db_dr_rounded")
db_class = payload.get("db_class")
genre_profile = payload.get("genre_profile")
tracks_with_dr = payload.get("tracks_with_dr")
score_action_enabled = payload.get("score_action_enabled")

if isinstance(dr_rounded, (int, float)):
    dr_rounded = int(round(float(dr_rounded)))
else:
    dr_rounded = ""
if isinstance(db_dr_rounded, (int, float)):
    db_dr_rounded = int(round(float(db_dr_rounded)))
else:
    db_dr_rounded = ""
if album_class is None:
    album_class = ""
if db_class is None:
    db_class = ""
if genre_profile is None:
    genre_profile = ""
if not isinstance(tracks_with_dr, int):
    tracks_with_dr = 0
score_action_enabled = 1 if bool(score_action_enabled) else 0

print(f"{dr_rounded}\x1f{album_class}\x1f{db_dr_rounded}\x1f{db_class}\x1f{genre_profile}\x1f{tracks_with_dr}\x1f{score_action_enabled}")
PY
}

inspect_write_score_to_db_for_row_id() {
  local row_id="$1"
  local meta_file="$2"
  [[ "$row_id" =~ ^[0-9]+$ ]] || {
    ACTION_MESSAGE="Inspect score failed: invalid row id."
    return 1
  }
  if [[ "$DB_WRITABLE" != true ]]; then
    ACTION_MESSAGE="Inspect score unavailable: DB is read-only."
    return 1
  fi

  local row_sep=$'\x1f'
  local row_data=""
  row_data="$(inspect_album_row_snapshot_for_id "$row_id")"
  if [[ -z "$row_data" ]]; then
    ACTION_MESSAGE="Inspect score failed: row not found (id=$row_id)."
    return 1
  fi

  local meta_line=""
  if ! meta_line="$(inspect_load_score_meta "$meta_file" 2>/dev/null)"; then
    ACTION_MESSAGE="Inspect score failed: recalculated score data unavailable."
    return 1
  fi
  local new_dr_rounded new_grade _db_dr_rounded _db_grade _new_profile tracks_with_dr score_action_enabled
  IFS="$row_sep" read -r new_dr_rounded new_grade _db_dr_rounded _db_grade _new_profile tracks_with_dr score_action_enabled <<< "$meta_line"
  [[ "$tracks_with_dr" =~ ^[0-9]+$ ]] || tracks_with_dr=0
  [[ "$score_action_enabled" =~ ^[01]$ ]] || score_action_enabled=0
  if ((tracks_with_dr == 0)) || [[ -z "$new_dr_rounded" || ! "$new_dr_rounded" =~ ^-?[0-9]+$ || -z "$new_grade" || "$new_grade" == "-" ]]; then
    ACTION_MESSAGE="Inspect score skipped: no recalculated DR/class available."
    return 1
  fi
  if ((score_action_enabled != 1)); then
    ACTION_MESSAGE="Score unchanged for this album (DR/Class already match DB)."
    return 0
  fi

  local rid artist album year source_path old_grade old_dr old_profile
  IFS="$row_sep" read -r rid artist album year source_path old_grade old_dr old_profile <<< "$row_data"
  [[ "$old_grade" == "" ]] && old_grade="-"
  local old_dr_rounded=""
  if [[ "$old_dr" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    old_dr_rounded="$(awk -v v="$old_dr" 'BEGIN{printf "%.0f", v+0}')"
  fi

  local new_dr_sql now
  new_dr_sql="$(sql_num_or_null "$new_dr_rounded")"
  now="$(date +%s)"
  if ! sqlite3 "$DB_PATH" \
    "UPDATE album_quality
     SET
       quality_grade='$(sql_escape "$new_grade")',
       dynamic_range_score=$new_dr_sql,
       grade_rank=CASE '$(sql_escape "$new_grade")'
         WHEN 'F' THEN 1
         WHEN 'C' THEN 2
         WHEN 'B' THEN 3
         WHEN 'A' THEN 4
         WHEN 'S' THEN 5
         ELSE 0
       END,
       last_checked_at=$now,
       checked_sort=$now
     WHERE id=$rid;" >/dev/null 2>&1; then
    ACTION_MESSAGE="Inspect score failed: DB update failed."
    return 1
  fi

  invalidate_count_cache
  local old_dr_label="-"
  if [[ -n "$old_dr_rounded" ]]; then
    old_dr_label="$old_dr_rounded"
  fi
  ACTION_MESSAGE="Score saved for $artist - $album: DR ${old_dr_label} -> ${new_dr_rounded}, Class ${old_grade} -> ${new_grade}."
  return 0
}

command_ref_available() {
  local cmd_ref="$1"
  if [[ -z "$cmd_ref" ]]; then
    return 1
  fi
  if [[ "$cmd_ref" == */* ]]; then
    [[ -x "$cmd_ref" ]]
    return $?
  fi
  has_bin "$cmd_ref"
}

format_epoch_local() {
  local epoch="$1"
  [[ "$epoch" =~ ^[0-9]+$ ]] || {
    printf '-'
    return 0
  }
  if ((epoch <= 0)); then
    printf '-'
    return 0
  fi
  local label=""
  label="$(date_format_epoch "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  if [[ -z "$label" ]]; then
    label="$epoch"
  fi
  printf '%s' "$label"
}

print_album_analysis_report_for_row_id() {
  local row_id="$1"
  local meta_file="${2:-}"
  [[ "$row_id" =~ ^[0-9]+$ ]] || return 1

  local row_sep=$'\x1f'
  local row_data=""
  row_data="$(
    sqlite3 -separator "$row_sep" -noheader "$DB_PATH" \
      "SELECT
         id,
         COALESCE(artist,''),
         COALESCE(album,''),
         COALESCE(year_int,0),
         COALESCE(source_path,''),
         COALESCE(quality_grade,'-'),
         COALESCE(quality_score,''),
         COALESCE(dynamic_range_score,''),
         COALESCE(current_quality,''),
         COALESCE(codec,''),
         COALESCE(bitrate,''),
         COALESCE(recode_recommendation,''),
         COALESCE(needs_recode,0),
         COALESCE(needs_replacement,0),
         COALESCE(scan_failed,0),
         COALESCE(recommendation,''),
         COALESCE(notes,''),
         COALESCE(last_checked_at,0),
         COALESCE(genre_profile,''),
         COALESCE(recode_source_profile,'')
       FROM album_quality
       WHERE id=$row_id
       LIMIT 1;" 2>/dev/null || true
  )"
  [[ -n "$row_data" ]] || return 1

  local rid artist album year source_path quality_grade quality_score dr_score current_quality codec bitrate recode_rec
  local needs_recode needs_replace scan_failed recommendation notes last_checked genre_profile recode_source_profile
  IFS="$row_sep" read -r rid artist album year source_path quality_grade quality_score dr_score current_quality codec bitrate recode_rec needs_recode needs_replace scan_failed recommendation notes last_checked genre_profile recode_source_profile <<< "$row_data"

  local checked_label
  checked_label="$(format_epoch_local "$last_checked")"
  local dr_grade_py
  dr_grade_py="${SCRIPT_DIR}/../lib/py/dr_grade.py"

  local value_json value_err
  value_json="$(mktemp "${TMPDIR:-/tmp}/audlint_album_value_json.XXXXXX" 2>/dev/null || true)"
  value_err="$(mktemp "${TMPDIR:-/tmp}/audlint_album_value_err.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$value_json" || -z "$value_err" ]]; then
    rm -f "$value_json" "$value_err"
    return 1
  fi

  local value_status="skipped"
  if [[ -n "$source_path" && -d "$source_path" ]]; then
    if [[ -x "$AUDLINT_VALUE_BIN" ]]; then
      if [[ -n "$genre_profile" ]]; then
        if GENRE_PROFILE="$genre_profile" "$AUDLINT_VALUE_BIN" "$source_path" >"$value_json" 2>"$value_err"; then
          value_status="ok"
        else
          value_status="failed"
        fi
      else
        if "$AUDLINT_VALUE_BIN" "$source_path" >"$value_json" 2>"$value_err"; then
          value_status="ok"
        else
          value_status="failed"
        fi
      fi
    fi
  fi

  if command_ref_available "$PYTHON_BIN"; then
    ALBUM_ANALYSIS_ROW_ID="$rid" \
    ALBUM_ANALYSIS_ARTIST="$artist" \
    ALBUM_ANALYSIS_ALBUM="$album" \
    ALBUM_ANALYSIS_YEAR="$year" \
    ALBUM_ANALYSIS_SOURCE_PATH="$source_path" \
    ALBUM_ANALYSIS_GRADE="$quality_grade" \
    ALBUM_ANALYSIS_QUALITY_SCORE="$quality_score" \
    ALBUM_ANALYSIS_DR_SCORE="$dr_score" \
    ALBUM_ANALYSIS_CURRENT_QUALITY="$current_quality" \
    ALBUM_ANALYSIS_CODEC="$codec" \
    ALBUM_ANALYSIS_BITRATE="$bitrate" \
    ALBUM_ANALYSIS_RECODE_REC="$recode_rec" \
    ALBUM_ANALYSIS_NEEDS_RECODE="$needs_recode" \
    ALBUM_ANALYSIS_NEEDS_REPLACE="$needs_replace" \
    ALBUM_ANALYSIS_SCAN_FAILED="$scan_failed" \
    ALBUM_ANALYSIS_RECOMMENDATION="$recommendation" \
    ALBUM_ANALYSIS_NOTES="$notes" \
    ALBUM_ANALYSIS_CHECKED_LABEL="$checked_label" \
    ALBUM_ANALYSIS_GENRE_PROFILE="$genre_profile" \
    ALBUM_ANALYSIS_RECODE_SOURCE_PROFILE="$recode_source_profile" \
    ALBUM_ANALYSIS_VALUE_STATUS="$value_status" \
    ALBUM_ANALYSIS_COLOR="$INTERACTIVE" \
    ALBUM_ANALYSIS_META_FILE="$meta_file" \
    ALBUM_ANALYSIS_DR_GRADE_PY="$dr_grade_py" \
    ALBUM_ANALYSIS_TRACK_DR_PY="$SCRIPT_DIR/../lib/py/track_dr.py" \
    "$PYTHON_BIN" - "$value_json" "$value_err" <<'PY'
import json
import hashlib
import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import sys
import unicodedata

try:
    from rich.console import Console
    from rich.table import Table
    from rich import box
    from rich.markup import escape as rich_escape
except Exception:
    Console = None
    Table = None
    box = None
    rich_escape = None


value_json_path = pathlib.Path(sys.argv[1])
value_err_path = pathlib.Path(sys.argv[2])
TRACK_MATCHER_VERSION = 4


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_flag(name: str, default: bool = False) -> bool:
    raw = (env(name, "1" if default else "0") or "").strip().lower()
    return raw in {"1", "true", "yes", "on"}


def first_line(path: pathlib.Path) -> str:
    if not path.exists():
        return ""
    text = path.read_text(encoding="utf-8", errors="replace").strip()
    if not text:
        return ""
    return text.splitlines()[0].strip()


def load_json_if_ok(path: pathlib.Path, status: str):
    if status != "ok" or not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return {}


def fmt_dr(v) -> str:
    if v is None:
        return "-"
    try:
        val = float(v)
    except Exception:
        return "-"
    if val.is_integer():
        return str(int(val))
    return f"{val:.2f}".rstrip("0").rstrip(".")


def load_grade_helpers():
    grade_py = env("ALBUM_ANALYSIS_DR_GRADE_PY", "")
    if grade_py and pathlib.Path(grade_py).is_file():
        try:
            spec = importlib.util.spec_from_file_location("dr_grade", grade_py)
            if spec and spec.loader:
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                grade_fn = getattr(mod, "grade_from_dr", None)
                norm_fn = getattr(mod, "normalize_genre_profile", None)
                if callable(grade_fn) and callable(norm_fn):
                    return grade_fn, norm_fn
        except Exception:
            pass

    thresholds = {
        "audiophile": [(14, "S"), (12, "A"), (9, "B"), (6, "C")],
        "high_energy": [(11, "S"), (9, "A"), (7, "B"), (4, "C")],
        "standard": [(12, "S"), (9, "A"), (7, "B"), (5, "C")],
    }

    def _normalize_profile(raw):
        key = (raw or "standard").strip().lower()
        if key in {"audiophile", "high_energy", "standard"}:
            return key
        return "standard"

    def _grade_from_dr(dr_value, genre_profile="standard"):
        profile = _normalize_profile(genre_profile)
        try:
            dr_num = float(dr_value)
        except Exception:
            return "F"
        for lower, grade in thresholds[profile]:
            if dr_num >= lower:
                return grade
        return "F"

    return _grade_from_dr, _normalize_profile


def load_track_dr_lookup():
    track_dr_py = env("ALBUM_ANALYSIS_TRACK_DR_PY", "")
    if track_dr_py and pathlib.Path(track_dr_py).is_file():
        try:
            spec = importlib.util.spec_from_file_location("track_dr", track_dr_py)
            if spec and spec.loader:
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                lookup_fn = getattr(mod, "lookup_track_dr", None)
                if callable(lookup_fn):
                    return lookup_fn
        except Exception:
            pass
    return None


def human_size(num_bytes: int) -> str:
    size = float(max(0, int(num_bytes)))
    units = ["B", "K", "M", "G", "T"]
    idx = 0
    while size >= 1024.0 and idx < len(units) - 1:
        size /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(size)}{units[idx]}"
    if size >= 100:
        return f"{size:.0f}{units[idx]}"
    if size >= 10:
        return f"{size:.1f}{units[idx]}"
    return f"{size:.2f}{units[idx]}"


def sample_fmt_bits(sample_fmt: str):
    mapping = {
        "s16": 16, "s16p": 16,
        "s24": 24, "s24p": 24,
        "s32": 32, "s32p": 32,
        "flt": 32, "fltp": 32,
        "dbl": 64, "dblp": 64,
    }
    return mapping.get((sample_fmt or "").strip().lower())


def norm_name(raw: str) -> str:
    text = os.path.basename(str(raw or ""))
    text = unicodedata.normalize("NFKC", text)
    text = text.strip().casefold()
    text = re.sub(r"\s+", " ", text)
    return text


def fold_diacritics(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text or "")
    return "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")


def strip_track_prefix(text: str) -> str:
    out = re.sub(r"^\d+:\d+\s+", "", text)  # dr14 key prefix MM:SS
    out = re.sub(r"\s+\[\w+\]$", "", out)   # dr14 key suffix [ext]
    out = re.sub(r"^\d+\s*[\.\-_]\s*", "", out)  # track numbering
    return out.strip()


def aliases_for_name(raw: str):
    base = norm_name(raw)
    if not base:
        return []
    out = {base, fold_diacritics(base)}
    if "." in base:
        base_no_ext = base.rsplit(".", 1)[0].strip()
        out.add(base_no_ext)
        out.add(fold_diacritics(base_no_ext))
    stripped = strip_track_prefix(base)
    if stripped:
        out.add(stripped)
        out.add(fold_diacritics(stripped))
    if "." in stripped:
        stripped_no_ext = stripped.rsplit(".", 1)[0].strip()
        out.add(stripped_no_ext)
        out.add(fold_diacritics(stripped_no_ext))
    return [x for x in out if x]


AUDIO_EXTS = {
    ".flac", ".alac", ".m4a", ".wav", ".aiff", ".aif", ".aifc", ".caf",
    ".dsf", ".dff", ".wv", ".ape", ".dts", ".dca", ".mp4", ".mp3", ".aac",
    ".ogg", ".opus",
}


def list_album_audio_files(album_path: pathlib.Path):
    if not album_path or not album_path.is_dir():
        return []
    files = []
    for p in album_path.iterdir():
        if not p.is_file():
            continue
        if p.suffix.lower() in AUDIO_EXTS:
            files.append(p)
    files.sort(key=lambda p: p.name.lower())
    return files


def files_fingerprint(files):
    h = hashlib.sha256()
    h.update(b"audlint-inspect-cache-v1\0")
    for p in files:
        st = p.stat()
        h.update(p.name.encode("utf-8", "surrogateescape"))
        h.update(b"\0")
        h.update(str(st.st_size).encode("ascii", "strict"))
        h.update(b"\0")
        h.update(str(st.st_mtime_ns).encode("ascii", "strict"))
        h.update(b"\0")
    return h.hexdigest()


def ffprobe_kv(track_path: pathlib.Path, show_entries: str, select_streams: str = ""):
    if not shutil.which("ffprobe"):
        return ""
    cmd = [
        "ffprobe",
        "-v", "error",
    ]
    if select_streams:
        cmd.extend(["-select_streams", select_streams])
    cmd.extend([
        "-show_entries", show_entries,
        "-of", "default=noprint_wrappers=1:nokey=0",
        str(track_path),
    ])
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return ""
    return out


def first_genre_tag(raw_kv: str) -> str:
    text = (raw_kv or "").strip()
    if not text:
        return ""
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if "genre" not in key.strip().lower():
            continue
        v = value.strip()
        if v:
            return v
    return ""


def compact_genre_tag(raw: str, max_len: int = 20) -> str:
    text = re.sub(r"\s+", " ", (raw or "").strip())
    if not text:
        return "-"
    if len(text) <= max_len:
        return text
    cut = max(1, max_len - 3)
    return text[:cut].rstrip() + "..."


def ffprobe_track_meta(track_path: pathlib.Path):
    core_kv = ffprobe_kv(
        track_path,
        "stream=codec_name,bit_rate,sample_rate,bits_per_raw_sample,sample_fmt",
        "a:0",
    )
    if not core_kv:
        return {}
    meta = {}
    for line in core_kv.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        meta[key.strip()] = value.strip()
    meta["genre_track_tag"] = first_genre_tag(ffprobe_kv(track_path, "stream_tags=genre", "a:0"))
    meta["genre_album_tag"] = first_genre_tag(ffprobe_kv(track_path, "format_tags=genre"))
    return meta


def build_track_meta_rows(files, genre_profile: str):
    rows = []
    for track_path in files:
        st = track_path.stat()
        meta = ffprobe_track_meta(track_path)

        codec = (meta.get("codec_name") or "").strip().lower()
        if not codec:
            codec = track_path.suffix.lower().lstrip(".") or "-"

        bitrate = "-"
        bit_rate_raw = (meta.get("bit_rate") or "").strip()
        if bit_rate_raw.isdigit() and int(bit_rate_raw) > 0:
            bitrate = f"{(int(bit_rate_raw) + 500) // 1000}k"

        sr_hz = (meta.get("sample_rate") or "").strip()
        sr_val = int(sr_hz) if sr_hz.isdigit() and int(sr_hz) > 0 else None
        bits_raw = (meta.get("bits_per_raw_sample") or "").strip()
        if bits_raw.isdigit() and int(bits_raw) > 0:
            bits_val = int(bits_raw)
        else:
            bits_val = sample_fmt_bits(meta.get("sample_fmt", ""))
        profile = f"{sr_val}/{bits_val}" if sr_val and bits_val else "-"
        genre_track_tag = compact_genre_tag(meta.get("genre_track_tag", ""))
        genre_album_tag = compact_genre_tag(meta.get("genre_album_tag", ""))
        genre_tag = genre_track_tag if genre_track_tag != "-" else genre_album_tag

        rows.append(
            {
                "track": track_path.name,
                "genre": genre_profile,
                "genre_tag": genre_tag,
                "size": human_size(st.st_size),
                "codec": codec,
                "bitrate": bitrate,
                "profile": profile,
            }
        )
    return rows


def read_cache(cache_path: pathlib.Path):
    if not cache_path.exists():
        return {}
    try:
        data = json.loads(cache_path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def write_cache(cache_path: pathlib.Path, payload: dict):
    try:
        tmp_path = cache_path.with_suffix(cache_path.suffix + ".tmp")
        tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_path.replace(cache_path)
    except Exception:
        return


def render_table(headers, rows):
    if console is not None and Table is not None and box is not None:
        table = Table(
            box=box.SIMPLE_HEAVY,
            show_header=True,
            header_style="bold bright_cyan",
            expand=False,
        )
        aligns = ["left", "left", "left", "right", "left", "right", "right", "right", "center"]
        for idx, header in enumerate(headers):
            table.add_column(header, justify=aligns[idx] if idx < len(aligns) else "left")
        for row in rows:
            table.add_row(*[str(x) for x in row])
        console.print(table)
        return

    # Fallback plain output.
    widths = [len(h) for h in headers]
    for row in rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(str(cell)))
    print(" | ".join(str(headers[idx]).ljust(widths[idx]) for idx in range(len(headers))))
    print("-+-".join("-" * widths[idx] for idx in range(len(headers))))
    for row in rows:
        print(" | ".join(str(row[idx]).ljust(widths[idx]) for idx in range(len(headers))))


color_enabled = env_flag("ALBUM_ANALYSIS_COLOR", False)
console = None
if Console is not None:
    if color_enabled:
        console = Console(highlight=False, markup=True, force_terminal=True, color_system="auto")
    else:
        console = Console(highlight=False, markup=False, force_terminal=False, color_system=None)


def emit(line: str = ""):
    if console is None:
        print(line)
        return
    console.print(line, markup=color_enabled)


def safe_markup(text) -> str:
    raw = "" if text is None else str(text)
    if not color_enabled or rich_escape is None:
        return raw
    return rich_escape(raw)


def section_heading(title: str, underline: str) -> None:
    if color_enabled:
        emit(f"[bold bright_yellow]{safe_markup(title)}[/bold bright_yellow]")
    else:
        emit(title)


def kv_line(label: str, value) -> None:
    if color_enabled:
        emit(f"[bold cyan]{safe_markup(label)}:[/bold cyan] [white]{safe_markup(value)}[/white]")
    else:
        emit(f"{label}: {value}")


def print_album_metadata_table(
    cache_state: str,
    cache_file: pathlib.Path,
    value_status: str,
    value_err: str,
    calc_dr_int,
    calc_class: str,
    db_dr_int,
    db_class: str,
    genre_adjustment_note: str,
) -> None:
    emit()
    section_heading("Album Analysis", "==============")
    emit()
    items = [
        ("ID", env("ALBUM_ANALYSIS_ROW_ID")),
        ("Artist", env("ALBUM_ANALYSIS_ARTIST")),
        ("Album", env("ALBUM_ANALYSIS_ALBUM")),
        ("Year", env("ALBUM_ANALYSIS_YEAR")),
        ("Library Path", env("ALBUM_ANALYSIS_SOURCE_PATH")),
        ("Checked", env("ALBUM_ANALYSIS_CHECKED_LABEL")),
        ("DR", "-" if calc_dr_int is None else str(calc_dr_int)),
        ("DR in DB", "-" if db_dr_int is None else str(db_dr_int)),
        ("Class", calc_class or "-"),
        ("Class in DB", db_class or "-"),
    ]

    if console is not None and Table is not None:
        table = Table(
            box=None,
            show_header=False,
            expand=False,
            pad_edge=False,
            highlight=False,
            show_lines=False,
        )
        table.add_column(justify="left", no_wrap=True)
        table.add_column(justify="left", no_wrap=False)
        table.add_column(justify="left", no_wrap=True)
        table.add_column(justify="left", no_wrap=False)
        for idx in range(0, len(items), 2):
            k1, v1 = items[idx]
            if idx + 1 < len(items):
                k2, v2 = items[idx + 1]
            else:
                k2, v2 = "", ""
            if color_enabled:
                table.add_row(
                    f"[bold cyan]{safe_markup(k1)}[/bold cyan]:",
                    f"{safe_markup(v1)}",
                    f"[bold cyan]{safe_markup(k2)}[/bold cyan]:" if k2 else "",
                    f"{safe_markup(v2)}" if k2 else "",
                )
            else:
                table.add_row(f"{k1}:", f"{v1}", f"{k2}:" if k2 else "", f"{v2}" if k2 else "")
        console.print(table)
    else:
        left_w = max(len(f"{k}:") for k, _ in items[::2]) if items else 0
        right_w = max(len(f"{k}:") for k, _ in items[1::2]) if len(items) > 1 else 0
        for idx in range(0, len(items), 2):
            k1, v1 = items[idx]
            if idx + 1 < len(items):
                k2, v2 = items[idx + 1]
                emit(f"{k1 + ':':<{left_w}} {v1}    {k2 + ':':<{right_w}} {v2}")
            else:
                emit(f"{k1 + ':':<{left_w}} {v1}")

    emit()
    cache_tail = f" ({cache_file})" if cache_file else ""
    cache_value = f"{cache_state}{cache_tail}"
    if color_enabled:
        emit(f"[bold #b38cff]inspect-cache:[/bold #b38cff] [#b8b8c8]{safe_markup(cache_value)}[/#b8b8c8]")
    else:
        kv_line("inspect-cache", cache_value)
    if genre_adjustment_note:
        kv_line("Scoring preset factor", genre_adjustment_note)
    if value_status != "ok":
        kv_line("DR source unavailable", f"{value_status}{f' ({value_err})' if value_err else ''}")


def build_value_signature(dr_tracks_map: dict, genre: str) -> str:
    normalized = []
    for key, raw in (dr_tracks_map or {}).items():
        try:
            normalized.append([str(key), float(raw)])
        except Exception:
            continue
    normalized.sort(key=lambda item: item[0])
    blob = json.dumps(
        {"genre_profile": str(genre or ""), "tracks": normalized},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return hashlib.sha256(blob.encode("utf-8", "surrogateescape")).hexdigest()


value_status = env("ALBUM_ANALYSIS_VALUE_STATUS", "skipped")
value_data = load_json_if_ok(value_json_path, value_status)
value_err = first_line(value_err_path)
grade_from_dr, normalize_genre_profile = load_grade_helpers()
track_dr_lookup = load_track_dr_lookup()
genre_profile = normalize_genre_profile(env("ALBUM_ANALYSIS_GENRE_PROFILE", "standard"))
db_class = (env("ALBUM_ANALYSIS_GRADE", "-") or "-").strip() or "-"
db_dr_raw = (env("ALBUM_ANALYSIS_DR_SCORE", "") or "").strip()
db_dr_num = None
try:
    if db_dr_raw:
        db_dr_num = float(db_dr_raw)
except Exception:
    db_dr_num = None
db_dr_int = int(round(db_dr_num)) if db_dr_num is not None else None

dr_tracks_raw = value_data.get("tracks", {}) if isinstance(value_data, dict) else {}
if not isinstance(dr_tracks_raw, dict):
    dr_tracks_raw = {}
value_signature = build_value_signature(dr_tracks_raw, genre_profile)

dr_exact = {}
for name, dr_raw in dr_tracks_raw.items():
    try:
        dr_num = float(dr_raw)
    except Exception:
        continue
    for alias in aliases_for_name(name):
        dr_exact[alias] = dr_num


def match_dr_for_track(track_name: str):
    if callable(track_dr_lookup):
        try:
            dr_val = track_dr_lookup(dr_tracks_raw, track_name)
            if dr_val is not None:
                return float(dr_val)
        except Exception:
            pass
    aliases = aliases_for_name(track_name)
    for alias in aliases:
        if alias in dr_exact:
            return dr_exact[alias]
    for alias in aliases:
        for key, dr_num in dr_exact.items():
            if alias and key and (alias in key or key in alias):
                return dr_num
    return None

album_dir = pathlib.Path(env("ALBUM_ANALYSIS_SOURCE_PATH", ""))
audio_files = list_album_audio_files(album_dir)
cache_file = album_dir / ".audlint_inspect_cache.json" if album_dir else pathlib.Path("")
track_rows = []
table_rows = []
mean_values = []
cache_state = "n/a"
if audio_files:
    fingerprint = files_fingerprint(audio_files)
    cache_data = read_cache(cache_file) if cache_file else {}
    cached_tracks = cache_data.get("tracks", []) if isinstance(cache_data, dict) else []
    cached_table_rows = cache_data.get("table_rows", []) if isinstance(cache_data, dict) else []
    cached_mean = cache_data.get("album_mean_dr") if isinstance(cache_data, dict) else None
    cached_class = cache_data.get("album_class") if isinstance(cache_data, dict) else None
    cache_matcher_version = 0
    if isinstance(cache_data, dict):
        try:
            cache_matcher_version = int(cache_data.get("matcher_version", 0) or 0)
        except Exception:
            cache_matcher_version = 0
    if (
        isinstance(cache_data, dict)
        and cache_matcher_version == TRACK_MATCHER_VERSION
        and cache_data.get("fingerprint") == fingerprint
        and cache_data.get("value_signature") == value_signature
        and str(cache_data.get("genre_profile", "")) == str(genre_profile)
        and isinstance(cached_table_rows, list)
        and len(cached_table_rows) > 0
    ):
        for row in cached_table_rows:
            if isinstance(row, list):
                table_rows.append([str(cell) for cell in row])
        if isinstance(cached_mean, (int, float)):
            mean_values = [float(cached_mean)]
        cache_state = "hit"
    elif (
        isinstance(cache_data, dict)
        and cache_data.get("fingerprint") == fingerprint
        and isinstance(cached_tracks, list)
    ):
        for item in cached_tracks:
            if not isinstance(item, dict):
                continue
            track_rows.append(
                {
                    "track": str(item.get("track", "-")),
                    "genre": str(item.get("genre", genre_profile)),
                    "genre_tag": str(item.get("genre_tag", "-")),
                    "size": str(item.get("size", "-")),
                    "codec": str(item.get("codec", "-")),
                    "bitrate": str(item.get("bitrate", "-")),
                    "profile": str(item.get("profile", "-")),
                }
            )
        cache_state = "miss"
    else:
        track_rows = build_track_meta_rows(audio_files, genre_profile)
        cache_state = "miss"
if not table_rows:
    for base in track_rows:
        full_track_name = str(base.get("track", "-")).replace("\n", " ").replace("\r", " ")
        display_track_name = full_track_name if len(full_track_name) <= 52 else full_track_name[:49] + "..."
        dr_val = match_dr_for_track(full_track_name)
        grade = "-"
        if dr_val is not None:
            grade = grade_from_dr(dr_val, genre_profile)
            mean_values.append(float(dr_val))
        table_rows.append(
            [
                display_track_name,
                str(base.get("genre", genre_profile)),
                str(base.get("genre_tag", "-")),
                str(base.get("size", "-")),
                str(base.get("codec", "-")),
                str(base.get("bitrate", "-")),
                str(base.get("profile", "-")),
                fmt_dr(dr_val),
                grade,
            ]
        )
    if audio_files and cache_file:
        album_mean_for_cache = (sum(mean_values) / len(mean_values)) if mean_values else None
        album_class_for_cache = grade_from_dr(album_mean_for_cache, genre_profile) if album_mean_for_cache is not None else "-"
        payload = {
            "version": 4,
            "matcher_version": TRACK_MATCHER_VERSION,
            "fingerprint": fingerprint,
            "value_signature": value_signature,
            "genre_profile": genre_profile,
            "track_count": len(track_rows),
            "tracks_with_dr": len(mean_values),
            "tracks": track_rows,
            "table_rows": table_rows,
            "album_mean_dr": album_mean_for_cache,
            "album_class": album_class_for_cache,
        }
        write_cache(cache_file, payload)

if table_rows:
    section_heading("Tracks (Recalculated)", "---------------------")
    render_table(
        ["Track Name", "Scoring Preset", "Genre Tag", "Size", "Codec", "Bitrate", "Profile", "DR", "Grade"],
        table_rows,
    )

album_mean_dr = None
album_class = "-"
if mean_values:
    album_mean_dr = sum(mean_values) / len(mean_values)
    album_class = grade_from_dr(album_mean_dr, genre_profile)
album_mean_dr_int = int(round(album_mean_dr)) if album_mean_dr is not None else None
standard_class = "-"
genre_adjustment_note = ""
if album_mean_dr is not None:
    standard_class = grade_from_dr(album_mean_dr, "standard")
    if genre_profile != "standard" and standard_class != album_class:
        dr_label = str(album_mean_dr_int) if album_mean_dr_int is not None else fmt_dr(album_mean_dr)
        genre_adjustment_note = f"album-level scoring preset {genre_profile} changed class {standard_class} -> {album_class} at DR {dr_label}"
score_action_enabled = (
    album_mean_dr_int is not None
    and (
        (db_dr_int is None or album_mean_dr_int != db_dr_int)
        or (album_class != db_class)
    )
)

print_album_metadata_table(
    cache_state,
    cache_file,
    value_status,
    value_err,
    album_mean_dr_int,
    album_class,
    db_dr_int,
    db_class,
    genre_adjustment_note,
)

meta_file_raw = env("ALBUM_ANALYSIS_META_FILE", "").strip()
if meta_file_raw:
    try:
        pathlib.Path(meta_file_raw).write_text(
            json.dumps(
                {
                    "album_mean_dr": album_mean_dr,
                    "album_mean_dr_rounded": album_mean_dr_int,
                    "album_class": album_class,
                    "db_dr_rounded": db_dr_int,
                    "db_class": db_class,
                    "score_action_enabled": bool(score_action_enabled),
                    "genre_profile": genre_profile,
                    "tracks_total": len(table_rows),
                    "tracks_with_dr": len(mean_values),
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
    except Exception:
        pass
PY
  else
    printf 'Album Analysis\n'
    printf '==============\n'
    printf 'ID: %s\n' "$rid"
    printf 'Artist: %s\n' "$artist"
    printf 'Album: %s\n' "$album"
    printf 'Year: %s\n' "$year"
    printf 'Library Path: %s\n' "$source_path"
    printf 'Checked: %s\n' "$checked_label"
    printf '\nPython not available for detailed per-track report (%s).\n' "$PYTHON_BIN"
  fi

  rm -f "$value_json" "$value_err"
}

show_album_analysis_page_for_row_id() {
  local row_id="$1"
  local report_file meta_file
  report_file="$(mktemp "${TMPDIR:-/tmp}/audlint_album_report.XXXXXX" 2>/dev/null || true)"
  meta_file="$(mktemp "${TMPDIR:-/tmp}/audlint_album_meta.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$report_file" || -z "$meta_file" ]]; then
    rm -f "$report_file" "$meta_file"
    ACTION_MESSAGE="Album analysis failed: could not create temporary report."
    return 1
  fi
  if ! print_album_analysis_report_for_row_id "$row_id" "$meta_file" >"$report_file"; then
    rm -f "$report_file" "$meta_file"
    ACTION_MESSAGE="Album analysis failed: row not found (id=$row_id)."
    return 1
  fi

  if [[ "$INTERACTIVE" == "yes" ]]; then
    local choice_file runner_script inspect_choice
    local inspect_menu_right=""
    local meta_line="" _m1="" _m2="" _m3="" _m4="" _m5="" _m6="" score_action_enabled=0
    choice_file="$(mktemp "${TMPDIR:-/tmp}/audlint_album_choice.XXXXXX" 2>/dev/null || true)"
    runner_script="$(mktemp "${TMPDIR:-/tmp}/audlint_album_menu.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$choice_file" || -z "$runner_script" ]]; then
      rm -f "$report_file" "$meta_file" "$choice_file" "$runner_script"
      ACTION_MESSAGE="Album analysis failed: could not create interactive menu files."
      return 1
    fi

    cat >"$runner_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
report_file="$1"
choice_file="$2"
score_enabled="${3:-0}"
cat "$report_file"
choice=""
if IFS= read -r -s -n 1 choice 2>/dev/null; then
  :
elif IFS= read -r -n 1 choice; then
  :
else
  choice="q"
fi
case "$choice" in
Q)
  choice="Q"
  ;;
x | X)
  choice="x"
  ;;
c | C)
  choice="c"
  ;;
s | S)
  choice="s"
  if [[ "$score_enabled" != "1" ]]; then
    choice="q"
  fi
  ;;
q)
  choice="q"
  ;;
*) choice="q" ;;
esac
printf '%s\n' "$choice" >"$choice_file"
EOF
    chmod +x "$runner_script"

    while true; do
      inspect_menu_right='[x Remove] | [Q Compare] | [c Clear Info] | [q Back]'
      score_action_enabled=0
      meta_line="$(inspect_load_score_meta "$meta_file" 2>/dev/null || true)"
      if [[ -n "$meta_line" ]]; then
        IFS=$'\x1f' read -r _m1 _m2 _m3 _m4 _m5 _m6 score_action_enabled <<< "$meta_line"
        [[ "$score_action_enabled" =~ ^[01]$ ]] || score_action_enabled=0
      fi
      if ((score_action_enabled == 1)); then
        inspect_menu_right='[x Remove] | [Q Compare] | [c Clear Info] | [s Score to DB] | [q Back]'
      fi

      if ! VIRTWIN_COMPACT_TOP=1 VIRTWIN_TITLE_PLAIN=1 VIRTWIN_RIGHT_TITLE="$inspect_menu_right" virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "Album View" --no-wait "$runner_script" "$report_file" "$choice_file" "$score_action_enabled"; then
        ACTION_MESSAGE="Album analysis window failed for row id=$row_id."
        rm -f "$report_file" "$meta_file" "$choice_file" "$runner_script"
        return 1
      fi

      inspect_choice="$(tr -d '[:space:]' <"$choice_file" 2>/dev/null || true)"
      case "$inspect_choice" in
      Q)
        inspect_compare_album_for_row_id "$row_id" || true
        continue
        ;;
      x)
        inspect_full_remove_album_for_row_id "$row_id" || true
        ;;
      c)
        inspect_clear_db_cache_and_queue_row_id "$row_id" || true
        ;;
      s)
        inspect_write_score_to_db_for_row_id "$row_id" "$meta_file" || true
        ;;
      q | "")
        ACTION_MESSAGE="Album analysis closed for row id=$row_id."
        ;;
      *)
        ACTION_MESSAGE="Album analysis closed (unsupported choice: $inspect_choice)."
        ;;
      esac
      break
    done
    rm -f "$report_file" "$meta_file" "$choice_file" "$runner_script"
    return 0
  fi

  cat "$report_file"
  rm -f "$report_file" "$meta_file"
  return 0
}

run_album_analysis_for_row_ids() {
  local selected_ids=("$@")
  local valid_ids=()
  local row_id
  for row_id in "${selected_ids[@]}"; do
    [[ "$row_id" =~ ^[0-9]+$ ]] || continue
    valid_ids+=("$row_id")
  done
  if ((${#valid_ids[@]} != 1)); then
    ACTION_MESSAGE="Album analysis requires selecting exactly 1 row."
    return 1
  fi
  show_album_analysis_page_for_row_id "${valid_ids[0]}"
}

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
  local artist="$1"
  local year="$2"
  local album="$3"
  local artist_dir album_dir release_dir index_dir
  artist_dir="$(player_path_component "$artist")"
  album_dir="$(player_path_component "$album")"
  if [[ "$year" =~ ^[0-9]{4}$ ]] && ((year > 0)); then
    release_dir="${year} - ${album_dir}"
  else
    release_dir="$album_dir"
  fi
  index_dir="$(printf '%s' "$artist_dir" | cut -c1 | tr '[:lower:]' '[:upper:]')"
  [[ "$index_dir" =~ ^[A-Z0-9]$ ]] || index_dir="_"
  printf '%s/%s/%s/%s' "$MEDIA_PLAYER_PATH" "$index_dir" "$artist_dir" "$release_dir"
}

player_relative_album_path_from_source() {
  local source_path="$1"
  local root_real source_real rel
  [[ -n "${LIBRARY_ROOT:-}" && -n "$source_path" ]] || return 1
  root_real="$(path_resolve "$LIBRARY_ROOT" 2>/dev/null || printf '%s' "$LIBRARY_ROOT")"
  source_real="$(path_resolve "$source_path" 2>/dev/null || printf '%s' "$source_path")"
  case "$source_real" in
  "$root_real"/*) ;;
  *) return 1 ;;
  esac
  rel="${source_real#"$root_real"/}"
  [[ -n "$rel" ]] || return 1
  printf '%s' "$rel"
}

player_album_dest_dir_for_source() {
  local source_path="$1"
  local artist="$2"
  local year="$3"
  local album="$4"
  local rel_path=""
  rel_path="$(player_relative_album_path_from_source "$source_path" || true)"
  if [[ -n "$rel_path" ]]; then
    printf '%s/%s' "$MEDIA_PLAYER_PATH" "$rel_path"
    return 0
  fi
  player_album_dest_dir "$artist" "$year" "$album"
}

transfer_first_audio_file() {
  local source_path="$1"
  local files=()
  local f

  # Flat scan first (fast, covers the common case).
  audio_collect_files "$source_path" files
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    printf '%s' "$f"
    return 0
  done

  # Recursive fallback for nested layouts.
  # shellcheck disable=SC2046
  while IFS= read -r -d '' f; do
    printf '%s' "$f"
    return 0
  done < <(find "$source_path" -type f \( $(audio_find_iname_args) \) -print0 2>/dev/null)

  return 1
}

transfer_year_from_tag_dump() {
  local tag_dump="$1"
  local -A years_by_key=()
  local line key value norm_key

  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#TAG:}"
    key="${key#tag:}"
    key="$(lower_text "$key")"
    norm_key="$(printf '%s' "$key" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
    [[ -n "$norm_key" ]] || continue
    if [[ "$value" =~ ([12][0-9]{3}) ]]; then
      years_by_key["$norm_key"]="${BASH_REMATCH[1]}"
    fi
  done <<< "$tag_dump"

  local -a preferred_keys=(
    original_year_release
    original_release_year
    originalyear_release
    originalyear
    original_year
    originalreleaseyear
    original_release_date
    originaldate
    original_date
    tdor
    tory
    original_release
  )
  local key_name
  for key_name in "${preferred_keys[@]}"; do
    if [[ -n "${years_by_key[$key_name]:-}" ]]; then
      printf '%s' "${years_by_key[$key_name]}"
      return 0
    fi
  done

  for key_name in "${!years_by_key[@]}"; do
    if [[ "$key_name" == *original* ]] && ([[ "$key_name" == *year* ]] || [[ "$key_name" == *date* ]]); then
      printf '%s' "${years_by_key[$key_name]}"
      return 0
    fi
  done

  return 1
}

transfer_year_from_tag_dump_generic() {
  local tag_dump="$1"
  local line key value norm_key
  local -a generic_keys=(release_year releaseyear release_date releasedate date year)
  local key_name

  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#TAG:}"
    key="${key#tag:}"
    key="$(lower_text "$key")"
    norm_key="$(printf '%s' "$key" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
    [[ -n "$norm_key" ]] || continue
    for key_name in "${generic_keys[@]}"; do
      if [[ "$norm_key" == "$key_name" ]] && [[ "$value" =~ ([12][0-9]{3}) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
      fi
    done
  done <<< "$tag_dump"

  return 1
}

transfer_year_from_source_path() {
  local source_path="$1"
  local base_name
  base_name="$(basename "$source_path")"

  if [[ "$base_name" =~ ^([12][0-9]{3})[[:space:]_.-] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$base_name" =~ ^\[([12][0-9]{3})\] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$base_name" =~ ^([12][0-9]{3})$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

transfer_year_for_source() {
  local source_path="$1"
  local fallback_year="$2"
  local resolved_year="0"

  if [[ "$fallback_year" =~ ^[12][0-9]{3}$ ]]; then
    resolved_year="$fallback_year"
  fi

  local audio_file=""
  local tag_dump=""
  local tag_year=""
  local generic_tag_year=""
  if has_bin ffprobe; then
    audio_file="$(transfer_first_audio_file "$source_path" || true)"
    if [[ -n "$audio_file" ]]; then
      if has_bin timeout; then
        tag_dump="$(timeout 5 ffprobe -v error -show_entries format_tags -of default=noprint_wrappers=1 "$audio_file" </dev/null 2>/dev/null || true)"
      else
        tag_dump="$(ffprobe -v error -show_entries format_tags -of default=noprint_wrappers=1 "$audio_file" </dev/null 2>/dev/null || true)"
      fi
      tag_year="$(transfer_year_from_tag_dump "$tag_dump" || true)"
      if [[ "$tag_year" =~ ^[12][0-9]{3}$ ]]; then
        printf '%s' "$tag_year"
        return 0
      fi
    fi
  fi

  local path_year=""
  path_year="$(transfer_year_from_source_path "$source_path" || true)"
  if [[ "$path_year" =~ ^[12][0-9]{3}$ ]]; then
    printf '%s' "$path_year"
    return 0
  fi

  generic_tag_year="$(transfer_year_from_tag_dump_generic "$tag_dump" || true)"
  if [[ "$generic_tag_year" =~ ^[12][0-9]{3}$ ]]; then
    printf '%s' "$generic_tag_year"
    return 0
  fi

  printf '%s' "$resolved_year"
}

transfer_size_included_for_file() {
  local file_path="$1"
  local base_name lowered
  base_name="$(basename "$file_path")"
  case "$base_name" in
  .audlint_inspect_cache.json | .any2flac_truepeak_cache.tsv | .dff2flac_truepeak_cache.tsv | .sox_album_done | .sox_album_profile)
    return 1
    ;;
  esac

  lowered="$(lower_text "$base_name")"
  case "$lowered" in
  cover.jpg | cover.jpeg)
    return 0
    ;;
  *.jpg | *.jpeg | *.png | *.gif | *.webp | *.bmp | *.tif | *.tiff)
    return 1
    ;;
  esac

  return 0
}

transfer_payload_size_bytes_for_dir() {
  local dir_path="$1"
  local total_bytes=0
  local file_path file_bytes

  [[ -d "$dir_path" ]] || {
    printf '0'
    return 0
  }

  while IFS= read -r -d '' file_path; do
    transfer_size_included_for_file "$file_path" || continue
    file_bytes="$(stat_size_bytes "$file_path" 2>/dev/null || true)"
    [[ "$file_bytes" =~ ^[0-9]+$ ]] || continue
    total_bytes=$((total_bytes + file_bytes))
  done < <(find "$dir_path" -type f -print0 2>/dev/null)

  printf '%s' "$total_bytes"
}

transfer_payload_total_size_bytes_for_manifest() {
  local manifest_file="$1"
  local total_bytes=0
  local artist album year source_path dest_dir dir_bytes

  [[ -f "$manifest_file" ]] || {
    printf '0'
    return 0
  }

  while IFS=$'\x1f' read -r artist album year source_path dest_dir; do
    [[ -n "$source_path" ]] || continue
    dir_bytes="$(transfer_payload_size_bytes_for_dir "$source_path" || true)"
    [[ "$dir_bytes" =~ ^[0-9]+$ ]] || dir_bytes=0
    total_bytes=$((total_bytes + dir_bytes))
  done < "$manifest_file"

  printf '%s' "$total_bytes"
}

transfer_human_size_label() {
  local bytes="${1:-0}"
  local -a units=("b" "Kb" "Mb" "Gb" "Tb")
  local unit_idx=0
  local unit_size=1
  local whole frac

  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

  while ((bytes >= unit_size * 1024)) && ((unit_idx < ${#units[@]} - 1)); do
    unit_size=$((unit_size * 1024))
    unit_idx=$((unit_idx + 1))
  done

  if ((unit_idx == 0)); then
    printf '%s%s' "$bytes" "${units[$unit_idx]}"
    return 0
  fi

  whole=$((bytes / unit_size))
  frac=$((((bytes % unit_size) * 10 + unit_size / 2) / unit_size))
  if ((frac >= 10)); then
    whole=$((whole + 1))
    frac=0
  fi

  if ((whole >= 100 || frac == 0)); then
    printf '%s%s' "$whole" "${units[$unit_idx]}"
  else
    printf '%s.%s%s' "$whole" "$frac" "${units[$unit_idx]}"
  fi
}

run_transfer_for_row_ids() {
  local selected_ids=("$@")
  local transfer_log="${LIBRARY_BROWSER_TRANSFER_LOG:-/tmp/library_browser_transfer.last.log}"
  : >"$transfer_log" 2>/dev/null || transfer_log=""
  if [[ -n "$transfer_log" ]]; then
    printf '[%s] transfer start ids=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${selected_ids[*]:-<none>}" >>"$transfer_log" 2>/dev/null || true
  fi
  if ! show_transfer_action; then
    ACTION_MESSAGE="Transfer unavailable: AUDL_MEDIA_PLAYER_PATH is missing or not writable."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: AUDL_MEDIA_PLAYER_PATH unavailable/unwritable (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${MEDIA_PLAYER_PATH:-<empty>}" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if ! command_ref_available "$RSYNC_BIN"; then
    ACTION_MESSAGE="Transfer unavailable: rsync not found ($RSYNC_BIN)."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: rsync unavailable (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RSYNC_BIN" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if ! command_ref_available "$SYNC_BIN"; then
    ACTION_MESSAGE="Transfer unavailable: sync command not found ($SYNC_BIN)."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: sync unavailable (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SYNC_BIN" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if ((${#selected_ids[@]} == 0)); then
    ACTION_MESSAGE="No rows selected for transfer."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: no row ids selected\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi

  local manifest_file
  manifest_file="$(mktemp "${TMPDIR:-/tmp}/library_browser_transfer_manifest.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$manifest_file" ]]; then
    ACTION_MESSAGE="Failed to create transfer manifest."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: failed to create manifest\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if [[ -n "$transfer_log" ]]; then
    printf '[%s] manifest=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$manifest_file" >>"$transfer_log" 2>/dev/null || true
  fi

  local row_id row artist album year source_path
  for row_id in "${selected_ids[@]}"; do
    [[ "$row_id" =~ ^[0-9]+$ ]] || continue
    row="$(
      sqlite3 -separator $'\t' -noheader "$DB_PATH" \
        "SELECT
           artist,
           album,
           COALESCE(year_int,0),
           COALESCE(source_path,'')
         FROM album_quality
         WHERE id=$row_id
         LIMIT 1;" 2>/dev/null || true
    )"
    if [[ -z "$row" ]]; then
      rm -f "$manifest_file"
      ACTION_MESSAGE="Transfer failed: row not found (id=$row_id)."
      if [[ -n "$transfer_log" ]]; then
        printf '[%s] abort: row not found id=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$row_id" >>"$transfer_log" 2>/dev/null || true
      fi
      return 1
    fi
    IFS=$'\t' read -r artist album year source_path <<< "$row"
    if ! transfer_manifest_append_entry "$manifest_file" "$transfer_log" "$row_id" "$artist" "$album" "$year" "$source_path"; then
      rm -f "$manifest_file"
      return 1
    fi
  done

  if ! run_transfer_manifest "$manifest_file" "$transfer_log" "${#selected_ids[@]}"; then
    return 1
  fi
  ACTION_MESSAGE="Transfer completed for ${#selected_ids[@]} album(s)."
  return 0
}

transfer_manifest_append_entry() {
  local manifest_file="$1"
  local transfer_log="$2"
  local row_id="$3"
  local artist="$4"
  local album="$5"
  local year="$6"
  local source_path="$7"
  local dest_dir transfer_year
  local resolved_source_row=""
  local resolved_source_id=""
  local resolved_source_path=""

  resolved_source_row="$(find_transfer_source_row "$row_id" "$artist" "$album" "$year" "$source_path" || true)"
  if [[ -n "$resolved_source_row" ]]; then
    IFS=$'\t' read -r resolved_source_id resolved_source_path <<< "$resolved_source_row"
  fi
  if [[ -z "$resolved_source_path" || ! -d "$resolved_source_path" ]]; then
    ACTION_MESSAGE="Transfer failed: source path unavailable for $artist - $album."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: source missing for id=%s artist=%s album=%s path=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$row_id" "$artist" "$album" "${source_path:-<empty>}" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if [[ -n "$transfer_log" && -n "$source_path" && "$resolved_source_path" != "$source_path" ]]; then
    printf '[%s] fallback: row id=%s resolved via row id=%s path=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$row_id" "${resolved_source_id:-<unknown>}" "$resolved_source_path" >>"$transfer_log" 2>/dev/null || true
  fi
  source_path="$resolved_source_path"

  transfer_year="$(transfer_year_for_source "$source_path" "$year")"
  [[ "$transfer_year" =~ ^[12][0-9]{3}$ ]] || transfer_year="$year"
  dest_dir="$(player_album_dest_dir_for_source "$source_path" "$artist" "$transfer_year" "$album")"
  if [[ -n "$transfer_log" ]]; then
    printf '[%s] row id=%s source=%s year_db=%s year_transfer=%s dest=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$row_id" "$source_path" "$year" "$transfer_year" "$dest_dir" >>"$transfer_log" 2>/dev/null || true
  fi
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$artist" "$album" "$transfer_year" "$source_path" "$dest_dir" >>"$manifest_file"
}

find_transfer_source_row() {
  local row_id="$1"
  local artist="$2"
  local album="$3"
  local year="$4"
  local source_path="$5"
  local album_lc artist_lc year_sql
  local candidate_id candidate_artist _candidate_album candidate_path

  if [[ -n "$source_path" && -d "$source_path" ]]; then
    printf '%s\t%s' "$row_id" "$source_path"
    return 0
  fi

  album_lc="$(norm_lc "$album")"
  artist_lc="$(norm_lc "$artist")"
  year_sql="$(sql_num_or_null "$year")"
  [[ "$year_sql" == "NULL" ]] && year_sql=0

  while IFS=$'\t' read -r candidate_id candidate_artist _candidate_album candidate_path; do
    [[ -n "$candidate_path" && -d "$candidate_path" ]] || continue
    printf '%s\t%s' "$candidate_id" "$candidate_path"
    return 0
  done < <(
    sqlite3 -separator $'\t' -noheader "$DB_PATH" \
      "SELECT
         id,
         COALESCE(artist,''),
         COALESCE(album,''),
         COALESCE(source_path,'')
       FROM album_quality
       WHERE album_lc='$(sql_escape "$album_lc")'
         AND year_int=$year_sql
         AND COALESCE(source_path,'') <> ''
       ORDER BY
         CASE WHEN id=$row_id THEN 0 ELSE 1 END ASC,
         CASE WHEN artist_lc='$(sql_escape "$artist_lc")' THEN 0 ELSE 1 END ASC,
         id ASC;" 2>/dev/null || true
  )

  return 1
}

run_transfer_manifest() {
  local manifest_file="$1"
  local transfer_log="$2"
  local selected_count="$3"
  local total_size_bytes total_size_label
  local runner_script
  total_size_bytes="$(transfer_payload_total_size_bytes_for_manifest "$manifest_file" || true)"
  [[ "$total_size_bytes" =~ ^[0-9]+$ ]] || total_size_bytes=0
  total_size_label="$(transfer_human_size_label "$total_size_bytes")"
  runner_script="$(mktemp "${TMPDIR:-/tmp}/library_browser_transfer.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$runner_script" ]]; then
    rm -f "$manifest_file"
    ACTION_MESSAGE="Failed to create transfer runner script."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: failed to create runner script\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  cat >"$runner_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
manifest_file="$1"
rsync_bin="$2"
sync_bin="$3"
player_path="$4"
log_file="${5:-}"
total_size_label="${6:-}"
title_row="${VIRTWIN_TITLE_ROW:-}"
term_cols="${VIRTWIN_TERM_COLS:-0}"
log_note() {
  local msg="$1"
  [[ -n "$log_file" ]] || return 0
  printf '%s\n' "$msg" >>"$log_file" 2>/dev/null || true
}

virtwin_status_set() {
  local idx="$1"
  local total="$2"
  local artist="$3"
  local year="$4"
  local album="$5"
  local action="${6:-transferring...}"
  local size_suffix=""
  [[ "$title_row" =~ ^[0-9]+$ ]] || return 0
  [[ "$term_cols" =~ ^[0-9]+$ ]] || return 0
  ((term_cols > 0)) || return 0
  if [[ -n "$total_size_label" ]]; then
    size_suffix=" | transferring ${total_size_label}..."
    action=""
  fi
  local text="${idx} of ${total} | ${artist} - ${year} - ${album}"
  if [[ -n "$action" ]]; then
    text+=" | ${action}"
  fi
  text+="${size_suffix}"
  text="${text//$'\n'/ }"
  text="${text//$'\r'/ }"
  local max_len="$term_cols"
  if ((max_len < 8)); then
    return 0
  fi
  if ((${#text} > max_len)); then
    text="${text:0:max_len}"
  fi
  local col=$((term_cols - ${#text} + 1))
  ((col < 1)) && col=1
  local rendered="$text"
  if [[ -z "${NO_COLOR:-}" ]]; then
    local part1 part2
    part1="${idx} of ${total}"
    part2="${artist} - ${year} - ${album}"
    rendered=""
    rendered+=$'\033[1;38;2;77;163;255m'"$part1"$'\033[0m'
    rendered+=$'\033[1;38;2;111;141;255m | \033[0m'
    rendered+=$'\033[1;38;2;142;109;245m'"$part2"$'\033[0m'
    if [[ -n "$action" ]]; then
      rendered+=$'\033[1;38;2;179;140;255m | \033[0m'
      rendered+=$'\033[1;38;2;208;179;255m'"$action"$'\033[0m'
    fi
    if [[ -n "$size_suffix" ]]; then
      rendered+=$'\033[1;38;2;179;140;255m | \033[0m'
      rendered+=$'\033[1;38;2;208;179;255m'"transferring ${total_size_label}..."$'\033[0m'
    fi
  fi
  # Use DEC save/restore here; CSI s/u leaves duplicated title rows in some
  # terminal/tab environments when live status updates are emitted.
  printf '\0337\033[%s;1H\033[K\033[%s;%sH%s\0338' "$title_row" "$title_row" "$col" "$rendered"
}

printf 'Media player path: %s\n\n' "$player_path"
rsync_args=(
  -av
  --delete
  --itemize-changes
  --exclude='.audlint_inspect_cache.json'
  --exclude='.any2flac_truepeak_cache.tsv'
  --exclude='.dff2flac_truepeak_cache.tsv'
  --exclude='.sox_album_done'
  --exclude='.sox_album_profile'
  --include='[cC][oO][vV][eE][rR].[jJ][pP][gG]'
  --include='[cC][oO][vV][eE][rR].[jJ][pP][eE][gG]'
  --exclude='*.[jJ][pP][gG]'
  --exclude='*.[jJ][pP][eE][gG]'
  --exclude='*.[pP][nN][gG]'
  --exclude='*.[gG][iI][fF]'
  --exclude='*.[wW][eE][bB][pP]'
  --exclude='*.[bB][mM][pP]'
  --exclude='*.[tT][iI][fF]'
  --exclude='*.[tT][iI][fF][fF]'
)
if "$rsync_bin" --help 2>/dev/null | grep -q -- '--info'; then
  rsync_args+=(--info=progress2,name1)
  printf 'rsync mode: verbose + itemize + progress2\n\n'
elif "$rsync_bin" --help 2>/dev/null | grep -q -- '--progress'; then
  rsync_args+=(--progress)
  printf 'rsync mode: verbose + itemize + progress\n\n'
else
  printf 'rsync mode: verbose + itemize (no progress option available)\n\n'
fi
if "$rsync_bin" --help 2>/dev/null | grep -q -- '--outbuf'; then
  rsync_args+=(--outbuf=L)
fi
log_note "runner rsync args: ${rsync_args[*]}"
total_count="$(awk 'END { print NR+0 }' "$manifest_file" 2>/dev/null || echo 0)"
[[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0
album_count=0
while IFS=$'\x1f' read -r artist album year source_path dest_dir; do
  [[ -n "$source_path" ]] || continue
  album_count=$((album_count + 1))
  virtwin_status_set "$album_count" "$total_count" "$artist" "$year" "$album" "transferring..."
  printf '[%s] %s - %s (%s)\n' "$album_count" "$artist" "$album" "$year"
  printf 'source: %s\n' "$source_path"
  printf 'dest:   %s\n' "$dest_dir"
  mkdir -p "$(dirname "$dest_dir")"
  "$rsync_bin" "${rsync_args[@]}" "$source_path"/ "$dest_dir"/
  printf '\n'
done < "$manifest_file"

printf 'Running sync...\n'
"$sync_bin"
printf 'Transfer completed: %s album(s).\n' "$album_count"
EOF
  chmod +x "$runner_script"

  if [[ -n "$transfer_log" ]]; then
    printf '[%s] runner=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$runner_script" >>"$transfer_log" 2>/dev/null || true
    printf '[%s] total_size_bytes=%s total_size_label=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$total_size_bytes" "$total_size_label" >>"$transfer_log" 2>/dev/null || true
  fi

  local transfer_ok=0
  local transfer_rc=0
  local first_title=""
  if IFS=$'\x1f' read -r first_artist first_album first_year _first_source _first_dest <"$manifest_file"; then
    if [[ -n "${first_artist:-}" ]]; then
      first_title="1 of ${selected_count} | ${first_artist} - ${first_year} - ${first_album} | transferring ${total_size_label}..."
    fi
  fi
  if VIRTWIN_RIGHT_TITLE="$first_title" virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "transfer-player" \
    "$runner_script" "$manifest_file" "$RSYNC_BIN" "$SYNC_BIN" "$MEDIA_PLAYER_PATH" "$transfer_log" "$total_size_label"; then
    transfer_ok=1
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] transfer rc=0\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$transfer_log" 2>/dev/null || true
    fi
  else
    transfer_rc=$?
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] transfer rc=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$transfer_rc" >>"$transfer_log" 2>/dev/null || true
    fi
  fi
  rm -f "$runner_script" "$manifest_file"

  if ((transfer_ok == 1)); then
    return 0
  fi
  if [[ -n "$transfer_log" && -s "$transfer_log" ]]; then
    ACTION_MESSAGE="Transfer failed (exit $transfer_rc). Log: $transfer_log"
  else
    ACTION_MESSAGE="Transfer failed (exit $transfer_rc)."
  fi
  return 1
}

run_transfer_for_snapshot_entries() {
  local snapshot_entries=("$@")
  local transfer_log="${LIBRARY_BROWSER_TRANSFER_LOG:-/tmp/library_browser_transfer.last.log}"
  local start_ids="<none>"
  local entry row_id artist album year source_path
  : >"$transfer_log" 2>/dev/null || transfer_log=""
  if ((${#snapshot_entries[@]} > 0)); then
    start_ids=""
    for entry in "${snapshot_entries[@]}"; do
      IFS=$'\x1f' read -r row_id artist album year source_path <<< "$entry"
      [[ -n "$row_id" ]] || continue
      if [[ -n "$start_ids" ]]; then
        start_ids+=" "
      fi
      start_ids+="$row_id"
    done
    [[ -n "$start_ids" ]] || start_ids="<none>"
  fi
  if [[ -n "$transfer_log" ]]; then
    printf '[%s] transfer start ids=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$start_ids" >>"$transfer_log" 2>/dev/null || true
  fi
  if ! show_transfer_action; then
    ACTION_MESSAGE="Transfer unavailable: AUDL_MEDIA_PLAYER_PATH is missing or not writable."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: AUDL_MEDIA_PLAYER_PATH unavailable/unwritable (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${MEDIA_PLAYER_PATH:-<empty>}" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if ! command_ref_available "$RSYNC_BIN"; then
    ACTION_MESSAGE="Transfer unavailable: rsync not found ($RSYNC_BIN)."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: rsync unavailable (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RSYNC_BIN" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if ! command_ref_available "$SYNC_BIN"; then
    ACTION_MESSAGE="Transfer unavailable: sync command not found ($SYNC_BIN)."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: sync unavailable (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SYNC_BIN" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if ((${#snapshot_entries[@]} == 0)); then
    ACTION_MESSAGE="No rows selected for transfer."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: no row ids selected\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi

  local manifest_file
  manifest_file="$(mktemp "${TMPDIR:-/tmp}/library_browser_transfer_manifest.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$manifest_file" ]]; then
    ACTION_MESSAGE="Failed to create transfer manifest."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: failed to create manifest\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$transfer_log" 2>/dev/null || true
    fi
    return 1
  fi
  if [[ -n "$transfer_log" ]]; then
    printf '[%s] manifest=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$manifest_file" >>"$transfer_log" 2>/dev/null || true
  fi

  for entry in "${snapshot_entries[@]}"; do
    IFS=$'\x1f' read -r row_id artist album year source_path <<< "$entry"
    if ! transfer_manifest_append_entry "$manifest_file" "$transfer_log" "$row_id" "$artist" "$album" "$year" "$source_path"; then
      rm -f "$manifest_file"
      return 1
    fi
  done

  if ! run_transfer_manifest "$manifest_file" "$transfer_log" "${#snapshot_entries[@]}"; then
    return 1
  fi
  ACTION_MESSAGE="Transfer completed for ${#snapshot_entries[@]} album(s)."
  return 0
}

mark_album_has_lyrics_for_row_id() {
  local row_id="$1"
  [[ "$row_id" =~ ^[0-9]+$ ]] || return 1
  sqlite3 "$DB_PATH" "UPDATE album_quality SET has_lyrics=1 WHERE id=$row_id;" >/dev/null 2>&1
}

run_lyrics_seek_for_row_ids() {
  local selected_ids=("$@")
  if [[ "$HAS_COL_HAS_LYRICS" != "1" ]]; then
    ACTION_MESSAGE="Lyrics marking unavailable: has_lyrics column missing."
    return 1
  fi
  if ! show_lyrics_action; then
    ACTION_MESSAGE="Lyrics unavailable: lyrics_seek.sh not found ($LYRICS_SEEK_BIN)."
    return 1
  fi
  if ((${#selected_ids[@]} == 0)); then
    ACTION_MESSAGE="No rows selected for lyrics."
    return 1
  fi

  local manifest_file success_file
  manifest_file="$(mktemp "${TMPDIR:-/tmp}/library_browser_lyrics_manifest.XXXXXX" 2>/dev/null || true)"
  success_file="$(mktemp "${TMPDIR:-/tmp}/library_browser_lyrics_success.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$manifest_file" || -z "$success_file" ]]; then
    rm -f "$manifest_file" "$success_file"
    ACTION_MESSAGE="Failed to create lyrics temporary files."
    return 1
  fi

  local row_id row artist album year source_path
  for row_id in "${selected_ids[@]}"; do
    [[ "$row_id" =~ ^[0-9]+$ ]] || continue
    row="$(
      sqlite3 -separator $'\t' -noheader "$DB_PATH" \
        "SELECT
           artist,
           album,
           COALESCE(year_int,0),
           COALESCE(source_path,'')
         FROM album_quality
         WHERE id=$row_id
         LIMIT 1;" 2>/dev/null || true
    )"
    if [[ -z "$row" ]]; then
      rm -f "$manifest_file" "$success_file"
      ACTION_MESSAGE="Lyrics failed: row not found (id=$row_id)."
      return 1
    fi
    IFS=$'\t' read -r artist album year source_path <<< "$row"
    if [[ -z "$source_path" || ! -d "$source_path" ]]; then
      rm -f "$manifest_file" "$success_file"
      ACTION_MESSAGE="Lyrics failed: source path unavailable for $artist - $album."
      return 1
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$row_id" "$artist" "$album" "$year" "$source_path" >>"$manifest_file"
  done

  local runner_script
  runner_script="$(mktemp "${TMPDIR:-/tmp}/library_browser_lyrics.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$runner_script" ]]; then
    rm -f "$manifest_file" "$success_file"
    ACTION_MESSAGE="Failed to create lyrics runner script."
    return 1
  fi
  cat >"$runner_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
manifest_file="$1"
lyrics_seek_bin="$2"
success_file="$3"
title_row="${VIRTWIN_TITLE_ROW:-}"
term_cols="${VIRTWIN_TERM_COLS:-0}"
total=0
ok=0
failed=0
total_count="$(awk 'END { print NR+0 }' "$manifest_file" 2>/dev/null || echo 0)"
[[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0

virtwin_status_set() {
  local idx="$1"
  local total_items="$2"
  local artist="$3"
  local year="$4"
  local album="$5"
  local action="${6:-lyrics...}"
  [[ "$title_row" =~ ^[0-9]+$ ]] || return 0
  [[ "$term_cols" =~ ^[0-9]+$ ]] || return 0
  ((term_cols > 0)) || return 0
  local text="${idx} of ${total_items} | ${artist} - ${year} - ${album} | ${action}"
  text="${text//$'\n'/ }"
  text="${text//$'\r'/ }"
  if ((${#text} > term_cols)); then
    text="${text:0:term_cols}"
  fi
  local col=$((term_cols - ${#text} + 1))
  ((col < 1)) && col=1
  local rendered="$text"
  if [[ -z "${NO_COLOR:-}" ]]; then
    local part1 part2 part3
    part1="${idx} of ${total_items}"
    part2="${artist} - ${year} - ${album}"
    part3="${action}"
    rendered=$'\033[1;38;2;77;163;255m'"$part1"$'\033[0m'
    rendered+=$'\033[1;38;2;111;141;255m | \033[0m'
    rendered+=$'\033[1;38;2;142;109;245m'"$part2"$'\033[0m'
    rendered+=$'\033[1;38;2;179;140;255m | \033[0m'
    rendered+=$'\033[1;38;2;208;179;255m'"$part3"$'\033[0m'
  fi
  # Use DEC save/restore here; CSI s/u leaves duplicated title rows in some
  # terminal/tab environments when live status updates are emitted.
  printf '\0337\033[%s;1H\033[K\033[%s;%sH%s\0338' "$title_row" "$title_row" "$col" "$rendered"
}

while IFS=$'\x1f' read -r row_id artist album year source_path; do
  [[ -n "$row_id" ]] || continue
  total=$((total + 1))
  virtwin_status_set "$total" "$total_count" "$artist" "$year" "$album" "lyrics..."
  printf '[%s] %s - %s (%s)\n' "$total" "$artist" "$album" "$year"
  printf 'path: %s\n' "$source_path"
  if (cd "$source_path" && "$lyrics_seek_bin" -y); then
    ok=$((ok + 1))
    printf '%s\n' "$row_id" >>"$success_file"
    printf 'result: ok\n\n'
  else
    failed=$((failed + 1))
    printf 'result: failed\n\n'
  fi
done < "$manifest_file"
printf 'Lyrics batch complete: total=%s ok=%s failed=%s\n' "$total" "$ok" "$failed"
if ((failed > 0)); then
  exit 1
fi
exit 0
EOF
  chmod +x "$runner_script"

  local lyrics_ok=0
  local lyrics_rc=0
  local first_title=""
  if IFS=$'\x1f' read -r _first_row_id first_artist first_album first_year _first_source <"$manifest_file"; then
    if [[ -n "${first_artist:-}" ]]; then
      first_title="1 of ${#selected_ids[@]} | ${first_artist} - ${first_year} - ${first_album} | lyrics..."
    fi
  fi
  if VIRTWIN_RIGHT_TITLE="$first_title" virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "lyrics-seek" \
    "$runner_script" "$manifest_file" "$LYRICS_SEEK_BIN" "$success_file"; then
    lyrics_ok=1
  else
    lyrics_rc=$?
  fi

  local success_count=0
  while IFS= read -r row_id; do
    [[ "$row_id" =~ ^[0-9]+$ ]] || continue
    if mark_album_has_lyrics_for_row_id "$row_id"; then
      success_count=$((success_count + 1))
    fi
  done < "$success_file"
  rm -f "$runner_script" "$manifest_file" "$success_file"
  invalidate_count_cache

  if ((lyrics_ok == 1)); then
    ACTION_MESSAGE="Lyrics completed for ${success_count} album(s)."
    return 0
  fi
  ACTION_MESSAGE="Lyrics finished with failures (exit $lyrics_rc); marked ${success_count} album(s)."
  return 1
}

run_flac_recode_for_row_id() {
  local row_id="$1"
  local wait_for_key="${2:-1}"
  local batch_index="${3:-1}"
  local batch_total="${4:-1}"
  local mode="${5:-run}"
  [[ "$row_id" =~ ^[0-9]+$ ]] || {
    ACTION_MESSAGE="Invalid row id: $row_id"
    return 1
  }

  local row row_artist row_album row_year row_source_path row_recode row_needs_recode row_needs_replace
  local row_codec row_current_quality row_recode_source_profile row_last_recoded
  row="$(
    sqlite3 -separator $'\t' -noheader "$DB_PATH" \
      "SELECT
         artist,
         album,
         COALESCE(year_int,0),
         COALESCE(source_path,''),
         COALESCE(recode_recommendation,''),
         COALESCE(needs_recode,0),
         COALESCE(needs_replacement,0),
         COALESCE(codec,''),
         COALESCE(current_quality,''),
         COALESCE(recode_source_profile,''),
         COALESCE(last_recoded_at,0)
       FROM album_quality
       WHERE id=$row_id
       LIMIT 1;" 2>/dev/null || true
  )"
  if [[ -z "$row" ]]; then
    ACTION_MESSAGE="Row not found for FLAC action."
    return 1
  fi
  IFS=$'\t' read -r row_artist row_album row_year row_source_path row_recode row_needs_recode row_needs_replace row_codec row_current_quality row_recode_source_profile row_last_recoded <<< "$row"
  [[ "$row_needs_recode" =~ ^[0-9]+$ ]] || row_needs_recode=0
  [[ "$row_needs_replace" =~ ^[0-9]+$ ]] || row_needs_replace=0
  local dts_replace_actionable=0
  if ((row_needs_replace == 1)) && is_dts_codec_value "$row_codec"; then
    dts_replace_actionable=1
  fi
  if ((row_needs_recode != 1 && dts_replace_actionable != 1)); then
    ACTION_MESSAGE="Selected row is not actionable (needs_recode != Y and no DTS replacement)."
    return 1
  fi
  [[ "$row_last_recoded" =~ ^[0-9]+$ ]] || row_last_recoded=0
  if ((HAS_COL_LAST_RECODED_AT == 1)) && ((row_last_recoded > 0)); then
    _recode_date="$(awk -v t="$row_last_recoded" 'BEGIN{printf strftime("%Y-%m-%d",t+0)}')"
    ACTION_MESSAGE="Already recoded on ${_recode_date} (green star). Clear last_recoded_at in DB to re-encode."
    return 1
  fi
  if [[ -z "$row_source_path" || ! -d "$row_source_path" ]]; then
    ACTION_MESSAGE="Album path not found for selected row: $row_source_path"
    return 1
  fi
  local target_profile allow_lossy_source=0
  target_profile="$(resolve_recode_target_profile "$row_recode" "$row_codec" "$row_current_quality" "$row_recode_source_profile" "$row_needs_replace" || true)"
  if [[ -z "$target_profile" ]]; then
    ACTION_MESSAGE="Unable to determine target profile for recode recommendation."
    return 1
  fi
  if ((dts_replace_actionable == 1 && row_needs_recode != 1)); then
    allow_lossy_source=1
  fi
  if [[ ! -x "$ANY2FLAC_BIN" ]]; then
    ACTION_MESSAGE="any2flac.sh not found at $ANY2FLAC_BIN"
    return 1
  fi
  if [[ "$mode" == "check" ]]; then
    return 0
  fi

  local runner_script
  runner_script="$(mktemp "${TMPDIR:-/tmp}/library_browser_recode.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$runner_script" ]]; then
    ACTION_MESSAGE="Failed to create temporary runner script."
    return 1
  fi
  cat >"$runner_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source_path="$1"
target_profile="$2"
any2flac_bin="$3"
artist="$4"
album="$5"
year="$6"
batch_index="${7:-1}"
batch_total="${8:-1}"
allow_lossy_source="${9:-0}"
title_row="${VIRTWIN_TITLE_ROW:-}"
term_cols="${VIRTWIN_TERM_COLS:-0}"

virtwin_status_set() {
  local action="$1"
  if [[ ! "$title_row" =~ ^[0-9]+$ || ! "$term_cols" =~ ^[0-9]+$ ]] || ((term_cols <= 0)); then
    return 0
  fi
  status_text="${batch_index} of ${batch_total} | ${artist} - ${year} - ${album} | ${action}"
  status_text="${status_text//$'\n'/ }"
  status_text="${status_text//$'\r'/ }"
  if ((${#status_text} > term_cols)); then
    status_text="${status_text:0:term_cols}"
  fi
  status_col=$((term_cols - ${#status_text} + 1))
  ((status_col < 1)) && status_col=1
  rendered_status="$status_text"
  if [[ -z "${NO_COLOR:-}" ]]; then
    local part1 part2 part3
    part1="${batch_index} of ${batch_total}"
    part2="${artist} - ${year} - ${album}"
    part3="${action}"
    rendered_status=$'\033[1;38;2;77;163;255m'"$part1"$'\033[0m'
    rendered_status+=$'\033[1;38;2;111;141;255m | \033[0m'
    rendered_status+=$'\033[1;38;2;142;109;245m'"$part2"$'\033[0m'
    rendered_status+=$'\033[1;38;2;179;140;255m | \033[0m'
    rendered_status+=$'\033[1;38;2;208;179;255m'"$part3"$'\033[0m'
  fi
  # Use DEC save/restore here; CSI s/u leaves duplicated title rows in some
  # terminal/tab environments when live status updates are emitted.
  printf '\0337\033[%s;1H\033[K\033[%s;%sH%s\0338' "$title_row" "$title_row" "$status_col" "$rendered_status"
}

virtwin_status_set "planning..."

printf 'Album: %s - %s (%s)\n' "$artist" "$album" "$year"
printf 'Source: %s\n' "$source_path"
printf 'Target profile: %s\n' "$target_profile"
if [[ "$allow_lossy_source" == "1" ]]; then
  printf 'Source policy: lossy-source transcode enabled for this workflow\n'
fi
printf '\n'
any2flac_lossy_args=()
if [[ "$allow_lossy_source" == "1" ]]; then
  any2flac_lossy_args+=(--allow-lossy-source)
fi
printf '[1/2] Recode plan\n'
AUDL_ARTWORK_FETCH_MISSING=1 "$any2flac_bin" --profile "$target_profile" --dir "$source_path" --with-boost --plan-only "${any2flac_lossy_args[@]}"
printf '\n'
virtwin_status_set "encoding..."
printf '[2/2] Recode convert\n'
AUDL_ARTWORK_FETCH_MISSING=1 "$any2flac_bin" --profile "$target_profile" --dir "$source_path" --with-boost --yes "${any2flac_lossy_args[@]}"
printf '\nWorkflow completed successfully.\n'
EOF
  chmod +x "$runner_script"

  local workflow_ok=0
  local virtwin_wait_flag=()
  if [[ "$wait_for_key" != "1" ]]; then
    virtwin_wait_flag=(--no-wait)
  fi
  local right_title="${batch_index} of ${batch_total} | ${row_artist} - ${row_year} - ${row_album} | planning..."
  if VIRTWIN_RIGHT_TITLE="$right_title" virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "recode+autoboost" \
    "${virtwin_wait_flag[@]}" \
    "$runner_script" "$row_source_path" "$target_profile" "$ANY2FLAC_BIN" "$row_artist" "$row_album" "$row_year" "$batch_index" "$batch_total" "$allow_lossy_source"; then
    workflow_ok=1
  fi
  rm -f "$runner_script"

  if ((workflow_ok != 1)); then
    ACTION_MESSAGE="FLAC recode failed for $row_artist - $row_album."
    return 1
  fi

  if ! delete_and_requeue_album_for_scan "$row_id" "$row_artist" "$row_year" "$row_album" "$row_source_path"; then
    ACTION_MESSAGE="FLAC recode completed, but DB update failed."
    return 1
  fi
  invalidate_count_cache
  ACTION_MESSAGE="FLAC recode completed for $row_artist - $row_album; queued for rescan."
  return 0
}

run_flac_recode_batch_for_row_ids() {
  local actionable_ids=("$@")
  local total="${#actionable_ids[@]}"
  if ((total == 0)); then
    ACTION_MESSAGE="No actionable rows selected for FLAC recode."
    return 1
  fi
  if [[ ! -x "$ANY2FLAC_BIN" ]]; then
    ACTION_MESSAGE="any2flac.sh not found at $ANY2FLAC_BIN"
    return 1
  fi

  local -a manifest_rows=()
  local -a build_failures=()
  local idx row_id manifest_fields
  for idx in "${!actionable_ids[@]}"; do
    row_id="${actionable_ids[$idx]}"
    if manifest_fields="$(flac_recode_manifest_fields_for_row_id "$row_id")"; then
      manifest_rows+=("${row_id}"$'\x1f'"${manifest_fields}")
    else
      build_failures+=("[$((idx + 1))/$total] ${ACTION_MESSAGE:-unknown failure}")
    fi
  done

  total="${#manifest_rows[@]}"
  if ((total == 0)); then
    ACTION_MESSAGE="FLAC recode batch aborted before run. ${build_failures[0]:-No actionable rows remained.}"
    return 1
  fi

  local manifest_file results_file runner_script
  manifest_file="$(mktemp "${TMPDIR:-/tmp}/library_browser_recode_batch_manifest.XXXXXX" 2>/dev/null || true)"
  results_file="$(mktemp "${TMPDIR:-/tmp}/library_browser_recode_batch_results.XXXXXX" 2>/dev/null || true)"
  runner_script="$(mktemp "${TMPDIR:-/tmp}/library_browser_recode_batch_runner.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$manifest_file" || -z "$results_file" || -z "$runner_script" ]]; then
    rm -f "$manifest_file" "$results_file" "$runner_script"
    ACTION_MESSAGE="Failed to create FLAC recode batch temporary files."
    return 1
  fi

  local first_title=""
  local row_artist row_album row_year row_source_path target_profile allow_lossy_source
  for idx in "${!manifest_rows[@]}"; do
    IFS=$'\x1f' read -r row_id row_artist row_album row_year row_source_path target_profile allow_lossy_source <<< "${manifest_rows[$idx]}"
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$row_id" \
      "$row_artist" \
      "$row_album" \
      "$row_year" \
      "$row_source_path" \
      "$target_profile" \
      "$allow_lossy_source" \
      "$((idx + 1))" \
      "$total" >>"$manifest_file"
    if [[ -z "$first_title" ]]; then
      first_title="1 of ${total} | ${row_artist} - ${row_year} - ${row_album} | planning..."
    fi
  done

  cat >"$runner_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
manifest_file="$1"
any2flac_bin="$2"
results_file="$3"
title_row="${VIRTWIN_TITLE_ROW:-}"
term_cols="${VIRTWIN_TERM_COLS:-0}"
batch_failed=0

virtwin_status_set() {
  local idx="$1"
  local total_items="$2"
  local artist="$3"
  local year="$4"
  local album="$5"
  local action="$6"
  if [[ ! "$title_row" =~ ^[0-9]+$ || ! "$term_cols" =~ ^[0-9]+$ ]] || ((term_cols <= 0)); then
    return 0
  fi
  local status_text status_col rendered_status
  status_text="${idx} of ${total_items} | ${artist} - ${year} - ${album} | ${action}"
  status_text="${status_text//$'\n'/ }"
  status_text="${status_text//$'\r'/ }"
  if ((${#status_text} > term_cols)); then
    status_text="${status_text:0:term_cols}"
  fi
  status_col=$((term_cols - ${#status_text} + 1))
  ((status_col < 1)) && status_col=1
  rendered_status="$status_text"
  if [[ -z "${NO_COLOR:-}" ]]; then
    local part1 part2 part3
    part1="${idx} of ${total_items}"
    part2="${artist} - ${year} - ${album}"
    part3="${action}"
    rendered_status=$'\033[1;38;2;77;163;255m'"$part1"$'\033[0m'
    rendered_status+=$'\033[1;38;2;111;141;255m | \033[0m'
    rendered_status+=$'\033[1;38;2;142;109;245m'"$part2"$'\033[0m'
    rendered_status+=$'\033[1;38;2;179;140;255m | \033[0m'
    rendered_status+=$'\033[1;38;2;208;179;255m'"$part3"$'\033[0m'
  fi
  printf '\0337\033[%s;1H\033[K\033[%s;%sH%s\0338' "$title_row" "$title_row" "$status_col" "$rendered_status"
}

while IFS=$'\x1f' read -r row_id artist album year source_path target_profile allow_lossy_source batch_index batch_total; do
  [[ -n "$row_id" ]] || continue
  virtwin_status_set "$batch_index" "$batch_total" "$artist" "$year" "$album" "planning..."
  printf 'Album: %s - %s (%s)\n' "$artist" "$album" "$year"
  printf 'Source: %s\n' "$source_path"
  printf 'Target profile: %s\n' "$target_profile"
  if [[ "$allow_lossy_source" == "1" ]]; then
    printf 'Source policy: lossy-source transcode enabled for this workflow\n'
  fi
  printf '\n'
  any2flac_lossy_args=()
  if [[ "$allow_lossy_source" == "1" ]]; then
    any2flac_lossy_args+=(--allow-lossy-source)
  fi
  printf '[1/2] Recode plan\n'
  if ! AUDL_ARTWORK_FETCH_MISSING=1 "$any2flac_bin" --profile "$target_profile" --dir "$source_path" --with-boost --plan-only "${any2flac_lossy_args[@]}"; then
    rc=$?
    printf 'FAIL\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1fplan failed (exit %s)\n' \
      "$batch_index" "$row_id" "$artist" "$album" "$year" "$source_path" "$rc" >>"$results_file"
    printf '\nAlbum failed during plan step (exit %s).\n\n' "$rc"
    batch_failed=1
    continue
  fi
  printf '\n'
  virtwin_status_set "$batch_index" "$batch_total" "$artist" "$year" "$album" "encoding..."
  printf '[2/2] Recode convert\n'
  if ! AUDL_ARTWORK_FETCH_MISSING=1 "$any2flac_bin" --profile "$target_profile" --dir "$source_path" --with-boost --yes "${any2flac_lossy_args[@]}"; then
    rc=$?
    printf 'FAIL\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1fconvert failed (exit %s)\n' \
      "$batch_index" "$row_id" "$artist" "$album" "$year" "$source_path" "$rc" >>"$results_file"
    printf '\nAlbum failed during convert step (exit %s).\n\n' "$rc"
    batch_failed=1
    continue
  fi
  printf 'OK\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$batch_index" "$row_id" "$artist" "$album" "$year" "$source_path" >>"$results_file"
  printf '\nWorkflow completed successfully.\n\n'
done < "$manifest_file"

exit "$batch_failed"
EOF
  chmod +x "$runner_script"

  local batch_rc=0
  if ! VIRTWIN_RIGHT_TITLE="$first_title" virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "recode+autoboost" \
    "$runner_script" "$manifest_file" "$ANY2FLAC_BIN" "$results_file"; then
    batch_rc=$?
  fi

  local success=0
  local failed=0
  local -a failed_details=()
  local -A result_seen=()
  local status detail_msg
  while IFS=$'\x1f' read -r status idx row_id row_artist row_album row_year row_source_path detail_msg; do
    [[ -n "$status" ]] || continue
    result_seen["$row_id"]=1
    if [[ "$status" == "OK" ]]; then
      if delete_and_requeue_album_for_scan "$row_id" "$row_artist" "$row_year" "$row_album" "$row_source_path"; then
        success=$((success + 1))
      else
        failed=$((failed + 1))
        failed_details+=("[$idx/$total] DB update failed after recode for $row_artist - $row_album.")
      fi
    else
      failed=$((failed + 1))
      failed_details+=("[$idx/$total] FLAC recode failed for $row_artist - $row_album. ${detail_msg}")
    fi
  done < "$results_file"

  for idx in "${!manifest_rows[@]}"; do
    IFS=$'\x1f' read -r row_id row_artist row_album row_year row_source_path target_profile allow_lossy_source <<< "${manifest_rows[$idx]}"
    if [[ -z "${result_seen[$row_id]:-}" ]]; then
      failed=$((failed + 1))
      failed_details+=("[$((idx + 1))/$total] FLAC recode failed for $row_artist - $row_album. Missing batch result output.")
    fi
  done

  if ((${#build_failures[@]} > 0)); then
    failed=$((failed + ${#build_failures[@]}))
    failed_details+=("${build_failures[@]}")
  fi

  rm -f "$manifest_file" "$results_file" "$runner_script"
  invalidate_count_cache

  if ((failed == 0)); then
    ACTION_MESSAGE="FLAC recode completed for ${success} album(s); queued for rescan."
    return 0
  fi
  if ((success == 0)); then
    ACTION_MESSAGE="FLAC recode failed for all ${failed} album(s). ${failed_details[0]}"
  else
    ACTION_MESSAGE="FLAC recode completed for ${success} album(s); ${failed} failed. ${failed_details[0]}"
  fi
  if ((batch_rc != 0 && ${#failed_details[@]} == 0)); then
    ACTION_MESSAGE="FLAC recode batch failed (exit $batch_rc)."
  fi
  return 1
}

show_recode_report_modal() {
  local heading="$1"
  shift || true
  local details=("$@")
  [[ "$INTERACTIVE" == "yes" ]] || return 0
  ((${#details[@]} > 0)) || return 0

  local report_file
  report_file="$(mktemp "${TMPDIR:-/tmp}/library_browser_recode_report.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$report_file" ]]; then
    return 0
  fi
  {
    printf '%s\n\n' "$heading"
    local line
    for line in "${details[@]}"; do
      printf '%s\n' "$line"
    done
  } >"$report_file"

  virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "recode-report" cat "$report_file" || true
  rm -f "$report_file"
}

run_flac_recode_for_row_ids() {
  local selected_ids=("$@")
  local valid_ids=()
  local row_id
  for row_id in "${selected_ids[@]}"; do
    [[ "$row_id" =~ ^[0-9]+$ ]] || continue
    valid_ids+=("$row_id")
  done

  local selected_total="${#valid_ids[@]}"
  if ((selected_total == 0)); then
    ACTION_MESSAGE="No valid rows selected for FLAC recode."
    return 1
  fi

  local -a actionable_ids=()
  local -a skipped_details=()
  local idx preflight_msg
  for idx in "${!valid_ids[@]}"; do
    row_id="${valid_ids[$idx]}"
    if run_flac_recode_for_row_id "$row_id" "0" "$((idx + 1))" "$selected_total" "check"; then
      actionable_ids+=("$row_id")
    else
      preflight_msg="${ACTION_MESSAGE:-unknown failure}"
      skipped_details+=("[$((idx + 1))/$selected_total] $preflight_msg")
    fi
  done

  local total="${#actionable_ids[@]}"
  local skipped_count="${#skipped_details[@]}"
  if ((skipped_count > 0)); then
    show_recode_report_modal \
      "FLAC recode preflight issues (selected rows):" \
      "${skipped_details[@]}"
  fi
  if ((total == 0)); then
    ACTION_MESSAGE="FLAC recode batch aborted: ${skipped_count} selected album(s) not actionable. ${skipped_details[0]}"
    return 1
  fi

  if ((total > 1)); then
    if run_flac_recode_batch_for_row_ids "${actionable_ids[@]}"; then
      if ((skipped_count > 0)); then
        ACTION_MESSAGE="${ACTION_MESSAGE} Skipped ${skipped_count} selected album(s) before run. ${skipped_details[0]}"
        return 1
      fi
      return 0
    fi
    if ((skipped_count > 0)); then
      ACTION_MESSAGE="${ACTION_MESSAGE} Skipped ${skipped_count} selected album(s) before run. ${skipped_details[0]}"
    fi
    return 1
  fi

  local success=0
  local failed=0
  local -a failed_details=()
  local detail_msg=""

  for idx in "${!actionable_ids[@]}"; do
    row_id="${actionable_ids[$idx]}"
    local wait_for_key=1
    if ((total > 1 && idx < total - 1)); then
      wait_for_key=0
    fi
    if run_flac_recode_for_row_id "$row_id" "$wait_for_key" "$((idx + 1))" "$total"; then
      success=$((success + 1))
    else
      failed=$((failed + 1))
      detail_msg="${ACTION_MESSAGE:-unknown failure}"
      failed_details+=("[$((idx + 1))/$total] $detail_msg")
    fi
  done

  if ((failed == 0)); then
    ACTION_MESSAGE="FLAC recode completed for ${success} album(s); queued for rescan."
    if ((skipped_count > 0)); then
      ACTION_MESSAGE="${ACTION_MESSAGE} Skipped ${skipped_count} selected album(s) before run. ${skipped_details[0]}"
      return 1
    fi
    return 0
  fi
  if ((success == 0)); then
    ACTION_MESSAGE="FLAC recode failed for all ${failed} actionable album(s). ${failed_details[0]}"
  else
    ACTION_MESSAGE="FLAC recode completed for ${success} album(s); ${failed} failed. ${failed_details[0]}"
  fi
  if ((skipped_count > 0)); then
    ACTION_MESSAGE="${ACTION_MESSAGE} Skipped ${skipped_count} selected album(s) before run. ${skipped_details[0]}"
  fi
  return 1
}

apply_row_action() {
  local mode="$1"
  local ids_csv="$2"
  local changed_count=0
  if [[ "$DB_WRITABLE" != true ]]; then
    ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    return 1
  fi
  case "$mode" in
  delete)
    local requeue_count=0
    requeue_count="$(
      sqlite3 -noheader "$DB_PATH" \
        "SELECT COUNT(*)
         FROM album_quality
         WHERE id IN ($ids_csv)
           AND COALESCE(source_path,'') <> '';" 2>/dev/null || echo 0
    )"
    [[ "$requeue_count" =~ ^[0-9]+$ ]] || requeue_count=0

    changed_count="$(
      sqlite3 -noheader "$DB_PATH" "
        BEGIN;
        INSERT INTO scan_roadmap (
          artist, artist_lc, album, album_lc, year_int, source_path, album_mtime, scan_kind, enqueued_at
        )
        SELECT
          artist,
          artist_lc,
          album,
          album_lc,
          COALESCE(year_int, 0),
          source_path,
          0,
          'new',
          0
        FROM album_quality
        WHERE id IN ($ids_csv)
          AND COALESCE(source_path,'') <> ''
        ON CONFLICT(artist_lc, album_lc, year_int) DO UPDATE SET
          artist=excluded.artist,
          album=excluded.album,
          source_path=excluded.source_path,
          album_mtime=0,
          scan_kind='new',
          enqueued_at=0;
        DELETE FROM album_quality WHERE id IN ($ids_csv);
        SELECT changes();
        COMMIT;
      " 2>/dev/null || echo 0
    )"
    [[ "$changed_count" =~ ^[0-9]+$ ]] || changed_count=0
    if ((requeue_count > 0)); then
      ACTION_MESSAGE="Deleted ${changed_count} row(s); queued ${requeue_count} for immediate rescan."
    else
      ACTION_MESSAGE="Deleted ${changed_count} row(s)."
    fi
    ;;
  mark_rarity)
    changed_count="$(sqlite3 -noheader "$DB_PATH" "UPDATE album_quality SET rarity=1 WHERE id IN ($ids_csv); SELECT changes();" 2>/dev/null || echo 0)"
    [[ "$changed_count" =~ ^[0-9]+$ ]] || changed_count=0
    ACTION_MESSAGE="Marked ${changed_count} row(s) as rarity."
    ;;
  unmark_rarity)
    changed_count="$(sqlite3 -noheader "$DB_PATH" "UPDATE album_quality SET rarity=0 WHERE id IN ($ids_csv); SELECT changes();" 2>/dev/null || echo 0)"
    [[ "$changed_count" =~ ^[0-9]+$ ]] || changed_count=0
    ACTION_MESSAGE="Unmarked rarity on ${changed_count} row(s)."
    ;;
  *)
    ACTION_MESSAGE="Unknown action mode: $mode"
    return 1
    ;;
  esac
  invalidate_count_cache
}

command_preview() {
  local dir_flag="--desc"
  if [[ "$SORT_DIR" == "asc" ]]; then
    dir_flag="--asc"
  fi

  local cmd=("audlint.sh")
  cmd+=("--class" "$CLASS_FILTER")
  cmd+=("--sort" "$SORT_KEY" "$dir_flag")
  if [[ -n "$SEARCH_QUERY" ]]; then
    cmd+=("--search" "$SEARCH_QUERY")
  fi
  if [[ "$CODEC_FILTER" != "all" ]]; then
    cmd+=("--codec" "$(codec_filter_label "$CODEC_FILTER")")
  fi
  if [[ "$PROFILE_FILTER" != "all" ]]; then
    cmd+=("--profile" "$(profile_filter_label "$PROFILE_FILTER")")
  fi
  cmd+=("--page-size" "$PAGE_SIZE")
  if [[ "$ACTIVE_VIEW" != "custom" ]]; then
    cmd+=("--view" "$ACTIVE_VIEW")
  fi
  if [[ "$FILTER_REPLACE_ONLY" == "1" ]]; then
    cmd+=("#replace-only")
  fi
  if [[ "$FILTER_UPSCALED_ONLY" == "1" ]]; then
    cmd+=("#upscaled-only")
  fi
  if [[ "$FILTER_REPLACE_OR_UPSCALED" == "1" ]]; then
    cmd+=("#replace-or-upscaled")
  fi
  if [[ "$FILTER_MIXED_ONLY" == "1" ]]; then
    cmd+=("#scan-failed-only")
  fi
  if [[ "$FILTER_RARITY_ONLY" == "1" ]]; then
    cmd+=("#rarity-only")
  fi

  printf '%s' "${cmd[*]}"
}

if [[ "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
  --help)
    show_help
    exit 0
    ;;
  --help-profiles)
    show_help_profiles
    exit 0
    ;;
  --view)
    shift
    value="${1:-}"
    [[ -n "$value" ]] || {
      echo "Error: --view requires a preset name" >&2
      exit 2
    }
    VIEW_KEY="$(normalize_view_key "$value" || true)"
    [[ -n "$VIEW_KEY" ]] || {
      echo "Error: invalid --view preset: $value" >&2
      exit 2
    }
    apply_view_preset "$VIEW_KEY"
    ;;
  --class)
    shift
    value="${1:-}"
    [[ -n "$value" ]] || {
      echo "Error: --class requires value: all|s-b|c-f" >&2
      exit 2
    }
    CLASS_FILTER="$(normalize_class_filter "$value" || true)"
    [[ -n "$CLASS_FILTER" ]] || {
      echo "Error: invalid --class value: $value" >&2
      exit 2
    }
    ACTIVE_VIEW="custom"
    ;;
  --sort)
    shift
    value="${1:-}"
    [[ -n "$value" ]] || {
      echo "Error: --sort requires a key" >&2
      exit 2
    }
    SORT_KEY="$(normalize_sort_key "$value" || true)"
    [[ -n "$SORT_KEY" ]] || {
      echo "Error: invalid --sort key: $value" >&2
      exit 2
    }
    ACTIVE_VIEW="custom"
    ;;
  --asc)
    SORT_DIR="asc"
    ACTIVE_VIEW="custom"
    ;;
  --desc)
    SORT_DIR="desc"
    ACTIVE_VIEW="custom"
    ;;
  --search)
    shift
    [[ $# -gt 0 ]] || {
      echo "Error: --search requires a value (use \"\" to clear)" >&2
      exit 2
    }
    value="${1:-}"
    SEARCH_QUERY="$(normalize_search_query "$value")"
    PAGE=1
    ;;
  --codec)
    shift
    [[ $# -gt 0 ]] || {
      echo "Error: --codec requires a value (use all to clear)" >&2
      exit 2
    }
    value="${1:-}"
    CODEC_FILTER="$(normalize_codec_filter "$value")"
    ACTIVE_VIEW="custom"
    PAGE=1
    ;;
  --profile)
    shift
    [[ $# -gt 0 ]] || {
      echo "Error: --profile requires a value (use all to clear)" >&2
      exit 2
    }
    value="${1:-}"
    PROFILE_FILTER="$(normalize_profile_filter "$value")"
    ACTIVE_VIEW="custom"
    PAGE=1
    ;;
  --page-size)
    shift
    value="${1:-}"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ || "$value" == "0" ]]; then
      echo "Error: --page-size requires integer >= 1" >&2
      exit 2
    fi
    PAGE_SIZE="$value"
    ;;
  --page)
    shift
    value="${1:-}"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ || "$value" == "0" ]]; then
      echo "Error: --page requires integer >= 1" >&2
      exit 2
    fi
    PAGE="$value"
    ;;
  --db)
    shift
    value="${1:-}"
    [[ -n "$value" ]] || {
      echo "Error: --db requires a path" >&2
      exit 2
    }
    DB_PATH="$value"
    ;;
  --album-id)
    shift
    value="${1:-}"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ || "$value" == "0" ]]; then
      echo "Error: --album-id requires integer >= 1" >&2
      exit 2
    fi
    ALBUM_ANALYSIS_ID="$value"
    ;;
  --interactive)
    INTERACTIVE="yes"
    ;;
  --no-interactive)
    INTERACTIVE="no"
    ;;
  -*)
    echo "Error: unknown option: $1" >&2
    show_help
    exit 2
    ;;
  *)
    echo "Error: unexpected argument: $1" >&2
    show_help
    exit 2
    ;;
  esac
  shift || true
done

DB_PATH="$(resolve_library_db_path "$DB_PATH" || true)"
if [[ -z "$DB_PATH" ]]; then
  echo "Error: AUDL_DB_PATH is not set. Example: AUDL_DB_PATH='\$AUDL_PATH/library.sqlite'" >&2
  exit 2
fi

if ! has_bin sqlite3; then
  echo "Error: sqlite3 not found" >&2
  exit 1
fi

if [[ -z "$ALBUM_ANALYSIS_ID" ]]; then
  if ! table_require_rich; then
    echo "Error: rich table renderer unavailable" >&2
    exit 1
  fi
fi

DB_DIR="$(dirname "$DB_PATH")"
if [[ ! -d "$DB_DIR" || ! -r "$DB_DIR" ]]; then
  echo "Error: DB directory unavailable/unreadable: $DB_DIR" >&2
  exit 1
fi

if [[ ! -w "$DB_DIR" ]]; then
  DB_WRITABLE=false
fi

if [[ -e "$DB_PATH" ]]; then
  if [[ ! -r "$DB_PATH" ]]; then
    echo "Error: DB file unavailable/unreadable: $DB_PATH" >&2
    exit 1
  fi
  if [[ ! -w "$DB_PATH" ]]; then
    DB_WRITABLE=false
  fi
else
  if [[ "$DB_WRITABLE" != true ]]; then
    echo "Error: DB file missing and directory is not writable: $DB_PATH" >&2
    exit 1
  fi
fi

if [[ "$DB_WRITABLE" == true ]]; then
  album_quality_db_init "$DB_PATH" || {
    echo "Error: failed to initialize album_quality in DB: $DB_PATH" >&2
    exit 1
  }
  scan_roadmap_db_init "$DB_PATH" || {
    echo "Error: failed to initialize scan_roadmap in DB: $DB_PATH" >&2
    exit 1
  }
  album_quality_db_backup "$DB_PATH" "${ALBUM_QUALITY_DB_SCHEMA_CHANGED:-0}" || {
    echo "Error: DB integrity check failed — aborting to protect backups." >&2
    exit 1
  }
  if [[ "$SYNC_LC_ON_STARTUP" == "1" ]]; then
    album_quality_sync_lc_columns "$DB_PATH" || true
  fi
else
  has_album_table="$(sqlite3 -noheader "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='album_quality' LIMIT 1;" 2>/dev/null || true)"
  if [[ "$has_album_table" != "1" ]]; then
    echo "Error: DB is read-only and album_quality table is missing: $DB_PATH" >&2
    exit 1
  fi
  DB_STATUS_LABEL="DB read-only"
fi

has_fts_table="$(sqlite3 -noheader "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='album_quality_fts' LIMIT 1;" 2>/dev/null || true)"
if [[ "$has_fts_table" == "1" ]]; then
  HAS_FTS_SEARCH=1
fi
detect_album_quality_columns "$DB_PATH"
if album_quality_has_index_contract "$DB_PATH"; then
  HAS_INDEX_CONTRACT=1
fi
refresh_sort_key_exprs

if [[ "$INTERACTIVE" == "auto" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    INTERACTIVE="yes"
  else
    INTERACTIVE="no"
  fi
fi

if [[ "$INTERACTIVE" == "yes" ]]; then
  AUDLINT_TERMINAL_CLEANUP_ACTIVE=1
fi

if [[ -n "$ALBUM_ANALYSIS_ID" ]]; then
  if ! show_album_analysis_page_for_row_id "$ALBUM_ANALYSIS_ID"; then
    if [[ -n "$ACTION_MESSAGE" ]]; then
      echo "$ACTION_MESSAGE" >&2
    else
      echo "Album analysis failed for row id=$ALBUM_ANALYSIS_ID" >&2
    fi
    exit 1
  fi
  exit 0
fi

while true; do
  refresh_sort_key_exprs
  SORT_EXPR="$(sort_expr_for_key "$SORT_KEY" || true)"
  [[ -n "$SORT_EXPR" ]] || {
    echo "Error: invalid sort key: $SORT_KEY" >&2
    exit 2
  }
  SORT_TIE_SQL="$(sort_tie_break_for_key "$SORT_KEY")"

  SORT_DIR_SQL="DESC"
  if [[ "$SORT_DIR" == "asc" ]]; then
    SORT_DIR_SQL="ASC"
  fi
  ARTIST_TIE_DIR_SQL="ASC"
  if [[ "$CODEC_FILTER" != "all" || "$PROFILE_FILTER" != "all" || -n "$SEARCH_QUERY" ]]; then
    ARTIST_TIE_DIR_SQL="$SORT_DIR_SQL"
  fi
  ORDER_SQL="ORDER BY $SORT_EXPR $SORT_DIR_SQL$SORT_TIE_SQL, $KEYSET_ARTIST_SQL_EXPR $ARTIST_TIE_DIR_SQL, $KEYSET_ALBUM_SQL_EXPR ASC, year_int ASC, id ASC"

  WHERE_SQL="$(build_where_sql || true)"
  [[ -n "$WHERE_SQL" || "$CLASS_FILTER" == "all" ]] || {
    echo "Error: invalid class filter: $CLASS_FILTER" >&2
    exit 2
  }

  state_count_key="$(count_cache_key_for_state)"
  grade_stats_plain=""
  grade_s=0
  grade_a=0
  grade_b=0
  grade_c=0
  grade_f=0
  queue_rows=0
  if [[ "$INTERACTIVE" == "yes" && "$COUNT_CACHE_VALID" == "1" && "$COUNT_CACHE_KEY" == "$state_count_key" ]]; then
    total_rows="$COUNT_CACHE_VALUE"
    grade_s="$COUNT_CACHE_GRADE_S"
    grade_a="$COUNT_CACHE_GRADE_A"
    grade_b="$COUNT_CACHE_GRADE_B"
    grade_c="$COUNT_CACHE_GRADE_C"
    grade_f="$COUNT_CACHE_GRADE_F"
    queue_rows="$COUNT_CACHE_QUEUE"
  else
    stats_row="$(album_quality_browser_stats_row "$DB_PATH" "$WHERE_SQL")"
    IFS=$'\t' read -r total_rows grade_s grade_a grade_b grade_c grade_f queue_rows <<< "$stats_row"
    [[ "$total_rows" =~ ^[0-9]+$ ]] || total_rows=0
    [[ "$grade_s" =~ ^[0-9]+$ ]] || grade_s=0
    [[ "$grade_a" =~ ^[0-9]+$ ]] || grade_a=0
    [[ "$grade_b" =~ ^[0-9]+$ ]] || grade_b=0
    [[ "$grade_c" =~ ^[0-9]+$ ]] || grade_c=0
    [[ "$grade_f" =~ ^[0-9]+$ ]] || grade_f=0
    [[ "$queue_rows" =~ ^[0-9]+$ ]] || queue_rows=0
    if [[ "$INTERACTIVE" == "yes" ]]; then
      COUNT_CACHE_KEY="$state_count_key"
      COUNT_CACHE_VALUE="$total_rows"
      COUNT_CACHE_VALID=1
      COUNT_CACHE_GRADE_S="$grade_s"
      COUNT_CACHE_GRADE_A="$grade_a"
      COUNT_CACHE_GRADE_B="$grade_b"
      COUNT_CACHE_GRADE_C="$grade_c"
      COUNT_CACHE_GRADE_F="$grade_f"
      COUNT_CACHE_QUEUE="$queue_rows"
    fi
  fi
  grade_stats_plain="$(format_grade_stats_plain "$total_rows" "$grade_s" "$grade_a" "$grade_b" "$grade_c" "$grade_f")"

  total_pages=1
  if ((total_rows > 0)); then
    total_pages=$(((total_rows + PAGE_SIZE - 1) / PAGE_SIZE))
  fi
  if ((PAGE > total_pages)); then
    PAGE="$total_pages"
  fi
  if ((PAGE < 1)); then
    PAGE=1
  fi

  snapshot_rows_raw=""
  if [[ -n "$ROW_ACTION_MODE" && -n "$ROW_ACTION_ROWS_RAW_SNAPSHOT" ]]; then
    snapshot_rows_raw="$ROW_ACTION_ROWS_RAW_SNAPSHOT"
    ROW_ACTION_ROWS_RAW_SNAPSHOT=""
  fi

  rows_raw=""
  if [[ "$PENDING_NAV" == "next" || "$PENDING_NAV" == "prev" ]]; then
    if keyset_checked_enabled_for_state; then
      if [[ "$PENDING_NAV" == "next" && -n "$CURSOR_LAST_ID" ]]; then
        seek_cond="$(build_checked_seek_condition "next" "$CURSOR_LAST_CHECKED" "$CURSOR_LAST_ARTIST" "$CURSOR_LAST_ALBUM" "$CURSOR_LAST_YEAR" "$CURSOR_LAST_ID" "$SORT_DIR_SQL" "$ARTIST_TIE_DIR_SQL")"
        seek_where="$WHERE_SQL AND $seek_cond"
        rows_raw="$(fetch_rows_raw "$seek_where" "$ORDER_SQL" "LIMIT $PAGE_SIZE")"
        if [[ -n "$rows_raw" ]]; then
          PAGE=$((PAGE + 1))
        fi
      elif [[ "$PENDING_NAV" == "prev" && -n "$CURSOR_FIRST_ID" && $PAGE -gt 1 ]]; then
        seek_cond="$(build_checked_seek_condition "prev" "$CURSOR_FIRST_CHECKED" "$CURSOR_FIRST_ARTIST" "$CURSOR_FIRST_ALBUM" "$CURSOR_FIRST_YEAR" "$CURSOR_FIRST_ID" "$SORT_DIR_SQL" "$ARTIST_TIE_DIR_SQL")"
        seek_where="$WHERE_SQL AND $seek_cond"
        rev_sort_dir_sql="$(reverse_sort_dir "$SORT_DIR_SQL")"
        rev_artist_tie_dir_sql="$(reverse_sort_dir "$ARTIST_TIE_DIR_SQL")"
        rev_order_sql="ORDER BY $KEYSET_CHECKED_SQL_EXPR $rev_sort_dir_sql, $KEYSET_ARTIST_SQL_EXPR $rev_artist_tie_dir_sql, $KEYSET_ALBUM_SQL_EXPR DESC, year_int DESC, id DESC"
        rows_raw_rev="$(fetch_rows_raw "$seek_where" "$rev_order_sql" "LIMIT $PAGE_SIZE")"
        if [[ -n "$rows_raw_rev" ]]; then
          PAGE=$((PAGE - 1))
          rows_raw="$(reverse_lines "$rows_raw_rev")"
        fi
      else
        if [[ "$PENDING_NAV" == "next" && $PAGE -lt $total_pages ]]; then
          PAGE=$((PAGE + 1))
        elif [[ "$PENDING_NAV" == "prev" && $PAGE -gt 1 ]]; then
          PAGE=$((PAGE - 1))
        fi
      fi
    else
      if [[ "$PENDING_NAV" == "next" && $PAGE -lt $total_pages ]]; then
        PAGE=$((PAGE + 1))
      elif [[ "$PENDING_NAV" == "prev" && $PAGE -gt 1 ]]; then
        PAGE=$((PAGE - 1))
      fi
    fi
    PENDING_NAV=""
  fi

  offset=$(((PAGE - 1) * PAGE_SIZE))
  if [[ -n "$snapshot_rows_raw" ]]; then
    rows_raw="$snapshot_rows_raw"
  elif [[ -z "$rows_raw" ]]; then
    rows_raw="$(fetch_rows_raw "$WHERE_SQL" "$ORDER_SQL" "LIMIT $PAGE_SIZE OFFSET $offset")"
  fi
  rows="$(parse_rows_raw "$rows_raw")"
  rows="$(decorate_rows_for_sort_column "$rows" "$SORT_KEY")"
  row_action_row_ids=()
  row_action_transfer_entries=()
  row_selection_labels=()
  row_action_selectable_count=0
  if [[ "$INTERACTIVE" == "yes" && -n "$ROW_ACTION_MODE" ]]; then
    selectable_idx=1
    c0="" c1="" c2="" c3="" c4="" c5="" c6="" c7="" c8="" c9="" c10="" c11="" c12="" c13="" c14="" c15="" c16="" c17="" c18=""
    while IFS="$ROW_RAW_SEP" read -r c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 c18; do
      [[ -n "$c0$c1$c2$c3$c4$c5$c6$c7$c8$c9$c10$c11$c12$c13$c14$c15$c16$c17$c18" ]] || continue
      [[ "$c15" =~ ^[0-9]+$ ]] || continue
      if [[ "$ROW_ACTION_MODE" == "album_analysis" ]]; then
        if inspect_row_is_selectable "$c16" "$c9" "$c8"; then
          row_action_row_ids+=("$c15")
          row_selection_labels+=("$selectable_idx")
          row_action_selectable_count=$((row_action_selectable_count + 1))
        else
          row_action_row_ids+=("")
          if [[ "$USE_COLOR" == true ]]; then
            row_selection_labels+=("[dim]${selectable_idx}[/]")
          else
            row_selection_labels+=("$selectable_idx")
          fi
        fi
      else
        row_action_row_ids+=("$c15")
        row_selection_labels+=("$selectable_idx")
        if [[ "$ROW_ACTION_MODE" == "transfer" ]]; then
          row_action_transfer_entries+=("$(printf '%s\x1f%s\x1f%s\x1f%s\x1f%s' "$c15" "$c0" "$c17" "$c14" "$c18")")
        fi
      fi
      selectable_idx=$((selectable_idx + 1))
    done <<< "$rows_raw"
  fi
  table_headers="$(build_table_headers)"
  table_widths="$(table_widths_csv no)"
  display_rows="$rows"
  if [[ "$INTERACTIVE" == "yes" && -n "$ROW_ACTION_MODE" ]]; then
    row_header="ROW"
    if [[ "$USE_COLOR" == true ]]; then
      row_header="[bold #aee8ff]ROW[/]"
    fi
    table_headers="${row_header},${table_headers}"
    table_widths="$(table_widths_csv yes)"
    display_rows="$(prepend_row_labels "$rows" "${row_selection_labels[@]}")"
  fi

  if [[ "$INTERACTIVE" == "yes" ]]; then
    printf '\033[H\033[2J'
  fi
  next_run_label="$(next_run_hhmm)"
  print_status_line \
    "$(view_title_for_key "$ACTIVE_VIEW")" "$CLASS_FILTER" "$SORT_KEY" "$SORT_DIR" "$PAGE" "$total_pages" "$total_rows" "$queue_rows" "$next_run_label" "$DB_STATUS_LABEL" "$grade_stats_plain"
  print_filter_status_line \
    "$(codec_filter_label "$CODEC_FILTER")" \
    "$(profile_filter_label "$PROFILE_FILTER")" \
    "$(upper_text "$SORT_DIR")" \
    "${SEARCH_QUERY:--}"
  printf 'command: %s\n' "$(command_preview)"
  if [[ -n "$ACTION_MESSAGE" ]]; then
    if [[ "$USE_COLOR" == true ]]; then
      printf '%b\n' "$(color_text_hex "#b8f5ff" "$ACTION_MESSAGE")"
    else
      printf '%s\n' "$ACTION_MESSAGE"
    fi
    ACTION_MESSAGE=""
  fi

  if [[ "$INTERACTIVE" == "yes" ]]; then
    print_nav_line
  fi

  printf '%s\n' "$display_rows" | table_render_tsv \
    "$table_headers" \
    "$table_widths"

  if [[ "$INTERACTIVE" != "yes" ]]; then
    break
  fi

  if [[ -n "$ROW_ACTION_MODE" ]]; then
    max_delete_idx=${#row_action_row_ids[@]}
    if [[ "$ROW_ACTION_MODE" == "album_analysis" && $row_action_selectable_count -eq 0 ]]; then
      ACTION_MESSAGE="No inspect-eligible rows on current page (re-encode/pending-rescan rows are disabled)."
      ROW_ACTION_MODE=""
      continue
    fi
    if ((max_delete_idx == 0)); then
      ACTION_MESSAGE="No rows on current page for action."
      ROW_ACTION_MODE=""
      continue
    fi
    delete_input=""
    if audlint_prompt_line "$(row_action_prompt_for_mode "$ROW_ACTION_MODE")" delete_input 1; then
      compact_delete_input="$(printf '%s' "$delete_input" | tr -d '[:space:]')"
      if [[ -z "$compact_delete_input" ]]; then
        ROW_ACTION_MODE=""
        continue
      fi
      if ! selected_idx_line="$(parse_delete_selection "$delete_input" "$max_delete_idx")"; then
        ACTION_MESSAGE="Invalid row selection: $delete_input"
        ROW_ACTION_MODE=""
        continue
      fi
      selected_row_ids=()
      selected_transfer_entries=()
      selected_indexes=()
      selected_disabled=0
      IFS=' ' read -r -a selected_indexes <<< "$selected_idx_line"
      for selected_idx in "${selected_indexes[@]}"; do
        [[ "$selected_idx" =~ ^[0-9]+$ ]] || continue
        row_pos=$((selected_idx - 1))
        if ((row_pos >= 0 && row_pos < ${#row_action_row_ids[@]})); then
          selected_row_id="${row_action_row_ids[$row_pos]}"
          if [[ -z "$selected_row_id" ]]; then
            selected_disabled=1
            continue
          fi
          selected_row_ids+=("$selected_row_id")
          if [[ "$ROW_ACTION_MODE" == "transfer" ]]; then
            selected_transfer_entries+=("${row_action_transfer_entries[$row_pos]:-}")
          fi
        fi
      done
      if [[ "$ROW_ACTION_MODE" == "album_analysis" && "$selected_disabled" == "1" ]]; then
        ACTION_MESSAGE="Selected row is disabled in inspect mode (re-encode/pending-rescan)."
        ROW_ACTION_MODE=""
        continue
      fi
      if ((${#selected_row_ids[@]} == 0)); then
        ACTION_MESSAGE="No valid rows selected."
        ROW_ACTION_MODE=""
        continue
      fi
      if [[ "$ROW_ACTION_MODE" == "transfer" ]]; then
        run_transfer_for_snapshot_entries "${selected_transfer_entries[@]}" || true
        ROW_ACTION_MODE=""
        continue
      fi
      if [[ "$ROW_ACTION_MODE" == "lyrics_seek" ]]; then
        run_lyrics_seek_for_row_ids "${selected_row_ids[@]}" || true
        ROW_ACTION_MODE=""
        continue
      fi
      if [[ "$ROW_ACTION_MODE" == "album_analysis" ]]; then
        run_album_analysis_for_row_ids "${selected_row_ids[@]}" || true
        ROW_ACTION_MODE=""
        continue
      fi
      if [[ "$ROW_ACTION_MODE" == "recode_flac" ]]; then
        run_flac_recode_for_row_ids "${selected_row_ids[@]}" || true
        ROW_ACTION_MODE=""
        continue
      fi
      ids_csv="$(IFS=,; echo "${selected_row_ids[*]}")"
      if ! apply_row_action "$ROW_ACTION_MODE" "$ids_csv"; then
        ACTION_MESSAGE="Failed to apply action: $ROW_ACTION_MODE"
      fi
    fi
    ROW_ACTION_MODE=""
    continue
  fi

  if [[ "$QUIT_CONFIRM_MODE" == "1" ]]; then
    quit_choice=""
    if ! audlint_prompt_key 'Quit application? [y Quit, n Cancel, c Clear Filters] > ' quit_choice 0 1; then
      quit_choice="n"
    fi
    case "$quit_choice" in
    y)
      break
      ;;
    n)
      QUIT_CONFIRM_MODE=0
      ;;
    c)
      QUIT_CONFIRM_MODE=0
      reset_primary_state
      continue
      ;;
    *)
      QUIT_CONFIRM_MODE=0
      ;;
    esac
    continue
  fi

  key=""
  if ! audlint_prompt_key 'q=quit > ' key 0 1; then
    break
  fi

  case "$key" in
  0)
    apply_view_preset default
    PAGE=1
    ;;
  1)
    ACTIVE_VIEW="custom"
    SORT_KEY="year"
    SORT_DIR="desc"
    PAGE=1
    ;;
  2)
    ACTIVE_VIEW="custom"
    SORT_KEY="dr"
    SORT_DIR="desc"
    PAGE=1
    ;;
  3)
    ACTIVE_VIEW="custom"
    SORT_KEY="grade"
    SORT_DIR="asc"
    PAGE=1
    ;;
  4)
    ACTIVE_VIEW="custom"
    base_where_sql="$(build_where_sql no || true)"
    if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_CODEC_NORM" == "1" ]]; then
      codec_key_sql="codec_norm"
    else
      codec_norm_sql_expr="$(codec_norm_expr_sql)"
      codec_key_sql="${codec_norm_sql_expr}"
    fi
    codec_rows="$(album_quality_inventory_rows "$DB_PATH" "$base_where_sql" "$codec_key_sql" "inventory_key ASC")"
    codec_keys=()
    codec_counts=()
    if [[ -n "$codec_rows" ]]; then
      while IFS=$'\t' read -r codec_key codec_count; do
        [[ -n "$codec_key" ]] || continue
        if [[ "$codec_key" == "__all__" ]]; then
          codec_keys+=("all")
          codec_counts+=("$codec_count")
          continue
        fi
        codec_keys+=("$codec_key")
        codec_counts+=("$codec_count")
      done <<< "$codec_rows"
    fi
    if ((${#codec_keys[@]} == 0)); then
      codec_keys=("all")
      codec_counts=("0")
    fi
    max_idx=$(( ${#codec_keys[@]} - 1 ))
    printf 'codec filter (single select, current=%s)\n' "$(codec_filter_label "$CODEC_FILTER")"
    print_single_select_options_compact codec_keys codec_counts codec_filter_label 3
    tty_print_text $'\n'
    tty_print_text "$(render_prompt_text "choose codec [$(menu_choice_range_hint "$max_idx")] (auto-apply) > ")"
    codec_choice="$(read_menu_choice_immediate "$max_idx" || true)"
    tty_print_text $'\n'
    if [[ -n "$codec_choice" ]] && [[ "$codec_choice" =~ ^[0-9]+$ ]] && ((codec_choice >= 0 && codec_choice <= max_idx)); then
      CODEC_FILTER="${codec_keys[$codec_choice]}"
    fi
    PAGE=1
    ;;
  5)
    ACTIVE_VIEW="custom"
    base_where_sql="$(build_where_sql yes no || true)"
    if [[ "$HAS_INDEX_CONTRACT" == "1" && "$HAS_COL_PROFILE_NORM" == "1" ]]; then
      profile_key_sql="profile_norm"
    else
      profile_key_sql="$(profile_norm_expr_sql)"
    fi
    profile_order_sql="CASE
         WHEN inventory_key='~unknown' THEN 3
         WHEN INSTR(inventory_key,'/')>0 THEN 0
         ELSE 2
       END ASC,
       CASE
         WHEN INSTR(inventory_key,'/')>0 THEN
           CASE
             WHEN LOWER(TRIM(SUBSTR(inventory_key,INSTR(inventory_key,'/')+1)))='64f' THEN 640
             WHEN LOWER(TRIM(SUBSTR(inventory_key,INSTR(inventory_key,'/')+1)))='32f' THEN 320
             WHEN LOWER(TRIM(SUBSTR(inventory_key,INSTR(inventory_key,'/')+1))) GLOB '[0-9][0-9]*'
               THEN CAST(LOWER(TRIM(SUBSTR(inventory_key,INSTR(inventory_key,'/')+1))) AS INTEGER)*10
             ELSE 0
           END
         ELSE 0
       END DESC,
       CASE
         WHEN INSTR(inventory_key,'/')>0 THEN
           CASE
             WHEN TRIM(SUBSTR(inventory_key,1,INSTR(inventory_key,'/')-1)) GLOB '[0-9]*'
               OR TRIM(SUBSTR(inventory_key,1,INSTR(inventory_key,'/')-1)) GLOB '[0-9]*.[0-9]*'
               THEN CAST(TRIM(SUBSTR(inventory_key,1,INSTR(inventory_key,'/')-1)) AS REAL)
             ELSE 0
           END
         ELSE 0
       END DESC,
       inventory_key ASC"
    profile_rows="$(album_quality_inventory_rows "$DB_PATH" "$base_where_sql" "$profile_key_sql" "$profile_order_sql")"
    profile_keys=()
    profile_counts=()
    if [[ -n "$profile_rows" ]]; then
      while IFS=$'\t' read -r profile_key profile_count; do
        [[ -n "$profile_key" ]] || continue
        if [[ "$profile_key" == "__all__" ]]; then
          profile_keys+=("all")
          profile_counts+=("$profile_count")
          continue
        fi
        profile_keys+=("$profile_key")
        profile_counts+=("$profile_count")
      done <<< "$profile_rows"
    fi
    if ((${#profile_keys[@]} == 0)); then
      profile_keys=("all")
      profile_counts=("0")
    fi
    max_idx=$(( ${#profile_keys[@]} - 1 ))
    printf 'profile filter (single select, current=%s)\n' "$(profile_filter_label "$PROFILE_FILTER")"
    print_single_select_options_compact profile_keys profile_counts profile_filter_label 3
    tty_print_text $'\n'
    tty_print_text "$(render_prompt_text "choose profile [$(menu_choice_range_hint "$max_idx")] (auto-apply) > ")"
    profile_choice="$(read_menu_choice_immediate "$max_idx" || true)"
    tty_print_text $'\n'
    if [[ -n "$profile_choice" ]] && [[ "$profile_choice" =~ ^[0-9]+$ ]] && ((profile_choice >= 0 && profile_choice <= max_idx)); then
      PROFILE_FILTER="${profile_keys[$profile_choice]}"
    fi
    PAGE=1
    ;;
  6)
    apply_view_preset scan_failed
    PAGE=1
    ;;
  R)
    apply_view_preset rarity_only
    PAGE=1
    ;;
  e)
    apply_view_preset encode_only
    PAGE=1
    ;;
  a)
    SORT_DIR="asc"
    ;;
  d)
    SORT_DIR="desc"
    ;;
  c)
    reset_primary_state
    ;;
  /)
    search_value=""
    if audlint_prompt_line 'search artist/album (blank=clear) > ' search_value 1; then
      SEARCH_QUERY="$(normalize_search_query "$search_value")"
      PAGE=1
    fi
    ;;
  n)
    if ((PAGE < total_pages)); then
      PENDING_NAV="next"
    fi
    ;;
  p)
    if ((PAGE > 1)); then
      PENDING_NAV="prev"
    fi
    ;;
  r)
    if [[ "$DB_WRITABLE" == true ]]; then
      prime_row_action_snapshot "$rows_raw"
      ROW_ACTION_MODE="mark_rarity"
    else
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    fi
    ;;
  u)
    if [[ "$DB_WRITABLE" != true ]]; then
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    elif [[ "$FILTER_RARITY_ONLY" == "1" ]]; then
      prime_row_action_snapshot "$rows_raw"
      ROW_ACTION_MODE="unmark_rarity"
    else
      ACTION_MESSAGE="Unmark is available only in Rarities view."
    fi
    ;;
  x)
    if [[ "$DB_WRITABLE" == true ]]; then
      prime_row_action_snapshot "$rows_raw"
      ROW_ACTION_MODE="delete"
    else
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    fi
    ;;
  s)
    if ! show_sync_action; then
      ACTION_MESSAGE="Sync unavailable: set writable AUDL_SYNC_DEST in .env."
    elif [[ -x "$SYNC_MUSIC_BIN" ]]; then
      if virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "sync-music" "$SYNC_MUSIC_BIN"; then
        ACTION_MESSAGE="sync-music completed."
      else
        ACTION_MESSAGE="sync-music failed."
      fi
    else
      ACTION_MESSAGE="sync-music.sh not found at $SYNC_MUSIC_BIN"
    fi
    ;;
  f)
    if [[ "$DB_WRITABLE" != true ]]; then
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    elif ! show_flac_action; then
      ACTION_MESSAGE="FLAC recode is available only in Recode view (needs_recode plus DTS replacements). Press e first."
    else
      prime_row_action_snapshot "$rows_raw"
      ROW_ACTION_MODE="recode_flac"
    fi
    ;;
  t)
    if ! show_transfer_action; then
      ACTION_MESSAGE="Transfer unavailable: AUDL_MEDIA_PLAYER_PATH is missing or not writable."
    else
      prime_row_action_snapshot "$rows_raw"
      ROW_ACTION_MODE="transfer"
    fi
    ;;
  l)
    if [[ "$DB_WRITABLE" != true ]]; then
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    elif ! show_lyrics_action; then
      ACTION_MESSAGE="Lyrics unavailable: lyrics_seek.sh not found ($LYRICS_SEEK_BIN)."
    else
      prime_row_action_snapshot "$rows_raw"
      ROW_ACTION_MODE="lyrics_seek"
    fi
    ;;
  i)
    prime_row_action_snapshot "$rows_raw"
    ROW_ACTION_MODE="album_analysis"
    ;;
  m)
    if [[ -z "$LIBRARY_ROOT" || ! -x "$AUDLINT_TASK_BIN" || ! -x "$AUDLINT_MAINTAIN_BIN" ]]; then
      ACTION_MESSAGE="Maintain unavailable: audlint-maintain.sh/audlint-task.sh missing or LIBRARY_ROOT not set."
    else
      AUDLINT_TASK_BIN="$AUDLINT_TASK_BIN" \
      AUDL_TASK_MAX_ALBUMS="$AUDLINT_TASK_MAX_ALBUMS" \
      AUDL_TASK_MAX_TIME_SEC="$AUDLINT_TASK_MAX_TIME_SEC" \
      AUDL_TASK_LOG_PATH="$AUDLINT_TASK_LOG" \
      AUDLINT_TASK_DISCOVERY_CACHE_FILE="$AUDLINT_TASK_DISCOVERY_CACHE_FILE" \
      AUDLINT_LIBRARY_ROOT="$LIBRARY_ROOT" \
      AUDL_MEDIA_PLAYER_PATH="$MEDIA_PLAYER_PATH" \
      AUDL_CRON_INTERVAL_MIN="$AUDLINT_CRON_INTERVAL_MIN" \
      virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "maintain" --no-wait \
        "$AUDLINT_MAINTAIN_BIN" || true
      invalidate_count_cache
    fi
    ;;
  L)
    if [[ ! -f "$AUDLINT_TASK_LOG" ]]; then
      ACTION_MESSAGE="No log yet: $AUDLINT_TASK_LOG"
    else
      virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "log" \
        cat "$AUDLINT_TASK_LOG"
    fi
    ;;
  P)
    if [[ -z "$LIBRARY_ROOT" || ! -x "$AUDLINT_TASK_BIN" ]]; then
      ACTION_MESSAGE="Purge unavailable: audlint-task.sh not found or LIBRARY_ROOT not set."
    elif [[ "$DB_WRITABLE" != true ]]; then
      ACTION_MESSAGE="DB is read-only; purge action is disabled."
    else
      if virtwin_run_command 5 "$(term_lines_value)" "$(term_cols_value)" "purge-missing" \
        "$AUDLINT_TASK_BIN" --purge-missing "$LIBRARY_ROOT"; then
        ACTION_MESSAGE="Purge completed."
        invalidate_count_cache
      else
        ACTION_MESSAGE="Purge cancelled or failed."
      fi
    fi
    ;;
  q)
    QUIT_CONFIRM_MODE=1
    ;;
  *)
    ;;
  esac
done
