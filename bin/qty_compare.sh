#!/usr/bin/env bash
# qty_compare.sh — compare two albums side-by-side using audlint quality metrics.

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
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/python.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/util.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/rich.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true

AUDLINT_VALUE_BIN="${AUDLINT_VALUE_BIN:-$SCRIPT_DIR/audlint-value.sh}"
PYTHON_BIN="${AUDL_PYTHON_BIN:-python3}"
AUDLINT_VALUE_PYTHON_BIN="${AUDLINT_VALUE_PYTHON_BIN:-$PYTHON_BIN}"
TRACK_DR_PY="${TRACK_DR_PY:-$SCRIPT_DIR/../lib/py/track_dr.py}"
NO_COLOR="${NO_COLOR:-}"
USE_COLOR=false
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  USE_COLOR=true
fi
if [[ "$USE_COLOR" == true ]]; then
  ui_init_colors
  C_RESET="${RESET:-}"
  C_BOLD="$(tput bold 2>/dev/null || printf '')"
  C_CYAN="${CYAN:-}"
  C_GREEN="${GREEN:-}"
  C_YELLOW="${YELLOW:-}"
  C_RED="${RED:-}"
  C_MAGENTA="$(tput setaf 5 2>/dev/null || printf '')"
  C_ORANGE="$(tput setaf 208 2>/dev/null || printf '\033[38;5;208m')"
else
  C_RESET=""
  C_BOLD=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_MAGENTA=""
  C_ORANGE=""
fi

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")
  $(basename "$0") /abs/path/to/album1 /abs/path/to/album2

Usage:
  $(basename "$0") [--help] [ALBUM1_ABS_PATH ALBUM2_ABS_PATH]

Compare two albums side-by-side (per-track + overall) using audlint-value
analysis.

Interactive mode:
  $(basename "$0")

Non-interactive mode:
  $(basename "$0") /abs/path/to/album1 /abs/path/to/album2

Notes:
  - Album paths must be absolute directories.
  - If paths are omitted, the script prompts for them.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

progress_update() {
  local msg="$1"
  if [[ -t 2 ]]; then
    printf '\r\033[2K%s' "$msg" >&2
  else
    printf '%s\n' "$msg" >&2
  fi
}

progress_clear() {
  if [[ -t 2 ]]; then
    printf '\r\033[2K' >&2
  fi
}

normalize_path_input() {
  local p="$1"
  p="$(printf '%s' "$p" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$p" in
  \"*\") p="${p:1:${#p}-2}" ;;
  \'*\') p="${p:1:${#p}-2}" ;;
  esac
  # Accept shell-escaped absolute path forms entered in interactive prompts,
  # e.g. /path/Artist\\,\\ Name/1999\\ -\\ Album.
  p="${p//\\ / }"
  p="${p//\\,/,}"
  p="${p//\\(/(}"
  p="${p//\\)/)}"
  p="${p//\\[/[}"
  p="${p//\\]/]}"
  printf '%s\n' "$p"
}

normalize_abs_dir() {
  local p="$1"
  [[ "$p" = /* ]] || return 2
  [[ -d "$p" ]] || return 3
  (cd "$p" >/dev/null 2>&1 && pwd) || return 4
}

prompt_album_path() {
  local prompt="$1"
  local p=""
  while true; do
    tty_prompt_line "$prompt" p || return 1
    p="$(normalize_path_input "$p")"
    if [[ -z "$p" ]]; then
      printf 'Path is required.\n' >&2
      continue
    fi
    if [[ "$p" != /* ]]; then
      printf 'Path must be absolute.\n' >&2
      continue
    fi
    if [[ ! -d "$p" ]]; then
      printf 'Directory not found: %s\n' "$p" >&2
      continue
    fi
    printf '%s\n' "$p"
    return 0
  done
}

collect_album_files() { audio_collect_files "$1" "$2"; }

# Aliases — canonical implementations live in lib/sh/audio.sh.
source_quality_label()       { audio_source_quality_label "$@"; }
album_source_quality_label() { audio_album_source_quality_label "$@"; }

grade_rank() {
  case "$1" in
  S) printf '5' ;;
  A) printf '4' ;;
  B) printf '3' ;;
  C) printf '2' ;;
  F) printf '1' ;;
  *) printf '0' ;;
  esac
}

rank_to_grade() {
  case "$1" in
  5) printf 'S' ;;
  4) printf 'A' ;;
  3) printf 'B' ;;
  2) printf 'C' ;;
  1) printf 'F' ;;
  *) printf 'N/A' ;;
  esac
}

# Run audlint-value.sh on an album dir, store JSON in a variable.
# Usage: scan_album_value ALBUM_DIR OUT_JSON_VAR OUT_GRADE_VAR OUT_DR_VAR OUT_GENRE_VAR
# Returns 0 on success, 1 on failure (OUT_* set to empty/N/A).
scan_album_value() {
  local album_dir="$1"
  local -n _sav_json="$2"
  local -n _sav_grade="$3"
  local -n _sav_dr="$4"
  local -n _sav_genre="$5"
  _sav_json=""
  _sav_grade="N/A"
  _sav_dr="N/A"
  _sav_genre="standard"
  if [[ ! -x "$AUDLINT_VALUE_BIN" ]]; then
    return 1
  fi
  local raw
  raw="$(GENRE_PROFILE="${GENRE_PROFILE:-standard}" "$AUDLINT_VALUE_BIN" "$album_dir" 2>/dev/null)" || return 1
  _sav_json="$raw"
  local parsed
  parsed="$("$AUDLINT_VALUE_PYTHON_BIN" - "$raw" <<'PY' 2>/dev/null
import json, sys
d = json.loads(sys.argv[1])
print(d.get("grade","N/A"))
print(d.get("drTotal","N/A"))
print(d.get("genreProfile","standard"))
PY
  )" || return 1
  { IFS= read -r _sav_grade; IFS= read -r _sav_dr; IFS= read -r _sav_genre; } <<< "$parsed"
}

# Look up per-track DR from audlint-value JSON using a fuzzy basename match.
# dr14meter track keys look like: "3:54 01 - Loser [flac]"
# We strip the leading MM:SS and trailing [ext], then compare to the file's
# basename without extension.
# Usage: track_dr_from_json JSON_STR FILEPATH GENRE_PROFILE
# Prints: DR_INT GRADE (tab-separated)
track_dr_grade_from_json() {
  local json="$1"
  local filepath="$2"
  local genre_profile="${3:-standard}"
  local dr_grade_py="$SCRIPT_DIR/../lib/py/dr_grade.py"
  if [[ ! -f "$TRACK_DR_PY" ]]; then
    printf 'N/A\tN/A\n'
    return 0
  fi
  "$AUDLINT_VALUE_PYTHON_BIN" "$TRACK_DR_PY" lookup-grade "$json" "$filepath" "$genre_profile" "$dr_grade_py" 2>/dev/null || printf 'N/A\tN/A\n'
}

analyze_track() {
  local file="$1"
  local album_json="$2"   # JSON string from scan_album_value (may be empty)
  local genre_profile="${3:-standard}"

  local dr="N/A"
  local grade="N/A"
  if [[ -n "$album_json" ]]; then
    local dr_grade_out
    dr_grade_out="$(track_dr_grade_from_json "$album_json" "$file" "$genre_profile")"
    IFS=$'\t' read -r dr grade <<< "$dr_grade_out"
  fi

  [[ -n "$dr"    ]] || dr="N/A"
  [[ -n "$grade" ]] || grade="N/A"
  # TSV: dr grade
  printf '%s\t%s\n' "$dr" "$grade"
}

album_codec_label() {
  local files_var="$1"
  local -n _acl_files="$files_var"
  local first="" codec f
  for f in "${_acl_files[@]}"; do
    codec="$(audio_codec_name "$f" || true)"
    [[ -n "$codec" ]] || codec="unknown"
    if [[ -z "$first" ]]; then
      first="$codec"
    elif [[ "$codec" != "$first" ]]; then
      printf 'mixed\n'
      return 0
    fi
  done
  [[ -n "$first" ]] || first="unknown"
  printf '%s\n' "$first"
}

album1=""
album2=""

if [[ "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

if [[ $# -eq 2 ]]; then
  album1="$1"
  album2="$2"
elif [[ $# -ne 0 ]]; then
  show_help
  exit 2
fi

if [[ -z "$album1" ]]; then
  album1="$(prompt_album_path "Enter album 1 abs path: ")"
fi
if [[ -z "$album2" ]]; then
  album2="$(prompt_album_path "Enter album 2 abs path: ")"
fi

album1="$(normalize_path_input "$album1")"
album2="$(normalize_path_input "$album2")"
album1="$(normalize_abs_dir "$album1" || true)"
album2="$(normalize_abs_dir "$album2" || true)"
[[ -n "$album1" ]] || die "Album 1 must be an existing absolute directory." 2
[[ -n "$album2" ]] || die "Album 2 must be an existing absolute directory." 2

has_bin ffprobe || die "ffprobe not found in PATH."
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  else
    die "python interpreter not found: $PYTHON_BIN"
  fi
fi
if ! command -v "$AUDLINT_VALUE_PYTHON_BIN" >/dev/null 2>&1; then
  AUDLINT_VALUE_PYTHON_BIN="$PYTHON_BIN"
fi
[[ -f "$TRACK_DR_PY" ]] || die "track DR helper not found: $TRACK_DR_PY"
table_require_rich || die "python rich is required for table rendering."

files1=()
files2=()
collect_album_files "$album1" files1
collect_album_files "$album2" files2

(( ${#files1[@]} > 0 )) || die "No supported audio files found in album 1: $album1"
(( ${#files2[@]} > 0 )) || die "No supported audio files found in album 2: $album2"
album1_profile="$(album_source_quality_label files1 || true)"
album2_profile="$(album_source_quality_label files2 || true)"
[[ -n "$album1_profile" ]] || album1_profile="N/A"
[[ -n "$album2_profile" ]] || album2_profile="N/A"
album1_codec="$(album_codec_label files1 || true)"
album2_codec="$(album_codec_label files2 || true)"
[[ -n "$album1_codec" ]] || album1_codec="unknown"
[[ -n "$album2_codec" ]] || album2_codec="unknown"

max_tracks="${#files1[@]}"
if (( ${#files2[@]} > max_tracks )); then
  max_tracks="${#files2[@]}"
fi

# Run audlint-value.sh once per album upfront for DR14 + grade data.
progress_update 'Scanning album 1 with audlint-value...'
album1_json="" album1_grade="N/A" album1_dr_total="N/A" album1_genre="standard"
scan_album_value "$album1" album1_json album1_grade album1_dr_total album1_genre || true

progress_update 'Scanning album 2 with audlint-value...'
album2_json="" album2_grade="N/A" album2_dr_total="N/A" album2_genre="standard"
scan_album_value "$album2" album2_json album2_grade album2_dr_total album2_genre || true
progress_clear

sum1_dr=0
sum2_dr=0
cnt1_dr=0
cnt2_dr=0
worst1_rank=99
worst2_rank=99

track_rows=()

for ((i=0; i<max_tracks; i++)); do
  f1="-"
  f2="-"
  p1_codec="N/A"
  p2_codec="N/A"
  p1_profile="N/A"
  p2_profile="N/A"
  r1="N/A\tN/A"
  r2="N/A\tN/A"

  if (( i < ${#files1[@]} )); then
    f1="${files1[$i]}"
    p1_codec="$(audio_codec_name "$f1" || true)"
    [[ -n "$p1_codec" ]] || p1_codec="unknown"
    p1_profile="$(source_quality_label "$f1" || true)"
    [[ -n "$p1_profile" ]] || p1_profile="N/A"
    progress_update "Analyzing album 1 track $((i + 1))/${#files1[@]}..."
    r1="$(analyze_track "$f1" "$album1_json" "$album1_genre" || printf 'N/A\tN/A')"
  fi
  if (( i < ${#files2[@]} )); then
    f2="${files2[$i]}"
    p2_codec="$(audio_codec_name "$f2" || true)"
    [[ -n "$p2_codec" ]] || p2_codec="unknown"
    p2_profile="$(source_quality_label "$f2" || true)"
    [[ -n "$p2_profile" ]] || p2_profile="N/A"
    progress_update "Analyzing album 2 track $((i + 1))/${#files2[@]}..."
    r2="$(analyze_track "$f2" "$album2_json" "$album2_genre" || printf 'N/A\tN/A')"
  fi

  # TSV: dr grade
  IFS=$'\t' read -r dr1 g1 <<<"$r1"
  IFS=$'\t' read -r dr2 g2 <<<"$r2"

  if is_numeric "$dr1"; then
    sum1_dr="$(awk -v a="$sum1_dr" -v b="$dr1" 'BEGIN{printf "%.6f", a+b}')"
    cnt1_dr="$((cnt1_dr + 1))"
  fi
  if is_numeric "$dr2"; then
    sum2_dr="$(awk -v a="$sum2_dr" -v b="$dr2" 'BEGIN{printf "%.6f", a+b}')"
    cnt2_dr="$((cnt2_dr + 1))"
  fi
  g1_rank="$(grade_rank "$g1")"
  g2_rank="$(grade_rank "$g2")"
  if (( g1_rank > 0 && g1_rank < worst1_rank )); then
    worst1_rank="$g1_rank"
  fi
  if (( g2_rank > 0 && g2_rank < worst2_rank )); then
    worst2_rank="$g2_rank"
  fi
  b1="$(basename "$f1")"
  b2="$(basename "$f2")"
  track_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(rich_style_album1 "$b1")" "$(rich_style_codec "$p1_codec")" "$(rich_style_profile "$p1_profile")" "$(rich_style_grade "$g1")" \
    "$(rich_style_album2 "$b2")" "$(rich_style_codec "$p2_codec")" "$(rich_style_profile "$p2_profile")" "$(rich_style_grade "$g2")")")
done
progress_clear
if [[ -t 2 ]]; then
  printf '\n' >&2
fi

# Use album-level DR total from audlint-value if available; otherwise avg of per-track.
avg1_dr="N/A"
avg2_dr="N/A"
if is_numeric "$album1_dr_total"; then
  avg1_dr="$album1_dr_total"
elif (( cnt1_dr > 0 )); then
  avg1_dr="$(awk -v a="$sum1_dr" -v n="$cnt1_dr" 'BEGIN{printf "%.0f", a/n}')"
fi
if is_numeric "$album2_dr_total"; then
  avg2_dr="$album2_dr_total"
elif (( cnt2_dr > 0 )); then
  avg2_dr="$(awk -v a="$sum2_dr" -v n="$cnt2_dr" 'BEGIN{printf "%.0f", a/n}')"
fi

# Overall grade: use album-level grade from audlint-value (more reliable than
# worst-track heuristic); fall back to worst track if not available.
worst1_grade="$(rank_to_grade "$worst1_rank")"
worst2_grade="$(rank_to_grade "$worst2_rank")"
[[ "$album1_grade" != "N/A" && -n "$album1_grade" ]] && worst1_grade="$album1_grade"
[[ "$album2_grade" != "N/A" && -n "$album2_grade" ]] && worst2_grade="$album2_grade"

printf '\n'
printf '%sAlbum 1:%s %s\n' "${C_BOLD}${C_CYAN}" "$C_RESET" "$album1"
printf '%sAlbum 2:%s %s\n' "${C_BOLD}${C_ORANGE}" "$C_RESET" "$album2"
printf '\n'
track_table_columns="Album1,Codec,Profile,Grade,Album2,Codec,Profile,Grade"
track_table_title="Tracks"
if [[ "$USE_COLOR" == true ]]; then
  track_table_columns="[bold cyan]Album 1[/],[bold magenta]Codec[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold dark_orange3]Album 2[/],[bold magenta]Codec[/],[bold cyan]Profile[/],[bold green]Grade[/]"
  track_table_title="[bold]Tracks[/]"
fi
printf '%s\n' "${track_rows[@]}" | table_render_tsv \
  "$track_table_columns" \
  "21,8,9,7,21,8,9,7" \
  "$track_table_title" \
  "left,center,center,center,left,center,center,center"

summary_rows=()
summary_rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$(rich_style_album1 "$(basename "$album1")")" "$(rich_style_codec "$album1_codec")" "$(rich_style_profile "$album1_profile")" "$(rich_style_grade "$worst1_grade")" "$(rich_style_score "DR${avg1_dr}")")")
summary_rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$(rich_style_album2 "$(basename "$album2")")" "$(rich_style_codec "$album2_codec")" "$(rich_style_profile "$album2_profile")" "$(rich_style_grade "$worst2_grade")" "$(rich_style_score "DR${avg2_dr}")")")

printf '\n'
summary_table_columns="Album,Codec,Profile,Grade,DR"
summary_table_title="Overall"
if [[ "$USE_COLOR" == true ]]; then
  summary_table_columns="[bold]Album[/],[bold magenta]Codec[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold green]DR[/]"
  summary_table_title="[bold]Overall[/]"
fi
printf '%s\n' "${summary_rows[@]}" | table_render_tsv \
  "$summary_table_columns" \
  "28,8,9,7,8" \
  "$summary_table_title" \
  "left,center,center,center,right"
