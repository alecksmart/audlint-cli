#!/usr/bin/env bash
# spectre.sh - Generate spectrogram PNG files from audio (file/dir/all modes).

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
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path

SPECTRO_WIDTH="${SPECTRO_WIDTH:-1920}"
SPECTRO_HEIGHT="${SPECTRO_HEIGHT:-1080}"
SPECTRO_LEGEND="${SPECTRO_LEGEND:-1}"

RENDER_ALL_TRACK_PNGS=false
CHECK_DEPS_ONLY=false
TARGET=""

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

show_help() {
  cat <<EOF_HELP
Quick use:
  $(basename "$0") "/path/to/song.flac"
  $(basename "$0") "/path/to/album_folder"
  $(basename "$0") --all "/path/to/album_folder"

Usage: $(basename "$0") [options] "/path/to/target"
       $(basename "$0") --check-deps
       $(basename "$0") --help

Generate spectrogram PNG files from audio.

Modes:
  file path      Generate one PNG next to the input file.
  dir path       Generate album_spectre.png in the directory.
  --all + dir    Generate album_spectre.png plus per-track PNG files.

Output names:
  file mode:   <input_basename>.png
  dir mode:    album_spectre.png
  --all mode:  album_spectre.png + per-track <track_basename>.png

Options:
  --all          In directory mode, also render per-track PNGs.
  --check-deps   Check required runtime dependencies and exit.
  --help         Show this help message.

Environment:
  SPECTRO_WIDTH   Output width in px (default: 1920)
  SPECTRO_HEIGHT  Output height in px (default: 1080)
  SPECTRO_LEGEND  ffmpeg showspectrumpic legend flag, 0 or 1 (default: 1)
EOF_HELP
}

check_deps() {
  local ok=1
  local dep
  for dep in ffmpeg ffprobe; do
    if ! has_bin "$dep"; then
      printf 'Missing dependency: %s\n' "$dep" >&2
      ok=0
    fi
  done

  if [[ "$ok" -eq 1 ]]; then
    printf 'OK: spectre dependencies are available.\n'
    return 0
  fi
  return 1
}

collect_spectre_audio_files() {
  local dir="$1"
  local out_var="$2"
  local recursive="${3:-false}"
  local -n out_ref="$out_var"
  local discovered_files=()
  local f

  out_ref=()
  if [[ "$recursive" == true ]]; then
    # shellcheck disable=SC2046
    while IFS= read -r -d '' f; do
      out_ref+=("$f")
    done < <(find "$dir" -type f \( $(audio_find_iname_args) \) -print0 | sort -z)
    return 0
  fi

  audio_collect_files "$dir" discovered_files
  for f in "${discovered_files[@]}"; do
    out_ref+=("$f")
  done
}

<<<<<<< HEAD
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

=======
>>>>>>> develop
ffmpeg_concat_escape_path() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

generate_spectrogram_png() {
  local in="$1"
  local out_png="$2"

  ffmpeg -y -hide_banner -loglevel error -nostdin \
    -i "$in" \
    -lavfi "showspectrumpic=s=${SPECTRO_WIDTH}x${SPECTRO_HEIGHT}:legend=${SPECTRO_LEGEND}" \
    "$out_png" </dev/null
}

generate_file_mode() {
  local input_file="$1"
  local output_png
  local stem

  stem="${input_file%.*}"
  output_png="${stem}.png"

  log "Generating spectrogram: $(basename "$input_file")"
  if generate_spectrogram_png "$input_file" "$output_png"; then
    log "Saved: $(basename "$output_png")"
    return 0
  fi

  log "Failed: $(basename "$input_file")"
  return 1
}

generate_album_png() {
  local target_dir="$1"
  local files_var="$2"
  local -n files_ref="$files_var"

  local album_png="$target_dir/album_spectre.png"
  local tmpdir
  local concat_list
  local merged_file
  local escaped
  local f

  if ((${#files_ref[@]} == 1)); then
    log "Album mode: single file source, rendering directly."
    generate_spectrogram_png "${files_ref[0]}" "$album_png"
    log "Saved: $(basename "$album_png")"
    return 0
  fi

  tmpdir="$(mktemp -d)"
  concat_list="$tmpdir/concat.txt"
  merged_file="$tmpdir/album-merged.wav"

  for f in "${files_ref[@]}"; do
    escaped="$(ffmpeg_concat_escape_path "$f")"
    printf "file '%s'\n" "$escaped" >>"$concat_list"
  done

  log "Album mode: merging ${#files_ref[@]} file(s)..."
  if ! ffmpeg -y -hide_banner -loglevel error -nostdin \
    -f concat -safe 0 -i "$concat_list" -vn -c:a pcm_s24le "$merged_file" </dev/null; then
    rm -rf "$tmpdir"
    log "Album merge failed."
    return 1
  fi
<<<<<<< HEAD
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
=======

  if ! generate_spectrogram_png "$merged_file" "$album_png"; then
    rm -rf "$tmpdir"
    log "Album spectrogram generation failed."
    return 1
  fi

>>>>>>> develop
  rm -rf "$tmpdir"
  log "Saved: $(basename "$album_png")"
  return 0
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    show_help
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
    --help)
      show_help
      exit 0
      ;;
    --all)
      RENDER_ALL_TRACK_PNGS=true
      ;;
    --check-deps)
      CHECK_DEPS_ONLY=true
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      show_help >&2
      exit 1
      ;;
    *)
      TARGET="$1"
      ;;
    esac
    shift
  done

  if [[ "$CHECK_DEPS_ONLY" == true ]]; then
    check_deps
    exit $?
  fi

  [[ -n "$TARGET" ]] || {
    printf 'Error: No target specified.\n' >&2
    exit 1
  }

  [[ -e "$TARGET" ]] || {
    printf 'Error: Path not found: %s\n' "$TARGET" >&2
    exit 1
  }
}

main() {
  parse_args "$@"
  check_deps || exit 1

  if [[ -d "$TARGET" ]]; then
    local all_files=()
    collect_spectre_audio_files "$TARGET" all_files true

    if ((${#all_files[@]} == 0)); then
      printf 'No supported audio files found under: %s\n' "$TARGET" >&2
      return 1
    fi

    if [[ "$RENDER_ALL_TRACK_PNGS" == true ]]; then
      local file
      for file in "${all_files[@]}"; do
        generate_file_mode "$file" || true
      done
    fi

    generate_album_png "$TARGET" all_files
    return $?
  fi

  generate_file_mode "$TARGET"
}

main "$@"
