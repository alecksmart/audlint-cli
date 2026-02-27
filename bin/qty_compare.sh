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

AUDLINT_ANALYZE_BIN="${AUDLINT_ANALYZE_BIN:-$SCRIPT_DIR/audlint-analyze.sh}"
AUDLINT_VALUE_BIN="${AUDLINT_VALUE_BIN:-$SCRIPT_DIR/audlint-value.sh}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
AUDLINT_VALUE_PYTHON_BIN="${AUDLINT_VALUE_PYTHON_BIN:-$PYTHON_BIN}"
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
analysis plus audlint-analyze spectral guidance.

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

normalize_spectral_recommendation() {
  local spec_rec="$1"
  local source_profile="$2"
  local source_norm target_raw target_norm out

  source_norm="$(profile_normalize "$source_profile" || true)"
  target_raw="$(printf '%s\n' "$spec_rec" | grep -Eio '[0-9]+([.][0-9]+)?(k(hz)?)?[/:-][0-9]{1,3}f?' | head -n 1 || true)"
  target_norm="$(profile_normalize "$target_raw" || true)"

  if [[ -n "$target_norm" && -n "$source_norm" && "$target_norm" == "$source_norm" ]]; then
    printf 'Keep as-is'
    return 0
  fi

  if [[ -n "$target_norm" && -n "$target_raw" ]]; then
    out="${spec_rec/$target_raw/$target_norm}"
    printf '%s' "$out"
    return 0
  fi

  printf '%s' "$spec_rec"
}

# Run audlint-analyze.sh --json on an album dir, store JSON in a variable.
# Usage: scan_album_analyze ALBUM_DIR OUT_JSON_VAR
# Returns 0 on success, 1 on failure (OUT_JSON_VAR set to empty).
scan_album_analyze() {
  local album_dir="$1"
  local -n _saa_json="$2"
  _saa_json=""
  if [[ ! -x "$AUDLINT_ANALYZE_BIN" ]]; then
    return 1
  fi
  local raw
  raw="$("$AUDLINT_ANALYZE_BIN" --json "$album_dir" 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  _saa_json="$raw"
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
  "$AUDLINT_VALUE_PYTHON_BIN" - "$json" "$filepath" "$genre_profile" "$dr_grade_py" <<'PY' 2>/dev/null
import json, sys, os, re, importlib.util

data      = json.loads(sys.argv[1])
filepath  = sys.argv[2]
genre     = sys.argv[3]
grade_py  = sys.argv[4]

tracks = data.get("tracks", {})
basename = os.path.basename(filepath)
stem = os.path.splitext(basename)[0].lower().strip()

# dr14meter key format: "MM:SS Name [ext]" — strip duration prefix and [ext] suffix
def key_stem(k):
    k = re.sub(r"^\d+:\d+\s+", "", k)   # strip leading MM:SS
    k = re.sub(r"\s+\[\w+\]$", "", k)   # strip trailing [ext]
    k = re.sub(r"^\d+\.\s*", "", k)     # strip leading track number
    return k.lower().strip()

dr = None
for k, v in tracks.items():
    if key_stem(k) == stem:
        dr = v
        break
# fuzzy fallback: check if stem is contained in key or vice versa
if dr is None:
    for k, v in tracks.items():
        ks = key_stem(k)
        if ks in stem or stem in ks:
            dr = v
            break

if dr is None:
    print("N/A\tN/A")
    sys.exit(0)

spec = importlib.util.spec_from_file_location("dr_grade", grade_py)
mod  = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
grade = mod.grade_from_dr(dr, genre)
print(f"{dr}\t{grade}")
PY
}

# Look up per-track spectral target from audlint-analyze JSON.
# Usage: track_spectral_from_analyze_json JSON_STR FILEPATH
# Prints: TARGET_PROFILE UPSCALED_FLAG REASON CUTOFF_KHZ (tab-separated)
track_spectral_from_analyze_json() {
  local json="$1"
  local filepath="$2"
  "$AUDLINT_VALUE_PYTHON_BIN" - "$json" "$filepath" <<'PY' 2>/dev/null
import json, sys, os

data = json.loads(sys.argv[1])
filepath = os.path.realpath(sys.argv[2])
basename = os.path.basename(filepath)
album_bits = data.get("album_bits") or 24
tracks = data.get("tracks") or []

selected = None
for entry in tracks:
    raw = entry.get("file")
    if not isinstance(raw, str):
        continue
    if os.path.realpath(raw) == filepath:
        selected = entry
        break

if selected is None:
    for entry in tracks:
        raw = entry.get("file")
        if not isinstance(raw, str):
            continue
        if os.path.basename(raw) == basename:
            selected = entry
            break

if selected is None:
    print("N/A\tN/A\tN/A\tN/A")
    raise SystemExit(0)

tgt_sr = selected.get("tgt_sr")
src_sr = selected.get("sr_in")
cutoff_hz = selected.get("cutoff_hz")

if not isinstance(tgt_sr, (int, float)):
    print("N/A\tN/A\tN/A\tN/A")
    raise SystemExit(0)

try:
    tgt_sr_i = int(tgt_sr)
    bits_i = int(album_bits)
except Exception:
    print("N/A\tN/A\tN/A\tN/A")
    raise SystemExit(0)

profile = f"{tgt_sr_i}/{bits_i}"
upscaled = 0
if isinstance(src_sr, (int, float)) and tgt_sr_i < int(src_sr):
    upscaled = 1

if isinstance(cutoff_hz, (int, float)):
    cutoff_khz = f"{float(cutoff_hz)/1000.0:.2f}"
    reason = f"audlint-analyze cutoff≈{cutoff_khz}kHz"
else:
    cutoff_khz = "N/A"
    reason = "audlint-analyze spectral target mapping"

print(f"{profile}\t{upscaled}\t{reason}\t{cutoff_khz}")
PY
}

analyze_track() {
  local file="$1"
  local album_json="$2"   # JSON string from scan_album_value (may be empty)
  local album_analyze_json="$3"   # JSON string from audlint-analyze --json (may be empty)
  local genre_profile="${4:-standard}"
  local source_profile="${5:-N/A}"

  local dr="N/A"
  local grade="N/A"
  if [[ -n "$album_json" ]]; then
    local dr_grade_out
    dr_grade_out="$(track_dr_grade_from_json "$album_json" "$file" "$genre_profile")"
    IFS=$'\t' read -r dr grade <<< "$dr_grade_out"
  fi
<<<<<<< HEAD
  tmpdir="$(mktemp -d)"
  excerpt="$tmpdir/excerpt.wav"
  local cmp_eval_sr
  cmp_eval_sr=$(( sr > 192000 ? 192000 : sr ))
  ffmpeg -y -hide_banner -loglevel error -nostdin -ss "$start_sec" -t 60 -i "$file" -ac 1 -ar "$cmp_eval_sr" -c:a pcm_s24le "$excerpt" </dev/null 2>/dev/null || true
=======
>>>>>>> develop

  local spec_rec="N/A" spec_conf="N/A" spec_reason="N/A" spec_bw99="N/A" upscaled="0"
  if [[ -n "$album_analyze_json" ]]; then
    local spectral_track_out spectral_profile
    spectral_track_out="$(track_spectral_from_analyze_json "$album_analyze_json" "$file" || true)"
    IFS=$'\t' read -r spectral_profile upscaled spec_reason spec_bw99 <<<"$spectral_track_out"
    if [[ -n "${spectral_profile:-}" && "$spectral_profile" != "N/A" ]]; then
      spec_rec="Store as ${spectral_profile}"
    fi
  fi
  spec_rec="$(normalize_spectral_recommendation "$spec_rec" "$source_profile")"

  local codec
  codec="$(audio_codec_name "$file")"
  if is_lossy_codec "$codec"; then
    spec_rec="LOSSY"
    spec_conf="HIGH"
    spec_reason="Lossy codec (${codec:-unknown})"
  fi

  [[ -n "$dr"        ]] || dr="N/A"
  [[ -n "$grade"     ]] || grade="N/A"
  [[ -n "$upscaled"  ]] || upscaled="N/A"
  [[ -n "$spec_rec"  ]] || spec_rec="N/A"
  [[ -n "$spec_conf" ]] || spec_conf="N/A"
  [[ -n "$spec_reason" ]] || spec_reason="N/A"
  [[ -n "$spec_bw99" ]] || spec_bw99="N/A"
  spec_reason="$(sanitize_cell "$spec_reason")"
  spec_rec="$(sanitize_cell "$spec_rec")"
  # TSV: dr grade upscaled spec_rec spec_conf spec_reason spec_bw99
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$dr" "$grade" "$upscaled" "$spec_rec" "$spec_conf" "$spec_reason" "$spec_bw99"
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

has_bin ffmpeg || die "ffmpeg not found in PATH."
has_bin ffprobe || die "ffprobe not found in PATH."
[[ -x "$AUDLINT_ANALYZE_BIN" ]] || die "Missing executable: $AUDLINT_ANALYZE_BIN"
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
album1_codec="$(album_codec_label files1 || true)"
album2_codec="$(album_codec_label files2 || true)"
[[ -n "$album1_codec" ]] || album1_codec="unknown"
[[ -n "$album2_codec" ]] || album2_codec="unknown"

max_tracks="${#files1[@]}"
if (( ${#files2[@]} > max_tracks )); then
  max_tracks="${#files2[@]}"
fi

# Run audlint-value.sh once per album upfront for DR14 + grade data.
printf 'Scanning album 1 with audlint-value...\r' >&2
album1_json="" album1_grade="N/A" album1_dr_total="N/A" album1_genre="standard"
scan_album_value "$album1" album1_json album1_grade album1_dr_total album1_genre || true
album1_analyze_json=""
scan_album_analyze "$album1" album1_analyze_json || true

printf 'Scanning album 2 with audlint-value...\r' >&2
album2_json="" album2_grade="N/A" album2_dr_total="N/A" album2_genre="standard"
scan_album_value "$album2" album2_json album2_grade album2_dr_total album2_genre || true
album2_analyze_json=""
scan_album_analyze "$album2" album2_analyze_json || true
printf '%-60s\r' '' >&2

sum1_dr=0
sum2_dr=0
cnt1_dr=0
cnt2_dr=0
worst1_rank=99
worst2_rank=99
up1=0
up2=0
declare -A spec_rec_count1=()
declare -A spec_rec_count2=()

track_rows=()

for ((i=0; i<max_tracks; i++)); do
  f1="-"
  f2="-"
  p1_codec="N/A"
  p2_codec="N/A"
  p1_profile="N/A"
  p2_profile="N/A"
  r1="N/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A"
  r2="N/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A"

  if (( i < ${#files1[@]} )); then
    f1="${files1[$i]}"
    p1_codec="$(audio_codec_name "$f1" || true)"
    [[ -n "$p1_codec" ]] || p1_codec="unknown"
    p1_profile="$(source_quality_label "$f1" || true)"
    [[ -n "$p1_profile" ]] || p1_profile="N/A"
    printf 'Analyzing album 1 track %d/%d...\r' "$((i + 1))" "${#files1[@]}" >&2
    r1="$(analyze_track "$f1" "$album1_json" "$album1_analyze_json" "$album1_genre" "$p1_profile" || printf 'N/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A')"
  fi
  if (( i < ${#files2[@]} )); then
    f2="${files2[$i]}"
    p2_codec="$(audio_codec_name "$f2" || true)"
    [[ -n "$p2_codec" ]] || p2_codec="unknown"
    p2_profile="$(source_quality_label "$f2" || true)"
    [[ -n "$p2_profile" ]] || p2_profile="N/A"
    printf 'Analyzing album 2 track %d/%d...\r' "$((i + 1))" "${#files2[@]}" >&2
    r2="$(analyze_track "$f2" "$album2_json" "$album2_analyze_json" "$album2_genre" "$p2_profile" || printf 'N/A\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A')"
  fi

  # TSV: dr grade upscaled spec_rec spec_conf spec_reason spec_bw99
  IFS=$'\t' read -r dr1 g1 u1 srec1 sconf1 sreason1 sbw991 <<<"$r1"
  IFS=$'\t' read -r dr2 g2 u2 srec2 sconf2 sreason2 sbw992 <<<"$r2"

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
  [[ "$u1" == "1" ]] && up1="$((up1 + 1))"
  [[ "$u2" == "1" ]] && up2="$((up2 + 1))"
  if [[ -n "$srec1" && "$srec1" != "N/A" && "$srec1" != "ERR" ]]; then
    spec_rec_count1["$srec1"]="$(( ${spec_rec_count1["$srec1"]:-0} + 1 ))"
  fi
  if [[ -n "$srec2" && "$srec2" != "N/A" && "$srec2" != "ERR" ]]; then
    spec_rec_count2["$srec2"]="$(( ${spec_rec_count2["$srec2"]:-0} + 1 ))"
  fi

  b1="$(basename "$f1")"
  b2="$(basename "$f2")"
  track_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(rich_style_album1 "$b1")" "$(rich_style_codec "$p1_codec")" "$(rich_style_profile "$p1_profile")" "$(rich_style_grade "$g1")" "$(rich_style_spec_rec "$srec1")" \
    "$(rich_style_album2 "$b2")" "$(rich_style_codec "$p2_codec")" "$(rich_style_profile "$p2_profile")" "$(rich_style_grade "$g2")" "$(rich_style_spec_rec "$srec2")")")
done
printf '\n' >&2

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

top_srec1="$(top_spec_rec spec_rec_count1)"
top_srec2="$(top_spec_rec spec_rec_count2)"

printf '\n'
printf '%sAlbum 1:%s %s\n' "${C_BOLD}${C_CYAN}" "$C_RESET" "$album1"
printf '%sAlbum 2:%s %s\n' "${C_BOLD}${C_ORANGE}" "$C_RESET" "$album2"
printf '\n'
track_table_columns="Album1,Codec,Profile,Grade,Spec Rec,Album2,Codec,Profile,Grade,Spec Rec"
track_table_title="Tracks"
if [[ "$USE_COLOR" == true ]]; then
  track_table_columns="[bold cyan]Album 1[/],[bold magenta]Codec[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold yellow]Spec Rec[/],[bold dark_orange3]Album 2[/],[bold magenta]Codec[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold yellow]Spec Rec[/]"
  track_table_title="[bold]Tracks[/]"
fi
printf '%s\n' "${track_rows[@]}" | table_render_tsv \
  "$track_table_columns" \
  "21,8,9,7,16,21,8,9,7,16" \
  "$track_table_title" \
  "left,center,center,center,left,left,center,center,center,left"

summary_rows=()
summary_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(rich_style_album1 "$(basename "$album1")")" "$(rich_style_codec "$album1_codec")" "$(rich_style_profile "$album1_profile")" "$(rich_style_grade "$worst1_grade")" "$(rich_style_score "DR${avg1_dr}")" "$(rich_style_spec_rec "$top_srec1")")")
summary_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(rich_style_album2 "$(basename "$album2")")" "$(rich_style_codec "$album2_codec")" "$(rich_style_profile "$album2_profile")" "$(rich_style_grade "$worst2_grade")" "$(rich_style_score "DR${avg2_dr}")" "$(rich_style_spec_rec "$top_srec2")")")

printf '\n'
summary_table_columns="Album,Codec,Profile,Grade,DR,Spectral Rec"
summary_table_title="Overall"
if [[ "$USE_COLOR" == true ]]; then
  summary_table_columns="[bold]Album[/],[bold magenta]Codec[/],[bold cyan]Profile[/],[bold green]Grade[/],[bold green]DR[/],[bold yellow]Spectral Rec[/]"
  summary_table_title="[bold]Overall[/]"
fi
printf '%s\n' "${summary_rows[@]}" | table_render_tsv \
  "$summary_table_columns" \
  "28,8,9,7,8,40" \
  "$summary_table_title" \
  "left,center,center,center,right,left"
