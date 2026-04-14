#!/usr/bin/env bash
# audlint-analyze — Spectral bandwidth analysis: determines the ideal recode
# target profile (SR/bits) for an album directory by inspecting actual source
# files via FFT-based frequency cutoff detection.
#
# Output (stdout):
#   On success: SR/bits e.g. "48000/24"
#   On no-recode-needed: "Re-encoding not needed" (exit 0)
#
# Cache:
#   Writes .sox_album_profile in the album dir after analysis.
#   Writes .sox_album_done when all files match the target (no-recode guard).
#
# Algorithm:
#   For each track, samples up to MAX_WINDOWS windows of WINDOW_SEC seconds,
#   computes FFT magnitude spectrum, and checks whether the source is a fake
#   upscale or simply above the project PCM ceiling. If either is true, the
#   analyzer resolves the underlying standard family (44100 or 48000) and
#   chooses the leanest lossless downgrade target within that family
#   (44.1/88.2/176.4 or 48/96/192) that preserves the detected music
#   bandwidth, capped at 176.4/24 or 192/24 by family.
#   Album target SR = max of per-track targets. Album bits = min(24, max_src_bits).
#
# Dependencies: sox (sox_ng recommended), soxi, python3 (with numpy)
# Optional:     ffprobe — used as duration fallback for containers where soxi
#               reports 0 duration (ALAC/AAC in M4A with older sox builds)

set -euo pipefail

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

SCRIPT_RULESET_BASE="v8"
HEADROOM_HZ="${AUDLINT_ANALYZE_HEADROOM_HZ:-500}"
THRESH_REL_DB="${AUDLINT_ANALYZE_THRESH_REL_DB:--55}"
WINDOW_SEC="${AUDLINT_ANALYZE_WINDOW_SEC:-8}"
MAX_WINDOWS="${AUDLINT_ANALYZE_MAX_WINDOWS:-12}"
FINGERPRINT_SAMPLE_BYTES="${AUDLINT_ANALYZE_FINGERPRINT_SAMPLE_BYTES:-65536}"
FINGERPRINT_MODE="meta+headtail-v1"

PYTHON_BIN="${AUDL_PYTHON_BIN:-python3}"
AUDLINT_ANALYZE_PY="${AUDLINT_ANALYZE_PY:-$SCRIPT_DIR/../lib/py/audlint_analyze.py}"

show_help() {
  cat <<'EOF'
Usage: audlint-analyze [--json] FILE_OR_ALBUM_DIR
       audlint-analyze [--exact] [--json] FILE_OR_ALBUM_DIR

Determine the ideal recode target profile (SR/bits) for an album directory by:
  1. checking for fake upscale or a source above the family PCM ceiling,
  2. resolving the underlying 44.1k / 48k family when a downgrade is needed,
  3. choosing the best downgrade target that preserves available music data,
     capped at 176.4/24 or 192/24 by family for higher-resolution sources.

Options:
  --exact:
    force a slower, deeper analysis pass with more windows and per-channel
    verification instead of using the default auto mode
  --json:
    emit JSON payload instead of SR/bits text

Default mode:
  audlint-analyze first runs the fast pass. If album confidence is low, it
  automatically reruns exact analysis and returns that result.

Output:
  default:
    SR/bits e.g. "48000/24"               — recode target
    "Re-encoding not needed"              — all files already match target
  --json:
    JSON payload with album target, fake-upscale verdict, family, and
    per-track spectral cutoff details

Cache files written into the album directory:
  .sox_album_profile   — RULESET/TARGET_SR/TARGET_BITS + fingerprint hashes
  .sox_album_done      — written when no recode is needed

Environment overrides:
  AUDLINT_ANALYZE_HEADROOM_HZ    Hz of headroom below spectral cutoff (default: 500)
  AUDLINT_ANALYZE_THRESH_REL_DB  dB threshold relative to spectral peak (default: -55)
  AUDLINT_ANALYZE_WINDOW_SEC     analysis window length in seconds (default: 8)
  AUDLINT_ANALYZE_MAX_WINDOWS    maximum analysis windows per track (default: 12)
  AUDLINT_ANALYZE_FINGERPRINT_SAMPLE_BYTES
                                bytes sampled from file head+tail for content hash
                                (default: 65536)
  AUDLINT_ANALYZE_DECODE_TIMEOUT_SEC
                                per-window decoder timeout before fallback
                                (default: max(20, WINDOW_SEC*4))

Dependencies: sox (sox_ng recommended), soxi, python3 (with numpy)
Optional:     ffprobe — duration fallback for ALAC/AAC-in-M4A containers
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

if [[ $# -eq 1 && ("${1:-}" == "-h" || "${1:-}" == "--help") ]]; then
  show_help
  exit 0
fi

OUTPUT_MODE="profile"
REQUESTED_ANALYSIS_MODE="auto"
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  --json)
    OUTPUT_MODE="json"
    shift
    ;;
  --exact)
    REQUESTED_ANALYSIS_MODE="exact"
    shift
    ;;
  *)
    break
    ;;
  esac
done

[[ $# -eq 1 ]] || { show_help >&2; exit 2; }
SCRIPT_RULESET="${SCRIPT_RULESET_BASE}-${REQUESTED_ANALYSIS_MODE}"

if ! have "$PYTHON_BIN"; then
  echo "Missing dep: python3" >&2
  exit 1
fi
if [[ ! -f "$AUDLINT_ANALYZE_PY" ]]; then
  echo "Missing helper: $AUDLINT_ANALYZE_PY" >&2
  exit 1
fi
if ! { have sox && have soxi; } && ! have ffmpeg; then
  echo "Missing deps: require sox+soxi or ffmpeg for audio decode" >&2
  exit 1
fi

IN="$1"
if [[ -d "$IN" ]]; then
  ALBUM_DIR="$(cd "$IN" && pwd)"
else
  [[ -f "$IN" ]] || { echo "Not found: $IN" >&2; exit 1; }
  ALBUM_DIR="$(cd "$(dirname "$IN")" && pwd)"
fi

PROFILE_FILE="$ALBUM_DIR/.sox_album_profile"
DONE_FILE="$ALBUM_DIR/.sox_album_done"

warn_cache_write_failure() {
  local target="$1"
  printf 'Warning: could not update analyzer cache: %s\n' "$target" >&2
}

write_profile_cache_file() {
  local tmp_profile
  tmp_profile="$(mktemp -t audlint_profile.XXXXXX)" || return 1
  cat >"$tmp_profile" <<EOF
RULESET=$SCRIPT_RULESET
REQUESTED_ANALYSIS_MODE=$REQUESTED_ANALYSIS_MODE_EFFECTIVE
ANALYSIS_MODE=$ANALYSIS_MODE
AUTO_EXACT_FALLBACK=$AUTO_EXACT_FALLBACK
ALBUM_CONFIDENCE=$ALBUM_CONFIDENCE
TARGET_SR=$TARGET_SR
TARGET_BITS=$TARGET_BITS
ALBUM_FAKE_UPSCALE=$ALBUM_FAKE_UPSCALE
ALBUM_HAS_FAKE_UPSCALE_TRACKS=$ALBUM_HAS_FAKE_UPSCALE_TRACKS
ALBUM_FAMILY_SR=$ALBUM_FAMILY_SR
ALBUM_DECISION=$ALBUM_DECISION
SOURCE_FINGERPRINT=$CURRENT_SOURCE_FINGERPRINT
CONFIG_FINGERPRINT=$CURRENT_CONFIG_FINGERPRINT
FINGERPRINT_MODE=$FINGERPRINT_MODE
EOF
  if ! mv -f "$tmp_profile" "$PROFILE_FILE" 2>/dev/null; then
    rm -f "$tmp_profile"
    return 1
  fi
  return 0
}

update_done_marker_file() {
  if album_matches_target_profile "$TARGET_SR" "$TARGET_BITS"; then
    { : >"$DONE_FILE"; } 2>/dev/null || return 1
  else
    rm -f "$DONE_FILE" 2>/dev/null || return 1
  fi
  return 0
}

compute_source_fingerprint() {
  "$PYTHON_BIN" "$AUDLINT_ANALYZE_PY" source-fingerprint "$ALBUM_DIR" "$FINGERPRINT_SAMPLE_BYTES" "${FILES[@]}"
}

compute_config_fingerprint() {
  "$PYTHON_BIN" "$AUDLINT_ANALYZE_PY" config-fingerprint "$SCRIPT_RULESET" "$HEADROOM_HZ" "$THRESH_REL_DB" "$WINDOW_SEC" "$MAX_WINDOWS" "$FINGERPRINT_SAMPLE_BYTES" "$FINGERPRINT_MODE"
}

album_matches_target_profile() {
  local target_sr="$1"
  local target_bits="$2"
  local f sr bits
  for f in "${FILES[@]}"; do
    sr="$(audio_probe_sample_rate_hz "$f")"
    bits="$(audio_probe_bit_depth_bits "$f")"
    [[ "$sr" =~ ^[0-9]+$ && "$bits" =~ ^[0-9]+$ ]] || return 1
    [[ "$sr" == "$target_sr" ]] || return 1
    (( bits >= target_bits )) || return 1
  done
  return 0
}

# collect audio files (non-recursive)
mapfile -t FILES < <(
  # shellcheck disable=SC2046
  find "$ALBUM_DIR" -maxdepth 1 \( -type f -o -type l \) \( $(audio_find_iname_args) \) -print | sort
)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No audio files found in: $ALBUM_DIR" >&2
  exit 1
fi

CURRENT_SOURCE_FINGERPRINT="$(compute_source_fingerprint)"
CURRENT_CONFIG_FINGERPRINT="$(compute_config_fingerprint)"

# If already profiled and marked done, verify and short-circuit.
# JSON mode always performs a fresh analysis because callers expect per-track details.
if [[ "$OUTPUT_MODE" != "json" && -f "$PROFILE_FILE" && -f "$DONE_FILE" ]]; then
  PROFILE_RULESET="$(profile_cache_get "$PROFILE_FILE" RULESET)"
  PROFILE_TARGET_SR="$(profile_cache_get "$PROFILE_FILE" TARGET_SR)"
  PROFILE_TARGET_BITS="$(profile_cache_get "$PROFILE_FILE" TARGET_BITS)"
  PROFILE_SOURCE_FINGERPRINT="$(profile_cache_get "$PROFILE_FILE" SOURCE_FINGERPRINT)"
  PROFILE_CONFIG_FINGERPRINT="$(profile_cache_get "$PROFILE_FILE" CONFIG_FINGERPRINT)"
  PROFILE_FINGERPRINT_MODE="$(profile_cache_get "$PROFILE_FILE" FINGERPRINT_MODE)"

  if [[ "$PROFILE_RULESET" == "$SCRIPT_RULESET" \
    && -n "$PROFILE_TARGET_SR" \
    && -n "$PROFILE_TARGET_BITS" \
    && -n "$PROFILE_SOURCE_FINGERPRINT" \
    && -n "$PROFILE_CONFIG_FINGERPRINT" \
    && "$PROFILE_FINGERPRINT_MODE" == "$FINGERPRINT_MODE" \
    && "$PROFILE_SOURCE_FINGERPRINT" == "$CURRENT_SOURCE_FINGERPRINT" \
    && "$PROFILE_CONFIG_FINGERPRINT" == "$CURRENT_CONFIG_FINGERPRINT" ]]; then
    echo "Re-encoding not needed"
    exit 0
  fi
fi

# Analyse all tracks → choose album target.
tmpjson="$(mktemp -t sox_analyze.XXXXXX)"

if ! "$PYTHON_BIN" "$AUDLINT_ANALYZE_PY" analyze "$HEADROOM_HZ" "$THRESH_REL_DB" "$WINDOW_SEC" "$MAX_WINDOWS" "$REQUESTED_ANALYSIS_MODE" "${FILES[@]}" >"$tmpjson"; then
  echo "Analysis failed." >&2
  rm -f "$tmpjson"
  exit 1
fi

if ! grep -q '"album_sr"' "$tmpjson"; then
  echo "Analysis failed." >&2
  rm -f "$tmpjson"
  exit 1
fi

TARGET_SR="$("$PYTHON_BIN" -c 'import json;print(json.load(open("'"$tmpjson"'"))["album_sr"])')"
TARGET_BITS="$("$PYTHON_BIN" -c 'import json;print(json.load(open("'"$tmpjson"'"))["album_bits"])')"
ANALYZE_SUMMARY="$("$PYTHON_BIN" - "$tmpjson" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
family = payload.get("album_family_sr")
print(payload.get("requested_analysis_mode", "auto"))
print(payload.get("analysis_mode", "fast"))
print("1" if payload.get("auto_exact_fallback") else "0")
print(payload.get("album_confidence", "low"))
print("1" if payload.get("album_fake_upscale") else "0")
print("1" if payload.get("album_has_fake_upscale_tracks") else "0")
print("" if family is None else str(family))
print(payload.get("album_decision", "keep_source"))
PY
)"
{
  IFS= read -r REQUESTED_ANALYSIS_MODE_EFFECTIVE
  IFS= read -r ANALYSIS_MODE
  IFS= read -r AUTO_EXACT_FALLBACK
  IFS= read -r ALBUM_CONFIDENCE
  IFS= read -r ALBUM_FAKE_UPSCALE
  IFS= read -r ALBUM_HAS_FAKE_UPSCALE_TRACKS
  IFS= read -r ALBUM_FAMILY_SR
  IFS= read -r ALBUM_DECISION
} <<< "$ANALYZE_SUMMARY"

if [[ "$AUTO_EXACT_FALLBACK" == "1" ]]; then
  echo "Got low confidence in fast test, running exact mode..." >&2
fi

if ! write_profile_cache_file; then
  warn_cache_write_failure "$PROFILE_FILE"
fi

if ! update_done_marker_file; then
  warn_cache_write_failure "$DONE_FILE"
fi

if [[ "$OUTPUT_MODE" == "json" ]]; then
  cat "$tmpjson"
  rm -f "$tmpjson"
  exit 0
fi

rm -f "$tmpjson"
echo "${TARGET_SR}/${TARGET_BITS}"
