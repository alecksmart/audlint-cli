#!/usr/bin/env bash
# cue2flac.sh — Split a high-resolution audio file into per-track FLACs using a .cue sheet.
#
# Usage:
#   cue2flac.sh [<dir>|<file.cue>] [--profile <sr/bits>] [--help-profiles] [--check-upscale] [--out <output_root>] [--dry-run] [--yes]
#
# Input:  directory containing source audio + .cue, OR direct path to a .cue file.
# Output: AUDL_CUE2FLAC_OUTPUT_DIR/<Artist>/<Year> - <Album>/NN Track Title.flac
#         (AUDL_CUE2FLAC_OUTPUT_DIR loaded from .env, default: $HOME/Downloads/Encoded)
#
# Splitting:     ffmpeg -ss/-t (sector-accurate timecodes from CUE INDEX 01)
# Encoding:      encoder.sh abstraction (sox preferred, ffmpeg fallback)
# Resampling:    sox rate -v -s -L <target>k dither -s
# Gain/boost:    album-wide headroom: -0.3 - max_true_peak (applied before SRC in sox chain)
# Tagging:       metaflac --import-tags-from (explicit TAG=value from CUE metadata)
# Formats:       FLAC, WAV (native sox); WavPack/APE/DSF/DFF (pre-convert to temp WAV via ffmpeg)
# Multi-file:    CUE sheets with multiple FILE directives (e.g. vinyl Side A / Side B) are supported.
# --check-upscale: spectral target analysis via audlint-analyze.sh;
#                  auto-selects the recommended encode profile instead of defaulting to 192000/24.

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
source "$BOOTSTRAP_DIR/../lib/sh/profile.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/python.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/artwork.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path
ui_init_colors

AUDLINT_ANALYZE_BIN="${AUDLINT_ANALYZE_BIN:-$SCRIPT_DIR/audlint-analyze.sh}"
AUDLINT_COVER_ALBUM_BIN="${AUDLINT_COVER_ALBUM_BIN:-$SCRIPT_DIR/cover_album.sh}"

require_bins ffmpeg ffprobe >/dev/null || exit 2

# === DEFAULTS ===
INPUT_ARG="."
DEFAULT_PROFILE="192000/24"
TARGET_PROFILE=""
CHECK_UPSCALE=0
OUTPUT_ROOT_ARG=""
DRY_RUN=0
ASSUME_YES=0
SAFETY_MARGIN_DB="$(audio_auto_boost_target_true_peak_db)"
MIN_APPLY_GAIN_DB="$(audio_auto_boost_min_apply_db)"

show_help() {
  cat <<'EOF_HELP'
Usage:
  cue2flac.sh [<dir>|<file.cue>] [options]

Options:
  --profile <sr/bits>    Target encode profile (default: 192000/24). No upscale. Mutually exclusive with --check-upscale.
  --help-profiles        Show accepted profile input forms and common targets.
  --check-upscale        Run audlint-analyze spectral target detection and auto-select the best encode profile.
  --out <path>           Override AUDL_CUE2FLAC_OUTPUT_DIR from .env.
  --dry-run              Print plan and track list; no files written.
  --yes                  Skip confirmation prompt.
  -h, --help             Show this help.

Input:  Directory containing audio + .cue, or direct path to .cue file.
Output: <AUDL_CUE2FLAC_OUTPUT_DIR>/<Artist>/<Year> - <Album>/NN Track Title.flac
EOF_HELP
}

show_help_profiles() {
  profile_print_help
  printf '\n'
  profile_print_supported_targets
  printf '\ncue2flac profile limits:\n'
  printf '  - Target bits accepted: 16, 24, 32\n'
  printf '  - Fuzzy inputs accepted; normalized internally before validation.\n'
}

# CUE FILE resolution priority when the referenced extension is wrong/missing.
# Example: CUE says "album.wav" but only "album.ape" exists on disk.
CUE_SOURCE_EXT_PRIORITY=(flac wav wv ape dsf dff)

cue_resolve_source_file() {
  local source_dir="$1"
  local cue_ref="$2"
  local candidate=""
  local stem=""
  local ext=""

  [[ -n "$cue_ref" ]] || return 1

  # Exact path first.
  candidate="$source_dir/$cue_ref"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # Case-insensitive exact name match in source dir.
  candidate="$(find "$source_dir" -maxdepth 1 -type f -iname "$cue_ref" | head -n 1 || true)"
  if [[ -n "$candidate" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # Extension fallback using the same basename in known source formats.
  stem="$cue_ref"
  if [[ "$cue_ref" == *.* ]]; then
    stem="${cue_ref%.*}"
  fi
  [[ -n "$stem" ]] || return 1

  for ext in "${CUE_SOURCE_EXT_PRIORITY[@]}"; do
    candidate="$source_dir/$stem.$ext"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="$(find "$source_dir" -maxdepth 1 -type f -iname "$stem.$ext" | head -n 1 || true)"
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

cue_count_resolvable_file_refs() {
  local cue_path="$1"
  local source_dir="$2"
  local line ref
  local total=0
  local matched=0
  local candidate=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*FILE[[:space:]]+ ]] || continue

    ref=""
    if [[ "$line" =~ ^[[:space:]]*FILE[[:space:]]+\"([^\"]+)\" ]]; then
      ref="${BASH_REMATCH[1]}"
    else
      ref="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*FILE[[:space:]]+//; s/[[:space:]]+[[:alnum:]_]+[[:space:]]*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')"
    fi
    [[ -n "$ref" ]] || continue

    ((total += 1))
    candidate="$(cue_resolve_source_file "$source_dir" "$ref" || true)"
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      ((matched += 1))
    fi
  done <"$cue_path"

  printf '%s %s\n' "$matched" "$total"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    show_help
    exit 0
    ;;
  --help-profiles)
    show_help_profiles
    exit 0
    ;;
  --profile)
    shift
    TARGET_PROFILE="${1:-}"
    [[ -n "$TARGET_PROFILE" ]] || { echo "Error: --profile requires a value." >&2; exit 2; }
    ;;
  --check-upscale)
    CHECK_UPSCALE=1
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
    show_help >&2
    exit 2
    ;;
  *)
    INPUT_ARG="$1"
    ;;
  esac
  shift
done

# Mutual exclusion: --check-upscale and --profile cannot be used together
if ((CHECK_UPSCALE == 1)) && [[ -n "$TARGET_PROFILE" ]]; then
  echo "Error: --check-upscale and --profile are mutually exclusive." >&2
  exit 2
fi

# === LOCATE CUE FILE ===
CUE_FILE=""
SOURCE_DIR=""

if [[ -f "$INPUT_ARG" && "${INPUT_ARG,,}" == *.cue ]]; then
  CUE_FILE="$(path_resolve "$INPUT_ARG" 2>/dev/null || printf '%s' "$INPUT_ARG")"
  SOURCE_DIR="$(dirname "$CUE_FILE")"
elif [[ -d "$INPUT_ARG" ]]; then
  SOURCE_DIR="$(path_resolve "$INPUT_ARG" 2>/dev/null || printf '%s' "$INPUT_ARG")"
  mapfile -t _cue_candidates < <(find "$SOURCE_DIR" -maxdepth 1 -iname "*.cue" | sort || true)
  if ((${#_cue_candidates[@]} == 0)); then
    CUE_FILE=""
  elif ((${#_cue_candidates[@]} == 1)); then
    CUE_FILE="${_cue_candidates[0]}"
  else
    declare -a _resolvable_candidates=()
    for _candidate in "${_cue_candidates[@]}"; do
      read -r _matched _total < <(cue_count_resolvable_file_refs "$_candidate" "$SOURCE_DIR")
      if [[ "$_matched" =~ ^[0-9]+$ && "$_total" =~ ^[0-9]+$ ]] && ((_total > 0)) && ((_matched == _total)); then
        _resolvable_candidates+=("$_candidate")
      fi
    done

    if ((${#_resolvable_candidates[@]} == 1)); then
      CUE_FILE="${_resolvable_candidates[0]}"
      printf 'Auto-selected CUE: %s (unique candidate with resolvable FILE references)\n' "$CUE_FILE"
    else
      echo "Error: multiple .cue files found in '$SOURCE_DIR'; specify one explicitly." >&2
      printf '  %s\n' "${_cue_candidates[@]}" >&2
      exit 2
    fi
  fi
else
  echo "Error: '$INPUT_ARG' is not a directory or .cue file." >&2
  exit 2
fi

if [[ -z "$CUE_FILE" || ! -f "$CUE_FILE" ]]; then
  echo "Error: no .cue file found in '$SOURCE_DIR'." >&2
  exit 1
fi

cue_trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

cue_extract_line_value() {
  local line="$1"
  local directive="$2"
  local value="${line%$'\r'}"
  value="$(cue_trim_whitespace "$value")"
  [[ "$value" == "$directive"* ]] || return 1
  value="${value#"$directive"}"
  value="$(cue_trim_whitespace "$value")"
  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%%\"*}"
  fi
  value="$(cue_trim_whitespace "$value")"
  printf '%s' "$value"
}

cue_extract_file_key() {
  local line="$1"
  local value="${line%$'\r'}"
  if [[ "$value" =~ ^[[:space:]]*FILE[[:space:]]+\"([^\"]+)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  value="$(cue_extract_line_value "$value" "FILE" || true)"
  if [[ "$value" =~ ^(.+)[[:space:]]+[[:alnum:]_]+$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  value="$(cue_trim_whitespace "$value")"
  printf '%s' "$value"
}

# === PARSE CUE: GLOBAL METADATA ===
ALBUM=""
DATE=""
GENRE=""
GLOBAL_ARTIST=""
DATE_FROM_CUE=""
YEAR_FROM_CUE=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*TRACK[[:space:]]+ ]] && break

  if [[ -z "$ALBUM" && "$line" =~ ^TITLE[[:space:]]+ ]]; then
    ALBUM="$(cue_extract_line_value "$line" "TITLE" || true)"
  elif [[ -z "$GLOBAL_ARTIST" && "$line" =~ ^PERFORMER[[:space:]]+ ]]; then
    GLOBAL_ARTIST="$(cue_extract_line_value "$line" "PERFORMER" || true)"
  elif [[ -z "$GENRE" && "$line" =~ ^REM[[:space:]]+GENRE[[:space:]]+ ]]; then
    GENRE="$(cue_extract_line_value "$line" "REM GENRE" || true)"
  elif [[ -z "$DATE_FROM_CUE" && "$line" =~ ^REM[[:space:]]+DATE[[:space:]]+ ]]; then
    DATE_FROM_CUE="$(cue_extract_line_value "$line" "REM DATE" || true)"
  elif [[ -z "$YEAR_FROM_CUE" && "$line" =~ ^REM[[:space:]]+YEAR[[:space:]]+ ]]; then
    YEAR_FROM_CUE="$(cue_extract_line_value "$line" "REM YEAR" || true)"
  fi
done <"$CUE_FILE"
DATE="${DATE_FROM_CUE:-$YEAR_FROM_CUE}"

# Extract 4-digit year from DATE (handles YYYY or YYYY-MM-DD)
YEAR=""
if [[ "$DATE" =~ ^([0-9]{4}) ]]; then
  YEAR="${BASH_REMATCH[1]}"
elif [[ "$YEAR_FROM_CUE" =~ ^([0-9]{4}) ]]; then
  YEAR="${BASH_REMATCH[1]}"
else
  YEAR="YYYY"
fi

# === PARSE CUE: PER-TRACK METADATA + FILE ASSOCIATIONS ===
# TRACK_FILE_KEY[t]        = basename of the FILE directive that owns this track
# TRACK_IS_LAST_IN_FILE[t] = 1 if this track is the last one in its FILE block (no -t on extract)
declare -a TITLES=()
declare -a PERFORMERS=()
declare -a INDEXES=()
declare -a TRACK_FILE_KEY=()
declare -a TRACK_IS_LAST_IN_FILE=()
# Ordered list of unique FILE basenames as they appear in the CUE (for pre-convert ordering)
declare -a CUE_FILE_KEYS=()
TOTAL_TRACKS=0

_current_file_key=""
current_track=0
in_track=0
_prev_track_in_file=0  # track number of the last track seen for the current FILE block
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ ^[[:space:]]*FILE[[:space:]]+ ]]; then
    # Mark the previous track (last in its file block) before switching files
    if ((_prev_track_in_file > 0)); then
      TRACK_IS_LAST_IN_FILE[$_prev_track_in_file]=1
    fi
    _current_file_key="$(cue_extract_file_key "$line")"
    # Record unique file keys in order
    local_found=0
    for _k in "${CUE_FILE_KEYS[@]+"${CUE_FILE_KEYS[@]}"}"; do
      [[ "$_k" == "$_current_file_key" ]] && { local_found=1; break; }
    done
    ((local_found == 0)) && CUE_FILE_KEYS+=("$_current_file_key")
    in_track=0
    _prev_track_in_file=0
  elif [[ "$line" =~ ^[[:space:]]*TRACK[[:space:]]+([0-9]+) ]]; then
    current_track="$((10#${BASH_REMATCH[1]}))"
    in_track=1
    TOTAL_TRACKS=$((current_track > TOTAL_TRACKS ? current_track : TOTAL_TRACKS))
    TRACK_FILE_KEY[$current_track]="${_current_file_key}"
    TRACK_IS_LAST_IN_FILE[$current_track]=0
    _prev_track_in_file=$current_track
  elif ((in_track == 1)) && [[ "$line" =~ ^[[:space:]]*TITLE[[:space:]] ]]; then
    title="$(cue_extract_line_value "$line" "TITLE" || true)"
    TITLES[$current_track]="$title"
  elif ((in_track == 1)) && [[ "$line" =~ ^[[:space:]]*PERFORMER[[:space:]] ]]; then
    performer="$(cue_extract_line_value "$line" "PERFORMER" || true)"
    PERFORMERS[$current_track]="$performer"
  elif ((in_track == 1)) && [[ "$line" =~ ^[[:space:]]*[Ii][Nn][Dd][Ee][Xx][[:space:]]+([0-9]{1,2})[[:space:]]+([0-9]{1,3}:[0-9]{2}:[0-9]{2}) ]]; then
    _idx_num="$((10#${BASH_REMATCH[1]}))"
    if ((_idx_num == 1)); then
      INDEXES[$current_track]="${BASH_REMATCH[2]}"
    fi
  fi
done <"$CUE_FILE"
# Mark the very last track as last-in-file
if ((_prev_track_in_file > 0)); then
  TRACK_IS_LAST_IN_FILE[$_prev_track_in_file]=1
fi

if ((TOTAL_TRACKS == 0)); then
  echo "Error: no TRACK entries found in '$CUE_FILE'." >&2
  exit 1
fi

if ((${#CUE_FILE_KEYS[@]} == 0)); then
  echo "Error: no FILE directives found in '$CUE_FILE'." >&2
  exit 1
fi

# === RESOLVE + VALIDATE SOURCE AUDIO FILES ===
# Map each CUE FILE key (basename) to its full path on disk.
declare -A CUE_FILE_PATHS=()
for _key in "${CUE_FILE_KEYS[@]}"; do
  _candidate="$(cue_resolve_source_file "$SOURCE_DIR" "$_key" || true)"
  if [[ -z "$_candidate" || ! -f "$_candidate" ]]; then
    echo "Error: audio file referenced in CUE not found: '$_key' (looked in '$SOURCE_DIR')" >&2
    exit 1
  fi
  CUE_FILE_PATHS["$_key"]="$_candidate"
done

# AUDIO_SOURCE = first file referenced (used for ext detection, probe, upscale check)
AUDIO_SOURCE="${CUE_FILE_PATHS[${CUE_FILE_KEYS[0]}]}"
AUDIO_EXT="${AUDIO_SOURCE##*.}"
AUDIO_EXT_LC="${AUDIO_EXT,,}"

# Validate all files exist (already done above) and warn if multiple files present
if ((${#CUE_FILE_KEYS[@]} > 1)); then
  printf 'Multi-file CUE sheet: %s source file(s) referenced.\n' "${#CUE_FILE_KEYS[@]}"
  for _k in "${CUE_FILE_KEYS[@]}"; do
    printf '  %s\n' "${CUE_FILE_PATHS[$_k]}"
  done
fi

CHECK_UPSCALE_TARGET_SR_HZ=""
CHECK_UPSCALE_TARGET_BITS=""
CHECK_UPSCALE_CUTOFF_KHZ=""

run_check_upscale_analysis() {
  local _analyze_dir _analyze_count _an_src _an_stage _an_json _an_lines _an_sr_hz _an_bits _an_cutoff_khz
  local _analyze_cmd=("$AUDLINT_ANALYZE_BIN")

  [[ -x "$AUDLINT_ANALYZE_BIN" ]] || {
    echo "Error: --check-upscale requires audlint-analyze.sh alongside cue2flac.sh (not executable: $AUDLINT_ANALYZE_BIN)." >&2
    exit 2
  }

  echo "Running audlint-analyze spectral target detection..."
  _analyze_dir="$_TMPDIR/check_upscale_analyze"
  rm -rf "$_analyze_dir"
  mkdir -p "$_analyze_dir"
  _analyze_count=0
  for _key in "${CUE_FILE_KEYS[@]}"; do
    _an_src="${CUE_FILE_PATHS[$_key]}"
    [[ -n "$_an_src" && -e "$_an_src" ]] || continue
    _an_stage="$(printf '%s/%02d_%s' "$_analyze_dir" "$((_analyze_count + 1))" "$(basename "$_an_src")")"
    if ! ln -s "$_an_src" "$_an_stage" 2>/dev/null; then
      echo "Error: failed to stage source for --check-upscale: $_an_src" >&2
      exit 1
    fi
    _analyze_count=$((_analyze_count + 1))
  done
  if ((_analyze_count == 0)); then
    echo "Error: no source files available for --check-upscale analysis." >&2
    exit 1
  fi

  _analyze_cmd+=(--json "$_analyze_dir")
  _an_json="$("${_analyze_cmd[@]}" </dev/null || true)"
  _an_lines="$(
    python3 - "$_an_json" <<'PY' 2>/dev/null || true
import json, sys
raw = sys.argv[1].strip()
if not raw:
    raise SystemExit(0)
data = json.loads(raw)
album_sr = data.get("album_sr")
album_bits = data.get("album_bits")
tracks = data.get("tracks") or []
cutoff_hz = None
for track in tracks:
    value = track.get("cutoff_hz")
    if value is None:
        continue
    value = float(value)
    if cutoff_hz is None or value > cutoff_hz:
        cutoff_hz = value
print("" if album_sr is None else int(album_sr))
print("" if album_bits is None else int(album_bits))
if cutoff_hz is None:
    print("")
else:
    print(f"{float(cutoff_hz)/1000.0:.2f}")
PY
  )"
  { IFS= read -r _an_sr_hz; IFS= read -r _an_bits; IFS= read -r _an_cutoff_khz; } <<< "$_an_lines"

  if [[ ! "$_an_sr_hz" =~ ^[0-9]+$ || ! "$_an_bits" =~ ^[0-9]+$ ]]; then
    echo "Error: audlint-analyze did not return a usable target profile for --check-upscale." >&2
    exit 1
  fi

  CHECK_UPSCALE_TARGET_SR_HZ="$_an_sr_hz"
  CHECK_UPSCALE_TARGET_BITS="$_an_bits"
  CHECK_UPSCALE_CUTOFF_KHZ="$_an_cutoff_khz"
}

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
  idx="${INDEXES[$t]:-}"
  if [[ -z "$idx" ]]; then
    echo "Error: missing INDEX 01 time for track $t in '$CUE_FILE'." >&2
    echo "       cue2flac requires INDEX 01 for every track to split safely." >&2
    exit 1
  fi
  TRACK_START_SEC[$t]="$(cue_index_to_seconds "$idx")"
done

# Validate per-file start times are strictly increasing, otherwise splitting can
# produce negative durations and merged/garbled output.
declare -A _prev_start_by_file=()
declare -A _prev_track_by_file=()
for t in $(seq 1 "$TOTAL_TRACKS"); do
  _track_key="${TRACK_FILE_KEY[$t]:-${CUE_FILE_KEYS[0]}}"
  _cur_start="${TRACK_START_SEC[$t]}"
  _prev_start="${_prev_start_by_file[$_track_key]:-}"
  if [[ -n "$_prev_start" ]]; then
    _is_increasing="$(awk -v cur="$_cur_start" -v prev="$_prev_start" 'BEGIN{if ((cur+0) > (prev+0)) print 1; else print 0}')"
    if [[ "$_is_increasing" != "1" ]]; then
      _prev_track="${_prev_track_by_file[$_track_key]}"
      echo "Error: non-increasing INDEX 01 timeline in '$CUE_FILE' for file '$_track_key'." >&2
      echo "       track $_prev_track (${INDEXES[$_prev_track]}) -> track $t (${INDEXES[$t]})." >&2
      echo "       Fix the CUE track INDEX values and retry." >&2
      exit 1
    fi
  fi
  _prev_start_by_file[$_track_key]="$_cur_start"
  _prev_track_by_file[$_track_key]="$t"
done
unset _prev_start_by_file _prev_track_by_file _track_key _cur_start _prev_start _is_increasing _prev_track _idx_num

# === SANITIZE PATH COMPONENT ===
sanitize_path_component() {
  local raw="$1"
  printf '%s' "$raw" | tr -d '\000-\037' | sed 's|/|_|g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

# === OUTPUT DIRECTORY ===
OUTPUT_ROOT="${OUTPUT_ROOT_ARG:-${AUDL_CUE2FLAC_OUTPUT_DIR:-$HOME/Downloads/Encoded}}"
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
  local normalized bits_part
  normalized="$(profile_normalize "$raw" || true)"
  [[ -n "$normalized" ]] || return 1
  bits_part="${normalized#*/}"
  case "$bits_part" in
  16 | 24 | 32) ;;
  *) return 1 ;;
  esac
  PARSED_SR_HZ="${normalized%%/*}"
  PARSED_BITS="$bits_part"
}

PARSED_SR_HZ=0
PARSED_BITS=0
profile_to_parse="${TARGET_PROFILE:-$DEFAULT_PROFILE}"
if ! parse_profile "$profile_to_parse"; then
  echo "Error: invalid profile '$profile_to_parse' (run --help-profiles for accepted forms)." >&2
  exit 2
fi
TARGET_SR_HZ="$PARSED_SR_HZ"
TARGET_BITS="$PARSED_BITS"

if ((CHECK_UPSCALE == 1)); then
  run_check_upscale_analysis
  TARGET_SR_HZ="$CHECK_UPSCALE_TARGET_SR_HZ"
  TARGET_BITS="$CHECK_UPSCALE_TARGET_BITS"
fi

# === PRE-CONVERT OPAQUE SOURCES ===
# sox cannot read WV/APE/DSF/DFF — convert each unique source file to a temp WAV.
# WORK_SOURCE_MAP: maps CUE FILE key → work path (original or converted WAV)
declare -A WORK_SOURCE_MAP=()
NEEDS_PRECONVERT=0
case "$AUDIO_EXT_LC" in
wv | ape | dsf | dff) NEEDS_PRECONVERT=1 ;;
esac

_dsd_target_sr=0
_dsd_target_bits=0

for _key in "${CUE_FILE_KEYS[@]}"; do
  _src="${CUE_FILE_PATHS[$_key]}"
  if ((NEEDS_PRECONVERT == 0)); then
    WORK_SOURCE_MAP["$_key"]="$_src"
    continue
  fi

  _safe_key="$(printf '%s' "$_key" | tr -cs 'a-zA-Z0-9._-' '_')"
  _work_wav="$_TMPDIR/preconv_${_safe_key}.wav"
  echo "Pre-converting '$(basename "$_src")' to temporary PCM WAV..."

  if [[ "$AUDIO_EXT_LC" == "dsf" || "$AUDIO_EXT_LC" == "dff" ]]; then
    if ((_dsd_target_sr == 0)); then
      if ((CHECK_UPSCALE == 1)) && [[ "$CHECK_UPSCALE_TARGET_SR_HZ" =~ ^[0-9]+$ && "$CHECK_UPSCALE_TARGET_BITS" =~ ^[0-9]+$ ]]; then
        _dsd_target_sr="$CHECK_UPSCALE_TARGET_SR_HZ"
        _dsd_target_bits="$CHECK_UPSCALE_TARGET_BITS"
      else
        _src_sr_hz="$(audio_probe_sample_rate_hz "$_src")"
        _dsd_profile="$(audio_dsd_max_pcm_profile "$_src_sr_hz")"
        _dsd_target_sr="${_dsd_profile%%|*}"
        _dsd_target_bits_rest="${_dsd_profile#*|}"
        _dsd_target_bits="${_dsd_target_bits_rest%%|*}"
      fi
      if ((_dsd_target_sr < TARGET_SR_HZ)); then
        TARGET_SR_HZ="$_dsd_target_sr"
      fi
      if ((_dsd_target_bits < TARGET_BITS)); then
        TARGET_BITS="$_dsd_target_bits"
      fi
    fi
    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$_src" \
      -vn -c:a pcm_s32 -ar "$_dsd_target_sr" \
      "$_work_wav" </dev/null
  else
    _wvape_bits="$(audio_probe_bit_depth_bits "$_src" || true)"
    if [[ ! "$_wvape_bits" =~ ^[0-9]+$ ]] || ((_wvape_bits <= 0)); then
      _wvape_bits=24
    fi
    if   ((_wvape_bits <= 16)); then _preconv_codec="pcm_s16le"
    elif ((_wvape_bits <= 24)); then _preconv_codec="pcm_s24le"
    else                             _preconv_codec="pcm_s32le"
    fi
    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$_src" \
      -vn -c:a "$_preconv_codec" \
      "$_work_wav" </dev/null
  fi
  echo "   Pre-convert complete: $(basename "$_work_wav")"
  WORK_SOURCE_MAP["$_key"]="$_work_wav"
done

# WORK_SOURCE = work path of the first file (used for source display, true peak,
# and per-track extraction)
WORK_SOURCE="${WORK_SOURCE_MAP[${CUE_FILE_KEYS[0]}]}"

# === PROBE SOURCE SR AND BIT DEPTH (cap target to source) ===
SRC_SR_HZ="$(audio_probe_sample_rate_hz "$WORK_SOURCE")"
SRC_BITS="$(audio_probe_bit_depth_bits "$WORK_SOURCE" || true)"
if [[ ! "$SRC_BITS" =~ ^[0-9]+$ ]] || ((SRC_BITS <= 0)); then
  SRC_BITS=24
fi

# No upscale: cap target SR and bits to the lowest referenced source profile.
CAP_SR_HZ="$SRC_SR_HZ"
CAP_BITS="$SRC_BITS"
for _key in "${CUE_FILE_KEYS[@]}"; do
  _cap_src="${WORK_SOURCE_MAP[$_key]}"
  [[ -n "$_cap_src" ]] || continue

  _cap_sr_hz="$(audio_probe_sample_rate_hz "$_cap_src")"
  if [[ "$_cap_sr_hz" =~ ^[0-9]+$ ]] && (( _cap_sr_hz > 0 )); then
    if [[ ! "$CAP_SR_HZ" =~ ^[0-9]+$ ]] || ((CAP_SR_HZ <= 0)) || (( _cap_sr_hz < CAP_SR_HZ )); then
      CAP_SR_HZ="$_cap_sr_hz"
    fi
  fi

  _cap_bits="$(audio_probe_bit_depth_bits "$_cap_src" || true)"
  if [[ ! "$_cap_bits" =~ ^[0-9]+$ ]] || (( _cap_bits <= 0 )); then
    _cap_bits=24
  fi
  if [[ ! "$CAP_BITS" =~ ^[0-9]+$ ]] || ((CAP_BITS <= 0)) || (( _cap_bits < CAP_BITS )); then
    CAP_BITS="$_cap_bits"
  fi
done

if [[ "$CAP_SR_HZ" =~ ^[0-9]+$ ]] && ((CAP_SR_HZ > 0)) && ((TARGET_SR_HZ > CAP_SR_HZ)); then
  TARGET_SR_HZ="$CAP_SR_HZ"
fi
if [[ "$CAP_BITS" =~ ^[0-9]+$ ]] && ((CAP_BITS > 0)) && ((TARGET_BITS > CAP_BITS)); then
  TARGET_BITS="$CAP_BITS"
fi

TARGET_PROFILE_LABEL="${TARGET_SR_HZ}/${TARGET_BITS}"

# === SPECTRAL UPSCALE CHECK ===
UPSCALE_CHECK_LABEL=""
if ((CHECK_UPSCALE == 1)); then
  if [[ "$CHECK_UPSCALE_TARGET_SR_HZ" =~ ^[0-9]+$ && "$CHECK_UPSCALE_TARGET_BITS" =~ ^[0-9]+$ ]]; then
    _check_sr="$CHECK_UPSCALE_TARGET_SR_HZ"
    _check_bits="$CHECK_UPSCALE_TARGET_BITS"
    if [[ "$CAP_SR_HZ" =~ ^[0-9]+$ ]] && ((CAP_SR_HZ > 0)) && ((_check_sr > CAP_SR_HZ)); then
      _check_sr="$CAP_SR_HZ"
    fi
    if [[ "$CAP_BITS" =~ ^[0-9]+$ ]] && ((CAP_BITS > 0)) && ((_check_bits > CAP_BITS)); then
      _check_bits="$CAP_BITS"
    fi
    TARGET_SR_HZ="$_check_sr"
    TARGET_BITS="$_check_bits"
    TARGET_PROFILE_LABEL="${TARGET_SR_HZ}/${TARGET_BITS}"
  fi

  if [[ "${CHECK_UPSCALE_CUTOFF_KHZ:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    UPSCALE_CHECK_LABEL="audlint-analyze max cutoff≈${CHECK_UPSCALE_CUTOFF_KHZ}kHz → Store as ${TARGET_PROFILE_LABEL}"
  else
    UPSCALE_CHECK_LABEL="audlint-analyze resolved target → Store as ${TARGET_PROFILE_LABEL}"
  fi
fi

# === TRUE PEAK / BOOST ===
echo "Probing true peak for album-wide headroom boost..."
TRUE_PEAK_DB="$(audio_probe_true_peak_db "$WORK_SOURCE")"
BOOST_GAIN_DB="0.000"
APPLY_BOOST=0
if audio_is_float_number "$TRUE_PEAK_DB"; then
  BOOST_GAIN_DB="$(awk -v m="$SAFETY_MARGIN_DB" -v p="$TRUE_PEAK_DB" 'BEGIN{printf "%.3f", m-p}')"
  if audio_float_abs_ge "$BOOST_GAIN_DB" "$MIN_APPLY_GAIN_DB"; then
    APPLY_BOOST=1
  fi
fi

# === PRINT PLAN ===
printf '\n'
printf '%sCUE file  :%s %s\n' "$DIM" "$RESET" "$CUE_FILE"
printf '%sSource    :%s %s (%s)\n' "$DIM" "$RESET" "$(ui_input_path_text "$(basename "$AUDIO_SOURCE")")" "$(ui_value_text "$AUDIO_EXT_LC")"
if ((${#CUE_FILE_KEYS[@]} > 1)); then
  printf '%sFiles     :%s %s file(s) in CUE sheet\n' "$DIM" "$RESET" "$(ui_value_text "${#CUE_FILE_KEYS[@]}")"
fi
printf '%sSource SR :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "${SRC_SR_HZ} Hz / ${SRC_BITS}-bit")"
printf '%sTarget    :%s %s (FLAC compression level 8)\n' "$DIM" "$RESET" "$(ui_value_text "$TARGET_PROFILE_LABEL")"
if ((CHECK_UPSCALE == 1)); then
  printf '%sCheck     :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$UPSCALE_CHECK_LABEL")"
fi
printf '%sEncoder   :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$(encoder_log_backend)")"
if ((APPLY_BOOST == 1)); then
  printf '%sBoost     :%s %s dB (true peak: %s)\n' \
    "$DIM" "$RESET" \
    "$(ui_gain_text "$(audio_db_gain_label "$BOOST_GAIN_DB" 3)")" \
    "$(ui_value_text "${TRUE_PEAK_DB} dBTP")"
else
  printf '%sBoost     :%s %s (true peak: %s, gain %s dB, abs < %s dB threshold)\n' \
    "$DIM" "$RESET" \
    "$(ui_warn_text "skipped")" \
    "$(ui_value_text "${TRUE_PEAK_DB} dBTP")" \
    "$(ui_gain_text "$(audio_db_gain_label "$BOOST_GAIN_DB" 3)")" \
    "$(ui_value_text "$MIN_APPLY_GAIN_DB")"
fi
printf '%sOutput    :%s %s\n' "$DIM" "$RESET" "$(ui_output_path_text "$OUTPUT_DIR")"
printf '\n%sTrack list:%s\n' "$DIM" "$RESET"
for t in $(seq 1 "$TOTAL_TRACKS"); do
  title="${TITLES[$t]:-Track $t}"
  artist="${PERFORMERS[$t]:-${GLOBAL_ARTIST:-}}"
  [[ -z "$artist" ]] && artist="${GLOBAL_ARTIST:-Unknown Artist}"
  idx="${INDEXES[$t]:-00:00:00}"
  out_name="$(printf '%02d' "$t") $(sanitize_path_component "$title").flac"
  printf '  [%02d] %s — %s  %s(INDEX %s)%s\n' "$t" "$title" "$artist" "$DIM" "$idx" "$RESET"
  printf '       %s %s\n' "$(ui_arrow_text)" "$(ui_output_path_text "$out_name")"
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
  printf '%sProceed?%s [y/N] > ' "$YELLOW" "$RESET"
  confirm_choice=""
  if ! tty_read_line confirm_choice; then
    echo "Cancelled." >&2
    exit 1
  fi
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
  date_display="${DATE:-[not set in CUE]}"
  out_name="$(printf '%02d' "$t") $(sanitize_path_component "$title").flac"
  out_path="$OUTPUT_DIR/$out_name"

  # Resolve work source for this track's file
  _track_key="${TRACK_FILE_KEY[$t]:-${CUE_FILE_KEYS[0]}}"
  _track_work_src="${WORK_SOURCE_MAP[$_track_key]}"

  printf '\n%s▶ [%02d/%02d] ENCODING%s %s\n' "$GREEN" "$t" "$TOTAL_TRACKS" "$RESET" "$(ui_output_path_text "$out_name")"
  printf '     %sTitle    :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$title")"
  printf '     %sArtist   :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$artist")"
  printf '     %sAlbum    :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "${ALBUM:-}")"
  printf '     %sDate     :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$date_display")"
  printf '     %sTrack    :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$t/$TOTAL_TRACKS")"
  printf '     %sStart    :%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$start_sec sec")"
  if ((APPLY_BOOST == 1)); then
    printf '     %sBoost    :%s %s dB\n' "$DIM" "$RESET" "$(ui_gain_text "$(audio_db_gain_label "$BOOST_GAIN_DB" 3)")"
  else
    printf '     %sBoost    :%s %s\n' "$DIM" "$RESET" "$(ui_warn_text "skipped")"
  fi

  # Duration: distance to next track within the same file, or EOF for the last track in the file.
  # NOTE: -ss/-t are placed AFTER -i (output-side seek) to avoid the ffmpeg atrim
  # nanosecond overflow bug that triggers "Value out of range" errors on large seek
  # positions (tracks late in long albums at high sample rates).
  split_args=(-ss "$start_sec")
  _is_last_in_file="${TRACK_IS_LAST_IN_FILE[$t]:-0}"
  if ((_is_last_in_file == 0)); then
    next_start="${TRACK_START_SEC[$((t + 1))]}"
    duration="$(awk -v e="$next_start" -v s="$start_sec" 'BEGIN{printf "%.6f", e-s}')"
    split_args+=(-t "$duration")
  fi

  tmp_seg="$_TMPDIR/track_$(printf '%02d' "$t").wav"

  # Extract segment via ffmpeg (output-side seek: -i first, then -ss/-t)
  if ! ffmpeg -hide_banner -loglevel error -nostdin -y \
    -i "$_track_work_src" \
    -vn "${split_args[@]}" -c:a "$SEG_PCM_CODEC" \
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
    printf '%s✅ Saved:%s %s\n' "$GREEN" "$RESET" "$(ui_output_path_text "$out_path")"
    ((ok_count += 1))
  else
    printf '%s❌ Encode failed: %s%s\n' "$RED" "$out_name" "$RESET" >&2
    ((fail_count += 1))
  fi

  rm -f "$tmp_seg"
done

printf '\n'
printf '%sDone:%s %s track(s) encoded, %s failed.\n' "$DIM" "$RESET" "$(ui_value_text "$ok_count")" "$(ui_value_text "$fail_count")"
printf '%sOutput:%s %s\n' "$DIM" "$RESET" "$(ui_output_path_text "$OUTPUT_DIR")"
printf '%sProfile:%s %s\n' "$DIM" "$RESET" "$(ui_value_text "$TARGET_PROFILE_LABEL")"
artwork_run_cover_album_postprocess "$OUTPUT_DIR" "$AUDLINT_COVER_ALBUM_BIN" "$DRY_RUN" || true

if ((fail_count > 0)); then
  exit 1
fi
