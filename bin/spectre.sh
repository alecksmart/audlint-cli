#!/opt/homebrew/bin/bash
# spectre.sh — Spectrogram + Header + Recommendation + Batch Summary
# Fixed: Cleanup prompt now correctly waits for keyboard input.

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
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/table.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/python.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ffprobe.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
ENV_PYTHON_BIN_OVERRIDE="${PYTHON_BIN:-}"
ENV_TABLE_PYTHON_BIN_OVERRIDE="${TABLE_PYTHON_BIN:-}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true

SPECTRO_WIDTH="${SPECTRO_WIDTH:-1920}"
SPECTRO_HEIGHT="${SPECTRO_HEIGHT:-1080}"
FONT_SIZE="${FONT_SIZE:-20}"
BGCOLOR="${BGCOLOR:-#111111}"
FGCOLOR="${FGCOLOR:-white}"
PY_HELPER="${SCRIPT_DIR}/spectre_eval.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"
if [[ -n "$ENV_PYTHON_BIN_OVERRIDE" ]]; then
  PYTHON_BIN="$ENV_PYTHON_BIN_OVERRIDE"
fi
if [[ -n "$ENV_TABLE_PYTHON_BIN_OVERRIDE" ]]; then
  TABLE_PYTHON_BIN="$ENV_TABLE_PYTHON_BIN_OVERRIDE"
fi
NO_COLOR="${NO_COLOR:-}"
# ====================

log() { log_ts "$@"; }
kv_get() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | awk -v k="$key" '$0 ~ ("^" k "=") { sub("^[^=]*=", "", $0); print; exit }'
}

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0") "/path/to/song.flac"
  $(basename "$0") "/path/to/album_folder"
  $(basename "$0") --all "/path/to/album_folder"

Usage: $(basename "$0") "/path/to/target"
       $(basename "$0") [--all] "/path/to/target"
       $(basename "$0") --help

Analyzes audio quality and recommends the best format for Plexamp.
Supported by default (ffmpeg permitting): flac, wav, m4a, mp3, ogg, opus, dsf, dff, wv, ape.

Switches:
  --all    In directory mode, also render per-track spectrogram PNGs.
  --help   Show this help message.
EOF
}

SUMMARY_ROWS=()
QUALITY_ROWS=()
GENERATED_PNGS=()
BATCH_FILES=()
BATCH_SRC_LABELS=()
BATCH_SPEC_REC=()
BATCH_CONF=()
BATCH_REASON=()
BATCH_Q_SCORE=()
BATCH_Q_GRADE=()
BATCH_Q_DYN=()
BATCH_Q_UPS=()
BATCH_Q_REC_BASE=()
BATCH_Q_REC_FINAL=()
BATCH_Q_REC_NOTE=()
BATCH_IS_LOSSY=()
BATCH_TRUE_PEAK=()
BATCH_LIKELY_CLIP=()
BATCH_FMAX_KHZ=()
BATCH_DUR_SEC=()
ALBUM_Q_AVAILABLE=false
ALBUM_Q_TRACKS=0
ALBUM_Q_SCORE="N/A"
ALBUM_Q_GRADE="N/A"
ALBUM_Q_DYN="N/A"
ALBUM_Q_UPS="N/A"
ALBUM_Q_REC="N/A"
ALBUM_Q_LRA="N/A"
ALBUM_Q_PEAK="N/A"
ALBUM_Q_CLIP="N/A"
ALBUM_GENRE_PROFILE="standard"
ALBUM_PNG_RENDERED=false
RENDER_ALL_TRACK_PNGS=false
PREMERGED_PARTS_MODE=false
TARGET=""
VERBOSE_MODE=false
USE_COLOR=false
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  USE_COLOR=true
fi

if [[ "$USE_COLOR" == true ]]; then
  ui_init_colors
  C_RESET="$RESET"
  C_DIM="$DIM"
  C_CYAN="$CYAN"
  C_GREEN="$GREEN"
  # shellcheck disable=SC2153
  C_YELLOW="$YELLOW"
  C_RED="$RED"
  C_BOLD="$(tput bold 2>/dev/null || printf '')"
  C_MAGENTA="$(tput setaf 5 2>/dev/null || printf '')"
  C_ORANGE="$(tput setaf 208 2>/dev/null || printf '\033[38;5;208m')"
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_MAGENTA=""
  C_ORANGE=""
  C_RED=""
fi

if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
  --help)
    show_help
    exit 0
    ;;
  --all)
    RENDER_ALL_TRACK_PNGS=true
    shift
    ;;
  -*)
    echo "Unknown option: $1"
    show_help
    exit 1
    ;;
  *)
    TARGET="$1"
    shift
    ;;
  esac
done

[[ -n "$TARGET" ]] || {
  echo "Error: No target specified."
  exit 1
}
[[ -e "$TARGET" ]] || {
  echo "Error: Path not found: $TARGET" >&2
  exit 1
}

for dep in ffmpeg ffprobe magick; do
  has_bin "$dep" || {
    echo "Error: $dep not found" >&2
    exit 1
  }
done

select_python_with_numpy
TABLE_PYTHON_BIN="${TABLE_PYTHON_BIN:-$PYTHON_BIN}"
table_require_rich || {
  echo "Error: python rich is required for table rendering. Install rich in $TABLE_PYTHON_BIN or set RICH_TABLE_CMD." >&2
  exit 1
}

collect_spectre_audio_files() {
  local dir="$1"
  local out_var="$2"
  local recursive="${3:-false}"
  local -n out_ref="$out_var"
  local discovered_files=()
  local f ext
  out_ref=()
  if [[ "$recursive" == true ]]; then
    while IFS= read -r -d '' f; do
      out_ref+=("$f")
    done < <(find "$dir" -type f \( \
      -iname "*.dsf" -o \
      -iname "*.dff" -o \
      -iname "*.wv" -o \
      -iname "*.flac" -o \
      -iname "*.wav" -o \
      -iname "*.m4a" -o \
      -iname "*.mp3" -o \
      -iname "*.ogg" -o \
      -iname "*.opus" -o \
      -iname "*.ape" \
      \) -print0 | sort -z)
    return 0
  fi
  audio_collect_files "$dir" discovered_files
  for f in "${discovered_files[@]}"; do
    ext="${f##*.}"
    ext="${ext,,}"
    case "$ext" in
    dsf | dff | wv | flac | wav | m4a | mp3 | ogg | opus | ape) out_ref+=("$f") ;;
    esac
  done
}

first_spectre_audio_file() {
  local dir="$1"
  local files=()
  collect_spectre_audio_files "$dir" files
  ((${#files[@]} > 0)) || return 1
  printf '%s\n' "${files[0]}"
}

is_numeric() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

num_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

num_le() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'
}

rich_escape() {
  printf '%s' "$1" | sed -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

# Aliases — canonical implementations live in lib/sh/audio.sh.
is_lossy_codec() { audio_is_lossy_codec "$@"; }

build_album_header() {
  local source_audio="$1"
  local album_dir="$2"
  local album_name
  album_name="$(basename "$album_dir")"

  local album_meta_payload album_artist album_year album_title
  album_meta_payload="$(ffprobe_album_key "$source_audio" || true)"
  album_artist="$(kv_get "ARTIST" "$album_meta_payload")"
  album_year="$(kv_get "YEAR" "$album_meta_payload")"
  album_title="$(kv_get "ALBUM" "$album_meta_payload")"
  [[ -n "$album_title" ]] || album_title="$album_name"
  if [[ "$album_year" == "0000" || -z "$album_year" ]]; then
    album_year="????"
  fi
  if [[ -n "$album_artist" ]]; then
    printf '%s - %s - %s' "$album_artist" "$album_year" "$album_title"
  else
    printf '%s - %s' "$album_year" "$album_title"
  fi
}

log_style_album_header() {
  local v="$1"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$v"
    return
  fi
  printf '%s%s%s' "${C_BOLD}${C_ORANGE}" "$v" "$C_RESET"
}

log_style_grade_value() {
  local v="$1"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$v"
    return
  fi
  case "$v" in
  S | A) printf '%s%s%s' "$C_GREEN" "$v" "$C_RESET" ;;
  B | C) printf '%s%s%s' "$C_YELLOW" "$v" "$C_RESET" ;;
  F) printf '%s%s%s' "$C_RED" "$v" "$C_RESET" ;;
  *) printf '%s' "$v" ;;
  esac
}

log_style_codec_value() {
  local codec="$1"
  [[ -n "$codec" ]] || codec="unknown"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$codec"
    return
  fi
  if is_lossy_codec "$codec"; then
    printf '%s%s%s' "$C_YELLOW" "$codec" "$C_RESET"
  else
    printf '%s%s%s' "$C_GREEN" "$codec" "$C_RESET"
  fi
}

log_style_processing_stem() {
  local v="$1"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$v"
    return
  fi
  printf '%s%s%s%s' "$C_BOLD" "$C_CYAN" "$v" "$C_RESET"
}

rich_style_conf() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  case "$v" in
  HIGH) printf '[green]%s[/]' "$esc" ;;
  MED) printf '[yellow]%s[/]' "$esc" ;;
  LOW) printf '[red]%s[/]' "$esc" ;;
  *) printf '%s' "$esc" ;;
  esac
}

rich_style_source() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[green]%s[/]' "$esc"
}

rich_style_q_score() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[green]%s[/]' "$esc"
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

rich_style_ups() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  case "$v" in
  YES) printf '[red]%s[/]' "$esc" ;;
  NO) printf '[green]%s[/]' "$esc" ;;
  *) printf '%s' "$esc" ;;
  esac
}

rich_style_action() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  case "$v" in
  Keep*) printf '[green]%s[/]' "$esc" ;;
  "Replace with CD Rip") printf '[yellow]%s[/]' "$esc" ;;
  "Replace with Lossless Rip") printf '[yellow]%s[/]' "$esc" ;;
  Trash*) printf '[red]%s[/]' "$esc" ;;
  *) printf '%s' "$esc" ;;
  esac
}

rich_style_filename() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[bold cyan]%s[/]' "$esc"
}

rich_style_album_label() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[bold dark_orange3]%s[/]' "$esc"
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
  WARNING:*) printf '[bold red]%s[/]' "$esc" ;;
  Upsample*) printf '[yellow]%s[/]' "$esc" ;;
  LOSSY) printf '[yellow]%s[/]' "$esc" ;;
  DSD\ Source*) printf '[green]%s[/]' "$esc" ;;
  Standard\ Definition*) printf '[green]%s[/]' "$esc" ;;
  *) printf '[magenta]%s[/]' "$esc" ;;
  esac
}

rich_style_reason() {
  local v="$1"
  local esc
  esc="$(rich_escape "$v")"
  if [[ "$USE_COLOR" != true ]]; then
    printf '%s' "$esc"
    return
  fi
  printf '[dim]%s[/]' "$esc"
}

apply_all_mode_overrides() {
  local total=${#BATCH_FILES[@]}
  ((total > 0)) || return 0

  local high_quality_count=0
  local quality_candidate_count=0
  local i
  for ((i = 0; i < total; i++)); do
    local is_lossy="${BATCH_IS_LOSSY[$i]:-NO}"
    if [[ "$is_lossy" == "YES" ]]; then
      continue
    fi
    ((quality_candidate_count += 1))
    local score="${BATCH_Q_SCORE[$i]}"
    local grade="${BATCH_Q_GRADE[$i]}"
    local ups="${BATCH_Q_UPS[$i]}"
    local base_action="${BATCH_Q_REC_BASE[$i]}"
    local is_high_quality=false

    if [[ "$base_action" == "Keep" && "$ups" == "NO" ]]; then
      is_high_quality=true
    elif [[ "$grade" =~ ^[SAB]$ && "$ups" != "YES" ]]; then
      is_high_quality=true
    elif is_numeric "$score" && num_ge "$score" 6.0 && [[ "$ups" != "YES" ]]; then
      is_high_quality=true
    fi

    if [[ "$is_high_quality" == true ]]; then
      ((high_quality_count += 1))
    fi
  done

  local album_majority_high=false
  if ((quality_candidate_count > 0 && high_quality_count * 2 > quality_candidate_count)); then
    album_majority_high=true
  fi

  local merged_album_high=false
  if [[ "$ALBUM_Q_AVAILABLE" == true && "$ALBUM_Q_UPS" != "YES" ]]; then
    if [[ "$ALBUM_Q_REC" == Keep* ]]; then
      merged_album_high=true
    elif [[ "$ALBUM_Q_GRADE" =~ ^[SAB]$ ]]; then
      merged_album_high=true
    elif is_numeric "$ALBUM_Q_SCORE" && num_ge "$ALBUM_Q_SCORE" 6.0; then
      merged_album_high=true
    fi
  fi

  for ((i = 0; i < total; i++)); do
    local base_action="${BATCH_Q_REC_BASE[$i]}"
    local final_action="$base_action"
    local override_note=""
    local is_lossy="${BATCH_IS_LOSSY[$i]:-NO}"

    if [[ "$is_lossy" == "YES" ]]; then
      final_action="Replace with Lossless Rip"
      override_note="lossy source"
      BATCH_Q_REC_FINAL[$i]="$final_action"
      BATCH_Q_REC_NOTE[$i]="$override_note"
      if [[ "$final_action" != "$base_action" ]]; then
        log "Override: ${BATCH_FILES[$i]} -> ${final_action} (${override_note})"
      fi
      continue
    fi

    local score="${BATCH_Q_SCORE[$i]}"
    local grade="${BATCH_Q_GRADE[$i]}"
    local dyn="${BATCH_Q_DYN[$i]}"
    local ups="${BATCH_Q_UPS[$i]}"
    local conf="${BATCH_CONF[$i]}"
    local fmax_khz="${BATCH_FMAX_KHZ[$i]}"
    local true_peak="${BATCH_TRUE_PEAK[$i]}"
    local clipped="${BATCH_LIKELY_CLIP[$i]}"

    local low_quality=false
    if [[ "$grade" == "C" || "$grade" == "F" || "$base_action" == "Trash" ]]; then
      low_quality=true
    elif is_numeric "$score" && num_le "$score" 4.0; then
      low_quality=true
    fi

    local very_low_peak=false
    if is_numeric "$true_peak" && num_le "$true_peak" -8.0; then
      very_low_peak=true
    fi

    local high_peak=false
    if is_numeric "$true_peak" && num_ge "$true_peak" -0.5; then
      high_peak=true
    fi

    local low_dr=false
    if is_numeric "$dyn" && num_le "$dyn" 4.0; then
      low_dr=true
    fi

    local clipping_or_brickwall=false
    if [[ "$clipped" == "1" ]]; then
      clipping_or_brickwall=true
    elif [[ "$high_peak" == true && "$low_dr" == true ]]; then
      clipping_or_brickwall=true
    fi

    local high_bandwidth=false
    if is_numeric "$fmax_khz" && num_ge "$fmax_khz" 30.0; then
      high_bandwidth=true
    fi

    local spectral_integrity=false
    if [[ "$ups" == "NO" && "$conf" != "LOW" && "$high_bandwidth" == true ]]; then
      spectral_integrity=true
    fi

    local low_bandwidth_upscaled=false
    if [[ "$ups" == "YES" ]] && is_numeric "$fmax_khz" && num_le "$fmax_khz" 14.0; then
      low_bandwidth_upscaled=true
    fi

    # Rule 0: obvious low-bandwidth upscaled sources should be marked for replacement.
    if [[ "$low_bandwidth_upscaled" == true ]]; then
      final_action="Replace with CD Rip"
      override_note="upscaled low-bandwidth source"
    fi

    # Rule 2: quiet/faded material can look low-quality by loudness-based scoring.
    if [[ "$low_quality" == true && "$very_low_peak" == true && "$final_action" != "Replace with CD Rip" ]]; then
      final_action="Keep (Quiet Track)"
      override_note="low peak with low score"
    fi

    # Rule 3: high-confidence non-upscaled content is only trashed on clear clipping/brickwall evidence.
    if [[ "$ups" == "NO" && "$conf" == "HIGH" && "$final_action" == "Trash" && "$clipping_or_brickwall" != true ]]; then
      final_action="Keep"
      override_note="spectral integrity guard"
    fi

    # Rule 1 + Rule 4: preserve authentic hi-res outliers when the album majority is high quality.
    if [[ ("$album_majority_high" == true || "$merged_album_high" == true) && "$final_action" == "Trash" && "$spectral_integrity" == true ]]; then
      final_action="Keep (Album Context)"
      if [[ "$very_low_peak" == true ]]; then
        override_note="quiet high-bandwidth outlier preserved"
      elif [[ "$merged_album_high" == true ]]; then
        override_note="album merged quality is high"
      else
        override_note="album majority high quality"
      fi
    fi

    BATCH_Q_REC_FINAL[$i]="$final_action"
    BATCH_Q_REC_NOTE[$i]="$override_note"

    if [[ "$final_action" != "$base_action" ]]; then
      log "Override: ${BATCH_FILES[$i]} -> ${final_action} (${override_note})"
    fi
  done
}

build_batch_tables() {
  SUMMARY_ROWS=()
  QUALITY_ROWS=()

  local total=${#BATCH_FILES[@]}
  local i
  for ((i = 0; i < total; i++)); do
    local filename="${BATCH_FILES[$i]}"
    local src_label="${BATCH_SRC_LABELS[$i]}"
    local rec="${BATCH_SPEC_REC[$i]}"
    local conf="${BATCH_CONF[$i]}"
    local reason="${BATCH_REASON[$i]}"
    local q_score="${BATCH_Q_SCORE[$i]}"
    local q_grade="${BATCH_Q_GRADE[$i]}"
    local q_dyn="${BATCH_Q_DYN[$i]}"
    local q_ups="${BATCH_Q_UPS[$i]}"
    local q_action="${BATCH_Q_REC_FINAL[$i]:-${BATCH_Q_REC_BASE[$i]}}"
    local filename_disp src_disp rec_disp conf_disp reason_disp
    local q_score_disp q_grade_disp q_dyn_disp q_ups_disp q_action_disp

    filename_disp="$(rich_style_filename "$filename")"
    src_disp="$(rich_style_source "$src_label")"
    rec_disp="$(rich_style_spec_rec "$rec")"
    conf_disp="$(rich_style_conf "$conf")"
    reason_disp="$(rich_style_reason "$reason")"

    q_score_disp="$(rich_style_q_score "$q_score")"
    q_grade_disp="$(rich_style_grade "$q_grade")"
    q_dyn_disp="$(rich_escape "$q_dyn")"
    q_ups_disp="$(rich_style_ups "$q_ups")"
    q_action_disp="$(rich_style_action "$q_action")"

    SUMMARY_ROWS+=("${filename_disp}"$'\t'"${src_disp}"$'\t'"${rec_disp}"$'\t'"${conf_disp}"$'\t'"${reason_disp}")
    QUALITY_ROWS+=("${filename_disp}"$'\t'"${q_score_disp}"$'\t'"${q_grade_disp}"$'\t'"${q_dyn_disp}"$'\t'"${q_ups_disp}"$'\t'"${q_action_disp}")
  done
}

analyze_file() {
  local in="$1"
  local filename
  filename=$(basename "$in")
  local ext="${filename##*.}"
  local stem="${filename%.*}"
  ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  local processing_name="$filename"
  if [[ "$filename" == *.* && "$stem" != "$filename" ]]; then
    local stem_log
    stem_log="$(log_style_processing_stem "$stem")"
    processing_name="${stem_log}.${ext}"
  else
    processing_name="$(log_style_processing_stem "$filename")"
  fi
  log "Processing: $processing_name"
  local render_track_png=false
  if [[ "$VERBOSE_MODE" == true || "$RENDER_ALL_TRACK_PNGS" == true ]]; then
    render_track_png=true
  fi

  local outdir sr bps sfmt
  outdir="$(dirname "$in")"
  sr=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$in" </dev/null)
  bps=$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$in" </dev/null)
  sfmt=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of csv=p=0 "$in" </dev/null)
  local codec_name
  codec_name="$(audio_codec_name "$in")"
  local is_lossy_track="NO"
  if is_lossy_codec "$codec_name"; then
    is_lossy_track="YES"
  fi
  sr="${sr%%,*}"
  bps="${bps%%,*}"
  sfmt="${sfmt%%,*}"
  if [[ -z "$sr" ]]; then
    echo "Warning: ffprobe could not decode audio stream for: $filename"
    echo "         This usually means your ffmpeg build lacks support for this format."
    echo "         Try a different ffmpeg build or convert the file first."
    return 1
  fi
  local dur
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in" </dev/null)
  dur="${dur%%,*}"

  local tmpdir
  tmpdir=$(mktemp -d)
  local excerpt="$tmpdir/excerpt.wav"
  local spectro_png="$tmpdir/s.png"
  local label_png="$tmpdir/l.png"
  local png="${outdir}/${stem}.png"
  if [[ "$render_track_png" == true ]]; then
    ffmpeg -y -hide_banner -loglevel error -nostdin -i "$in" -lavfi "showspectrumpic=s=${SPECTRO_WIDTH}x${SPECTRO_HEIGHT}:legend=1" "$spectro_png" </dev/null
  fi
  local start_sec
  start_sec=$(awk -v d="${dur:-0}" 'BEGIN{s=(d>60)?(d/2 - 30):0; printf "%.3f", s}')
  ffmpeg -y -hide_banner -loglevel error -nostdin -ss "$start_sec" -t 60 -i "$in" -ac 1 -c:a pcm_s24le "$excerpt" </dev/null

  local dsd_hint=0
  if [[ "$ext" == "dsf" || "$ext" == "dff" ]]; then
    dsd_hint=1
  fi
  local EVAL_OUT
  EVAL_OUT=$("$PYTHON_BIN" "$PY_HELPER" "$excerpt" "$sr" "$dsd_hint" </dev/null)
  local REC
  REC=$(kv_get "RECOMMEND" "$EVAL_OUT")
  local REASON
  REASON=$(kv_get "REASON" "$EVAL_OUT")
  local SUMMARY
  SUMMARY=$(kv_get "SUMMARY" "$EVAL_OUT")
  local CONF
  CONF=$(kv_get "CONFIDENCE" "$EVAL_OUT")
  local FMAX_KHZ
  FMAX_KHZ=$(kv_get "FMAX_KHZ" "$EVAL_OUT")

  local QUALITY_OUT=""
  local Q_SCORE="N/A"
  local Q_GRADE="N/A"
  local Q_DYN="N/A"
  local Q_LRA="N/A"
  local Q_PEAK="N/A"
  local Q_CLIP="N/A"
  local Q_UPS="N/A"
  local Q_REC="N/A"
  local Q_SPEC="N/A"
  if QUALITY_OUT=$("$PYTHON_BIN" "$PY_HELPER" --quality "$in" "--genre-profile=${ALBUM_GENRE_PROFILE}" </dev/null 2>/dev/null); then
    Q_SCORE=$(kv_get "QUALITY_SCORE" "$QUALITY_OUT")
    Q_GRADE=$(kv_get "MASTERING_GRADE" "$QUALITY_OUT")
    Q_DYN=$(kv_get "DYNAMIC_RANGE_SCORE" "$QUALITY_OUT")
    Q_LRA=$(kv_get "LRA_LU" "$QUALITY_OUT")
    Q_PEAK=$(kv_get "TRUE_PEAK_DBFS" "$QUALITY_OUT")
    Q_CLIP=$(kv_get "LIKELY_CLIPPED_DISTORTED" "$QUALITY_OUT")
    Q_UPS=$(kv_get "IS_UPSCALED" "$QUALITY_OUT")
    Q_REC=$(kv_get "RECOMMENDATION" "$QUALITY_OUT")
    Q_SPEC=$(kv_get "SPECTROGRAM" "$QUALITY_OUT")
    if [[ "$Q_UPS" == "1" ]]; then
      Q_UPS="YES"
    elif [[ "$Q_UPS" == "0" ]]; then
      Q_UPS="NO"
    fi
  else
    log "Quality analysis unavailable for: $filename"
  fi

  if [[ "$is_lossy_track" == "YES" ]]; then
    REC="LOSSY"
    REASON="Lossy codec (${codec_name:-unknown})"
    Q_REC="Replace with Lossless Rip"
  fi

  local bit_label=""
  if [[ -n "$bps" && "$bps" != "N/A" ]]; then
    bit_label="$bps"
  else
    case "$sfmt" in
    s16 | s16p) bit_label="16" ;;
    s24 | s24p) bit_label="24" ;;
    s32 | s32p) bit_label="32" ;;
    flt | fltp) bit_label="32f" ;;
    dbl | dblp) bit_label="64f" ;;
    *) bit_label="" ;;
    esac
  fi
  local src_label=""
  if [[ -n "$bit_label" ]]; then
    src_label="$(awk -v s="$sr" 'BEGIN{printf "%.1f", s/1000.0}')/$bit_label"
    src_label="${src_label%.0}"
  else
    src_label="$(awk -v s="$sr" 'BEGIN{printf "%.1f", s/1000.0}')/??"
    src_label="${src_label%.0}"
  fi

  if [[ "$render_track_png" == true ]]; then
    magick -background "$BGCOLOR" -fill "$FGCOLOR" -pointsize "$FONT_SIZE" -size "${SPECTRO_WIDTH}x" \
      caption:"File: ${filename}\nSource: ${src_label}\nRecommend: ${REC}\nConfidence: ${CONF}\nWhy: ${REASON}\nQuality: ${Q_SCORE}/10 (${Q_GRADE}) | ${Q_REC}" \
      -bordercolor "$BGCOLOR" -border 20x20 "$label_png"

    magick "$label_png" "$spectro_png" -append "$png"
    GENERATED_PNGS+=("$png")
  fi

  if [[ "$VERBOSE_MODE" == true ]]; then
    local CONF_COLOR="$C_YELLOW"
    case "$CONF" in
    HIGH) CONF_COLOR="$C_GREEN" ;;
    LOW) CONF_COLOR="$C_RED" ;;
    esac
    echo ""
    echo "${C_BOLD}${C_CYAN}--- Spectrogram Analysis ---${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Source${C_RESET}      : ${C_GREEN}${src_label}${C_RESET} ${C_DIM}(${sr} Hz)${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Confidence${C_RESET} : ${CONF_COLOR}${CONF}${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Reason${C_RESET}     : ${C_YELLOW}${REASON}${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Summary${C_RESET}    : ${C_DIM}${SUMMARY}${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Encode${C_RESET}     : ${C_MAGENTA}${REC}${C_RESET}"
    echo "${C_BOLD}${C_CYAN}--- Quality Analysis ---${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Q Score${C_RESET}    : ${C_GREEN}${Q_SCORE}${C_RESET} ${C_DIM}(1-10)${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Q Grade${C_RESET}    : ${C_MAGENTA}${Q_GRADE}${C_RESET} ${C_DIM}(S/A/B/C/F)${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Q Dyn${C_RESET}      : ${C_YELLOW}${Q_DYN}${C_RESET} ${C_DIM}(dynamic score)${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Q LRA${C_RESET}      : ${C_DIM}${Q_LRA}${C_RESET} ${C_DIM}(LU)${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Q Peak${C_RESET}     : ${C_DIM}${Q_PEAK}${C_RESET} ${C_DIM}(dBFS)${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Q Clip${C_RESET}     : ${C_DIM}${Q_CLIP}${C_RESET} ${C_DIM}(0/1)${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Upscaled${C_RESET}   : ${C_YELLOW}${Q_UPS}${C_RESET}"
    echo "${C_CYAN}${C_BOLD}Q Spectro${C_RESET}  : ${C_DIM}${Q_SPEC}${C_RESET}"
    local Q_REC_COLOR="$C_MAGENTA"
    case "$Q_REC" in
    Keep) Q_REC_COLOR="$C_GREEN" ;;
    "Replace with CD Rip") Q_REC_COLOR="$C_YELLOW" ;;
    "Replace with Lossless Rip") Q_REC_COLOR="$C_YELLOW" ;;
    Trash) Q_REC_COLOR="$C_RED" ;;
    esac
    echo "${C_CYAN}${C_BOLD}Verdict${C_RESET}    : ${Q_REC_COLOR}${Q_REC}${C_RESET}"
    echo ""
  else
    BATCH_FILES+=("$filename")
    BATCH_SRC_LABELS+=("$src_label")
    BATCH_SPEC_REC+=("$REC")
    BATCH_CONF+=("$CONF")
    BATCH_REASON+=("$REASON")
    BATCH_Q_SCORE+=("$Q_SCORE")
    BATCH_Q_GRADE+=("$Q_GRADE")
    BATCH_Q_DYN+=("$Q_DYN")
    BATCH_Q_UPS+=("$Q_UPS")
    BATCH_Q_REC_BASE+=("$Q_REC")
    BATCH_Q_REC_FINAL+=("$Q_REC")
    BATCH_Q_REC_NOTE+=("")
    BATCH_IS_LOSSY+=("$is_lossy_track")
    BATCH_TRUE_PEAK+=("$Q_PEAK")
    BATCH_LIKELY_CLIP+=("$Q_CLIP")
    BATCH_FMAX_KHZ+=("$FMAX_KHZ")
    BATCH_DUR_SEC+=("$dur")
  fi

  local q_grade_log codec_name_log
  q_grade_log="$(log_style_grade_value "$Q_GRADE")"
  codec_name_log="$(log_style_codec_value "${codec_name:-unknown}")"
  log "Quality: score=${Q_SCORE} grade=${q_grade_log} dyn=${Q_DYN} upscaled=${Q_UPS} peak=${Q_PEAK} clip=${Q_CLIP} rec=${Q_REC} lossy=${is_lossy_track} codec=${codec_name_log}"
  rm -rf "$tmpdir"
  if [[ "$render_track_png" == true ]]; then
    log "Saved report to: $(basename "$png")"
  fi
}

render_album_spectrogram() {
  local source_audio="$1"
  local album_dir="$2"
  local track_count="$3"
  local album_header
  album_header="$(build_album_header "$source_audio" "$album_dir")"
  local album_png="$album_dir/album_spectre.png"

  local src_sr src_bps src_sfmt src_dur
  src_sr=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$source_audio" </dev/null)
  src_bps=$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$source_audio" </dev/null)
  src_sfmt=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of csv=p=0 "$source_audio" </dev/null)
  src_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$source_audio" </dev/null)
  src_sr="${src_sr%%,*}"
  src_bps="${src_bps%%,*}"
  src_sfmt="${src_sfmt%%,*}"
  src_dur="${src_dur%%,*}"
  if [[ -z "$src_sr" ]]; then
    log "Album spectrogram skipped: ffprobe failed for source stream."
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  local excerpt="$tmpdir/excerpt.wav"
  local spectro_png="$tmpdir/s.png"
  local label_png="$tmpdir/l.png"

  log "Album report: generating spectrogram image..."
  ffmpeg -y -hide_banner -loglevel error -nostdin -i "$source_audio" -lavfi "showspectrumpic=s=${SPECTRO_WIDTH}x${SPECTRO_HEIGHT}:legend=1" "$spectro_png" </dev/null || {
    rm -rf "$tmpdir"
    log "Album spectrogram generation failed."
    return 1
  }

  local start_sec
  start_sec=$(awk -v d="${src_dur:-0}" 'BEGIN{s=(d>60)?(d/2 - 30):0; printf "%.3f", s}')
  log "Album report: extracting analysis excerpt..."
  local rec_eval_sr
  rec_eval_sr=$(( src_sr > 192000 ? 192000 : src_sr ))
  ffmpeg -y -hide_banner -loglevel error -nostdin -ss "$start_sec" -t 60 -i "$source_audio" -ac 1 -ar "$rec_eval_sr" -c:a pcm_s24le "$excerpt" </dev/null || {
    rm -rf "$tmpdir"
    log "Album spectrogram excerpt extraction failed."
    return 1
  }

  local src_ext="${source_audio##*.}"
  src_ext="$(printf '%s' "$src_ext" | tr '[:upper:]' '[:lower:]')"
  local dsd_hint=0
  if [[ "$src_ext" == "dsf" || "$src_ext" == "dff" ]]; then
    dsd_hint=1
  fi

  local eval_out rec reason conf
  log "Album report: running spectral analyzer..."
  eval_out=$("$PYTHON_BIN" "$PY_HELPER" "$excerpt" "$src_sr" "$dsd_hint" </dev/null)
  rec="$(kv_get "RECOMMEND" "$eval_out")"
  reason="$(kv_get "REASON" "$eval_out")"
  conf="$(kv_get "CONFIDENCE" "$eval_out")"

  local q_score="${ALBUM_Q_SCORE}"
  local q_grade="${ALBUM_Q_GRADE}"
  local q_rec="${ALBUM_Q_REC}"
  if [[ "$ALBUM_Q_AVAILABLE" != true ]]; then
    q_score="${BATCH_Q_SCORE[0]:-N/A}"
    q_grade="${BATCH_Q_GRADE[0]:-N/A}"
    q_rec="${BATCH_Q_REC_FINAL[0]:-${BATCH_Q_REC_BASE[0]:-N/A}}"
  fi

  local bit_label=""
  if [[ -n "$src_bps" && "$src_bps" != "N/A" ]]; then
    bit_label="$src_bps"
  else
    case "$src_sfmt" in
    s16 | s16p) bit_label="16" ;;
    s24 | s24p) bit_label="24" ;;
    s32 | s32p) bit_label="32" ;;
    flt | fltp) bit_label="32f" ;;
    dbl | dblp) bit_label="64f" ;;
    *) bit_label="" ;;
    esac
  fi

  local src_label
  if [[ -n "$bit_label" ]]; then
    src_label="$(awk -v s="$src_sr" 'BEGIN{printf "%.1f", s/1000.0}')/$bit_label"
    src_label="${src_label%.0}"
  else
    src_label="$(awk -v s="$src_sr" 'BEGIN{printf "%.1f", s/1000.0}')/??"
    src_label="${src_label%.0}"
  fi

  log "Album report: composing labeled PNG..."
  magick -background "$BGCOLOR" -fill "$FGCOLOR" -pointsize "$FONT_SIZE" -size "${SPECTRO_WIDTH}x" \
    caption:"${album_header}\nTracks: ${track_count}\nSource: ${src_label}\nRecommend: ${rec}\nConfidence: ${conf}\nWhy: ${reason}\nQuality: ${q_score}/10 (${q_grade}) | ${q_rec}" \
    -bordercolor "$BGCOLOR" -border 20x20 "$label_png" || {
    rm -rf "$tmpdir"
    log "Album label generation failed."
    return 1
  }

  magick "$label_png" "$spectro_png" -append "$album_png" || {
    rm -rf "$tmpdir"
    log "Album report PNG assembly failed."
    return 1
  }

  GENERATED_PNGS+=("$album_png")
  ALBUM_PNG_RENDERED=true
  rm -rf "$tmpdir"
  log "Saved album report to: $(basename "$album_png")"
}

ffmpeg_concat_escape_path() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

sum_batch_durations() {
  local total="0"
  local d
  for d in "${BATCH_DUR_SEC[@]}"; do
    if is_numeric "$d"; then
      total="$(awk -v a="$total" -v b="$d" 'BEGIN { printf "%.6f", a + b }')"
    fi
  done
  printf '%s\n' "$total"
}

probe_audio_duration_seconds() {
  local file_path="$1"
  local dur
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file_path" </dev/null 2>/dev/null || true)"
  dur="${dur%%,*}"
  if is_numeric "$dur"; then
    printf '%s\n' "$dur"
  else
    printf '0\n'
  fi
}

detect_premerged_album_parts_mode() {
  local files_var="$1"
  local -n files_ref="$files_var"
  local count=${#files_ref[@]}
  ((count >= 2 && count <= 8)) || return 1

  local long_count=0
  local image_codec_count=0
  local embedded_cue_count=0
  local cue_sidecar_found=false
  local f dur ext tags_payload

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cue_sidecar_found=true
    break
  done < <(find "$TARGET" -maxdepth 3 -type f -iname "*.cue" -print 2>/dev/null || true)

  for f in "${files_ref[@]}"; do
    dur="$(probe_audio_duration_seconds "$f")"
    if is_numeric "$dur" && num_ge "$dur" 900; then
      ((long_count += 1))
    fi

    ext="${f##*.}"
    ext="${ext,,}"
    case "$ext" in
    ape | wv) ((image_codec_count += 1)) ;;
    esac

    tags_payload="$(ffprobe -v error -show_entries format_tags -of default=noprint_wrappers=1 "$f" </dev/null 2>/dev/null || true)"
    if printf '%s\n' "$tags_payload" | grep -Eiq 'TAG:(cuesheet|cue_sheet|CUESHEET)='; then
      ((embedded_cue_count += 1))
    fi
  done

  ((long_count == count)) || return 1
  ((image_codec_count == count)) || return 1
  if [[ "$cue_sidecar_found" != true && "$embedded_cue_count" -eq 0 ]]; then
    return 1
  fi
  return 0
}

run_ffmpeg_concat_merge() {
  local concat_list="$1"
  local merged_file="$2"
  local total_duration_s="$3"
  local tmpdir="$4"

  if [[ -t 1 ]] && is_numeric "$total_duration_s" && num_ge "$total_duration_s" 1; then
    render_merge_progress_line() {
      local pct="$1"
      local bar_width=24
      local filled=$((pct * bar_width / 100))
      local empty=$((bar_width - filled))
      local filled_bar empty_bar
      filled_bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
      empty_bar="$(printf '%*s' "$empty" '' | tr ' ' '-')"
      printf '\rAlbum-wide quality merge: [%s%s] %3d%%' "$filled_bar" "$empty_bar" "$pct"
    }

    local progress_fifo="$tmpdir/ffmpeg-progress.fifo"
    local err_file="$tmpdir/ffmpeg-progress.err"
    if mkfifo "$progress_fifo"; then
      ffmpeg -y -hide_banner -loglevel error -nostats -nostdin -f concat -safe 0 -i "$concat_list" -vn -c:a pcm_s24le -progress "$progress_fifo" "$merged_file" 2>"$err_file" &
      local ffmpeg_pid=$!
      local line out_ms pct bucket
      local last_bucket=-1
      local progress_line_shown=false
      render_merge_progress_line 0
      progress_line_shown=true
      while IFS= read -r line; do
        case "$line" in
        out_time_ms=*)
          out_ms="${line#out_time_ms=}"
          if is_numeric "$out_ms"; then
            pct="$(awk -v out_ms="$out_ms" -v total_s="$total_duration_s" 'BEGIN {
              p=(out_ms/1000000.0)/total_s*100.0;
              if (p < 0) p=0;
              if (p > 100) p=100;
              printf "%d", p
            }')"
            bucket=$((pct / 5))
            if ((bucket > last_bucket)); then
              last_bucket=$bucket
              render_merge_progress_line "$pct"
            fi
          fi
          ;;
        progress=end)
          if ((last_bucket < 20)); then
            last_bucket=20
            render_merge_progress_line 100
          fi
          ;;
        esac
      done <"$progress_fifo"
      wait "$ffmpeg_pid"
      local rc=$?
      if [[ "$progress_line_shown" == true ]]; then
        printf '\n'
      fi
      if ((rc != 0)) && [[ -s "$err_file" ]]; then
        cat "$err_file" >&2
      fi
      rm -f "$progress_fifo" "$err_file"
      return "$rc"
    fi
  fi

  ffmpeg -y -hide_banner -loglevel error -nostdin -f concat -safe 0 -i "$concat_list" -vn -c:a pcm_s24le "$merged_file" </dev/null
}

analyze_album_quality_merged() {
  local files_var="$1"
  local -n files_ref="$files_var"

  ALBUM_Q_AVAILABLE=false
  ALBUM_PNG_RENDERED=false
  ALBUM_Q_TRACKS=${#files_ref[@]}
  ((ALBUM_Q_TRACKS > 1)) || return 0

  local tmpdir
  tmpdir="$(mktemp -d)"
  local concat_list="$tmpdir/concat.txt"
  local merged_file="$tmpdir/album-merged.wav"
  local total_duration_s
  total_duration_s="$(sum_batch_durations)"
  local f escaped
  log "Album-wide quality: preparing merged temporary file (${ALBUM_Q_TRACKS} tracks)..."
  for f in "${files_ref[@]}"; do
    escaped="$(ffmpeg_concat_escape_path "$f")"
    printf "file '%s'\n" "$escaped" >>"$concat_list"
  done

  if ! run_ffmpeg_concat_merge "$concat_list" "$merged_file" "$total_duration_s" "$tmpdir"; then
    log "Album-wide quality merge failed; continuing with per-track results."
    rm -rf "$tmpdir"
    return 0
  fi
  log "Album-wide quality: merged stream ready."
  render_album_spectrogram "$merged_file" "$TARGET" "$ALBUM_Q_TRACKS" || true

  local -a grade_ranks=()
  local grade
  for grade in "${BATCH_Q_GRADE[@]}"; do
    case "$grade" in
    F) grade_ranks+=(0) ;;
    C) grade_ranks+=(1) ;;
    B) grade_ranks+=(2) ;;
    A) grade_ranks+=(3) ;;
    S) grade_ranks+=(4) ;;
    *) grade_ranks+=(0) ;;
    esac
  done

  local -a sorted_ranks=()
  local rank
  while IFS= read -r rank; do
    sorted_ranks+=("$rank")
  done < <(printf '%s\n' "${grade_ranks[@]}" | sort -n)

  local percentile_rank=0
  if ((${#sorted_ranks[@]} > 0)); then
    local percentile_idx=$(( ${#sorted_ranks[@]} * 25 / 100 ))
    percentile_rank="${sorted_ranks[$percentile_idx]}"
  fi

  case "$percentile_rank" in
  0) ALBUM_Q_GRADE="F" ;;
  1) ALBUM_Q_GRADE="C" ;;
  2) ALBUM_Q_GRADE="B" ;;
  3) ALBUM_Q_GRADE="A" ;;
  4) ALBUM_Q_GRADE="S" ;;
  *) ALBUM_Q_GRADE="F" ;;
  esac

  local score_sum="0"
  local score_count=0
  local score
  for score in "${BATCH_Q_SCORE[@]}"; do
    if is_numeric "$score"; then
      score_sum="$(awk -v a="$score_sum" -v b="$score" 'BEGIN { printf "%.6f", a + b }')"
      ((score_count += 1))
    fi
  done
  if ((score_count > 0)); then
    ALBUM_Q_SCORE="$(awk -v sum="$score_sum" -v n="$score_count" 'BEGIN { printf "%.1f", sum / n }')"
  else
    ALBUM_Q_SCORE="N/A"
  fi

  ALBUM_Q_UPS="NO"
  local ups
  for ups in "${BATCH_Q_UPS[@]}"; do
    if [[ "$ups" == "YES" ]]; then
      ALBUM_Q_UPS="YES"
      break
    fi
  done

  case "$ALBUM_Q_GRADE" in
  F) ALBUM_Q_REC="Trash" ;;
  C) ALBUM_Q_REC="Replace with CD Rip" ;;
  B | A | S) ALBUM_Q_REC="Keep" ;;
  *) ALBUM_Q_REC="Keep" ;;
  esac

  ALBUM_Q_AVAILABLE=true
  ALBUM_Q_DYN="N/A"
  ALBUM_Q_LRA="N/A"
  ALBUM_Q_PEAK="N/A"
  ALBUM_Q_CLIP="N/A"

  log "Album grade (per-track 25th-pct): grade=${ALBUM_Q_GRADE} score=${ALBUM_Q_SCORE} upscaled=${ALBUM_Q_UPS} rec=${ALBUM_Q_REC}"
  rm -rf "$tmpdir"
}

cleanup_and_show_summary() {
  local has_pngs=false
  if ((${#GENERATED_PNGS[@]} > 0)); then
    has_pngs=true
  fi

  if [[ "$VERBOSE_MODE" != true ]]; then
    apply_all_mode_overrides
    build_batch_tables
    printf "%s\n" "${C_BOLD}${C_DIM}SPECTRAL FORMAT RECOMMENDATIONS${C_RESET}"
    printf "%s\n" "${C_DIM}Purpose: spectral bandwidth/integrity recommendation from excerpt FFT analysis.${C_RESET}"
    if ((${#SUMMARY_ROWS[@]} > 0)); then
      printf '%s\n' "${SUMMARY_ROWS[@]}" | table_render_tsv \
        "FILE NAME,SRC kHz/bit,SPECTRAL RECOMMENDATION,CONF,SPECTRAL REASON" \
        "38,10,44,6,58"
    else
      printf '' | table_render_tsv \
        "FILE NAME,SRC kHz/bit,SPECTRAL RECOMMENDATION,CONF,SPECTRAL REASON" \
        "38,10,44,6,58"
    fi

    printf "%s\n" "${C_BOLD}${C_DIM}MASTERING QUALITY CHECKS${C_RESET}"
    printf "%s\n" "${C_DIM}Purpose: loudness/dynamics/peak scoring and action recommendation.${C_RESET}"
    printf "%s\n" "${C_DIM}Qty: grade buckets (S/A/B/C/F) from dynamic-range scoring.${C_RESET}"
    local quality_rows=("${QUALITY_ROWS[@]}")
    if [[ "$ALBUM_Q_AVAILABLE" == true ]]; then
      quality_rows+=("__SECTION__"$'\t'"")
      quality_rows+=("$(rich_style_album_label "ALBUM (MERGED ${ALBUM_Q_TRACKS} TRACKS)")"$'\t'"$(rich_style_q_score "${ALBUM_Q_SCORE}")"$'\t'"$(rich_style_grade "${ALBUM_Q_GRADE}")"$'\t'"$(rich_escape "${ALBUM_Q_DYN}")"$'\t'"$(rich_style_ups "${ALBUM_Q_UPS}")"$'\t'"$(rich_style_action "${ALBUM_Q_REC}")")
    fi
    if ((${#quality_rows[@]} > 0)); then
      printf '%s\n' "${quality_rows[@]}" | table_render_tsv \
        "FILE NAME,Q 1-10,GRADE,DR,UPS,ACTION" \
        "38,8,6,5,5,24"
    else
      printf '' | table_render_tsv \
        "FILE NAME,Q 1-10,GRADE,DR,UPS,ACTION" \
        "38,8,6,5,5,24"
    fi
    printf "%s\n" "${C_DIM}Legend: DR=dynamic-range score from LRA, UPS=upscaled flag.${C_RESET}"
  fi

  if [[ "$has_pngs" == true && -t 0 && -t 1 ]]; then
    echo -n "Press any key to DELETE generated spectrogram PNG(s), or 'N' to keep and exit: "
    read -n 1 -r user_input </dev/tty
    echo ""
  elif [[ "$has_pngs" == true ]]; then
    user_input="N"
  else
    return
  fi

  if [[ ! "$user_input" =~ ^[Nn]$ ]]; then
    log "Cleaning up spectrogram files..."
    for p in "${GENERATED_PNGS[@]}"; do
      if [[ -f "$p" ]]; then rm -f "$p"; fi
    done
    log "Done. Folder is clean."
  else
    log "Exiting. Spectrograms preserved."
  fi
}

if [[ -d "$TARGET" ]]; then
  log "Audit Mode: Running folder analysis..."
  all_files=()
  collect_spectre_audio_files "$TARGET" all_files true
  if ((${#all_files[@]} == 0)); then
    echo "No supported audio files found under: $TARGET" >&2
    exit 1
  fi
  album_header_log=""
  album_header_log="$(build_album_header "${all_files[0]}" "$TARGET")"
  album_header_log="$(log_style_album_header "$album_header_log")"
  log "Album: $album_header_log"
  # Resolve genre profile from embedded tag so grading uses genre-adaptive thresholds.
  _genre_tag="$(kv_get "GENRE" "$(ffprobe_album_key "${all_files[0]}" 2>/dev/null || true)")"
  if [[ -n "$_genre_tag" ]]; then
    ALBUM_GENRE_PROFILE="$(audio_classify_genre_tag "$_genre_tag")"
    log "Genre profile: ${ALBUM_GENRE_PROFILE} (tag: ${_genre_tag})"
  fi
  unset _genre_tag
  if detect_premerged_album_parts_mode all_files; then
    PREMERGED_PARTS_MODE=true
    RENDER_ALL_TRACK_PNGS=true
    log "Detected pre-merged album image parts (.ape/.wv + cuesheet metadata): skipping synthetic album merge and rendering per-file spectrograms."
  fi
  for file in "${all_files[@]}"; do
    analyze_file "$file"
  done
  if [[ "$PREMERGED_PARTS_MODE" != true ]]; then
    analyze_album_quality_merged all_files
    if [[ "$ALBUM_PNG_RENDERED" != true ]]; then
      render_album_spectrogram "${all_files[0]}" "$TARGET" "${#all_files[@]}" || true
    fi
  fi
  cleanup_and_show_summary
else
  VERBOSE_MODE=true
  # Resolve genre profile from embedded tag for single-file mode.
  _genre_tag="$(kv_get "GENRE" "$(ffprobe_album_key "$TARGET" 2>/dev/null || true)")"
  if [[ -n "$_genre_tag" ]]; then
    ALBUM_GENRE_PROFILE="$(audio_classify_genre_tag "$_genre_tag")"
  fi
  unset _genre_tag
  analyze_file "$TARGET"
  cleanup_and_show_summary
fi
