#!/opt/homebrew/bin/bash
# cue2flac.sh — Split a high-resolution audio file into per-track FLACs using a .cue sheet.
#
# Usage:
#   cue2flac.sh [<dir>|<file.cue>] [--profile <sr/bits>] [--out <output_root>] [--dry-run] [--yes]
#
# Input:  directory containing source audio + .cue, OR direct path to a .cue file.
# Output: CUE2FLAC_OUTPUT_DIR/<Artist>/<Year> - <Album>/NN Track Title.flac
#         (CUE2FLAC_OUTPUT_DIR loaded from .env, default: $HOME/Downloads/Encoded)
#
# Splitting:   ffmpeg -ss/-t (sector-accurate timecodes from CUE INDEX 01)
# Encoding:    encoder.sh abstraction (sox preferred, ffmpeg fallback)
# Resampling:  sox rate -v -s -L <target>k dither -s
# Gain/boost:  album-wide headroom: -0.3 - max_true_peak (applied before SRC in sox chain)
# Tagging:     metaflac --import-tags-from (explicit TAG=value from CUE metadata)
# Formats:     FLAC, WAV (native sox); WavPack/APE/DSF/DFF (pre-convert to temp WAV via ffmpeg)

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
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/encoder.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path
ui_init_colors

require_bins ffmpeg ffprobe >/dev/null || exit 2

# === DEFAULTS ===
INPUT_ARG="."
DEFAULT_PROFILE="96/24"
TARGET_PROFILE=""
OUTPUT_ROOT_ARG=""
DRY_RUN=0
ASSUME_YES=0
SAFETY_MARGIN_DB="-0.3"
MIN_APPLY_GAIN_DB="0.3"

usage() {
  cat <<'EOF_HELP'
Usage:
  cue2flac.sh [<dir>|<file.cue>] [options]

Options:
  --profile <sr/bits>    Target encode profile (default: 96/24). No upscale.
  --out <path>           Override CUE2FLAC_OUTPUT_DIR from .env.
  --dry-run              Print plan and track list; no files written.
  --yes                  Skip confirmation prompt.
  -h, --help             Show this help.

Input:  Directory containing audio + .cue, or direct path to .cue file.
Output: <CUE2FLAC_OUTPUT_DIR>/<Artist>/<Year> - <Album>/NN Track Title.flac
EOF_HELP
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
    [[ -n "$TARGET_PROFILE" ]] || { echo "Error: --profile requires a value." >&2; exit 2; }
    ;;
  --out)
    shift
    OUTPUT_ROOT_ARG="${1:-}"
    [[ -n "$OUTPUT_ROOT_ARG" ]] || { echo "Error: --out requires a value." >&2; exit 2; }
    ;;
  --dry-run)
    DRY_RUN=1
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
    INPUT_ARG="$1"
    ;;
  esac
  shift
done

# === LOCATE CUE FILE ===
CUE_FILE=""
SOURCE_DIR=""

if [[ -f "$INPUT_ARG" && "${INPUT_ARG,,}" == *.cue ]]; then
  CUE_FILE="$(realpath "$INPUT_ARG" 2>/dev/null || printf '%s' "$INPUT_ARG")"
  SOURCE_DIR="$(dirname "$CUE_FILE")"
elif [[ -d "$INPUT_ARG" ]]; then
  SOURCE_DIR="$(realpath "$INPUT_ARG" 2>/dev/null || printf '%s' "$INPUT_ARG")"
  mapfile -t _cue_candidates < <(find "$SOURCE_DIR" -maxdepth 1 -iname "*.cue" | sort || true)
  if ((${#_cue_candidates[@]} == 0)); then
    CUE_FILE=""
  elif ((${#_cue_candidates[@]} == 1)); then
    CUE_FILE="${_cue_candidates[0]}"
  else
    echo "Error: multiple .cue files found in '$SOURCE_DIR'; specify one explicitly." >&2
    printf '  %s\n' "${_cue_candidates[@]}" >&2
    exit 2
  fi
else
  echo "Error: '$INPUT_ARG' is not a directory or .cue file." >&2
  exit 2
fi

if [[ -z "$CUE_FILE" || ! -f "$CUE_FILE" ]]; then
  echo "Error: no .cue file found in '$SOURCE_DIR'." >&2
  exit 1
fi

# === LOCATE SOURCE AUDIO (prefer FLAC > WAV > WV > APE > DSF > DFF) ===
AUDIO_SOURCE=""
for ext in flac wav wv ape dsf dff; do
  found="$(find "$SOURCE_DIR" -maxdepth 1 -iname "*.${ext}" | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    AUDIO_SOURCE="$found"
    break
  fi
done

if [[ -z "$AUDIO_SOURCE" ]]; then
  echo "Error: no supported audio file found in '$SOURCE_DIR'." >&2
  echo "       Supported: .flac .wav .wv .ape .dsf .dff" >&2
  exit 1
fi

AUDIO_EXT="${AUDIO_SOURCE##*.}"
AUDIO_EXT_LC="${AUDIO_EXT,,}"

# === PARSE CUE: GLOBAL METADATA ===
ALBUM=""
DATE=""
GENRE=""
GLOBAL_ARTIST=""
ALBUM="$(awk -F'"' '/^TITLE[[:space:]]/ {print $2; exit}' "$CUE_FILE")"
DATE="$(awk -F'"' '/^REM[[:space:]]+DATE[[:space:]]/ {print $2; exit}' "$CUE_FILE")"
if [[ -z "$DATE" ]]; then
  DATE="$(awk -F'"' '/^REM[[:space:]]+YEAR[[:space:]]/ {print $2; exit}' "$CUE_FILE")"
fi
GLOBAL_ARTIST="$(awk -F'"' '/^PERFORMER[[:space:]]/ {print $2; exit}' "$CUE_FILE")"
GENRE="$(awk -F'"' '/^REM[[:space:]]+GENRE[[:space:]]/ {print $2; exit}' "$CUE_FILE")"

# Extract 4-digit year from DATE (handles YYYY or YYYY-MM-DD)
YEAR=""
if [[ "$DATE" =~ ^([0-9]{4}) ]]; then
  YEAR="${BASH_REMATCH[1]}"
else
  YEAR="Unknown Year"
fi

# === PARSE CUE: PER-TRACK METADATA (titles, performers, INDEX 01 timestamps) ===
declare -a TITLES=()
declare -a PERFORMERS=()
declare -a INDEXES=()
TOTAL_TRACKS=0

current_track=0
in_track=0
while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*TRACK[[:space:]]+([0-9]+) ]]; then
    current_track="${BASH_REMATCH[1]}"
    in_track=1
    TOTAL_TRACKS=$((current_track > TOTAL_TRACKS ? current_track : TOTAL_TRACKS))
  elif ((in_track == 1)) && [[ "$line" =~ ^[[:space:]]*TITLE[[:space:]] ]]; then
    title=$(printf '%s' "$line" | sed -n 's/.*TITLE[[:space:]]*"\(.*\)"/\1/p')
    TITLES[$current_track]="$title"
  elif ((in_track == 1)) && [[ "$line" =~ ^[[:space:]]*PERFORMER[[:space:]] ]]; then
    performer=$(printf '%s' "$line" | sed -n 's/.*PERFORMER[[:space:]]*"\(.*\)"/\1/p')
    PERFORMERS[$current_track]="$performer"
  elif ((in_track == 1)) && [[ "$line" =~ ^[[:space:]]*INDEX[[:space:]]+01[[:space:]]+([0-9]{1,2}:[0-9]{2}:[0-9]{2}) ]]; then
    INDEXES[$current_track]="${BASH_REMATCH[1]}"
  fi
done <"$CUE_FILE"

if ((TOTAL_TRACKS == 0)); then
  echo "Error: no TRACK entries found in '$CUE_FILE'." >&2
  exit 1
fi

# === CUE INDEX → SECONDS ===
cue_index_to_seconds() {
  local idx="$1"
  local mm ss ff
  IFS=':' read -r mm ss ff <<<"$idx"
  awk -v m="$mm" -v s="$ss" -v f="$ff" 'BEGIN{printf "%.6f", m*60 + s + f/75.0}'
}

# Build start-second array
declare -a TRACK_START_SEC=()
for t in $(seq 1 "$TOTAL_TRACKS"); do
  idx="${INDEXES[$t]:-00:00:00}"
  TRACK_START_SEC[$t]="$(cue_index_to_seconds "$idx")"
done

# === SANITIZE PATH COMPONENT ===
sanitize_path_component() {
  local raw="$1"
  printf '%s' "$raw" | tr -d '\000-\037' | sed 's|/|_|g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

# === OUTPUT DIRECTORY ===
OUTPUT_ROOT="${OUTPUT_ROOT_ARG:-${CUE2FLAC_OUTPUT_DIR:-$HOME/Downloads/Encoded}}"
ARTIST_SAFE="$(sanitize_path_component "${GLOBAL_ARTIST:-Unknown Artist}")"
ALBUM_SAFE="$(sanitize_path_component "${YEAR} - ${ALBUM:-Unknown Album}")"
OUTPUT_DIR="$OUTPUT_ROOT/$ARTIST_SAFE/$ALBUM_SAFE"

# === TEMP DIR + CLEANUP ===
_TMPDIR=""
cleanup() {
  [[ -n "$_TMPDIR" ]] && rm -rf "$_TMPDIR"
}
trap cleanup EXIT

_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/cue2flac.XXXXXX")"

# === PROFILE PARSING ===
parse_profile() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)/([0-9]{1,2})$ ]] || return 1
  local sr_part="${BASH_REMATCH[1]}"
  local bits_part="${BASH_REMATCH[3]}"
  case "$bits_part" in
  16 | 24 | 32) ;;
  *) return 1 ;;
  esac
  PARSED_SR_HZ="$(awk -v s="$sr_part" 'BEGIN{printf "%.0f", s*1000.0;}')"
  PARSED_BITS="$bits_part"
}

PARSED_SR_HZ=0
PARSED_BITS=0
profile_to_parse="${TARGET_PROFILE:-$DEFAULT_PROFILE}"
if ! parse_profile "$profile_to_parse"; then
  echo "Error: invalid profile '$profile_to_parse' (expected format like 96/24, 44.1/16)." >&2
  exit 2
fi
TARGET_SR_HZ="$PARSED_SR_HZ"
TARGET_BITS="$PARSED_BITS"

# === PRE-CONVERT OPAQUE SOURCES ===
# sox cannot read WV/APE/DSF/DFF — convert to temp WAV first.
WORK_SOURCE="$AUDIO_SOURCE"
NEEDS_PRECONVERT=0
case "$AUDIO_EXT_LC" in
wv | ape) NEEDS_PRECONVERT=1 ;;
dsf | dff) NEEDS_PRECONVERT=1 ;;
esac

if ((NEEDS_PRECONVERT == 1)); then
  echo "Pre-converting source to temporary PCM WAV..."
  WORK_SOURCE="$_TMPDIR/source_pcm.wav"

  if [[ "$AUDIO_EXT_LC" == "dsf" || "$AUDIO_EXT_LC" == "dff" ]]; then
    # DSD: determine max PCM SR via audio_dsd_max_pcm_profile
    src_sr_hz="$(audio_probe_sample_rate_hz "$AUDIO_SOURCE")"
    dsd_profile="$(audio_dsd_max_pcm_profile "$src_sr_hz")"
    dsd_target_sr="${dsd_profile%%|*}"
    dsd_target_bits_rest="${dsd_profile#*|}"
    dsd_target_bits="${dsd_target_bits_rest%%|*}"
    # Use DSD-derived SR as both pre-convert SR and encode target (cap if lower than --profile)
    if ((dsd_target_sr < TARGET_SR_HZ)); then
      TARGET_SR_HZ="$dsd_target_sr"
    fi
    if ((dsd_target_bits < TARGET_BITS)); then
      TARGET_BITS="$dsd_target_bits"
    fi
    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$AUDIO_SOURCE" \
      -vn -c:a pcm_s32 -ar "$dsd_target_sr" \
      "$WORK_SOURCE" </dev/null
  else
    wvape_bits="$(ffprobe -v error -select_streams a:0 \
      -show_entries stream=bits_per_raw_sample -of csv=p=0 \
      "$AUDIO_SOURCE" </dev/null 2>/dev/null || true)"
    wvape_bits="${wvape_bits%%,*}"
    wvape_bits="$(printf '%s' "$wvape_bits" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ ! "$wvape_bits" =~ ^[0-9]+$ ]] || ((wvape_bits <= 0)); then
      wvape_bits=24
    fi
    if   ((wvape_bits <= 16)); then preconv_codec="pcm_s16le"
    elif ((wvape_bits <= 24)); then preconv_codec="pcm_s24le"
    else                           preconv_codec="pcm_s32le"
    fi
    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$AUDIO_SOURCE" \
      -vn -c:a "$preconv_codec" \
      "$WORK_SOURCE" </dev/null
  fi
  echo "   Pre-convert complete: $(basename "$WORK_SOURCE")"
fi

# === PROBE SOURCE SR AND BIT DEPTH (cap target to source) ===
SRC_SR_HZ="$(audio_probe_sample_rate_hz "$WORK_SOURCE")"
SRC_BITS="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 \
  "$WORK_SOURCE" </dev/null 2>/dev/null || true)"
SRC_BITS="${SRC_BITS%%,*}"
SRC_BITS="$(printf '%s' "$SRC_BITS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ ! "$SRC_BITS" =~ ^[0-9]+$ ]] || ((SRC_BITS <= 0)); then
  SRC_BITS=24
fi

# No upscale: cap target SR and bits to source
if [[ "$SRC_SR_HZ" =~ ^[0-9]+$ ]] && ((SRC_SR_HZ > 0)) && ((TARGET_SR_HZ > SRC_SR_HZ)); then
  TARGET_SR_HZ="$SRC_SR_HZ"
fi
if ((TARGET_BITS > SRC_BITS)); then
  TARGET_BITS="$SRC_BITS"
fi

TARGET_SR_KHZ="$(awk -v s="$TARGET_SR_HZ" 'BEGIN{printf "%.4g", s/1000.0;}')"
TARGET_PROFILE_LABEL="${TARGET_SR_KHZ}/${TARGET_BITS}"

# === TRUE PEAK / BOOST ===
echo "Probing true peak for album-wide headroom boost..."
TRUE_PEAK_DB="$(audio_probe_true_peak_db "$WORK_SOURCE")"
BOOST_GAIN_DB="0.000"
APPLY_BOOST=0
if audio_is_float_number "$TRUE_PEAK_DB"; then
  BOOST_GAIN_DB="$(awk -v m="$SAFETY_MARGIN_DB" -v p="$TRUE_PEAK_DB" 'BEGIN{printf "%.3f", m-p}')"
  if audio_float_ge "$BOOST_GAIN_DB" "$MIN_APPLY_GAIN_DB"; then
    APPLY_BOOST=1
  fi
fi

# === PRINT PLAN ===
printf '\n'
printf 'CUE file  : %s\n' "$CUE_FILE"
printf 'Source    : %s (%s)\n' "$(basename "$AUDIO_SOURCE")" "$AUDIO_EXT_LC"
printf 'Source SR : %s Hz / %s-bit\n' "$SRC_SR_HZ" "$SRC_BITS"
printf 'Target    : %s (FLAC compression level 8)\n' "$TARGET_PROFILE_LABEL"
printf 'Encoder   : %s\n' "$(encoder_log_backend)"
if ((APPLY_BOOST == 1)); then
  printf 'Boost     : +%s dB (true peak: %s dBTP)\n' "$BOOST_GAIN_DB" "$TRUE_PEAK_DB"
else
  printf 'Boost     : skipped (true peak: %s dBTP, gain %s dB < %s dB threshold)\n' \
    "$TRUE_PEAK_DB" "$BOOST_GAIN_DB" "$MIN_APPLY_GAIN_DB"
fi
printf 'Output    : %s\n' "$OUTPUT_DIR"
printf '\nTrack list:\n'
for t in $(seq 1 "$TOTAL_TRACKS"); do
  title="${TITLES[$t]:-Track $t}"
  artist="${PERFORMERS[$t]:-${GLOBAL_ARTIST:-}}"
  [[ -z "$artist" ]] && artist="${GLOBAL_ARTIST:-Unknown Artist}"
  idx="${INDEXES[$t]:-00:00:00}"
  out_name="$(printf '%02d' "$t") $(sanitize_path_component "$title").flac"
  printf '  [%02d] %s — %s  (INDEX %s)\n' "$t" "$title" "$artist" "$idx"
  printf '       -> %s\n' "$out_name"
done
printf '\n'

if ((DRY_RUN == 1)); then
  printf 'Dry-run mode: no files written.\n'
  exit 0
fi

# Confirmation
if ((ASSUME_YES == 0)); then
  if [[ ! -t 0 ]]; then
    echo "Error: confirmation required but stdin is not interactive. Re-run with --yes." >&2
    exit 1
  fi
  printf 'Proceed? [y/N] > '
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

mkdir -p "$OUTPUT_DIR"

# === SPLIT + ENCODE LOOP ===
if   ((SRC_BITS <= 16)); then SEG_PCM_CODEC="pcm_s16le"
elif ((SRC_BITS <= 24)); then SEG_PCM_CODEC="pcm_s24le"
else                         SEG_PCM_CODEC="pcm_s32le"
fi

ok_count=0
fail_count=0

for t in $(seq 1 "$TOTAL_TRACKS"); do
  title="${TITLES[$t]:-Track $t}"
  artist="${PERFORMERS[$t]:-}"
  [[ -z "$artist" ]] && artist="${GLOBAL_ARTIST:-Unknown Artist}"
  start_sec="${TRACK_START_SEC[$t]}"
  out_name="$(printf '%02d' "$t") $(sanitize_path_component "$title").flac"
  out_path="$OUTPUT_DIR/$out_name"

  printf '\n%s▶ [%02d/%02d] ENCODING%s %s\n' "$GREEN" "$t" "$TOTAL_TRACKS" "$RESET" "$out_name"
  printf '     Title    : %s\n' "$title"
  printf '     Artist   : %s\n' "$artist"
  printf '     Album    : %s\n' "${ALBUM:-}"
  printf '     Date     : %s\n' "${DATE:-}"
  printf '     Track    : %s/%s\n' "$t" "$TOTAL_TRACKS"
  printf '     Start    : %s sec\n' "$start_sec"
  if ((APPLY_BOOST == 1)); then
    printf '     Boost    : +%s dB\n' "$BOOST_GAIN_DB"
  else
    printf '     Boost    : skipped\n'
  fi

  # Duration: distance to next track's start, or EOF for last track
  split_args=(-ss "$start_sec")
  if ((t < TOTAL_TRACKS)); then
    next_start="${TRACK_START_SEC[$((t + 1))]}"
    duration="$(awk -v e="$next_start" -v s="$start_sec" 'BEGIN{printf "%.6f", e-s}')"
    split_args+=(-t "$duration")
  fi

  tmp_seg="$_TMPDIR/track_$(printf '%02d' "$t").wav"

  # Extract segment via ffmpeg
  if ! ffmpeg -hide_banner -loglevel error -nostdin -y \
    "${split_args[@]}" \
    -i "$WORK_SOURCE" \
    -vn -c:a "$SEG_PCM_CODEC" \
    "$tmp_seg" </dev/null; then
    printf '%s❌ Segment extract failed for track %s%s\n' "$RED" "$t" "$RESET" >&2
    ((fail_count += 1))
    rm -f "$tmp_seg"
    continue
  fi

  # Encode via encoder.sh
  enc_args=(
    --in "$tmp_seg"
    --out "$out_path"
    --sr "$TARGET_SR_HZ"
    --bits "$TARGET_BITS"
    --src-is-flac 0
  )
  ((APPLY_BOOST == 1)) && enc_args+=(--gain "$BOOST_GAIN_DB")
  [[ -n "$title" ]]            && enc_args+=(--tags "TITLE=$title")
  [[ -n "$artist" ]]           && enc_args+=(--tags "ARTIST=$artist")
  [[ -n "${ALBUM:-}" ]]        && enc_args+=(--tags "ALBUM=$ALBUM")
  [[ -n "${DATE:-}" ]]         && enc_args+=(--tags "DATE=$DATE")
  [[ -n "${GENRE:-}" ]]        && enc_args+=(--tags "GENRE=$GENRE")
  enc_args+=(--tags "TRACKNUMBER=$(printf '%02d' "$t")")
  enc_args+=(--tags "TRACKTOTAL=$TOTAL_TRACKS")

  if encoder_to_flac "${enc_args[@]}"; then
    printf '%s✅ Saved: %s%s\n' "$GREEN" "$out_path" "$RESET"
    ((ok_count += 1))
  else
    printf '%s❌ Encode failed: %s%s\n' "$RED" "$out_name" "$RESET" >&2
    ((fail_count += 1))
  fi

  rm -f "$tmp_seg"
done

printf '\n'
printf 'Done: %s track(s) encoded, %s failed.\n' "$ok_count" "$fail_count"
printf 'Output: %s\n' "$OUTPUT_DIR"

if ((fail_count > 0)); then
  exit 1
fi
