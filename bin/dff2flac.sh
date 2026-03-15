#!/usr/bin/env bash
# dff2flac.sh — convert DFF albums to FLAC with cue-aware track metadata.
# This script runs in the current folder by default and writes output to
# ./flac_out unless SOURCE_DIR/OUTPUT_DIR are overridden below.
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
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
ui_init_colors

require_bins ffmpeg ffprobe >/dev/null || exit 2

show_help() {
  cat <<'EOF'
Quick use:
  dff2flac.sh
  dff2flac.sh --dry-run

Usage:
  dff2flac.sh [--dry-run]

Options:
  --dry-run   Print plan and per-track actions; no files written.
  -h, --help  Show this help.

Behavior:
  - Reads .dff files from SOURCE_DIR (default: current directory).
  - Uses a sidecar .cue file when present for track titles/performers.
  - Determines a single album-safe target profile from DSD source rate.
  - Computes true-peak across tracks and applies one album-level gain.

Config (edit in script before run):
  SOURCE_DIR="."
  OUTPUT_DIR="./flac_out"

Dependencies: ffmpeg (with DSDIFF/DFF support), ffprobe
EOF
}

# Script-local defaults.
SOURCE_DIR="."
OUTPUT_DIR="./flac_out"
CUE_FILE="$(find "$SOURCE_DIR" -maxdepth 1 -iname "*.cue" | head -n 1)"

# === DRY RUN CHECK ===
DRY_RUN=0
case "${1:-}" in
-h | --help)
  show_help
  exit 0
  ;;
--dry-run)
  DRY_RUN=1
  ;;
"") ;;
*)
  printf 'Unknown argument: %s\n' "$1" >&2
  show_help >&2
  exit 2
  ;;
esac

analyze_track_worker() {
  local track_no="$1"
  local dff_file="$2"
  local result_file="$3"
  local source_sr_hz profile profile_tail target_sr_hz target_bits family_label policy_label
  local stat_sig mtime size key true_peak_db cache_state

  source_sr_hz="$(audio_probe_sample_rate_hz "$dff_file")"
  profile="$(audio_dsd_max_pcm_profile "$source_sr_hz")"
  target_sr_hz="${profile%%|*}"
  profile_tail="${profile#*|}"
  target_bits="${profile_tail%%|*}"
  profile_tail="${profile_tail#*|}"
  family_label="${profile_tail%%|*}"
  policy_label="${profile_tail#*|}"

  stat_sig="$(audio_probe_file_stat_signature "$dff_file" || true)"
  mtime=""
  size=""
  if [[ -n "$stat_sig" ]]; then
    IFS=$'\t' read -r mtime size <<<"$stat_sig"
  fi

  cache_state="miss"
  true_peak_db=""
  if [[ -n "$mtime" && -n "$size" ]]; then
    key="$(audio_true_peak_cache_key "$dff_file" "$mtime" "$size" "$CACHE_SEP")"
    true_peak_db="${TRUE_PEAK_CACHE[$key]:-}"
    if audio_is_float_number "$true_peak_db"; then
      cache_state="hit"
    fi
  fi

  if [[ "$cache_state" == "miss" ]]; then
    true_peak_db="$(audio_probe_true_peak_db "$dff_file")"
  fi

  if ! audio_is_float_number "$true_peak_db"; then
    printf 'ERR\t%s\t%s\tfailed to read true peak (loudnorm summary).\n' \
      "$track_no" "$dff_file" >"$result_file"
    return 0
  fi

  printf 'OK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$track_no" "$dff_file" "$source_sr_hz" "$target_sr_hz" "$target_bits" "$family_label" "$policy_label" "$true_peak_db" "$cache_state" "$mtime" "$size" >"$result_file"
  printf '   [%s/%s] analyzed: %s | cache=%s | true-peak=%s dBTP\n' \
    "$track_no" "$ANALYSIS_TOTAL_TRACKS" "$(basename "$dff_file")" "$cache_state" "$true_peak_db"
}

mkdir -p "$OUTPUT_DIR"

USE_CUE=1
if [[ ! -f "$CUE_FILE" ]]; then
  USE_CUE=0
  echo "⚠️  No .cue file found in \"$SOURCE_DIR\""
  echo "    Proceeding without cue: each .dff will be encoded with filename-based titles."
fi

# === PARSE GLOBAL METADATA ===
ALBUM=""
DATE=""
GLOBAL_ARTIST=""
if [[ "$USE_CUE" -eq 1 ]]; then
  ALBUM=$(awk -F'"' '/^TITLE/ {print $2; exit}' "$CUE_FILE")
  DATE=$(awk -F'"' '/^REM DATE/ {print $2; exit}' "$CUE_FILE")
  GLOBAL_ARTIST=$(awk -F'"' '/^PERFORMER/ {print $2; exit}' "$CUE_FILE")
fi

# === PARSE TRACK METADATA ===
declare -a TITLES
declare -a PERFORMERS

if [[ "$USE_CUE" -eq 1 ]]; then
  current_track=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*TRACK ]]; then
      ((current_track++))
    elif [[ "$line" =~ TITLE ]]; then
      title=$(echo "$line" | sed -n 's/.*TITLE *"\(.*\)"/\1/p')
      TITLES[$current_track]="$title"
    elif [[ "$line" =~ PERFORMER ]]; then
      performer=$(echo "$line" | sed -n 's/.*PERFORMER *"\(.*\)"/\1/p')
      PERFORMERS[$current_track]="$performer"
    fi
  done <"$CUE_FILE"
fi

# === PROCESS DFF FILES ===
dff_files=()
while IFS= read -r -d '' dff_file; do
  dff_files+=("$dff_file")
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -iname "*.dff" -print0 | sort -z)

if ((${#dff_files[@]} == 0)); then
  echo "⚠️  No .dff files found in \"$SOURCE_DIR\""
  exit 1
fi

SAFETY_MARGIN_DB="$(audio_auto_boost_target_true_peak_db)"
MIN_APPLY_GAIN_DB="$(audio_auto_boost_min_apply_db)"
MAX_TRUE_PEAK_DB="-1000.0"
BOOST_GAIN_DB="0.000"
APPLY_BOOST=0
CACHE_SEP=$'\037'
TRUE_PEAK_CACHE_FILE="$OUTPUT_DIR/.dff2flac_truepeak_cache.tsv"
ANALYSIS_TOTAL_TRACKS="${#dff_files[@]}"

declare -a TRACK_SOURCE_SR
declare -a TRACK_TARGET_SR
declare -a TRACK_TARGET_BITS
declare -a TRACK_FAMILY
declare -a TRACK_POLICY
declare -a TRACK_TRUE_PEAK

ref_source_sr=""
ref_target_sr=""
ref_target_bits=""
ref_family=""
ref_policy=""
analysis_errors=()
consistency_errors=()
declare -A TRUE_PEAK_CACHE=()

cpu_cores="$(audio_detect_cpu_cores)"
ANALYZE_JOBS="${DFF2FLAC_ANALYZE_JOBS:-$cpu_cores}"
if [[ ! "$ANALYZE_JOBS" =~ ^[0-9]+$ ]] || ((ANALYZE_JOBS <= 0)); then
  ANALYZE_JOBS=1
fi
if ((ANALYZE_JOBS > 4)); then
  ANALYZE_JOBS=4
fi
if ((ANALYZE_JOBS > ANALYSIS_TOTAL_TRACKS)); then
  ANALYZE_JOBS="$ANALYSIS_TOTAL_TRACKS"
fi

audio_load_true_peak_cache "$TRUE_PEAK_CACHE_FILE" TRUE_PEAK_CACHE "$CACHE_SEP"
cache_hits=0
cache_misses=0
analysis_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dff2flac_analysis.XXXXXX" 2>/dev/null || true)"
if [[ -z "$analysis_tmp_dir" ]]; then
  echo "❌ Failed to create analysis temp directory." >&2
  exit 1
fi

echo "🔎 Analyzing sources for consistent encode profile + album headroom..."
echo "   tracks=${ANALYSIS_TOTAL_TRACKS} workers=${ANALYZE_JOBS} cache=$(basename "$TRUE_PEAK_CACHE_FILE")"
jobs_running=0
for idx in "${!dff_files[@]}"; do
  track_no=$((idx + 1))
  dff_file="${dff_files[$idx]}"
  result_file="$analysis_tmp_dir/$track_no.tsv"
  analyze_track_worker "$track_no" "$dff_file" "$result_file" &
  ((jobs_running += 1))
  if ((jobs_running >= ANALYZE_JOBS)); then
    wait -n || true
    ((jobs_running -= 1))
  fi
done
while ((jobs_running > 0)); do
  wait -n || true
  ((jobs_running -= 1))
done

for track_no in $(seq 1 "$ANALYSIS_TOTAL_TRACKS"); do
  result_file="$analysis_tmp_dir/$track_no.tsv"
  if [[ ! -s "$result_file" ]]; then
    analysis_errors+=("Track $track_no: missing analysis result output.")
    continue
  fi

  IFS=$'\t' read -r status parsed_track dff_file source_sr_hz target_sr_hz target_bits family_label policy_label true_peak_db cache_state mtime size <"$result_file"
  if [[ "$status" == "ERR" ]]; then
    analysis_errors+=("Track $parsed_track: $dff_file: $source_sr_hz")
    continue
  fi
  if [[ "$status" != "OK" ]]; then
    analysis_errors+=("Track $track_no: malformed analysis output.")
    continue
  fi

  TRACK_SOURCE_SR[$track_no]="$source_sr_hz"
  TRACK_TARGET_SR[$track_no]="$target_sr_hz"
  TRACK_TARGET_BITS[$track_no]="$target_bits"
  TRACK_FAMILY[$track_no]="$family_label"
  TRACK_POLICY[$track_no]="$policy_label"
  TRACK_TRUE_PEAK[$track_no]="$true_peak_db"

  if [[ "$cache_state" == "hit" ]]; then
    ((cache_hits += 1))
  else
    ((cache_misses += 1))
  fi

  if [[ -n "$mtime" && -n "$size" ]] && audio_is_float_number "$true_peak_db"; then
    key="$(audio_true_peak_cache_key "$dff_file" "$mtime" "$size" "$CACHE_SEP")"
    TRUE_PEAK_CACHE["$key"]="$true_peak_db"
  fi

  if audio_float_gt "$true_peak_db" "$MAX_TRUE_PEAK_DB"; then
    MAX_TRUE_PEAK_DB="$true_peak_db"
  fi

  if [[ -z "$ref_source_sr" ]]; then
    ref_source_sr="$source_sr_hz"
    ref_target_sr="$target_sr_hz"
    ref_target_bits="$target_bits"
    ref_family="$family_label"
    ref_policy="$policy_label"
  elif [[ "$source_sr_hz" != "$ref_source_sr" || "$target_sr_hz" != "$ref_target_sr" || "$target_bits" != "$ref_target_bits" || "$family_label" != "$ref_family" || "$policy_label" != "$ref_policy" ]]; then
    consistency_errors+=("Track $track_no: $dff_file | source=${source_sr_hz}Hz target=${target_sr_hz}/${target_bits} family=${family_label} policy=${policy_label}")
  fi
done
rm -rf "$analysis_tmp_dir"
audio_save_true_peak_cache "$TRUE_PEAK_CACHE_FILE" TRUE_PEAK_CACHE "$CACHE_SEP"

if ((${#analysis_errors[@]} > 0)); then
  echo "❌ Analysis failed:"
  printf '  - %s\n' "${analysis_errors[@]}"
  exit 1
fi

if ((${#consistency_errors[@]} > 0)); then
  echo "❌ Inconsistent sources+details"
  echo "   Reference: source=${ref_source_sr}Hz target=${ref_target_sr}/${ref_target_bits} family=${ref_family} policy=${ref_policy}"
  printf '  - %s\n' "${consistency_errors[@]}"
  exit 1
fi

BOOST_GAIN_DB="$(awk -v m="$SAFETY_MARGIN_DB" -v p="$MAX_TRUE_PEAK_DB" 'BEGIN{printf "%.3f", m-p}')"
if audio_float_abs_ge "$BOOST_GAIN_DB" "$MIN_APPLY_GAIN_DB"; then
  APPLY_BOOST=1
fi

echo "     Max true peak   : $(ui_value_text "${MAX_TRUE_PEAK_DB} dBTP")"
echo "     Cache usage     : hits=$(ui_value_text "$cache_hits") misses=$(ui_value_text "$cache_misses")"
if ((APPLY_BOOST == 1)); then
  echo "     Auto boost gain : $(ui_gain_text "$(audio_db_gain_label "$BOOST_GAIN_DB" 3)") dB ($(ui_value_text "enabled"))"
else
  echo "     Auto boost gain : $(ui_gain_text "$(audio_db_gain_label "$BOOST_GAIN_DB" 3)") dB ($(ui_warn_text "skipped"): abs < $(ui_value_text "${MIN_APPLY_GAIN_DB} dB"))"
fi

for idx in "${!dff_files[@]}"; do
  track_no=$((idx + 1))
  dff_file="${dff_files[$idx]}"
  base_name="$(basename "$dff_file" .dff)"
  flac_file="$OUTPUT_DIR/$base_name.flac"
  source_sr_hz="${TRACK_SOURCE_SR[$track_no]}"
  target_sr_hz="${TRACK_TARGET_SR[$track_no]}"
  target_bits="${TRACK_TARGET_BITS[$track_no]}"
  family_label="${TRACK_FAMILY[$track_no]}"
  policy_label="${TRACK_POLICY[$track_no]}"

  if [[ "$USE_CUE" -eq 1 ]]; then
    title="${TITLES[$track_no]}"
    performer="${PERFORMERS[$track_no]}"
    [[ -z "$performer" ]] && performer="$GLOBAL_ARTIST"
  else
    title="$base_name"
    performer=""
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '\n%s▶ [%s] ENCODING%s %s %s %s\n' "$GREEN" "$track_no" "$RESET" "$(ui_input_path_text "$dff_file")" "$(ui_arrow_text)" "$(ui_output_path_text "$flac_file")"
  else
    echo -e "\n🎵 [$track_no] Converting: \"$dff_file\" → \"$flac_file\""
  fi
  echo "     Title    : $(ui_value_text "$title")"
  echo "     Artist   : $(ui_value_text "$performer")"
  echo "     Album    : $(ui_value_text "$ALBUM")"
  echo "     Date     : $(ui_value_text "$DATE")"
  echo "     Track    : $(ui_value_text "$track_no")"
  echo "     Source SR: $(ui_value_text "${source_sr_hz} Hz")"
  echo "     Target   : $(ui_value_text "${target_sr_hz} Hz / ${target_bits}-bit") ($(ui_value_text "$family_label"), $(ui_value_text "$policy_label"))"
  if ((APPLY_BOOST == 1)); then
    echo "     Boost    : $(ui_gain_text "$(audio_db_gain_label "$BOOST_GAIN_DB" 3)") dB ($(ui_value_text "album auto"))"
  else
    echo "     Boost    : $(ui_warn_text "skipped")"
  fi
  if [[ "$family_label" == "fallback" ]]; then
    echo "⚠️  Could not infer source family from sample rate \"$source_sr_hz\"; using 176400/24 ceiling with no-upscale guard."
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    enc_args=(--in "$dff_file" --out "$flac_file" --sr "$target_sr_hz" --bits "$target_bits" --src-is-flac 0 --src-codec dff)
    if ((APPLY_BOOST == 1)); then
      enc_args+=(--gain "$BOOST_GAIN_DB")
    fi
    # Inject explicit tags (DSD source has no Vorbis comments for metaflac to read).
    [[ -n "$title" ]]     && enc_args+=(--tags "TITLE=$title")
    [[ -n "$performer" ]] && enc_args+=(--tags "ARTIST=$performer")
    [[ -n "$ALBUM" ]]     && enc_args+=(--tags "ALBUM=$ALBUM")
    [[ -n "$DATE" ]]      && enc_args+=(--tags "DATE=$DATE")
    enc_args+=(--tags "TRACKNUMBER=$track_no")

    if encoder_to_flac "${enc_args[@]}"; then
      echo "✅ Saved: $(ui_output_path_text "$flac_file")"
    else
      echo "❌ Failed to convert \"$dff_file\"" >&2
    fi
  fi
done
