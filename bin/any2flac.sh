#!/opt/homebrew/bin/bash
# any2flac.sh - Convert audio files in a directory to FLAC at a target profile.
# Policy:
# - No lossy -> FLAC conversion (mp3/aac/etc. fail).
# - No upscaling: target sample rate/bit depth must not exceed source.
# - Replaces originals in-place (non-FLAC sources become .flac).

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
source "$BOOTSTRAP_DIR/../lib/sh/deps.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/encoder.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
require_bins ffprobe >/dev/null || exit 2
if ! encoder_has_sox && ! has_bin ffmpeg; then
  printf 'Missing dependency: sox or ffmpeg (at least one encoder is required)\n' >&2
  exit 2
fi

TARGET_PROFILE=""
WORK_DIR="."
DRY_RUN=0
ASSUME_YES=0
PLAN_ONLY=0
WITH_BOOST=0

TARGET_SR_HZ=0
TARGET_SR_LABEL=""
TARGET_BITS=0
TARGET_SAMPLE_FMT=""
BOOST_GAIN_DB="0.000"
APPLY_BOOST=0
BOOST_SAFETY_MARGIN_DB="-0.3"
BOOST_MIN_APPLY_DB="0.3"

usage() {
  cat <<'EOF_HELP'
Usage:
  any2flac.sh <profile> [directory]
  any2flac.sh --profile <profile> [--dir <directory>] [--dry-run] [--yes] [--plan-only] [--with-boost]

Profile format:
  <sample_rate_khz>/<bit_depth>
Examples:
  44.1/16
  48/24
  96/24
  192/24

Behavior:
  - Converts all supported audio files in the target directory.
  - Replaces originals in-place with FLAC outputs.
  - --plan-only prints per-file plan and exits without conversion.
  - --with-boost runs album true-peak analysis and applies one auto gain during encode.
  - Fails if target profile is above source profile (no upscale).
  - Fails if any source is lossy (no mp3/aac/... -> flac).
  - Fails when no audio files are found.
EOF_HELP
}

normalize_profile_label() {
  local sr_khz="$1"
  local bits="$2"
  printf '%s/%s' "$(awk -v s="$sr_khz" 'BEGIN{printf "%.1f", s;}' | sed 's/\.0$//')" "$bits"
}

parse_target_profile() {
  local raw="$1"
  local sr_part bits_part
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [[ -n "$raw" ]] || return 1
  [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)/([0-9]{1,2})$ ]] || return 1
  sr_part="${BASH_REMATCH[1]}"
  bits_part="${BASH_REMATCH[3]}"

  case "$bits_part" in
  16 | 24 | 32) ;;
  *) return 1 ;;
  esac

  TARGET_SR_HZ="$(awk -v s="$sr_part" 'BEGIN{printf "%.0f", s*1000.0;}')"
  [[ "$TARGET_SR_HZ" =~ ^[0-9]+$ ]] || return 1
  ((TARGET_SR_HZ > 0)) || return 1
  TARGET_BITS="$bits_part"
  TARGET_SR_LABEL="$(normalize_profile_label "$sr_part" "$bits_part")"

  case "$TARGET_BITS" in
  16) TARGET_SAMPLE_FMT="s16" ;;
  24 | 32) TARGET_SAMPLE_FMT="s32" ;;
  esac
}

probe_codec_name() {
  local in="$1"
  local codec
  codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  codec="${codec%%,*}"
  codec="$(printf '%s' "$codec" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$codec"
}

probe_bit_depth() {
  local in="$1"
  local bps sfmt
  bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  bps="${bps%%,*}"
  bps="$(printf '%s' "$bps" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$bps" =~ ^[0-9]+$ ]] && ((bps > 0)); then
    printf '%s' "$bps"
    return 0
  fi

  sfmt="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  sfmt="${sfmt%%,*}"
  sfmt="$(printf '%s' "$sfmt" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$sfmt" in
  s16 | s16p) printf '16' ;;
  s24 | s24p) printf '24' ;;
  s32 | s32p | flt | fltp) printf '32' ;;
  dbl | dblp) printf '64' ;;
  *) printf '0' ;;
  esac
}

# Alias — canonical implementation lives in lib/sh/audio.sh.
is_lossy_codec() { audio_is_lossy_codec "$@"; }

is_dsd_codec() {
  local codec="$1"
  case "$codec" in
  dsd*) return 0 ;;
  *) return 1 ;;
  esac
}

normalize_source_bit_depth() {
  local codec="$1"
  local bit_depth="$2"

  if is_dsd_codec "$codec"; then
    # DSD can probe as 1-bit; treat as 24-bit ceiling for PCM target validation.
    if [[ ! "$bit_depth" =~ ^[0-9]+$ ]] || ((bit_depth < 24)); then
      printf '24'
      return 0
    fi
  fi

  if [[ "$bit_depth" =~ ^[0-9]+$ ]] && ((bit_depth > 0)); then
    printf '%s' "$bit_depth"
  else
    printf '0'
  fi
}

profile_label_from_source() {
  local sr_hz="$1"
  local bits="$2"
  if [[ "$sr_hz" =~ ^[0-9]+$ ]] && ((sr_hz > 0)) && [[ "$bits" =~ ^[0-9]+$ ]] && ((bits > 0)); then
    printf '%s/%s' "$(awk -v s="$sr_hz" 'BEGIN{printf "%.1f", s/1000.0;}' | sed 's/\.0$//')" "$bits"
  else
    printf '?/?'
  fi
}

probe_bitrate_label() {
  local in="$1"
  local br
  br="$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  br="${br%%,*}"
  br="$(printf '%s' "$br" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$br" =~ ^[0-9]+$ ]] && ((br > 0)); then
    awk -v b="$br" 'BEGIN{printf "%.0fk", b/1000.0;}'
  else
    printf '?'
  fi
}

file_size_bytes() {
  local path="$1"
  local out=""
  if out="$(stat -f '%z' "$path" 2>/dev/null)"; then
    [[ "$out" =~ ^[0-9]+$ ]] && {
      printf '%s' "$out"
      return 0
    }
  fi
  if out="$(stat -c '%s' "$path" 2>/dev/null)"; then
    [[ "$out" =~ ^[0-9]+$ ]] && {
      printf '%s' "$out"
      return 0
    }
  fi
  printf '?'
}

print_plan_rows() {
  local src target src_profile src_codec src_bitrate src_size src_name
  printf '%s\n' 'Plan rows:'
  printf '%s\n' $'  Filename\tSize(bytes)\tCodec\tProfile\tBitrate\tTarget Profile'
  for src in "${audio_files[@]}"; do
    target="${target_for_source["$src"]}"
    src_profile="${source_profile_for_source["$src"]:-?/?}"
    src_codec="${source_codec_for_source["$src"]:-?}"
    src_bitrate="${source_bitrate_for_source["$src"]:-?}"
    src_size="$(file_size_bytes "$src")"
    src_name="$(basename "$src")"
    printf '  %s\t%s\t%s\t%s\t%s\t%s\n' "$src_name" "$src_size" "$src_codec" "$src_profile" "$src_bitrate" "$TARGET_SR_LABEL"
    # Keep summary checkpoint lines for backward compatibility with existing logs.
    printf '  - [%s | %s] %s -> %s | target=%s\n' "$src_codec" "$src_profile" "$src" "$target" "$TARGET_SR_LABEL"
  done
}

boost_analyze_worker() {
  local track_no="$1"
  local src="$2"
  local result_file="$3"
  local stat_sig mtime size key true_peak_db cache_state

  stat_sig="$(audio_probe_file_stat_signature "$src" || true)"
  mtime=""
  size=""
  if [[ -n "$stat_sig" ]]; then
    IFS=$'\t' read -r mtime size <<<"$stat_sig"
  fi

  cache_state="miss"
  true_peak_db=""
  if [[ -n "$mtime" && -n "$size" ]]; then
    key="$(audio_true_peak_cache_key "$src" "$mtime" "$size" "$BOOST_CACHE_SEP")"
    true_peak_db="${BOOST_TRUE_PEAK_CACHE[$key]:-}"
    if audio_is_float_number "$true_peak_db"; then
      cache_state="hit"
    fi
  fi

  if [[ "$cache_state" == "miss" ]]; then
    true_peak_db="$(audio_probe_true_peak_db "$src")"
  fi

  if ! audio_is_float_number "$true_peak_db"; then
    printf 'ERR\t%s\t%s\tfailed to read true peak (loudnorm summary).\n' "$track_no" "$src" >"$result_file"
    return 0
  fi

  printf 'OK\t%s\t%s\t%s\t%s\t%s\t%s\n' "$track_no" "$src" "$true_peak_db" "$cache_state" "$mtime" "$size" >"$result_file"
  printf '   [%s/%s] analyzed: %s | cache=%s | true-peak=%s dBTP\n' \
    "$track_no" "$BOOST_ANALYSIS_TOTAL" "$(basename "$src")" "$cache_state" "$true_peak_db"
}

run_boost_analysis_if_enabled() {
  local cache_hits cache_misses max_true_peak_db analysis_tmp_dir jobs_running
  local track_no src result_file status parsed_track true_peak_db cache_state mtime size key
  local errors=()

  if ((WITH_BOOST == 0)); then
    return 0
  fi

  BOOST_ANALYSIS_TOTAL="${#audio_files[@]}"
  BOOST_CACHE_SEP=$'\037'
  BOOST_CACHE_FILE="$WORK_DIR/.any2flac_truepeak_cache.tsv"
  declare -gA BOOST_TRUE_PEAK_CACHE=()
  audio_load_true_peak_cache "$BOOST_CACHE_FILE" BOOST_TRUE_PEAK_CACHE "$BOOST_CACHE_SEP"

  boost_jobs="${ANY2FLAC_ANALYZE_JOBS:-$(audio_detect_cpu_cores)}"
  if [[ ! "$boost_jobs" =~ ^[0-9]+$ ]] || ((boost_jobs <= 0)); then
    boost_jobs=1
  fi
  if ((boost_jobs > 4)); then
    boost_jobs=4
  fi
  if ((boost_jobs > BOOST_ANALYSIS_TOTAL)); then
    boost_jobs="$BOOST_ANALYSIS_TOTAL"
  fi

  echo "🔎 Analyzing true peak for album auto boost..."
  echo "   tracks=${BOOST_ANALYSIS_TOTAL} workers=${boost_jobs} cache=$(basename "$BOOST_CACHE_FILE")"

  analysis_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/any2flac_boost_analysis.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$analysis_tmp_dir" ]]; then
    echo "Error: failed to create boost analysis temp directory." >&2
    return 1
  fi

  cache_hits=0
  cache_misses=0
  max_true_peak_db="-1000.0"
  jobs_running=0
  for idx in "${!audio_files[@]}"; do
    track_no=$((idx + 1))
    src="${audio_files[$idx]}"
    result_file="$analysis_tmp_dir/$track_no.tsv"
    boost_analyze_worker "$track_no" "$src" "$result_file" &
    ((jobs_running += 1))
    if ((jobs_running >= boost_jobs)); then
      wait -n || true
      ((jobs_running -= 1))
    fi
  done
  while ((jobs_running > 0)); do
    wait -n || true
    ((jobs_running -= 1))
  done

  for track_no in $(seq 1 "$BOOST_ANALYSIS_TOTAL"); do
    result_file="$analysis_tmp_dir/$track_no.tsv"
    if [[ ! -s "$result_file" ]]; then
      errors+=("Track $track_no: missing analysis result output.")
      continue
    fi
    IFS=$'\t' read -r status parsed_track src true_peak_db cache_state mtime size <"$result_file"
    if [[ "$status" == "ERR" ]]; then
      errors+=("Track $parsed_track: $src: $true_peak_db")
      continue
    fi
    if [[ "$status" != "OK" ]]; then
      errors+=("Track $track_no: malformed analysis output.")
      continue
    fi

    if [[ "$cache_state" == "hit" ]]; then
      ((cache_hits += 1))
    else
      ((cache_misses += 1))
    fi

    if [[ -n "$mtime" && -n "$size" ]] && audio_is_float_number "$true_peak_db"; then
      key="$(audio_true_peak_cache_key "$src" "$mtime" "$size" "$BOOST_CACHE_SEP")"
      BOOST_TRUE_PEAK_CACHE["$key"]="$true_peak_db"
    fi

    if audio_float_gt "$true_peak_db" "$max_true_peak_db"; then
      max_true_peak_db="$true_peak_db"
    fi
  done

  rm -rf "$analysis_tmp_dir"
  audio_save_true_peak_cache "$BOOST_CACHE_FILE" BOOST_TRUE_PEAK_CACHE "$BOOST_CACHE_SEP"

  if ((${#errors[@]} > 0)); then
    printf '%s\n' "Boost analysis failed:"
    printf '  - %s\n' "${errors[@]}"
    return 1
  fi

  BOOST_GAIN_DB="$(awk -v m="$BOOST_SAFETY_MARGIN_DB" -v p="$max_true_peak_db" 'BEGIN{printf "%.3f", m-p}')"
  if audio_float_ge "$BOOST_GAIN_DB" "$BOOST_MIN_APPLY_DB"; then
    APPLY_BOOST=1
  else
    APPLY_BOOST=0
  fi

  printf 'Boost true peak: %s dBTP\n' "$max_true_peak_db"
  printf 'Boost cache usage: hits=%s misses=%s\n' "$cache_hits" "$cache_misses"
  if ((APPLY_BOOST == 1)); then
    printf 'Boost auto gain: +%s dB (enabled)\n' "$BOOST_GAIN_DB"
  else
    printf 'Boost auto gain: +%s dB (skipped: < %s dB)\n' "$BOOST_GAIN_DB" "$BOOST_MIN_APPLY_DB"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --profile)
    shift
    TARGET_PROFILE="${1:-}"
    [[ -n "$TARGET_PROFILE" ]] || {
      echo "Error: --profile requires a value." >&2
      exit 2
    }
    ;;
  --dir)
    shift
    WORK_DIR="${1:-}"
    [[ -n "$WORK_DIR" ]] || {
      echo "Error: --dir requires a value." >&2
      exit 2
    }
    ;;
  --dry-run)
    DRY_RUN=1
    ;;
  --plan-only)
    PLAN_ONLY=1
    ;;
  --with-boost)
    WITH_BOOST=1
    ;;
  --yes)
    ASSUME_YES=1
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "Error: unknown option: $1" >&2
    usage
    exit 2
    ;;
  *)
    if [[ -z "$TARGET_PROFILE" ]]; then
      TARGET_PROFILE="$1"
    elif [[ "$WORK_DIR" == "." ]]; then
      WORK_DIR="$1"
    else
      echo "Error: unexpected argument: $1" >&2
      usage
      exit 2
    fi
    ;;
  esac
  shift
done

if [[ -z "$TARGET_PROFILE" ]]; then
  echo "Error: profile is required." >&2
  usage
  exit 2
fi

if ! parse_target_profile "$TARGET_PROFILE"; then
  echo "Error: invalid profile '$TARGET_PROFILE' (expected format like 44.1/16, 96/24)." >&2
  exit 2
fi

if [[ ! -d "$WORK_DIR" ]]; then
  echo "Error: directory not found: $WORK_DIR" >&2
  exit 2
fi

audio_files=()
audio_collect_files "$WORK_DIR" audio_files
if ((${#audio_files[@]} == 0)); then
  echo "Error: no audio files found in: $WORK_DIR" >&2
  exit 1
fi

declare -A target_for_source=()
declare -A src_for_target=()
declare -A source_profile_for_source=()
declare -A source_codec_for_source=()
declare -A source_bitrate_for_source=()
preflight_errors=()

for src in "${audio_files[@]}"; do
  target="${src%.*}.flac"
  target_for_source["$src"]="$target"

  prev_src="${src_for_target["$target"]:-}"
  if [[ -n "$prev_src" && "$prev_src" != "$src" ]]; then
    preflight_errors+=("target collision: '$prev_src' and '$src' both map to '$target'")
    continue
  fi
  src_for_target["$target"]="$src"

  codec="$(probe_codec_name "$src")"
  sr_hz="$(audio_probe_sample_rate_hz "$src")"
  bit_depth="$(probe_bit_depth "$src")"
  eff_bit_depth="$(normalize_source_bit_depth "$codec" "$bit_depth")"
  src_profile="$(profile_label_from_source "$sr_hz" "$eff_bit_depth")"
  source_profile_for_source["$src"]="$src_profile"
  source_codec_for_source["$src"]="$codec"
  source_bitrate_for_source["$src"]="$(probe_bitrate_label "$src")"

  if [[ -z "$codec" ]]; then
    preflight_errors+=("$src: unable to detect codec")
    continue
  fi
  if is_lossy_codec "$codec"; then
    preflight_errors+=("$src: lossy source codec '$codec' is not allowed for FLAC replace workflow")
    continue
  fi
  if [[ ! "$sr_hz" =~ ^[0-9]+$ ]] || ((sr_hz <= 0)); then
    preflight_errors+=("$src: unable to detect sample rate")
    continue
  fi
  if [[ ! "$eff_bit_depth" =~ ^[0-9]+$ ]] || ((eff_bit_depth <= 0)); then
    preflight_errors+=("$src: unable to detect bit depth")
    continue
  fi
  if ((TARGET_SR_HZ > sr_hz || TARGET_BITS > eff_bit_depth)); then
    preflight_errors+=("$src: target '$TARGET_SR_LABEL' is higher than source '$src_profile' (upscale blocked)")
    continue
  fi
done

if ((${#preflight_errors[@]} > 0)); then
  printf '%s\n' "Preflight failed:"
  printf '  - %s\n' "${preflight_errors[@]}"
  exit 1
fi

if ! run_boost_analysis_if_enabled; then
  exit 1
fi

printf 'Target profile: %s (FLAC compression level 8)\n' "$TARGET_SR_LABEL"
printf 'Encoder: %s\n' "$(encoder_log_backend)"
printf 'Files to convert: %s\n' "${#audio_files[@]}"
if ((DRY_RUN == 1)); then
  printf 'Dry run: yes\n'
fi
if ((WITH_BOOST == 1)); then
  if ((APPLY_BOOST == 1)); then
    printf 'Boost mode: enabled (+%s dB)\n' "$BOOST_GAIN_DB"
  else
    printf 'Boost mode: enabled (gain skipped)\n'
  fi
fi
printf '%s\n' 'Summary checkpoint:'
print_plan_rows

if ((PLAN_ONLY == 1)); then
  printf 'Plan-only mode completed: %s file(s) validated.\n' "${#audio_files[@]}"
  exit 0
fi

if ((ASSUME_YES == 0)); then
  if [[ ! -t 0 ]]; then
    echo "Error: confirmation required but stdin is not interactive. Re-run with --yes." >&2
    exit 1
  fi
  printf 'Proceed with conversion? [y/N] > '
  confirm_choice=""
  if ! IFS= read -r confirm_choice </dev/tty; then
    printf '\n'
    echo "Cancelled." >&2
    exit 1
  fi
  printf '\n'
  if [[ "$confirm_choice" != "y" ]]; then
    echo "Cancelled."
    exit 1
  fi
fi

converted=0
for src in "${audio_files[@]}"; do
  target="${target_for_source["$src"]}"
  tmp_out="${target}.any2flac.tmp.$$.flac"
  printf 'Converting: %s -> %s\n' "$src" "$target"

  if ((DRY_RUN == 1)); then
    continue
  fi

  encode_gain_db=""
  if ((WITH_BOOST == 1 && APPLY_BOOST == 1)); then
    encode_gain_db="$BOOST_GAIN_DB"
  fi

  src_codec="${source_codec_for_source["$src"]:-}"
  encode_src_is_flac=1
  [[ "$src_codec" == "flac" ]] || encode_src_is_flac=0

  encode_args=(--in "$src" --out "$tmp_out" --sr "$TARGET_SR_HZ" --bits "$TARGET_BITS" --src-is-flac "$encode_src_is_flac")
  [[ -n "$encode_gain_db" ]] && encode_args+=(--gain "$encode_gain_db")

  if ! encoder_to_flac "${encode_args[@]}"; then
    rm -f "$tmp_out"
    echo "Error: encode failed for '$src'" >&2
    exit 1
  fi

  if [[ "$target" != "$src" ]]; then
    rm -f "$target"
    mv -f "$tmp_out" "$target"
    rm -f "$src"
  else
    # In-place replacement for FLAC source path.
    mv -f "$tmp_out" "$target"
  fi
  converted=$((converted + 1))
done

if ((DRY_RUN == 1)); then
  printf 'Dry run completed: %s file(s) validated for conversion.\n' "${#audio_files[@]}"
else
  printf 'Completed: %s file(s) converted to %s.\n' "$converted" "$TARGET_SR_LABEL"
fi
