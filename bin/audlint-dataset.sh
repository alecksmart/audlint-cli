#!/usr/bin/env bash
# audlint-dataset.sh - build a trusted-vs-fake analyzer validation dataset.

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
source "$BOOTSTRAP_DIR/../lib/sh/profile.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/encoder.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path

FORCE=0
DATASET_DIR=""
ALBUM_DIR=""
TRUSTED_PROFILE=""
TRUSTED_SR_HZ=0
TRUSTED_BITS=0
TRUSTED_LABEL=""
TMP_WORK_DIR=""
declare -a RESULT_FILES=()

show_help() {
  cat <<'EOF_HELP'
Usage:
  audlint-dataset.sh [--force] <dataset_dir> <album_dir> <trusted_profile>

Build a validation dataset from trusted WAV album sources.

Arguments:
  <dataset_dir>      dataset root to create/update
  <album_dir>        directory containing trusted WAV files
  <trusted_profile>  exact ground-truth profile, e.g. 44100/16, 96000/24

Options:
  --force            overwrite generated outputs instead of skipping them
  --help             show this help

Environment:
  AUDLINT_DATASET_JOBS   max concurrent ffmpeg jobs (default: min(cpu,4))
EOF_HELP
  printf '\n'
  profile_print_supported_targets
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

log_line() {
  printf '%s\n' "$1"
}

cleanup() {
  if [[ -n "$TMP_WORK_DIR" && -d "$TMP_WORK_DIR" ]]; then
    rm -rf "$TMP_WORK_DIR"
  fi
}

trap cleanup EXIT INT TERM

prepare_dataset_dirs() {
  local -a base_real_dirs=(
    "44100_16"
    "48000_24"
    "96000_24"
    "192000_24"
  )
  local -a fake_dirs=(
    "mp3_128_upscaled"
    "mp3_192_upscaled"
    "mp3_320_upscaled"
    "aac_128_upscaled"
    "aac_256_upscaled"
    "opus_96_upscaled"
    "opus_160_upscaled"
  )
  local -a edge_dirs=(
    "lowpass_mastering"
    "vinyl_rips"
    "noisy_live"
  )
  local dir

  mkdir -p "$DATASET_DIR/real" "$DATASET_DIR/fake" "$DATASET_DIR/edge_cases"
  for dir in "${base_real_dirs[@]}"; do
    mkdir -p "$DATASET_DIR/real/$dir"
  done
  mkdir -p "$DATASET_DIR/real/$TRUSTED_LABEL"
  for dir in "${fake_dirs[@]}"; do
    mkdir -p "$DATASET_DIR/fake/$dir"
  done
  for dir in "${edge_dirs[@]}"; do
    mkdir -p "$DATASET_DIR/edge_cases/$dir"
  done
}

collect_wav_files() {
  local dir="$1"
  local out_var="${2:-WAV_FILES}"
  # shellcheck disable=SC2178
  local -n out_ref="$out_var"
  local had_nullglob=0
  local had_nocaseglob=0
  local path

  shopt -q nullglob && had_nullglob=1
  shopt -q nocaseglob && had_nocaseglob=1
  shopt -s nullglob nocaseglob

  out_ref=()
  for path in "$dir"/*.wav; do
    [[ -f "$path" || -L "$path" ]] || continue
    out_ref+=("$path")
  done

  ((had_nullglob == 1)) || shopt -u nullglob
  ((had_nocaseglob == 1)) || shopt -u nocaseglob
}

is_lower_profile_than_trusted() {
  local profile="$1"
  local sr_hz="${profile%%/*}"
  local bits="${profile#*/}"

  [[ "$sr_hz" =~ ^[0-9]+$ && "$bits" =~ ^[0-9]+$ ]] || return 1
  if ((sr_hz < TRUSTED_SR_HZ)); then
    return 0
  fi
  if ((sr_hz == TRUSTED_SR_HZ && bits < TRUSTED_BITS)); then
    return 0
  fi
  return 1
}

copy_real_wav() {
  local src="$1"
  local dst=""
  dst="$DATASET_DIR/real/$TRUSTED_LABEL/$(basename "$src")"
  if [[ -e "$dst" && "$FORCE" -eq 0 ]]; then
    log_line "[SKIP] real copy exists $(basename "$dst")"
    return 0
  fi
  log_line "[REAL] copying $(basename "$src") -> real/$TRUSTED_LABEL/"
  cp -fp "$src" "$dst"
}

ffmpeg_encode_lossy() {
  local src="$1"
  local codec="$2"
  local bitrate_kbps="$3"
  local dst="$4"
  local channels="$5"
  local -a mix_args=()

  if [[ "$channels" =~ ^[0-9]+$ ]] && ((channels > 2)); then
    mix_args=(-ac 2)
  fi

  case "$codec" in
  mp3)
    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$src" \
      -map 0:a:0 \
      -map_metadata 0 \
      "${mix_args[@]}" \
      -c:a libmp3lame \
      -b:a "${bitrate_kbps}k" \
      "$dst" </dev/null
    ;;
  aac)
    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$src" \
      -map 0:a:0 \
      -map_metadata 0 \
      "${mix_args[@]}" \
      -c:a aac \
      -b:a "${bitrate_kbps}k" \
      -f ipod \
      "$dst" </dev/null
    ;;
  opus)
    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$src" \
      -map 0:a:0 \
      -map_metadata 0 \
      "${mix_args[@]}" \
      -c:a libopus \
      -b:a "${bitrate_kbps}k" \
      -vbr on \
      "$dst" </dev/null
    ;;
  *)
    return 1
    ;;
  esac
}

ffmpeg_render_flac() {
  local src="$1"
  local dst="$2"
  local sr_hz="$3"
  local bits="$4"
  local channels="$5"
  local -a render_args=(
    --in "$src"
    --out "$dst"
    --sr "$sr_hz"
    --bits "$bits"
  )

  if [[ "$channels" =~ ^[0-9]+$ ]] && ((channels > 2)); then
    render_args+=(--channels 2)
  fi

  encoder_render_flac_ffmpeg "${render_args[@]}"
}

generate_job_worker() {
  local task_id="$1"
  local mode="$2"
  local src="$3"
  local dst="$4"
  local codec="$5"
  local bitrate_kbps="$6"
  local out_sr_hz="$7"
  local out_bits="$8"
  local channels="$9"
  local result_file="${10}"
  local job_dir tmp_lossy lossy_ext tmp_out

  job_dir="$TMP_WORK_DIR/job_$task_id"
  mkdir -p "$job_dir"
  tmp_out="$job_dir/out.flac"

  if [[ "$mode" == "clean_real" ]]; then
    if ! ffmpeg_render_flac "$src" "$tmp_out" "$out_sr_hz" "$out_bits" "$channels"; then
      printf 'ERR\tffmpeg clean-real failed for %s\n' "$dst" >"$result_file"
      return 0
    fi
  else
    case "$codec" in
    mp3) lossy_ext="mp3" ;;
    aac) lossy_ext="m4a" ;;
    opus) lossy_ext="opus" ;;
    *) printf 'ERR\tunknown fake codec for %s\n' "$dst" >"$result_file"; return 0 ;;
    esac

    tmp_lossy="$job_dir/input.$lossy_ext"
    if ! ffmpeg_encode_lossy "$src" "$codec" "$bitrate_kbps" "$tmp_lossy" "$channels"; then
      printf 'ERR\tffmpeg lossy encode failed for %s\n' "$dst" >"$result_file"
      return 0
    fi
    if ! ffmpeg_render_flac "$tmp_lossy" "$tmp_out" "$out_sr_hz" "$out_bits" "$channels"; then
      printf 'ERR\tffmpeg fake upscale render failed for %s\n' "$dst" >"$result_file"
      return 0
    fi
  fi

  mkdir -p "$(dirname "$dst")"
  mv -f "$tmp_out" "$dst"
  printf 'OK\t%s\n' "$dst" >"$result_file"
}

wait_for_jobs() {
  local jobs_running="$1"
  while ((jobs_running > 0)); do
    wait -n || true
    jobs_running=$((jobs_running - 1))
  done
}

schedule_job() {
  local task_id="$1"
  local label="$2"
  local mode="$3"
  local src="$4"
  local dst="$5"
  local codec="$6"
  local bitrate_kbps="$7"
  local out_sr_hz="$8"
  local out_bits="$9"
  local channels="${10}"
  local result_file="${11}"

  if [[ -e "$dst" && "$FORCE" -eq 0 ]]; then
    log_line "[SKIP] ${label#\[*\] }"
    return 1
  fi

  log_line "$label"
  RESULT_FILES+=("$result_file")
  generate_job_worker "$task_id" "$mode" "$src" "$dst" "$codec" "$bitrate_kbps" "$out_sr_hz" "$out_bits" "$channels" "$result_file" &
  return 0
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  --force)
    FORCE=1
    shift
    ;;
  -h|--help)
    show_help
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    show_help >&2
    die "unknown option: $1" 2
    ;;
  *)
    break
    ;;
  esac
done

[[ $# -eq 3 ]] || {
  show_help >&2
  exit 2
}

DATASET_DIR="$1"
ALBUM_DIR="$2"
TRUSTED_PROFILE="$3"
RAW_TRUSTED_PROFILE="$TRUSTED_PROFILE"

[[ -d "$ALBUM_DIR" ]] || die "album_dir does not exist: $ALBUM_DIR"
TRUSTED_PROFILE="$(profile_normalize "$TRUSTED_PROFILE" || true)"
if [[ -z "$TRUSTED_PROFILE" || "$TRUSTED_PROFILE" != "$RAW_TRUSTED_PROFILE" || ! "$TRUSTED_PROFILE" =~ ^(44100|48000|88200|96000|176400|192000)/(16|24)$ ]]; then
  die "trusted_profile must match ^(44100|48000|88200|96000|176400|192000)/(16|24)$"
fi

require_bins ffmpeg ffprobe >/dev/null || exit 2

mkdir -p "$DATASET_DIR"
DATASET_DIR="$(cd "$DATASET_DIR" && pwd)"
ALBUM_DIR="$(cd "$ALBUM_DIR" && pwd)"

TRUSTED_SR_HZ="${TRUSTED_PROFILE%%/*}"
TRUSTED_BITS="${TRUSTED_PROFILE#*/}"
TRUSTED_LABEL="$(profile_dir_label "$TRUSTED_PROFILE" || true)"
[[ -n "$TRUSTED_LABEL" ]] || die "failed to normalize trusted_profile directory label"

collect_wav_files "$ALBUM_DIR" WAV_FILES
if ((${#WAV_FILES[@]} == 0)); then
  die "album_dir must contain at least one .wav file: $ALBUM_DIR"
fi

TMP_PARENT="${TMPDIR:-/tmp}/audlint-dataset"
mkdir -p "$TMP_PARENT"
TMP_WORK_DIR="$(mktemp -d "${TMP_PARENT}/run.XXXXXX" 2>/dev/null || true)"
[[ -n "$TMP_WORK_DIR" ]] || die "failed to create temp work directory under $TMP_PARENT"

prepare_dataset_dirs

for src in "${WAV_FILES[@]}"; do
  copy_real_wav "$src"
done

cpu_cores="$(audio_detect_cpu_cores)"
DATASET_JOBS="${AUDLINT_DATASET_JOBS:-$cpu_cores}"
if [[ ! "$DATASET_JOBS" =~ ^[0-9]+$ ]] || ((DATASET_JOBS <= 0)); then
  DATASET_JOBS=1
fi
if ((DATASET_JOBS > 4)); then
  DATASET_JOBS=4
fi

declare -a CLEAN_REAL_PROFILES=(
  "44100/16"
  "48000/24"
)
declare -a FAKE_VARIANTS=(
  "mp3:128:mp3_128_upscaled"
  "mp3:192:mp3_192_upscaled"
  "mp3:320:mp3_320_upscaled"
  "aac:128:aac_128_upscaled"
  "aac:256:aac_256_upscaled"
  "opus:96:opus_96_upscaled"
  "opus:160:opus_160_upscaled"
)

jobs_running=0
task_id=0
for src in "${WAV_FILES[@]}"; do
  base="$(basename "$src")"
  stem="${base%.*}"
  channels="$(audio_probe_channels "$src")"
  [[ "$channels" =~ ^[0-9]+$ ]] || channels=0

  for clean_profile in "${CLEAN_REAL_PROFILES[@]}"; do
    if ! is_lower_profile_than_trusted "$clean_profile"; then
      continue
    fi
    clean_label="$(profile_dir_label "$clean_profile" || true)"
    [[ -n "$clean_label" ]] || die "failed to normalize clean profile: $clean_profile"
    clean_sr_hz="${clean_profile%%/*}"
    clean_bits="${clean_profile#*/}"
    clean_dst="$DATASET_DIR/real/$clean_label/$stem.flac"
    task_id=$((task_id + 1))
    result_file="$TMP_WORK_DIR/result_$task_id.tsv"
    if schedule_job \
      "$task_id" \
      "[REAL] clean ${clean_profile} -> real/$clean_label/$(basename "$clean_dst")" \
      "clean_real" \
      "$src" \
      "$clean_dst" \
      "" \
      "0" \
      "$clean_sr_hz" \
      "$clean_bits" \
      "$channels" \
      "$result_file"; then
      ((jobs_running += 1))
      if ((jobs_running >= DATASET_JOBS)); then
        wait -n || true
        jobs_running=$((jobs_running - 1))
      fi
    fi
  done

  for variant in "${FAKE_VARIANTS[@]}"; do
    IFS=: read -r codec bitrate_kbps bucket <<<"$variant"
    fake_dst="$DATASET_DIR/fake/$bucket/$stem.$bucket.flac"
    task_id=$((task_id + 1))
    result_file="$TMP_WORK_DIR/result_$task_id.tsv"
    if schedule_job \
      "$task_id" \
      "[FAKE] $codec ${bitrate_kbps}k -> $(basename "$fake_dst")" \
      "fake" \
      "$src" \
      "$fake_dst" \
      "$codec" \
      "$bitrate_kbps" \
      "$TRUSTED_SR_HZ" \
      "$TRUSTED_BITS" \
      "$channels" \
      "$result_file"; then
      ((jobs_running += 1))
      if ((jobs_running >= DATASET_JOBS)); then
        wait -n || true
        jobs_running=$((jobs_running - 1))
      fi
    fi
  done
done

wait_for_jobs "$jobs_running"

errors=()
for result_file in "${RESULT_FILES[@]}"; do
  [[ -f "$result_file" ]] || {
    errors+=("missing worker result: $result_file")
    continue
  }
  IFS=$'\t' read -r status message <"$result_file"
  if [[ "$status" != "OK" ]]; then
    errors+=("$message")
  fi
done

if ((${#errors[@]} > 0)); then
  printf 'Dataset build failed:\n' >&2
  for message in "${errors[@]}"; do
    printf '  - %s\n' "$message" >&2
  done
  exit 1
fi

printf 'Dataset ready: %s\n' "$DATASET_DIR"
