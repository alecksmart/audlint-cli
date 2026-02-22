#!/opt/homebrew/bin/bash
# qty_compare.sh — compare two albums side-by-side using spectre quality metrics.

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

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true

PY_HELPER="$SCRIPT_DIR/spectre_eval.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"
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
Usage: $(basename "$0") [--help] [ALBUM1_ABS_PATH ALBUM2_ABS_PATH]

Compare two albums side-by-side (per-track + overall) using spectre quality metrics.

Interactive mode:
  $(basename "$0")

Non-interactive mode:
  $(basename "$0") /abs/path/to/album1 /abs/path/to/album2
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

kv_get() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | awk -v k="$key" '$0 ~ ("^" k "=") { sub("^[^=]*=", "", $0); print; exit }'
}

is_numeric() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

normalize_path_input() {
  local p="$1"
  p="$(printf '%s' "$p" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$p" in
  \"*\") p="${p:1:${#p}-2}" ;;
  \'*\') p="${p:1:${#p}-2}" ;;
  esac
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
    read -r -p "$prompt" p
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
is_lossy_codec()             { audio_is_lossy_codec "$@"; }
source_quality_label()       { audio_source_quality_label "$@"; }
album_source_quality_label() { audio_album_source_quality_label "$@"; }
sanitize_cell()              { audio_sanitize_cell "$@"; }

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

rich_escape() {
  printf '%s' "$1" | sed -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

rich_style_grade() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  case "$v" in
  S | A) printf '[green]%s[/]' "$esc" ;;
  B | C) printf '[yellow]%s[/]' "$esc" ;;
  F) printf '[red]%s[/]' "$esc" ;;
  *) printf '%s' "$esc" ;;
  esac
}

rich_style_spec_rec() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  case "$v" in
  LOSSY* | Trash*) printf '[bold red]%s[/]' "$esc" ;;
  Upsample* | "Replace with CD Rip" | "Replace with Lossless Rip") printf '[yellow]%s[/]' "$esc" ;;
  Keep*) printf '[green]%s[/]' "$esc" ;;
  Store\ as*) printf '[cyan]%s[/]' "$esc" ;;
  *) printf '[magenta]%s[/]' "$esc" ;;
  esac
}

rich_style_album1() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[bold cyan]%s[/]' "$esc"
}

rich_style_album2() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[bold dark_orange3]%s[/]' "$esc"
}

rich_style_score() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[bold green]%s[/]' "$esc"
}

rich_style_profile() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[bold #f6e58d]%s[/]' "$esc"
}

analyze_track() {
  local file="$1"
  local out spectral_out codec ext sr dur start_sec dsd_hint tmpdir excerpt
  if ! out="$("$PYTHON_BIN" "$PY_HELPER" --quality "$file" 2>/dev/null)"; then
    printf 'ERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\n'
    return 1
  fi
  local q_score grade dr peak upscaled clipped qrec
  q_score="$(kv_get QUALITY_SCORE "$out")"
  grade="$(kv_get MASTERING_GRADE "$out")"
  dr="$(kv_get DYNAMIC_RANGE_SCORE "$out")"
  peak="$(kv_get TRUE_PEAK_DBFS "$out")"
  upscaled="$(kv_get IS_UPSCALED "$out")"
  clipped="$(kv_get LIKELY_CLIPPED_DISTORTED "$out")"
  qrec="$(kv_get RECOMMEND_WITH_SPECTROGRAM "$out")"

  local _probe_out
  _probe_out="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -show_entries format=duration -of default=noprint_wrappers=1 "$file" </dev/null 2>/dev/null || true)"
  sr="$(printf '%s\n' "$_probe_out" | awk -F'=' '/^sample_rate=/{print $2; exit}')"
  dur="$(printf '%s\n' "$_probe_out" | awk -F'=' '/^duration=/{print $2; exit}')"
  start_sec="$(awk -v d="${dur:-0}" 'BEGIN{s=(d>60)?(d/2 - 30):0; printf "%.3f", s}')"
  ext="${file##*.}"
  ext="${ext,,}"
  dsd_hint=0
  if [[ "$ext" == "dsf" || "$ext" == "dff" ]]; then
    dsd_hint=1
  fi
  tmpdir="$(mktemp -d)"
  excerpt="$tmpdir/excerpt.wav"
  ffmpeg -y -hide_banner -loglevel error -nostdin -ss "$start_sec" -t 60 -i "$file" -ac 1 -c:a pcm_s24le "$excerpt" </dev/null 2>/dev/null || true

  local spec_rec spec_conf spec_reason spec_fmax
  spec_rec="N/A"
  spec_conf="N/A"
  spec_reason="N/A"
  spec_fmax="N/A"
  if [[ -s "$excerpt" && -n "$sr" ]] && spectral_out="$("$PYTHON_BIN" "$PY_HELPER" "$excerpt" "$sr" "$dsd_hint" 2>/dev/null)"; then
    spec_rec="$(kv_get RECOMMEND "$spectral_out")"
    spec_conf="$(kv_get CONFIDENCE "$spectral_out")"
    spec_reason="$(kv_get REASON "$spectral_out")"
    spec_fmax="$(kv_get FMAX_KHZ "$spectral_out")"
  fi
  rm -rf "$tmpdir"

  codec="$(audio_codec_name "$file")"
  if is_lossy_codec "$codec"; then
    spec_rec="LOSSY"
    spec_conf="HIGH"
    spec_reason="Lossy codec (${codec:-unknown})"
  fi

  [[ -n "$q_score" ]] || q_score="N/A"
  [[ -n "$grade" ]] || grade="N/A"
  [[ -n "$dr" ]] || dr="N/A"
  [[ -n "$peak" ]] || peak="N/A"
  [[ -n "$upscaled" ]] || upscaled="N/A"
  [[ -n "$clipped" ]] || clipped="N/A"
  [[ -n "$qrec" ]] || qrec="N/A"
  [[ -n "$spec_rec" ]] || spec_rec="N/A"
  [[ -n "$spec_conf" ]] || spec_conf="N/A"
  [[ -n "$spec_reason" ]] || spec_reason="N/A"
  [[ -n "$spec_fmax" ]] || spec_fmax="N/A"
  spec_reason="$(sanitize_cell "$spec_reason")"
  spec_rec="$(sanitize_cell "$spec_rec")"
  qrec="$(sanitize_cell "$qrec")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$q_score" "$grade" "$dr" "$peak" "$upscaled" "$clipped" "$qrec" "$spec_rec" "$spec_conf" "$spec_reason" "$spec_fmax"
}

top_spec_rec() {
  local map_name="$1"
  local -n map_ref="$map_name"
  local k top="" top_n=0
  for k in "${!map_ref[@]}"; do
    if (( map_ref["$k"] > top_n )); then
      top="$k"
      top_n="${map_ref["$k"]}"
    fi
  done
  if [[ -n "$top" ]]; then
    printf '%s\n' "$top"
  else
    printf 'N/A\n'
  fi
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

has_bin ffmpeg || die "ffmpeg not found in PATH."
has_bin ffprobe || die "ffprobe not found in PATH."
[[ -f "$PY_HELPER" ]] || die "Missing helper: $PY_HELPER"
select_python_with_numpy
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "python interpreter not found: $PYTHON_BIN"
TABLE_PYTHON_BIN="${TABLE_PYTHON_BIN:-$PYTHON_BIN}"
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

max_tracks="${#files1[@]}"
if (( ${#files2[@]} > max_tracks )); then
  max_tracks="${#files2[@]}"
fi

sum1_q=0
sum2_q=0
sum1_dr=0
sum2_dr=0
cnt1_q=0
cnt2_q=0
cnt1_dr=0
cnt2_dr=0
max1_peak="-9999"
max2_peak="-9999"
have1_peak=0
have2_peak=0
worst1_rank=99
worst2_rank=99
clip1=0
clip2=0
up1=0
up2=0
spec_high1=0
spec_high2=0
spec_med1=0
spec_med2=0
spec_low1=0
spec_low2=0

track_rows=()
declare -A spec_rec_count1=()
declare -A spec_rec_count2=()
declare -A qrec_count1=()
declare -A qrec_count2=()

for ((i=0; i<max_tracks; i++)); do
  idx="$((i + 1))"
  f1="-"
  f2="-"
  p1_profile="N/A"
  p2_profile="N/A"
  r1="N/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A"
  r2="N/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A"

  if (( i < ${#files1[@]} )); then
    f1="${files1[$i]}"
    p1_profile="$(source_quality_label "$f1" || true)"
    [[ -n "$p1_profile" ]] || p1_profile="N/A"
    printf 'Analyzing album 1 track %d/%d...\r' "$((i + 1))" "${#files1[@]}" >&2
    r1="$(analyze_track "$f1" || printf 'ERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR')"
  fi
  if (( i < ${#files2[@]} )); then
    f2="${files2[$i]}"
    p2_profile="$(source_quality_label "$f2" || true)"
    [[ -n "$p2_profile" ]] || p2_profile="N/A"
    printf 'Analyzing album 2 track %d/%d...\r' "$((i + 1))" "${#files2[@]}" >&2
    r2="$(analyze_track "$f2" || printf 'ERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR\tERR')"
  fi

  IFS=$'\t' read -r q1 g1 dr1 p1 u1 c1 qrec1 srec1 sconf1 sreason1 sfmax1 <<<"$r1"
  IFS=$'\t' read -r q2 g2 dr2 p2 u2 c2 qrec2 srec2 sconf2 sreason2 sfmax2 <<<"$r2"

  if is_numeric "$q1"; then
    sum1_q="$(awk -v a="$sum1_q" -v b="$q1" 'BEGIN{printf "%.6f", a+b}')"
    cnt1_q="$((cnt1_q + 1))"
  fi
  if is_numeric "$q2"; then
    sum2_q="$(awk -v a="$sum2_q" -v b="$q2" 'BEGIN{printf "%.6f", a+b}')"
    cnt2_q="$((cnt2_q + 1))"
  fi
  if is_numeric "$dr1"; then
    sum1_dr="$(awk -v a="$sum1_dr" -v b="$dr1" 'BEGIN{printf "%.6f", a+b}')"
    cnt1_dr="$((cnt1_dr + 1))"
  fi
  if is_numeric "$dr2"; then
    sum2_dr="$(awk -v a="$sum2_dr" -v b="$dr2" 'BEGIN{printf "%.6f", a+b}')"
    cnt2_dr="$((cnt2_dr + 1))"
  fi
  if is_numeric "$p1"; then
    if (( have1_peak == 0 )) || awk -v a="$p1" -v b="$max1_peak" 'BEGIN{exit !(a>b)}'; then
      max1_peak="$p1"
      have1_peak=1
    fi
  fi
  if is_numeric "$p2"; then
    if (( have2_peak == 0 )) || awk -v a="$p2" -v b="$max2_peak" 'BEGIN{exit !(a>b)}'; then
      max2_peak="$p2"
      have2_peak=1
    fi
  fi
  g1_rank="$(grade_rank "$g1")"
  g2_rank="$(grade_rank "$g2")"
  if (( g1_rank > 0 && g1_rank < worst1_rank )); then
    worst1_rank="$g1_rank"
  fi
  if (( g2_rank > 0 && g2_rank < worst2_rank )); then
    worst2_rank="$g2_rank"
  fi
  [[ "$c1" == "1" ]] && clip1="$((clip1 + 1))"
  [[ "$c2" == "1" ]] && clip2="$((clip2 + 1))"
  [[ "$u1" == "1" ]] && up1="$((up1 + 1))"
  [[ "$u2" == "1" ]] && up2="$((up2 + 1))"
  case "$sconf1" in
  HIGH) spec_high1="$((spec_high1 + 1))" ;;
  MED) spec_med1="$((spec_med1 + 1))" ;;
  LOW) spec_low1="$((spec_low1 + 1))" ;;
  esac
  case "$sconf2" in
  HIGH) spec_high2="$((spec_high2 + 1))" ;;
  MED) spec_med2="$((spec_med2 + 1))" ;;
  LOW) spec_low2="$((spec_low2 + 1))" ;;
  esac
  if [[ -n "$srec1" && "$srec1" != "N/A" && "$srec1" != "ERR" ]]; then
    spec_rec_count1["$srec1"]="$(( ${spec_rec_count1["$srec1"]:-0} + 1 ))"
  fi
  if [[ -n "$srec2" && "$srec2" != "N/A" && "$srec2" != "ERR" ]]; then
    spec_rec_count2["$srec2"]="$(( ${spec_rec_count2["$srec2"]:-0} + 1 ))"
  fi
  if [[ -n "$qrec1" && "$qrec1" != "N/A" && "$qrec1" != "ERR" ]]; then
    qrec_count1["$qrec1"]="$(( ${qrec_count1["$qrec1"]:-0} + 1 ))"
  fi
  if [[ -n "$qrec2" && "$qrec2" != "N/A" && "$qrec2" != "ERR" ]]; then
    qrec_count2["$qrec2"]="$(( ${qrec_count2["$qrec2"]:-0} + 1 ))"
  fi

  b1="$(basename "$f1")"
  b2="$(basename "$f2")"
  track_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(rich_style_album1 "$b1")" "$(rich_style_profile "$p1_profile")" "$(rich_style_grade "$g1")" "$(rich_style_spec_rec "$srec1")" \
    "$(rich_style_album2 "$b2")" "$(rich_style_profile "$p2_profile")" "$(rich_style_grade "$g2")" "$(rich_style_spec_rec "$srec2")")")
done
printf '\n' >&2

avg1_q="N/A"
avg2_q="N/A"
avg1_dr="N/A"
avg2_dr="N/A"
if (( cnt1_q > 0 )); then
  avg1_q="$(awk -v a="$sum1_q" -v n="$cnt1_q" 'BEGIN{printf "%.2f", a/n}')"
fi
if (( cnt2_q > 0 )); then
  avg2_q="$(awk -v a="$sum2_q" -v n="$cnt2_q" 'BEGIN{printf "%.2f", a/n}')"
fi
if (( cnt1_dr > 0 )); then
  avg1_dr="$(awk -v a="$sum1_dr" -v n="$cnt1_dr" 'BEGIN{printf "%.2f", a/n}')"
fi
if (( cnt2_dr > 0 )); then
  avg2_dr="$(awk -v a="$sum2_dr" -v n="$cnt2_dr" 'BEGIN{printf "%.2f", a/n}')"
fi

worst1_grade="$(rank_to_grade "$worst1_rank")"
worst2_grade="$(rank_to_grade "$worst2_rank")"
peak1_out="N/A"
peak2_out="N/A"
(( have1_peak == 1 )) && peak1_out="$max1_peak"
(( have2_peak == 1 )) && peak2_out="$max2_peak"

printf '\n'
printf '%sAlbum 1:%s %s\n' "${C_BOLD}${C_CYAN}" "$C_RESET" "$album1"
printf '%sAlbum 2:%s %s\n' "${C_BOLD}${C_ORANGE}" "$C_RESET" "$album2"
printf '\n'
track_table_columns="Album1,Profile,Grade,Spec Rec,Album2,Profile,Grade,Spec Rec"
track_table_title="Tracks"
if [[ "$USE_COLOR" == true ]]; then
  track_table_columns="[bold cyan]Album 1[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold yellow]Spec Rec[/],[bold dark_orange3]Album 2[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold yellow]Spec Rec[/]"
  track_table_title="[bold]Tracks[/]"
fi
printf '%s\n' "${track_rows[@]}" | table_render_tsv \
  "$track_table_columns" \
  "24,9,7,22,24,9,7,22" \
  "$track_table_title" \
  "left,center,center,left,left,center,center,left"

top_qrec1="$(top_spec_rec qrec_count1)"
top_qrec2="$(top_spec_rec qrec_count2)"

summary_rows=()
summary_rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$(rich_style_album1 "$(basename "$album1")")" "$(rich_style_profile "$album1_profile")" "$(rich_style_grade "$worst1_grade")" "$(rich_style_score "$avg1_q")" "$(rich_style_spec_rec "$top_qrec1")")")
summary_rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$(rich_style_album2 "$(basename "$album2")")" "$(rich_style_profile "$album2_profile")" "$(rich_style_grade "$worst2_grade")" "$(rich_style_score "$avg2_q")" "$(rich_style_spec_rec "$top_qrec2")")")

printf '\n'
summary_table_columns="Album,Profile,Grade,Score,Recommendation"
summary_table_title="Overall"
if [[ "$USE_COLOR" == true ]]; then
  summary_table_columns="[bold]Album[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold green]Score[/],[bold yellow]Recommendation[/]"
  summary_table_title="[bold]Overall[/]"
fi
printf '%s\n' "${summary_rows[@]}" | table_render_tsv \
  "$summary_table_columns" \
  "28,9,7,8,45" \
  "$summary_table_title" \
  "left,center,center,right,left"
