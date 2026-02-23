#!/opt/homebrew/bin/bash
# audlint.sh - Interactive browser for LIBRARY_DB.album_quality

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
source "$BOOTSTRAP_DIR/../lib/sh/env.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/deps.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/table.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/sqlite.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/virtwin.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true

PAGE_SIZE=12
PAGE=1
CLASS_FILTER="all"
CODEC_FILTER="all"
PROFILE_FILTER="all"
SORT_KEY="checked"
SORT_DIR="desc"
INTERACTIVE="auto"
DB_PATH="${LIBRARY_DB:-}"
ACTIVE_VIEW="default"
SEARCH_QUERY=""
NO_COLOR="${NO_COLOR:-}"
USE_COLOR=false
ROW_ACTION_MODE=""
QUIT_CONFIRM_MODE=0
ACTION_MESSAGE=""
DB_WRITABLE=true
DB_STATUS_LABEL=""
SYNC_LC_ON_STARTUP="${LIBRARY_BROWSER_SYNC_LC_ON_STARTUP:-0}"
CRON_INTERVAL_MIN="${LIBRARY_BROWSER_CRON_INTERVAL_MIN:-${CRON_INTERVAL_MIN:-20}}"
HAS_FTS_SEARCH=0
KEYSET_ENABLED="${LIBRARY_BROWSER_KEYSET_ON:-1}"
SYNC_MUSIC_BIN="${SYNC_MUSIC_BIN:-${REPO_ROOT:-}/bin/sync_music.sh}"
QTY_SEEK_BIN="${QTY_SEEK_BIN:-${REPO_ROOT:-}/bin/qty_seek.sh}"
QTY_SEEK_MAX_ALBUMS="${QTY_SEEK_MAX_ALBUMS:-30}"
QTY_SEEK_LOG="${QTY_SEEK_LOG:-$HOME/qty_seek.log}"
# Discovery cache path mirrors qty_seek.sh derivation (DB_PATH slug).
_qty_seek_db_slug="$(printf '%s' "${LIBRARY_DB:-}" | tr -cs 'A-Za-z0-9_-' '_')"
QTY_SEEK_DISCOVERY_CACHE="${DISCOVERY_CACHE_FILE:-${TMPDIR:-/tmp}/qty_seek_last_discovery_${_qty_seek_db_slug}}"
unset _qty_seek_db_slug
LIBRARY_ROOT="${LIBRARY_ROOT:-${SRC:-}}"
MEDIA_PLAYER_PATH="${MEDIA_PLAYER_PATH:-}"
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
COUNT_CACHE_KEY=""
COUNT_CACHE_VALUE=""
COUNT_CACHE_VALID=0

FILTER_REPLACE_ONLY=0
FILTER_UPSCALED_ONLY=0
FILTER_MIXED_ONLY=0
FILTER_REPLACE_OR_UPSCALED=0
FILTER_RARITY_ONLY=0

TABLE_LABELS=("ARTIST" "YEAR" "ALBUM" "GRADE" "RE" "SCAN FAIL" "CODEC" "PROFILE" "BITRATE" "RECODE" "LAST CHECKED")
TABLE_WIDTHS=(20 6 24 5 4 10 8 9 9 22 18)
TABLE_SORT_KEYS=("artist" "year" "album" "grade" "" "fail" "codec" "curr" "" "" "checked")
TABLE_SELECT_SQL=(
  "artist"
  "CASE WHEN year_int=0 THEN '-' ELSE CAST(year_int AS TEXT) END"
  "album"
  "COALESCE(quality_grade,'-')"
  "CASE WHEN COALESCE(needs_recode,0)=1 THEN 'Y' ELSE '-' END"
  "CASE WHEN scan_failed=1 THEN 'Y' ELSE '-' END"
  "COALESCE(NULLIF(codec,''),'-')"
  "COALESCE(NULLIF(current_quality,''),'-')"
  "COALESCE(NULLIF(bitrate,''),'-')"
  "CASE WHEN COALESCE(scan_failed,0)=1 THEN COALESCE(NULLIF(notes,''),NULLIF(recode_recommendation,''),'-') ELSE COALESCE(NULLIF(recode_recommendation,''),'-') END"
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
  --sort <key>               Sort key: checked|score|grade|artist|album|year|replace|fail|curr|codec (default: checked)
  --asc                      Sort ascending
  --desc                     Sort descending (default)
  --search <text>            Case-insensitive artist/album search (%...% fuzzy-like)
  --codec <name|all|unknown> Filter by one codec value (default: all)
  --profile <name|all|unknown> Filter by one profile value (default: all)
  --page-size <n>            Rows per page (default: 12)
  --page <n>                 Start page (default: 1)
  --db <path>                Override LIBRARY_DB path
  --interactive              Force interactive paging
  --no-interactive           Disable interactive paging
  --help                     Show this help

Interactive keys:
  0 = last checked (default)
  1 = grade-focused view (worst grade first)
  2 = codec inventory + choose single codec filter
  3 = profile inventory + choose single profile filter
      selector keys use 0-9 then a-z (10=a, 11=b, ...)
  4 = scan failed first
  5 = show rarities only
  e = show recode queue (needs_recode=Y)
  f = FLAC recode + boost for selected row(s) (recode view only)
  l = lyrics seek + embed for selected row(s)
  t = transfer selected albums to media player (when MEDIA_PLAYER_PATH is writable)
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

resolve_library_db_path() {
  local raw="$1"
  if [[ -z "$raw" && -n "${SRC:-}" ]]; then
    raw="$SRC/library.sqlite"
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
  if [[ "$HAS_COL_CHECKED_SORT" == "1" ]]; then
    KEYSET_CHECKED_SQL_EXPR="COALESCE(checked_sort,0)"
  else
    KEYSET_CHECKED_SQL_EXPR="COALESCE(last_checked_at,0)"
  fi
  if [[ "$HAS_COL_ARTIST_NORM" == "1" ]]; then
    KEYSET_ARTIST_SQL_EXPR="COALESCE(NULLIF(artist_norm,''),COALESCE(artist_lc,''))"
  else
    KEYSET_ARTIST_SQL_EXPR="COALESCE(artist_lc,'')"
  fi
  if [[ "$HAS_COL_ALBUM_NORM" == "1" ]]; then
    KEYSET_ALBUM_SQL_EXPR="COALESCE(NULLIF(album_norm,''),COALESCE(album_lc,''))"
  else
    KEYSET_ALBUM_SQL_EXPR="COALESCE(album_lc,'')"
  fi
}

codec_norm_expr_sql() {
  if [[ "$HAS_COL_CODEC_NORM" == "1" ]]; then
    printf "COALESCE(codec_norm,'')"
  else
    printf "LOWER(TRIM(COALESCE(codec,'')))"
  fi
}

profile_norm_expr_sql() {
  if [[ "$HAS_COL_PROFILE_NORM" == "1" ]]; then
    printf "COALESCE(profile_norm,'')"
  else
    printf "LOWER(TRIM(COALESCE(current_quality,'')))"
  fi
}

encode_lossy_exclusion_clause_sql() {
  local codec_expr
  codec_expr="$(codec_norm_expr_sql)"
  printf "(%s NOT IN ('mp2','mp3','aac','vorbis','opus','ac3','eac3','dca','dts','wma','wmav1','wmav2','wmavoice','amr_nb','amr_wb','gsm','g722','g723_1','g726','g729','qcelp','cook','ra_144','ra_288','atrac1','atrac3','atrac3al','atrac3p','speex','nellymoser','qdm2','alaw','mulaw') AND %s NOT LIKE 'adpcm_%%')" "$codec_expr" "$codec_expr"
}

lower_text() {
  local raw="$1"
  printf '%s' "${raw,,}"
}

upper_text() {
  local raw="$1"
  printf '%s' "${raw^^}"
}

title_case_words() {
  local raw="$1"
  raw="$(normalize_search_query "$raw")"
  [[ -n "$raw" ]] || {
    printf ''
    return 0
  }
  local out=()
  local word
  for word in $raw; do
    out+=("${word^}")
  done
  printf '%s' "${out[*]}"
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

menu_choice_label() {
  local idx="$1"
  local code=0
  local ch=""
  [[ "$idx" =~ ^[0-9]+$ ]] || return 1
  if ((idx <= 9)); then
    printf '%s' "$idx"
    return 0
  fi
  if ((idx <= 35)); then
    code=$((97 + idx - 10))
    printf -v ch '%b' "\\$(printf '%03o' "$code")"
    printf '%s' "$ch"
    return 0
  fi
  printf '%s' "$idx"
}

menu_choice_range_hint() {
  local max_idx="$1"
  [[ "$max_idx" =~ ^[0-9]+$ ]] || {
    printf '0'
    return 0
  }
  if ((max_idx <= 9)); then
    printf '0-%s' "$max_idx"
    return 0
  fi
  if ((max_idx <= 35)); then
    printf '0-9,a-%s' "$(menu_choice_label "$max_idx")"
    return 0
  fi
  printf '0-9,a-z,36-%s' "$max_idx"
}

menu_choice_index_from_key() {
  local key="$1"
  local max_idx="$2"
  local ord=0
  local idx=0

  [[ "$max_idx" =~ ^[0-9]+$ ]] || return 1

  if [[ "$key" =~ ^[0-9]$ ]]; then
    idx=$((10#$key))
  elif [[ "$key" =~ ^[[:alpha:]]$ ]]; then
    ord=$(printf '%d' "'$key")
    if ((ord < 97 || ord > 122)); then
      return 1
    fi
    idx=$((ord - 97 + 10))
  else
    return 1
  fi

  if ((idx < 0 || idx > max_idx)); then
    return 1
  fi
  printf '%s' "$idx"
}

read_menu_choice_immediate() {
  local max_idx="$1"
  local key="" choice=""
  local line=""
  local max_num=0
  [[ "$max_idx" =~ ^[0-9]+$ ]] || {
    printf ''
    return 0
  }
  max_num=$((10#$max_idx))

  # Fallback for very large menus where base36 single-key labels are insufficient.
  if ((max_num > 35)); then
    if ! IFS= read -r line </dev/tty; then
      printf ''
      return 1
    fi
    line="$(normalize_search_query "$line")"
    if [[ "$line" =~ ^[0-9]+$ ]]; then
      choice=$((10#$line))
      if ((choice >= 0 && choice <= max_num)); then
        printf '%s' "$choice"
        return 0
      fi
    fi
    printf ''
    return 0
  fi

  if ! IFS= read -r -s -n 1 key </dev/tty; then
    printf ''
    return 1
  fi

  if [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
    printf ''
    return 0
  fi

  choice="$(menu_choice_index_from_key "$key" "$max_num" || true)"
  printf '%s' "$choice"
}

print_single_select_options_compact() {
  local values_var="$1"
  local counts_var="$2"
  local label_fn="$3"
  local max_cols="${4:-3}"
  local -n values_ref="$values_var"
  local -n counts_ref="$counts_var"
  local -a option_lines=()
  local -a col_widths=()
  local idx=0
  local line=""
  local term_cols=0
  local cols=1
  local min_cols=1
  local total=0
  local rows=0
  local row=0
  local col=0
  local pos=0
  local line_len=0
  local needed_width=0
  local last_col=-1
  local pad_width=0
  local label=""
  local choice_label=""

  while ((idx < ${#values_ref[@]})); do
    label="$("$label_fn" "${values_ref[$idx]}")"
    choice_label="$(menu_choice_label "$idx")"
    line="$(printf '%s) %s (%s)' "$choice_label" "$label" "${counts_ref[$idx]}")"
    option_lines+=("$line")
    idx=$((idx + 1))
  done

  total=${#option_lines[@]}
  ((total > 0)) || return 0

  if [[ "$max_cols" =~ ^[0-9]+$ ]] && ((max_cols > 0)); then
    cols="$max_cols"
  fi
  if ((cols > total)); then
    cols=$total
  fi
  if ((total >= 4 && cols >= 2)); then
    min_cols=2
  fi

  if [[ -t 1 ]]; then
    term_cols="${COLUMNS:-0}"
    if [[ ! "$term_cols" =~ ^[0-9]+$ || "$term_cols" == "0" ]]; then
      term_cols="$(tput cols 2>/dev/null || echo 0)"
    fi
    [[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=0
  fi

  # Keep layout compact: try requested columns first, then reduce only if terminal width cannot fit.
  if ((term_cols > 0 && cols > min_cols)); then
    while ((cols > min_cols)); do
      rows=$(((total + cols - 1) / cols))
      col_widths=()
      for ((col = 0; col < cols; col++)); do
        col_widths+=("0")
      done
      for ((row = 0; row < rows; row++)); do
        for ((col = 0; col < cols; col++)); do
          # Fill options by column (top-to-bottom) before moving right.
          pos=$((row + (col * rows)))
          ((pos < total)) || continue
          line_len=${#option_lines[$pos]}
          if ((line_len > col_widths[$col])); then
            col_widths[$col]=$line_len
          fi
        done
      done
      needed_width=0
      for ((col = 0; col < cols; col++)); do
        needed_width=$((needed_width + col_widths[$col]))
        if ((col < cols - 1)); then
          needed_width=$((needed_width + 2))
        fi
      done
      if ((needed_width <= term_cols)); then
        break
      fi
      cols=$((cols - 1))
    done
  fi

  if ((cols <= 1 || total == 1)); then
    for line in "${option_lines[@]}"; do
      printf '%s\n' "$line"
    done
    return 0
  fi

  rows=$(((total + cols - 1) / cols))
  col_widths=()
  for ((col = 0; col < cols; col++)); do
    col_widths+=("0")
  done
  for ((row = 0; row < rows; row++)); do
    for ((col = 0; col < cols; col++)); do
      pos=$((row + (col * rows)))
      ((pos < total)) || continue
      line_len=${#option_lines[$pos]}
      if ((line_len > col_widths[$col])); then
        col_widths[$col]=$line_len
      fi
    done
  done

  for ((row = 0; row < rows; row++)); do
    last_col=-1
    for ((col = cols - 1; col >= 0; col--)); do
      pos=$((row + (col * rows)))
      if ((pos < total)); then
        last_col=$col
        break
      fi
    done
    ((last_col >= 0)) || continue

    for ((col = 0; col <= last_col; col++)); do
      pos=$((row + (col * rows)))
      line="${option_lines[$pos]}"
      if ((col < last_col)); then
        pad_width=$((col_widths[$col] + 2))
        printf '%-*s' "$pad_width" "$line"
      else
        printf '%s' "$line"
      fi
    done
    printf '\n'
  done
}

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

rich_escape() {
  printf '%s' "$1" | sed -e 's/\[/\\[/g' -e 's/\]/\\]/g'
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

  local gradient=("#ff8c00" "#ff9800" "#ffa500" "#ffb300" "#ffc107" "#ffca28" "#ffd54f" "#ffe082" "#ffecb3" "#fff1c2" "#fff7d6")
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

color_text_hex() {
  local hex="$1"
  local text="$2"
  local weight="${3:-normal}"
  hex="${hex#\#}"
  if [[ ${#hex} -ne 6 ]]; then
    printf '%s' "$text"
    return
  fi
  local r g b
  r=$((16#${hex:0:2}))
  g=$((16#${hex:2:2}))
  b=$((16#${hex:4:2}))
  if [[ "$weight" == "bold" ]]; then
    printf '\033[1;38;2;%d;%d;%dm%s\033[0m' "$r" "$g" "$b" "$text"
  else
    printf '\033[38;2;%d;%d;%dm%s\033[0m' "$r" "$g" "$b" "$text"
  fi
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

  if [[ "$USE_COLOR" != true ]]; then
    if [[ -n "$db_status" ]]; then
      printf 'Audlint-CLI | view=%s class=%s sort=%s/%s | page=%s/%s | total=%s | queue=%s | next_run=%s | [%s]\n' \
        "$view" "$class" "$sort_key" "$sort_dir" "$page" "$total_pages" "$total_rows" "$queue_rows" "$next_run" "$db_status"
    else
      printf 'Audlint-CLI | view=%s class=%s sort=%s/%s | page=%s/%s | total=%s | queue=%s | next_run=%s\n' \
        "$view" "$class" "$sort_key" "$sort_dir" "$page" "$total_pages" "$total_rows" "$queue_rows" "$next_run"
    fi
    return
  fi

  local seg1 seg2 seg3 seg4 seg5 seg6 seg7
  seg1="$(color_text_hex "#ff8c00" "Audlint-CLI" bold)"
  seg2="$(color_text_hex "#ffab2e" "view=$view class=$class sort=$sort_key/$sort_dir" bold)"
  seg3="$(color_text_hex "#ffc24a" "page=$page/$total_pages" bold)"
  seg4="$(color_text_hex "#ffd46b" "total=$total_rows" bold)"
  seg5="$(color_text_hex "#ffe18b" "queue=$queue_rows" bold)"
  seg6="$(color_text_hex "#fff0b3" "next_run=$next_run" bold)"
  if [[ -n "$db_status" ]]; then
    seg7="$(color_text_hex "#ff5252" "$db_status" bold)"
    printf '%b | %b | %b | %b | %b | %b | %b\n' "$seg1" "$seg2" "$seg3" "$seg4" "$seg5" "$seg6" "$seg7"
  else
    printf '%b | %b | %b | %b | %b | %b\n' "$seg1" "$seg2" "$seg3" "$seg4" "$seg5" "$seg6"
  fi
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
    if ((idx == 9)); then
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
  row_select_sql="$(table_select_sql_block)"
  sqlite3 -separator $'\t' -noheader "$DB_PATH" \
    "SELECT
${row_select_sql},
         ${KEYSET_CHECKED_SQL_EXPR},
         ${KEYSET_ARTIST_SQL_EXPR},
         ${KEYSET_ALBUM_SQL_EXPR},
         COALESCE(year_int,0),
         id
       FROM album_quality
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
  local c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15
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

  while IFS=$'\t' read -r c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15; do
    [[ -n "$c0$c1$c2$c3$c4$c5$c6$c7$c8$c9$c10$c11$c12$c13$c14$c15" ]] || continue
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
    if [[ "$HAS_COL_CHECKED_SORT" == "1" ]]; then
      printf 'COALESCE(checked_sort,0)'
    else
      printf 'COALESCE(last_checked_at,0)'
    fi
    ;;
  score) printf 'COALESCE(quality_score,9999)' ;;
  grade)
    if [[ "$HAS_COL_GRADE_RANK" == "1" ]]; then
      printf 'COALESCE(grade_rank,6)'
    else
      grade_rank_expr
    fi
    ;;
  artist)
    if [[ "$HAS_COL_ARTIST_NORM" == "1" ]]; then
      printf "COALESCE(NULLIF(artist_norm,''),COALESCE(artist_lc,''))"
    else
      printf "COALESCE(artist_lc,'')"
    fi
    ;;
  album)
    if [[ "$HAS_COL_ALBUM_NORM" == "1" ]]; then
      printf "COALESCE(NULLIF(album_norm,''),COALESCE(album_lc,''))"
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
    if [[ "$HAS_COL_CODEC_NORM" == "1" ]]; then
      printf "COALESCE(NULLIF(codec_norm,''),'~unknown')"
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
    printf ', COALESCE(quality_score,9999) ASC'
    ;;
  replace)
    printf ', %s ASC, COALESCE(quality_score,9999) ASC' "$(grade_rank_expr)"
    ;;
  fail)
    printf ', %s ASC, COALESCE(quality_score,9999) ASC' "$(grade_rank_expr)"
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
  local clauses=()
  local class_clause=""
  class_clause="$(class_clause_for_value "$CLASS_FILTER" || true)"
  if [[ -n "$class_clause" ]]; then
    clauses+=("$class_clause")
  fi
  if [[ "$FILTER_RARITY_ONLY" == "1" ]]; then
    clauses+=("COALESCE(rarity,0)=1")
  else
    clauses+=("COALESCE(rarity,0)=0")
  fi
  if [[ "$FILTER_REPLACE_OR_UPSCALED" == "1" ]]; then
    clauses+=("(COALESCE(needs_replacement,0)=1 OR COALESCE(needs_recode,0)=1)")
  else
    if [[ "$FILTER_REPLACE_ONLY" == "1" ]]; then
      clauses+=("COALESCE(needs_replacement,0)=1")
    fi
    if [[ "$FILTER_UPSCALED_ONLY" == "1" ]]; then
      clauses+=("COALESCE(needs_recode,0)=1")
    fi
  fi
  if [[ "$FILTER_MIXED_ONLY" == "1" ]]; then
    clauses+=("COALESCE(scan_failed,0)=1")
  fi
  if [[ "$ACTIVE_VIEW" == "encode_only" && "$HAS_COL_LAST_RECODED_AT" == "1" ]]; then
    clauses+=("COALESCE(last_recoded_at,0)=0")
  fi
  if [[ "$ACTIVE_VIEW" == "encode_only" ]]; then
    clauses+=("COALESCE(scan_failed,0)=0")
    clauses+=("$(encode_lossy_exclusion_clause_sql)")
  fi
  local search_clause=""
  search_clause="$(search_clause_for_query "$SEARCH_QUERY")"
  if [[ -n "$search_clause" ]]; then
    clauses+=("$search_clause")
  fi
  if [[ "$include_codec_filter" == "yes" && "$CODEC_FILTER" != "all" ]]; then
    if [[ "$CODEC_FILTER" == "~unknown" ]]; then
      if [[ "$HAS_COL_CODEC_NORM" == "1" ]]; then
        clauses+=("(codec_norm IS NULL OR codec_norm='')")
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
      if [[ "$HAS_COL_PROFILE_NORM" == "1" ]]; then
        clauses+=("(profile_norm IS NULL OR profile_norm='')")
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
}

roadmap_queue_count() {
  local count
  count="$(
    sqlite3 -noheader "$DB_PATH" \
      "SELECT CASE
         WHEN EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='scan_roadmap')
         THEN (SELECT COUNT(*) FROM scan_roadmap)
         ELSE 0
       END;" 2>/dev/null || echo 0
  )"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
}

next_run_hhmm() {
  local interval="$CRON_INTERVAL_MIN"
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
  label="$(date -r "$next_epoch" "+%H:%M" 2>/dev/null || true)"
  if [[ -z "$label" ]]; then
    label="$(date -d "@$next_epoch" "+%H:%M" 2>/dev/null || true)"
  fi
  [[ -n "$label" ]] || label="--:--"
  printf '%s' "$label"
}

view_button() {
  local key="$1"
  local label="$2"
  local view="$3"
  local force_active="${4:-}"   # optional: pass "1" to force active marker
  local suffix=""
  if [[ "$ACTIVE_VIEW" == "$view" || "$force_active" == "1" ]]; then
    suffix="*"
  fi
  if [[ "$USE_COLOR" != true ]]; then
    printf '[%s %s%s]' "$key" "$label" "$suffix"
    return
  fi
  printf '%b%b%b%b' \
    "$(color_text_hex "#aee8ff" "[")" \
    "$(color_text_hex "#ffffff" "$key" bold)" \
    "$(color_text_hex "#aee8ff" " ${label}${suffix}")" \
    "$(color_text_hex "#aee8ff" "]")"
}

hint_button() {
  local key="$1"
  local label="$2"
  if [[ "$USE_COLOR" != true ]]; then
    printf '[%s %s]' "$key" "$label"
    return
  fi
  printf '%b%b%b%b' \
    "$(color_text_hex "#aee8ff" "[")" \
    "$(color_text_hex "#ffffff" "$key" bold)" \
    "$(color_text_hex "#aee8ff" " ${label}")" \
    "$(color_text_hex "#aee8ff" "]")"
}

nav_separator() {
  if [[ "$USE_COLOR" != true ]]; then
    printf ' | '
    return
  fi
  printf '%b' "$(color_text_hex "#aee8ff" " | ")"
}

show_flac_action() {
  [[ "$ACTIVE_VIEW" == "encode_only" && "$FILTER_UPSCALED_ONLY" == "1" ]]
}

show_transfer_action() {
  [[ -n "$MEDIA_PLAYER_PATH" && -d "$MEDIA_PLAYER_PATH" && -w "$MEDIA_PLAYER_PATH" ]]
}

show_lyrics_action() {
  command_ref_available "$LYRICS_SEEK_BIN"
}

print_hint_buttons_line() {
  local first=1
  local btn
  for btn in "$@"; do
    if ((first == 1)); then
      printf '%s' "$btn"
      first=0
    else
      printf ' %s' "$btn"
    fi
  done
  printf '\n'
}

print_nav_line() {
  local show_flac=0
  local show_transfer=0
  if show_flac_action; then
    show_flac=1
  fi
  if show_transfer_action; then
    show_transfer=1
  fi
  printf '%s %s %s %s %s %s %s%s%s %s%s%s\n' \
    "$(view_button 0 Last default)" \
    "$(view_button 1 Grade grade_first)" \
    "$(view_button 2 Codecs codec_inventory "$([[ "$CODEC_FILTER" != "all" ]] && printf 1 || printf 0)")" \
    "$(view_button 3 Profiles encoding_inventory "$([[ "$PROFILE_FILTER" != "all" ]] && printf 1 || printf 0)")" \
    "$(view_button 4 'Scan Failed' scan_failed)" \
    "$(view_button 5 Rarities rarity_only)" \
    "$(view_button e Recode encode_only)" \
    "$(nav_separator)" \
    "$(hint_button a Asc)" \
    "$(hint_button d Desc)" \
    "$(nav_separator)" \
    "$(hint_button c 'Clear Filters')"
  local -a hint_buttons=()
  if [[ "$FILTER_RARITY_ONLY" == "1" ]]; then
    hint_buttons=(
      "$(hint_button / Search)"
      "$(hint_button r MarkRare)"
      "$(hint_button u Unmark)"
      "$(hint_button n Next)"
      "$(hint_button p Prev)"
      "$(hint_button x Delete)"
      "$(hint_button s Sync)"
    )
  else
    hint_buttons=(
      "$(hint_button / Search)"
      "$(hint_button r MarkRare)"
      "$(hint_button n Next)"
      "$(hint_button p Prev)"
      "$(hint_button x Delete)"
      "$(hint_button s Sync)"
    )
  fi
  if ((show_flac == 1)); then
    hint_buttons+=("$(hint_button f FLAC)")
  fi
  if ((show_transfer == 1)); then
    hint_buttons+=("$(hint_button t Transfer)")
  fi
  hint_buttons+=("$(hint_button l Lyrics)")
  if [[ -n "$LIBRARY_ROOT" && -x "$QTY_SEEK_BIN" ]]; then
    hint_buttons+=("$(hint_button m Maintain)")
    hint_buttons+=("$(hint_button L Log)")
    hint_buttons+=("$(hint_button P Purge)")
  fi
  hint_buttons+=("$(hint_button q Quit)")
  print_hint_buttons_line "${hint_buttons[@]}"
}

print_key_prompt() {
  local prompt='q=quit > '
  if [[ "$USE_COLOR" == true ]]; then
    printf '%b' "$(color_text_hex "#ffd98f" "$prompt" bold)"
    return 0
  fi
  printf '%s' "$prompt"
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

row_action_prompt_for_mode() {
  local action_label="select rows"
  case "$1" in
  delete) action_label="delete rows" ;;
  mark_rarity) action_label="mark as rarity" ;;
  unmark_rarity) action_label="unmark rarity" ;;
  recode_flac) action_label="select rows for FLAC recode" ;;
  lyrics_seek) action_label="select rows for lyrics seek" ;;
  transfer) action_label="transfer rows to player" ;;
  esac
  printf '%s (%s; blank=cancel) > ' "$action_label" "$(row_selection_options_hint)"
}

extract_target_profile_from_recode() {
  local recode="$1"
  local target=""
  target="$(printf '%s\n' "$recode" | sed -nE 's/.*[Ss]tore[[:space:]]+as[[:space:]]+([0-9]+([.][0-9]+)?\/[0-9]{1,2}).*/\1/p' | head -n 1)"
  if [[ -z "$target" ]]; then
    target="$(printf '%s\n' "$recode" | sed -nE 's/.*RECODE[[:space:]]+TO[[:space:]]+([0-9]+([.][0-9]+)?\/[0-9]{1,2}).*/\1/p' | head -n 1)"
  fi
  if [[ -z "$target" ]]; then
    target="$(printf '%s\n' "$recode" | grep -Eo '[0-9]+([.][0-9]+)?/[0-9]{1,2}' | head -n 1 || true)"
  fi
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
  local artist_dir album_dir release_dir
  artist_dir="$(player_path_component "$artist")"
  album_dir="$(player_path_component "$album")"
  if [[ "$year" =~ ^[0-9]{4}$ ]] && ((year > 0)); then
    release_dir="${year} - ${album_dir}"
  else
    release_dir="$album_dir"
  fi
  printf '%s/%s/%s' "$MEDIA_PLAYER_PATH" "$artist_dir" "$release_dir"
}

transfer_first_audio_file() {
  local source_path="$1"
  local had_nullglob=0
  local had_nocaseglob=0
  local f

  shopt -q nullglob && had_nullglob=1
  shopt -q nocaseglob && had_nocaseglob=1
  shopt -s nullglob nocaseglob

  for f in \
    "$source_path"/*.flac \
    "$source_path"/*.alac \
    "$source_path"/*.m4a \
    "$source_path"/*.wav \
    "$source_path"/*.dsf \
    "$source_path"/*.dff \
    "$source_path"/*.wv \
    "$source_path"/*.ape \
    "$source_path"/*.mp4 \
    "$source_path"/*.mp3 \
    "$source_path"/*.ogg \
    "$source_path"/*.opus; do
    [[ -f "$f" ]] || continue
    printf '%s' "$f"
    ((had_nullglob == 1)) || shopt -u nullglob
    ((had_nocaseglob == 1)) || shopt -u nocaseglob
    return 0
  done

  ((had_nullglob == 1)) || shopt -u nullglob
  ((had_nocaseglob == 1)) || shopt -u nocaseglob

  while IFS= read -r -d '' f; do
    printf '%s' "$f"
    return 0
  done < <(find "$source_path" -type f \( \
    -iname '*.flac' -o \
    -iname '*.alac' -o \
    -iname '*.m4a' -o \
    -iname '*.wav' -o \
    -iname '*.dsf' -o \
    -iname '*.dff' -o \
    -iname '*.wv' -o \
    -iname '*.ape' -o \
    -iname '*.mp4' -o \
    -iname '*.mp3' -o \
    -iname '*.ogg' -o \
    -iname '*.opus' \
    \) -print0 2>/dev/null)

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
    key="${key,,}"
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
    key="${key,,}"
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

run_transfer_for_row_ids() {
  local selected_ids=("$@")
  local transfer_log="${LIBRARY_BROWSER_TRANSFER_LOG:-/tmp/library_browser_transfer.last.log}"
  : >"$transfer_log" 2>/dev/null || transfer_log=""
  if [[ -n "$transfer_log" ]]; then
    printf '[%s] transfer start ids=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${selected_ids[*]:-<none>}" >>"$transfer_log" 2>/dev/null || true
  fi
  if ! show_transfer_action; then
    ACTION_MESSAGE="Transfer unavailable: MEDIA_PLAYER_PATH is missing or not writable."
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] abort: MEDIA_PLAYER_PATH unavailable/unwritable (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${MEDIA_PLAYER_PATH:-<empty>}" >>"$transfer_log" 2>/dev/null || true
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

  local row_id row artist album year source_path dest_dir transfer_year
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
    if [[ -z "$source_path" || ! -d "$source_path" ]]; then
      rm -f "$manifest_file"
      ACTION_MESSAGE="Transfer failed: source path unavailable for $artist - $album."
      if [[ -n "$transfer_log" ]]; then
        printf '[%s] abort: source missing for id=%s artist=%s album=%s path=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$row_id" "$artist" "$album" "${source_path:-<empty>}" >>"$transfer_log" 2>/dev/null || true
      fi
      return 1
    fi
    transfer_year="$(transfer_year_for_source "$source_path" "$year")"
    [[ "$transfer_year" =~ ^[12][0-9]{3}$ ]] || transfer_year="$year"
    dest_dir="$(player_album_dest_dir "$artist" "$transfer_year" "$album")"
    if [[ -n "$transfer_log" ]]; then
      printf '[%s] row id=%s source=%s year_db=%s year_transfer=%s dest=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$row_id" "$source_path" "$year" "$transfer_year" "$dest_dir" >>"$transfer_log" 2>/dev/null || true
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$artist" "$album" "$transfer_year" "$source_path" "$dest_dir" >>"$manifest_file"
  done

  local runner_script
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
#!/opt/homebrew/bin/bash
set -Eeuo pipefail
manifest_file="$1"
rsync_bin="$2"
sync_bin="$3"
player_path="$4"
log_file="${5:-}"
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
  [[ "$title_row" =~ ^[0-9]+$ ]] || return 0
  [[ "$term_cols" =~ ^[0-9]+$ ]] || return 0
  ((term_cols > 0)) || return 0
  local text="${idx} of ${total} | ${artist} - ${year} - ${album} | ${action}"
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
    local part1 part2 part3
    part1="${idx} of ${total}"
    part2="${artist} - ${year} - ${album}"
    part3="${action}"
    rendered=$'\033[1;38;2;77;163;255m'"$part1"$'\033[0m'
    rendered+=$'\033[1;38;2;111;141;255m | \033[0m'
    rendered+=$'\033[1;38;2;142;109;245m'"$part2"$'\033[0m'
    rendered+=$'\033[1;38;2;179;140;255m | \033[0m'
    rendered+=$'\033[1;38;2;208;179;255m'"$part3"$'\033[0m'
  fi
  # Right-aligned titles shift horizontally as text length changes; clear the
  # whole row first to avoid stale glyphs from prior renders.
  printf '\033[s\033[%s;1H\033[K\033[%s;%sH%s\033[u' "$title_row" "$title_row" "$col" "$rendered"
}

printf 'Media player path: %s\n\n' "$player_path"
rsync_args=(-av --delete --itemize-changes)
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
  if [[ -e "$dest_dir" ]]; then
    printf 'deleting existing destination: %s\n' "$dest_dir"
    rm -rf "$dest_dir"
  fi
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
  fi

  local transfer_ok=0
  local transfer_rc=0
  local first_title=""
  if IFS=$'\x1f' read -r first_artist first_album first_year _first_source _first_dest <"$manifest_file"; then
    if [[ -n "${first_artist:-}" ]]; then
      first_title="1 of ${#selected_ids[@]} | ${first_artist} - ${first_year} - ${first_album} | transferring..."
    fi
  fi
  if VIRTWIN_RIGHT_TITLE="$first_title" virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "transfer-player" \
    "$runner_script" "$manifest_file" "$RSYNC_BIN" "$SYNC_BIN" "$MEDIA_PLAYER_PATH" "$transfer_log"; then
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
    ACTION_MESSAGE="Transfer completed for ${#selected_ids[@]} album(s)."
    return 0
  fi
  if [[ -n "$transfer_log" && -s "$transfer_log" ]]; then
    ACTION_MESSAGE="Transfer failed (exit $transfer_rc). Log: $transfer_log"
  else
    ACTION_MESSAGE="Transfer failed (exit $transfer_rc)."
  fi
  return 1
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
#!/opt/homebrew/bin/bash
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
  printf '\033[s\033[%s;1H\033[K\033[%s;%sH%s\033[u' "$title_row" "$title_row" "$col" "$rendered"
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
  if VIRTWIN_RIGHT_TITLE="$first_title" virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "lyrics-seek" \
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

  local row row_artist row_album row_year row_source_path row_recode row_needs_recode
  row="$(
    sqlite3 -separator $'\t' -noheader "$DB_PATH" \
      "SELECT
         artist,
         album,
         COALESCE(year_int,0),
         COALESCE(source_path,''),
         COALESCE(recode_recommendation,''),
         COALESCE(needs_recode,0),
         COALESCE(last_recoded_at,0)
       FROM album_quality
       WHERE id=$row_id
       LIMIT 1;" 2>/dev/null || true
  )"
  if [[ -z "$row" ]]; then
    ACTION_MESSAGE="Row not found for FLAC action."
    return 1
  fi
  IFS=$'\t' read -r row_artist row_album row_year row_source_path row_recode row_needs_recode row_last_recoded <<< "$row"
  [[ "$row_needs_recode" =~ ^[0-9]+$ ]] || row_needs_recode=0
  if ((row_needs_recode != 1)); then
    ACTION_MESSAGE="Selected row is not actionable (needs_recode != Y)."
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
  local target_profile
  target_profile="$(extract_target_profile_from_recode "$row_recode")"
  if [[ -z "$target_profile" ]]; then
    ACTION_MESSAGE="Unable to extract target profile from recode recommendation."
    return 1
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
#!/opt/homebrew/bin/bash
set -Eeuo pipefail
source_path="$1"
target_profile="$2"
any2flac_bin="$3"
artist="$4"
album="$5"
year="$6"
batch_index="${7:-1}"
batch_total="${8:-1}"
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
  printf '\033[s\033[%s;1H\033[K\033[%s;%sH%s\033[u' "$title_row" "$title_row" "$status_col" "$rendered_status"
}

virtwin_status_set "planning..."

printf 'Album: %s - %s (%s)\n' "$artist" "$album" "$year"
printf 'Source: %s\n' "$source_path"
printf 'Target profile: %s\n' "$target_profile"
printf '\n'
printf '[1/2] Recode plan\n'
"$any2flac_bin" --profile "$target_profile" --dir "$source_path" --with-boost --plan-only
printf '\n'
virtwin_status_set "encoding..."
printf '[2/2] Recode convert\n'
"$any2flac_bin" --profile "$target_profile" --dir "$source_path" --with-boost --yes
printf '\nWorkflow completed successfully.\n'
EOF
  chmod +x "$runner_script"

  local workflow_ok=0
  local virtwin_wait_flag=()
  if [[ "$wait_for_key" != "1" ]]; then
    virtwin_wait_flag=(--no-wait)
  fi
  local right_title="${batch_index} of ${batch_total} | ${row_artist} - ${row_year} - ${row_album} | planning..."
  if VIRTWIN_RIGHT_TITLE="$right_title" virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "recode+autoboost" \
    "${virtwin_wait_flag[@]}" \
    "$runner_script" "$row_source_path" "$target_profile" "$ANY2FLAC_BIN" "$row_artist" "$row_album" "$row_year" "$batch_index" "$batch_total"; then
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

  virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "recode-report" cat "$report_file" || true
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
    changed_count="$(sqlite3 -noheader "$DB_PATH" "DELETE FROM album_quality WHERE id IN ($ids_csv); SELECT changes();" 2>/dev/null || echo 0)"
    [[ "$changed_count" =~ ^[0-9]+$ ]] || changed_count=0
    ACTION_MESSAGE="Deleted ${changed_count} row(s)."
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
  echo "Error: LIBRARY_DB is not set. Example: LIBRARY_DB='\$SRC/library.sqlite'" >&2
  exit 2
fi

if ! has_bin sqlite3; then
  echo "Error: sqlite3 not found" >&2
  exit 1
fi

if ! table_require_rich; then
  echo "Error: rich table renderer unavailable" >&2
  exit 1
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
refresh_sort_key_exprs

if [[ "$INTERACTIVE" == "auto" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    INTERACTIVE="yes"
  else
    INTERACTIVE="no"
  fi
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
  if [[ "$INTERACTIVE" == "yes" && "$COUNT_CACHE_VALID" == "1" && "$COUNT_CACHE_KEY" == "$state_count_key" ]]; then
    total_rows="$COUNT_CACHE_VALUE"
  else
    total_rows="$(sqlite3 -noheader "$DB_PATH" "SELECT COUNT(*) FROM album_quality $WHERE_SQL;" 2>/dev/null || echo 0)"
    [[ "$total_rows" =~ ^[0-9]+$ ]] || total_rows=0
    if [[ "$INTERACTIVE" == "yes" ]]; then
      COUNT_CACHE_KEY="$state_count_key"
      COUNT_CACHE_VALUE="$total_rows"
      COUNT_CACHE_VALID=1
    fi
  fi

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
  if [[ -z "$rows_raw" ]]; then
    rows_raw="$(fetch_rows_raw "$WHERE_SQL" "$ORDER_SQL" "LIMIT $PAGE_SIZE OFFSET $offset")"
  fi
  rows="$(parse_rows_raw "$rows_raw")"
  rows="$(decorate_rows_for_sort_column "$rows" "$SORT_KEY")"
  page_row_ids=()
  if [[ "$INTERACTIVE" == "yes" && -n "$ROW_ACTION_MODE" ]]; then
    c0="" c1="" c2="" c3="" c4="" c5="" c6="" c7="" c8="" c9="" c10="" c11="" c12="" c13="" c14="" c15=""
    while IFS=$'\t' read -r c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15; do
      [[ -n "$c0$c1$c2$c3$c4$c5$c6$c7$c8$c9$c10$c11$c12$c13$c14$c15" ]] || continue
      [[ "$c15" =~ ^[0-9]+$ ]] || continue
      page_row_ids+=("$c15")
    done <<< "$rows_raw"
  fi

  if [[ "$INTERACTIVE" == "yes" ]]; then
    printf '\033[H\033[2J'
  fi
  queue_rows="$(roadmap_queue_count)"
  next_run_label="$(next_run_hhmm)"
  print_status_line \
    "$(view_title_for_key "$ACTIVE_VIEW")" "$CLASS_FILTER" "$SORT_KEY" "$SORT_DIR" "$PAGE" "$total_pages" "$total_rows" "$queue_rows" "$next_run_label" "$DB_STATUS_LABEL"
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
    display_rows="$(prepend_row_numbers "$rows")"
  fi
  printf '%s\n' "$display_rows" | table_render_tsv \
    "$table_headers" \
    "$table_widths"

  if [[ "$INTERACTIVE" != "yes" ]]; then
    break
  fi

  if [[ -n "$ROW_ACTION_MODE" ]]; then
    max_delete_idx=${#page_row_ids[@]}
    if ((max_delete_idx == 0)); then
      ACTION_MESSAGE="No rows on current page for action."
      ROW_ACTION_MODE=""
      continue
    fi
    printf '%s' "$(row_action_prompt_for_mode "$ROW_ACTION_MODE")"
    delete_input=""
    if IFS= read -r delete_input </dev/tty; then
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
      selected_indexes=()
      IFS=' ' read -r -a selected_indexes <<< "$selected_idx_line"
      for selected_idx in "${selected_indexes[@]}"; do
        [[ "$selected_idx" =~ ^[0-9]+$ ]] || continue
        row_pos=$((selected_idx - 1))
        if ((row_pos >= 0 && row_pos < ${#page_row_ids[@]})); then
          selected_row_ids+=("${page_row_ids[$row_pos]}")
        fi
      done
      if ((${#selected_row_ids[@]} == 0)); then
        ACTION_MESSAGE="No valid rows selected."
        ROW_ACTION_MODE=""
        continue
      fi
      if [[ "$ROW_ACTION_MODE" == "transfer" ]]; then
        run_transfer_for_row_ids "${selected_row_ids[@]}" || true
        ROW_ACTION_MODE=""
        continue
      fi
      if [[ "$ROW_ACTION_MODE" == "lyrics_seek" ]]; then
        run_lyrics_seek_for_row_ids "${selected_row_ids[@]}" || true
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
    printf 'Really Quit? [y|n|c] > '
    quit_choice=""
    if ! IFS= read -r -n 1 quit_choice </dev/tty; then
      printf '\n'
      quit_choice="n"
    else
      printf '\n'
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

  print_key_prompt
  key=""
  if ! IFS= read -r -n 1 key </dev/tty; then
    printf '\n'
    break
  fi
  printf '\n'

  case "$key" in
  0)
    apply_view_preset default
    PAGE=1
    ;;
  1)
    apply_view_preset grade_first
    PAGE=1
    ;;
  2)
    ACTIVE_VIEW="custom"
    base_where_sql="$(build_where_sql no || true)"
    codec_norm_sql_expr="$(codec_norm_expr_sql)"
    codec_all_count="$(sqlite3 -noheader "$DB_PATH" "SELECT COUNT(*) FROM album_quality $base_where_sql;" 2>/dev/null || echo 0)"
    [[ "$codec_all_count" =~ ^[0-9]+$ ]] || codec_all_count=0
    codec_rows="$(
      sqlite3 -separator $'\t' -noheader "$DB_PATH" \
        "SELECT
           COALESCE(NULLIF(${codec_norm_sql_expr},''),'~unknown') AS codec_key,
           COUNT(*)
         FROM album_quality
         $base_where_sql
         GROUP BY codec_key
         ORDER BY codec_key ASC;" 2>/dev/null || true
    )"
    codec_keys=("all")
    codec_counts=("$codec_all_count")
    if [[ -n "$codec_rows" ]]; then
      while IFS=$'\t' read -r codec_key codec_count; do
        [[ -n "$codec_key" ]] || continue
        codec_keys+=("$codec_key")
        codec_counts+=("$codec_count")
      done <<< "$codec_rows"
    fi
    max_idx=$(( ${#codec_keys[@]} - 1 ))
    printf 'codec filter (single select, current=%s)\n' "$(codec_filter_label "$CODEC_FILTER")"
    print_single_select_options_compact codec_keys codec_counts codec_filter_label 3
    printf 'choose codec [%s] (auto-apply) > ' "$(menu_choice_range_hint "$max_idx")"
    codec_choice="$(read_menu_choice_immediate "$max_idx" || true)"
    printf '\n'
    if [[ -n "$codec_choice" ]] && [[ "$codec_choice" =~ ^[0-9]+$ ]] && ((codec_choice >= 0 && codec_choice <= max_idx)); then
      CODEC_FILTER="${codec_keys[$codec_choice]}"
    fi
    PAGE=1
    ;;
  3)
    ACTIVE_VIEW="custom"
    base_where_sql="$(build_where_sql yes no || true)"
    profile_norm_sql_expr="$(profile_norm_expr_sql)"
    profile_all_count="$(sqlite3 -noheader "$DB_PATH" "SELECT COUNT(*) FROM album_quality $base_where_sql;" 2>/dev/null || echo 0)"
    [[ "$profile_all_count" =~ ^[0-9]+$ ]] || profile_all_count=0
    profile_rows="$(
      sqlite3 -separator $'\t' -noheader "$DB_PATH" \
        "SELECT
           COALESCE(NULLIF(${profile_norm_sql_expr},''),'~unknown') AS profile_key,
           COUNT(*)
         FROM album_quality
         $base_where_sql
         GROUP BY profile_key
         ORDER BY
           CASE
             WHEN profile_key='~unknown' THEN 3
             WHEN INSTR(profile_key,'/')>0 THEN 0
             ELSE 2
           END ASC,
           CASE
             WHEN INSTR(profile_key,'/')>0 THEN
               CASE
                 WHEN LOWER(TRIM(SUBSTR(profile_key,INSTR(profile_key,'/')+1)))='64f' THEN 640
                 WHEN LOWER(TRIM(SUBSTR(profile_key,INSTR(profile_key,'/')+1)))='32f' THEN 320
                 WHEN LOWER(TRIM(SUBSTR(profile_key,INSTR(profile_key,'/')+1))) GLOB '[0-9][0-9]*'
                   THEN CAST(LOWER(TRIM(SUBSTR(profile_key,INSTR(profile_key,'/')+1))) AS INTEGER)*10
                 ELSE 0
               END
             ELSE 0
           END DESC,
           CASE
             WHEN INSTR(profile_key,'/')>0 THEN
               CASE
                 WHEN TRIM(SUBSTR(profile_key,1,INSTR(profile_key,'/')-1)) GLOB '[0-9]*'
                   OR TRIM(SUBSTR(profile_key,1,INSTR(profile_key,'/')-1)) GLOB '[0-9]*.[0-9]*'
                   THEN CAST(TRIM(SUBSTR(profile_key,1,INSTR(profile_key,'/')-1)) AS REAL)
                 ELSE 0
               END
             ELSE 0
           END DESC,
           profile_key ASC;" 2>/dev/null || true
    )"
    profile_keys=("all")
    profile_counts=("$profile_all_count")
    if [[ -n "$profile_rows" ]]; then
      while IFS=$'\t' read -r profile_key profile_count; do
        [[ -n "$profile_key" ]] || continue
        profile_keys+=("$profile_key")
        profile_counts+=("$profile_count")
      done <<< "$profile_rows"
    fi
    max_idx=$(( ${#profile_keys[@]} - 1 ))
    printf 'profile filter (single select, current=%s)\n' "$(profile_filter_label "$PROFILE_FILTER")"
    print_single_select_options_compact profile_keys profile_counts profile_filter_label 3
    printf 'choose profile [%s] (auto-apply) > ' "$(menu_choice_range_hint "$max_idx")"
    profile_choice="$(read_menu_choice_immediate "$max_idx" || true)"
    printf '\n'
    if [[ -n "$profile_choice" ]] && [[ "$profile_choice" =~ ^[0-9]+$ ]] && ((profile_choice >= 0 && profile_choice <= max_idx)); then
      PROFILE_FILTER="${profile_keys[$profile_choice]}"
    fi
    PAGE=1
    ;;
  4)
    apply_view_preset scan_failed
    PAGE=1
    ;;
  5)
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
    printf 'search artist/album (blank=clear) > '
    search_value=""
    if IFS= read -r search_value </dev/tty; then
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
      ROW_ACTION_MODE="mark_rarity"
    else
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    fi
    ;;
  u)
    if [[ "$DB_WRITABLE" != true ]]; then
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    elif [[ "$FILTER_RARITY_ONLY" == "1" ]]; then
      ROW_ACTION_MODE="unmark_rarity"
    else
      ACTION_MESSAGE="Unmark is available only in Rarities view."
    fi
    ;;
  x)
    if [[ "$DB_WRITABLE" == true ]]; then
      ROW_ACTION_MODE="delete"
    else
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    fi
    ;;
  s)
    if [[ -x "$SYNC_MUSIC_BIN" ]]; then
      if virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "sync-music" "$SYNC_MUSIC_BIN"; then
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
      ACTION_MESSAGE="FLAC recode is available only in Recode view filtered to needs_recode=Y. Press e first."
    else
      ROW_ACTION_MODE="recode_flac"
    fi
    ;;
  t)
    if ! show_transfer_action; then
      ACTION_MESSAGE="Transfer unavailable: MEDIA_PLAYER_PATH is missing or not writable."
    else
      ROW_ACTION_MODE="transfer"
    fi
    ;;
  l)
    if [[ "$DB_WRITABLE" != true ]]; then
      ACTION_MESSAGE="DB is read-only; mutation actions are disabled."
    elif ! show_lyrics_action; then
      ACTION_MESSAGE="Lyrics unavailable: lyrics_seek.sh not found ($LYRICS_SEEK_BIN)."
    else
      ROW_ACTION_MODE="lyrics_seek"
    fi
    ;;
  m)
    if [[ -z "$LIBRARY_ROOT" || ! -x "$QTY_SEEK_BIN" ]]; then
      ACTION_MESSAGE="Maintain unavailable: qty_seek.sh not found or LIBRARY_ROOT not set."
    else
      _maintain_rc=0
      VIRTWIN_LOG_FILE="$QTY_SEEK_LOG" \
        virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "maintain" --no-wait \
        "$QTY_SEEK_BIN" --max-albums "$QTY_SEEK_MAX_ALBUMS" "$LIBRARY_ROOT" || _maintain_rc=$?
      # Custom footer: offer full-discovery invalidation on success.
      if ((_maintain_rc == 0)); then
        invalidate_count_cache
        printf ' Press any key to return or [F] full rescan.'
      else
        printf ' Press any key to return.'
      fi
      _mkey=""
      IFS= read -r -n 1 -s _mkey </dev/tty || true
      if ((_maintain_rc == 0)) && [[ "${_mkey,,}" == "f" ]]; then
        rm -f "$QTY_SEEK_DISCOVERY_CACHE"
        VIRTWIN_LOG_FILE="$QTY_SEEK_LOG" \
          virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "maintain (full)" \
          "$QTY_SEEK_BIN" --max-albums "$QTY_SEEK_MAX_ALBUMS" --full-discovery "$LIBRARY_ROOT" || true
        invalidate_count_cache
        ACTION_MESSAGE="Full rescan completed. Log: $QTY_SEEK_LOG"
      elif ((_maintain_rc == 0)); then
        ACTION_MESSAGE="Maintenance scan completed. Log: $QTY_SEEK_LOG"
      else
        ACTION_MESSAGE="Maintenance scan failed. Log: $QTY_SEEK_LOG"
      fi
    fi
    ;;
  L)
    if [[ ! -f "$QTY_SEEK_LOG" ]]; then
      ACTION_MESSAGE="No log yet: $QTY_SEEK_LOG"
    else
      virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "log" \
        cat "$QTY_SEEK_LOG"
    fi
    ;;
  P)
    if [[ -z "$LIBRARY_ROOT" || ! -x "$QTY_SEEK_BIN" ]]; then
      ACTION_MESSAGE="Purge unavailable: qty_seek.sh not found or LIBRARY_ROOT not set."
    elif [[ "$DB_WRITABLE" != true ]]; then
      ACTION_MESSAGE="DB is read-only; purge action is disabled."
    else
      if virtwin_run_command 5 "${LINES:-$(tput lines)}" "${COLUMNS:-$(tput cols)}" "purge-missing" \
          "$QTY_SEEK_BIN" --purge-missing "$LIBRARY_ROOT"; then
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
tput clear
