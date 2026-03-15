#!/usr/bin/env bash
# audlint-task.sh - Cron-oriented library quality scanner.
# Scans albums via audlint-value (DR14 + spectral recode target) and upserts
# album_quality rows in AUDL_DB_PATH.
# GRADE is derived from DR14 dynamic range (dr_grade.py, genre-adaptive).
# RECODE target is determined cascade-free by audlint-analyze (FFT on source files).

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
source "$BOOTSTRAP_DIR/../lib/sh/seek.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/python.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ffprobe.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/sqlite.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/util.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/secure_backup.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path
AUDL_BIN_PATH="${AUDL_BIN_PATH:-$HOME/.local/bin}"

AUDLINT_VALUE_BIN="${AUDLINT_VALUE_BIN:-$SCRIPT_DIR/audlint-value.sh}"
AUDLINT_ANALYZE_BIN="${AUDLINT_ANALYZE_BIN:-$SCRIPT_DIR/audlint-analyze.sh}"
GENRE_LOOKUP="${SCRIPT_DIR}/../lib/py/genre_lookup.py"
TAG_WRITER="${SCRIPT_DIR}/tag_writer.sh"
PYTHON_BIN="${AUDL_PYTHON_BIN:-python3}"
# shellcheck source=/dev/null
[[ -f "$TAG_WRITER" ]] && source "$TAG_WRITER"
NO_COLOR="${NO_COLOR:-}"
MAX_ALBUMS=50
MAX_TIME=0   # 0 = unlimited; set via --max-time N (seconds)
# Deadline pacing guard:
# - finish buffer: keep this much time to flush writes and exit cleanly.
# - next album budget: minimum time budget required to start another album.
# - margin: extra cushion to avoid cron-boundary lock overlap due to jitter.
DEADLINE_FINISH_BUFFER_SEC="${AUDLINT_TASK_DEADLINE_FINISH_BUFFER_SEC:-120}"
DEADLINE_NEXT_ALBUM_BUDGET_SEC="${AUDLINT_TASK_NEXT_ALBUM_BUDGET_SEC:-120}"
DEADLINE_MARGIN_SEC="${AUDLINT_TASK_DEADLINE_MARGIN_SEC:-10}"
LAST_ANALYZED_ELAPSED_SEC=0
DEADLINE_GUARD_LAST_REMAINING=0
DEADLINE_GUARD_LAST_REQUIRED=0
DEADLINE_GUARD_LAST_NEXT_BUDGET=0
ROOT=""
PURGE_MISSING=false
DRY_RUN=false
FULL_DISCOVERY=false
# Discovery timestamp cache: written after each successful discovery pass so the
# next run can focus discovery on likely-changed albums (incremental walk).
# Override path via AUDLINT_TASK_DISCOVERY_CACHE_FILE or AUDL_CACHE_PATH.
DISCOVERY_CACHE_FILE="${AUDLINT_TASK_DISCOVERY_CACHE_FILE:-${AUDL_CACHE_PATH:-}}"   # per-DB default resolved at runtime
# How many seconds to hold off re-queuing a scan_failed album (default 7 days).
SCAN_FAIL_RETRY_SEC="${AUDLINT_TASK_SCAN_FAIL_RETRY_SEC:-$((7 * 86400))}"
# Use a single global default lock path so cron and interactive runs share one lock.
# Can still be overridden via AUDLINT_TASK_LOCK_DIR for tests/custom environments.
LOCK_DIR="${AUDLINT_TASK_LOCK_DIR:-/tmp/audlint-task.lock}"
LOCK_ACQUIRED=false
MERGE_LAST_ERROR=""
SCAN_LAST_OUT=""
MERGE_PCM_MAX_BYTES="${AUDLINT_TASK_MERGE_PCM_MAX_BYTES:-3800000000}"
MERGE_SAMPLE_RATIO="${AUDLINT_TASK_MERGE_SAMPLE_RATIO:-0.25}"
MERGE_SAMPLE_MIN_TRACKS="${AUDLINT_TASK_MERGE_SAMPLE_MIN_TRACKS:-4}"
MERGE_SAMPLE_MAX_TRACKS="${AUDLINT_TASK_MERGE_SAMPLE_MAX_TRACKS:-5}"
FFT_FAST_MODE="${AUDLINT_TASK_FAST_FFT:-0}"
FFT_FAST_MAX_WINDOWS="${AUDLINT_TASK_FFT_MAX_WINDOWS:-8}"
FFT_FAST_WINDOW_SEC="${AUDLINT_TASK_FFT_WINDOW_SEC:-6}"
declare -A AQ_LAST_CHECKED=()
declare -A AQ_SCAN_FAILED=()
declare -A AQ_SOURCE_PATH_CHECKED=()  # source_path → last_checked_at; used for dir-mtime fast-path

show_help() {
  local bin_path_example
  bin_path_example="$(env_expand_value "$AUDL_BIN_PATH")"
  cat <<EOF_HELP
Quick use:
  $(basename "$0") --max-albums 50 --max-time 1200 /path/to/library

Usage:
  $(basename "$0") [--max-albums N] [--max-time N] [--full-discovery] <library_root>
  $(basename "$0") --purge-missing [--dry-run] <library_root>

Mode:
  Cron scan only. This script is intended for scheduled library scans.
  Quality is evaluated from source files only (no merged temp streams).
  Albums are scanned in priority order:
    1) albums not present in album_quality
    2) albums changed since album row last_checked_at

Discovery:
  By default, if AUDL_CACHE_PATH is set, that file is used as the discovery cache
  (recommended: AUDL_CACHE_PATH="\$AUDL_PATH/library.cache"). If AUDL_CACHE_PATH is not
  set, a per-DB cache file is written next to AUDL_DB_PATH as
  .audlint_task_last_discovery_<db-filename>. Subsequent runs use
  'find -newer <cache>' on directories and audio files to prioritize only
  albums touched since the last discovery pass, reducing disk I/O.
  Use --full-discovery to force a complete walk (e.g. after adding
  a large batch of albums or when the cache file is stale/missing).

  Failed albums (scan_failed=1) are held for AUDLINT_TASK_SCAN_FAIL_RETRY_SEC
  seconds (default: 7 days) before being re-queued, to avoid hammering
  chronic scan failures on every cron run.

Purge mode (--purge-missing):
  Remove album_quality rows whose source_path no longer exists on disk.
  Requires the library root to be readable and writable (guards against
  unmounted volumes). Prompts for confirmation before deleting.
  Use --dry-run to preview without making any changes.

Options:
  --max-albums N    Maximum albums to analyze per run (default: 50).
  --max-time N      Stop accepting new albums N seconds after start.
                    Pacing guard requires enough remaining time for:
                    finish buffer + next album budget + margin
                    (defaults: 120s + max(120s,last album time) + 10s).
                    Set N to your full cron interval in seconds (e.g. 1200
                    for a 20-minute cron). Default: 0 (unlimited).
  --full-discovery  Force a full library walk instead of incremental.

Performance (env):
  AUDLINT_TASK_FAST_FFT=1          Enable faster FFT analysis for backlog catch-up.
  AUDLINT_TASK_FFT_MAX_WINDOWS=N   Override fast mode max windows (default: 8).
  AUDLINT_TASK_FFT_WINDOW_SEC=N    Override fast mode window seconds (default: 6).
  AUDLINT_TASK_DEADLINE_FINISH_BUFFER_SEC=N  Deadline flush buffer (default: 120).
  AUDLINT_TASK_NEXT_ALBUM_BUDGET_SEC=N       Min budget to start next album (default: 120).
  AUDLINT_TASK_DEADLINE_MARGIN_SEC=N          Extra deadline jitter cushion (default: 10).

Cron example (20-minute window):
  PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ; "$bin_path_example/audlint-task.sh" --max-albums 50 --max-time 1200 /path/to/library >> "\$HOME/audlint-task.log" 2>&1
EOF_HELP
}

log() { log_ts "$@"; }
elapsed_s() { echo $(( $(date +%s) - T_START )); }

normalize_nonneg_int() {
  local var_name="$1"
  local fallback="$2"
  local -n ref="$var_name"
  if [[ ! "$ref" =~ ^[0-9]+$ ]]; then
    ref="$fallback"
  fi
}

USE_COLOR=false
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  USE_COLOR=true
fi
if [[ "$USE_COLOR" == true ]]; then
  ui_init_colors
  C_RESET="${RESET:-}"
  C_GREEN="${GREEN:-}"
  C_YELLOW="${YELLOW:-}"
  C_CYAN="${CYAN:-}"
  C_DIM="${DIM:-}"
else
  C_RESET=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_DIM=""
fi

# classify_genre_tag is provided by lib/sh/audio.sh (audio_classify_genre_tag).
# Local alias to keep call sites concise.
classify_genre_tag() { audio_classify_genre_tag "$@"; }

# Aliases — canonical implementations live in lib/sh/audio.sh.
is_lossy_codec()             { audio_is_lossy_codec "$@"; }
source_quality_label()       { audio_source_quality_label "$@"; }

task_value_text() {
  local text="${1-}"
  if [[ "$USE_COLOR" == true ]]; then
    ui_value_text "$text"
  else
    printf '%s' "$text"
  fi
}

task_arrow_hint_text() {
  local text="${1-}"
  [[ -n "$text" ]] || return 0
  if [[ "$USE_COLOR" == true ]]; then
    printf '  %s %s' "$(ui_arrow_text)" "$(task_value_text "$text")"
  else
    printf '  -> %s' "$text"
  fi
}

task_album_info_text() {
  local codec="${1-}"
  local quality="${2-}"
  local hint="${3-}"
  printf '%s %s%s' "$(task_value_text "$codec")" "$(task_value_text "$quality")" "$hint"
}

task_elapsed_text() {
  local elapsed="${1-}"
  if [[ "$USE_COLOR" == true ]]; then
    ui_wrap "$C_DIM" "${elapsed}s"
  else
    printf '%ss' "$elapsed"
  fi
}

source_bitrate_kbps() {
  local in="$1"
  local raw
  audio_ffprobe_meta_prime "$in"
  raw="$(audio_probe_bitrate_bps "$in" || true)"
  if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw > 0)); then
    printf '%s\n' "$(((raw + 500) / 1000))"
    return 0
  fi
  printf ''
}

album_bitrate_label() {
  local files_var="$1"
  local -A album_summary=()
  audio_album_summary "$files_var" album_summary
  printf '%s\n' "${album_summary[bitrate_label]:-}"
}

album_source_quality_label() {
  local files_var="$1"
  local -A album_summary=()
  audio_album_summary "$files_var" album_summary
  printf '%s\n' "${album_summary[source_quality]:-?}"
}

album_codec_label() {
  local files_var="$1"
  local -A album_summary=()
  audio_album_summary "$files_var" album_summary
  printf '%s\n' "${album_summary[codec_name]:-unknown}"
}

album_has_lossy_codec() {
  local files_var="$1"
  local -A album_summary=()
  audio_album_summary "$files_var" album_summary
  [[ "${album_summary[has_lossy]:-0}" == "1" ]]
}

album_has_dsd_source_ext() {
  local files_var="$1"
  local -n files_ref="$files_var"
  local f ext
  for f in "${files_ref[@]}"; do
    ext="${f##*.}"
    ext="${ext,,}"
    case "$ext" in
    dsf | dff) return 0 ;;
    esac
  done
  return 1
}

album_has_force_recode_source_ext() {
  local files_var="$1"
  local -n files_ref="$files_var"
  local f ext
  for f in "${files_ref[@]}"; do
    ext="${f##*.}"
    ext="${ext,,}"
    case "$ext" in
    wav | aiff | aif | aifc | dsf | dff) return 0 ;;
    esac
  done
  return 1
}

profile_triggers_forced_upscale() {
  local profile="$1"
  local sr_label sr_hz bit_label bit_norm
  if [[ "$profile" != */* ]]; then
    return 1
  fi

  sr_label="${profile%%/*}"
  sr_hz="$(profile_sr_hz_normalize "$sr_label" || true)"
  [[ "$sr_hz" =~ ^[0-9]+$ ]] || sr_hz=0
  bit_label="${profile##*/}"
  sr_label="$(printf '%s' "$sr_label" | tr -d '[:space:]')"
  bit_label="$(printf '%s' "$bit_label" | tr -d '[:space:]')"
  bit_norm="${bit_label,,}"

  # 32f (float FLAC) is a lossless container semantically equivalent to 24-bit;
  # it is commonly produced by DAW exports and does not indicate upsampling.
  case "$bit_norm" in
  32f | 64f) return 1 ;;
  esac
  if [[ "$bit_norm" =~ ^[0-9]+$ ]] && ((bit_norm > 24)); then
    return 0
  fi

  # Hi-res sample rate with 16-bit depth is almost certainly an upsampled CD.
  if [[ "$bit_norm" == "16" ]]; then
    if ((sr_hz >= 88200)); then
      return 0
    fi
  fi

  ((sr_hz > 192000))
}

source_policy_force_upscale() {
  local files_var="$1"
  local source_profile="$2"

  if album_has_dsd_source_ext "$files_var"; then
    return 0
  fi
  if profile_triggers_forced_upscale "$source_profile"; then
    return 0
  fi
  return 1
}

resolve_library_db_path() {
  local raw="${AUDL_DB_PATH:-}"
  if [[ -z "$raw" && -n "${AUDL_PATH:-}" ]]; then
    raw="$AUDL_PATH/library.sqlite"
  fi
  [[ -n "$raw" ]] || return 1
  env_expand_value "$raw"
}

release_scan_lock() {
  if [[ "$LOCK_ACQUIRED" != true ]]; then
    return 0
  fi
  if [[ -d "$LOCK_DIR" ]]; then
    rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  LOCK_ACQUIRED=false
}

acquire_scan_lock_or_skip() {
  local pid_file="$LOCK_DIR/pid"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$pid_file"
    LOCK_ACQUIRED=true
    trap release_scan_lock EXIT INT TERM
    return 0
  fi

  local stale_pid=""
  if [[ -f "$pid_file" ]]; then
    stale_pid="$(cat "$pid_file" 2>/dev/null || true)"
  fi

  if [[ "$stale_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$pid_file"
      LOCK_ACQUIRED=true
      trap release_scan_lock EXIT INT TERM
      return 0
    fi
  fi

  log "Skip: previous audlint-task run still in progress (lock: $LOCK_DIR)"
  return 1
}

ffmpeg_concat_escape_path() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

collect_qty_audio_files() {
  local dir="$1"
  local out_var="$2"
  local -n out_ref="$out_var"
  local known_files=()
  local dir_files=()
  local codec=""
  local f
  local had_nullglob=0
  local -A seen=()
  out_ref=()

  # Fast path: known audio extensions from shared helper.
  audio_collect_files "$dir" known_files
  for f in "${known_files[@]}"; do
    [[ -f "$f" ]] || continue
    out_ref+=("$f")
    seen["$f"]=1
  done

  # Fallback/coverage path: probe remaining files for any audio stream so
  # uncommon extensions and codec containers still get indexed.
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  dir_files=("$dir"/*)
  ((had_nullglob == 1)) || shopt -u nullglob
  for f in "${dir_files[@]}"; do
    [[ -f "$f" ]] || continue
    [[ -n "${seen["$f"]+x}" ]] && continue
    codec="$(audio_codec_name "$f" || true)"
    [[ -n "$codec" ]] || continue
    out_ref+=("$f")
    seen["$f"]=1
  done
}

has_audio_files() {
  local dir="$1"
  local files=()
  collect_qty_audio_files "$dir" files
  [[ ${#files[@]} -gt 0 ]]
}

first_audio_file() {
  local dir="$1"
  local files=()
  collect_qty_audio_files "$dir" files
  [[ ${#files[@]} -gt 0 ]] || return 1
  printf '%s\n' "${files[0]}"
}

album_max_mtime() {
  local dir="$1"
  local files=()
  collect_qty_audio_files "$dir" files
  album_max_mtime_from_files files
}

album_max_mtime_from_files() {
  local files_var="$1"
  local -n files_ref="$files_var"
  [[ ${#files_ref[@]} -gt 0 ]] || return 1

  local max_mtime=0
  local f mtime
  for f in "${files_ref[@]}"; do
    mtime="$(stat_epoch_mtime "$f" || echo 0)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    ((mtime > max_mtime)) && max_mtime="$mtime"
  done
  printf '%s\n' "$max_mtime"
}

sample_fmt_to_bits() {
  local bits
  bits="$(audio_sample_fmt_to_bits "$1")"
  if [[ "$bits" =~ ^[0-9]+$ ]] && ((bits > 0)); then
    printf '%s' "$bits"
  else
    printf '24'
  fi
}

source_bit_depth_bits() {
  audio_probe_bit_depth_bits "$1"
}

source_duration_seconds() {
  audio_ffprobe_meta_prime "$1"
  audio_probe_duration_seconds "$1"
}

estimate_merged_pcm_bytes() {
  local files_var="$1"
  local -n files_ref="$files_var"
  (( ${#files_ref[@]} > 0 )) || {
    printf '0\t0\n'
    return 0
  }

  local first sr_hz ch bits total_sec est_bytes
  first="${files_ref[0]}"
  audio_ffprobe_meta_prime "$first"
  sr_hz="$(audio_probe_sample_rate_hz "$first")"
  ch="$(audio_probe_channels "$first")"
  bits="$(source_bit_depth_bits "$first" || true)"
  [[ "$sr_hz" =~ ^[0-9]+$ ]] || sr_hz=0
  [[ "$ch" =~ ^[0-9]+$ ]] || ch=2
  [[ "$bits" =~ ^[0-9]+$ ]] || bits=24

  total_sec=0
  local f dur
  for f in "${files_ref[@]}"; do
    dur="$(source_duration_seconds "$f")"
    total_sec="$(awk -v a="$total_sec" -v b="$dur" 'BEGIN{printf "%.6f", a+b}')"
  done

  if ((sr_hz <= 0 || ch <= 0 || bits <= 0)); then
    printf '0\t%s\n' "$total_sec"
    return 0
  fi

  est_bytes="$(awk -v d="$total_sec" -v sr="$sr_hz" -v c="$ch" -v b="$bits" 'BEGIN{printf "%.0f", d*sr*c*(b/8.0)}')"
  [[ "$est_bytes" =~ ^[0-9]+$ ]] || est_bytes=0
  printf '%s\t%s\n' "$est_bytes" "$total_sec"
}

select_merge_sample_files() {
  local files_var="$1"
  local out_var="$2"
  local -n files_ref="$files_var"
  # shellcheck disable=SC2178  # nameref for array; SC2178 is a false positive here
  local -n out_ref="$out_var"
  out_ref=("${files_ref[@]}")
  (( ${#files_ref[@]} > 0 )) || return 1

  local max_bytes min_tracks max_tracks
  max_bytes="${MERGE_PCM_MAX_BYTES:-3800000000}"
  min_tracks="${MERGE_SAMPLE_MIN_TRACKS:-4}"
  max_tracks="${MERGE_SAMPLE_MAX_TRACKS:-5}"
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=3800000000
  [[ "$min_tracks" =~ ^[0-9]+$ ]] || min_tracks=4
  [[ "$max_tracks" =~ ^[0-9]+$ ]] || max_tracks=5
  (( min_tracks < 1 )) && min_tracks=1
  (( max_tracks < min_tracks )) && max_tracks="$min_tracks"

  local est_bytes total_sec
  IFS=$'\t' read -r est_bytes total_sec <<< "$(estimate_merged_pcm_bytes "$files_var")"
  [[ "$est_bytes" =~ ^[0-9]+$ ]] || est_bytes=0
  if (( est_bytes <= 0 || est_bytes <= max_bytes )); then
    return 1
  fi

  local n k ratio
  n="${#files_ref[@]}"
  ratio="${MERGE_SAMPLE_RATIO:-0.25}"
  if [[ ! "$ratio" =~ ^0([.][0-9]+)?$|^1([.]0+)?$ ]]; then
    ratio="0.25"
  fi
  k="$(awk -v n="$n" -v r="$ratio" -v mn="$min_tracks" -v mx="$max_tracks" 'BEGIN{t=int(n*r+0.999999); if(t<mn)t=mn; if(t>mx)t=mx; if(t>n)t=n; if(t<1)t=1; print t}')"
  [[ "$k" =~ ^[0-9]+$ ]] || k=1
  (( k >= n )) && return 1

  local -A seen_idx=()
  local idx i
  local chosen=()
  for ((i=0; i<k; i++)); do
    if ((k == 1)); then
      idx=0
    else
      idx="$(awk -v i="$i" -v n="$n" -v k="$k" 'BEGIN{printf "%d", int((i*(n-1))/(k-1))}')"
    fi
    [[ "$idx" =~ ^[0-9]+$ ]] || idx=0
    if [[ -z "${seen_idx[$idx]+x}" ]]; then
      chosen+=("${files_ref[$idx]}")
      seen_idx["$idx"]=1
    fi
  done
  if (( ${#chosen[@]} < k )); then
    for ((i=0; i<n && ${#chosen[@]}<k; i++)); do
      if [[ -z "${seen_idx[$i]+x}" ]]; then
        chosen+=("${files_ref[$i]}")
        seen_idx["$i"]=1
      fi
    done
  fi

  out_ref=("${chosen[@]}")
  return 0
}

recode_is_actionable() {
  local recode="$1"
  [[ -n "$recode" ]] || return 1
  case "$recode" in
  "Keep as-is" | "Pending rescan"*) return 1 ;;
  *) return 0 ;;
  esac
}

# Build the human-readable RECODE string and needs_recode flag from:
#   source_quality  — CURR profile in canonical form e.g. "96000/24", "44100/16", "96000/32f"
#   recode_raw      — audlint-analyze output in canonical Hz form e.g. "48000/24", "96000/24"
#   force_recode_any_sr — when 1, always emit actionable recode for edge source
#                         containers (aiff/wav/dsf/dff), regardless of SR delta
# Outputs two lines: recode_str \n needs_recode (0|1)
build_recode_fields() {
  local source_quality="$1"  # canonical form: "96000/24", "48000/32f", "44100/16"
  local recode_raw="$2"      # canonical Hz form from audlint-analyze: "48000/24"
  local force_recode_any_sr="${3:-0}"
  local prior_source_quality="${4:-}"
  local source_norm prior_source_norm

  local target_display
  target_display="$(audvalue_format_profile "$recode_raw")"

  # Extract target SR in Hz from recode_raw ("48000/24" -> 48000).
  local target_hz="${recode_raw%%/*}"
  [[ "$target_hz" =~ ^[0-9]+$ ]] || { printf '%s\n%s\n' "Keep as-is" "0"; return; }

  # Edge containers should always get a recode action using the computed
  # best-fit profile, even when the SR matches.
  if [[ "$force_recode_any_sr" == "1" ]]; then
    printf '%s\n%s\n' "Recode to ${target_display}" "1"
    return
  fi

  source_norm="$(profile_normalize "$source_quality" || true)"
  [[ -n "$source_norm" ]] || { printf '%s\n%s\n' "Keep as-is" "0"; return; }
  local source_hz="${source_norm%%/*}"
  [[ "$source_hz" =~ ^[0-9]+$ ]] || { printf '%s\n%s\n' "Keep as-is" "0"; return; }

  prior_source_norm="$(profile_normalize "$prior_source_quality" || true)"
  local prior_source_hz="${prior_source_norm%%/*}"
  if [[ "$prior_source_hz" =~ ^[0-9]+$ ]] \
    && (( prior_source_hz > source_hz )) \
    && (( target_hz < source_hz )); then
    printf '%s\n%s\n' "Keep as-is" "0"
    return
  fi

  # needs_recode only when audlint-analyze recommends a lower SR than source.
  if (( target_hz < source_hz )); then
    printf '%s\n%s\n' "Recode to ${target_display}" "1"
  else
    printf '%s\n%s\n' "Keep as-is" "0"
  fi
}

resolve_analyze_recode_target() {
  local album_dir="$1"
  local recode_raw

  [[ -x "$AUDLINT_ANALYZE_BIN" ]] || return 1
  recode_raw="$("$AUDLINT_ANALYZE_BIN" "$album_dir" 2>/dev/null || true)"
  if [[ ! "$recode_raw" =~ ^[0-9]+/[0-9]+$ ]]; then
    recode_raw="$(profile_cache_target_profile "$album_dir" || true)"
  fi
  [[ "$recode_raw" =~ ^[0-9]+/[0-9]+$ ]] || return 1
  printf '%s\n' "$recode_raw"
  return 0
}

# ---------------------------------------------------------------------------
# LEGACY: ffmpeg merge functions — kept for potential future use (e.g.
# per-track DR verification or batch spectral export). Not called in the
# active scan flow; audlint-value/audlint-analyze operate on source files
# directly. Do not remove without a migration plan.
# ---------------------------------------------------------------------------
run_ffmpeg_concat_merge() {
  local concat_list="$1"
  local merged_file="$2"
  local err_file
  err_file="$(mktemp 2>/dev/null || true)"
  [[ -n "$err_file" ]] || {
    MERGE_LAST_ERROR="mktemp failed for ffmpeg stderr"
    return 1
  }

  MERGE_LAST_ERROR=""
  if ! ffmpeg -y -hide_banner -loglevel error -nostdin -f concat -safe 0 -i "$concat_list" -vn -c:a pcm_s24le -rf64 auto "$merged_file" </dev/null 2>"$err_file"; then
    MERGE_LAST_ERROR="$(grep -m1 '.' "$err_file" 2>/dev/null || true)"
    [[ -n "$MERGE_LAST_ERROR" ]] || MERGE_LAST_ERROR="ffmpeg merge failed"
    rm -f "$err_file"
    return 1
  fi

  if [[ -s "$err_file" ]]; then
    MERGE_LAST_ERROR="$(grep -m1 '.' "$err_file" 2>/dev/null || true)"
    [[ -n "$MERGE_LAST_ERROR" ]] || MERGE_LAST_ERROR="ffmpeg merge failed (stderr non-empty)"
    rm -f "$err_file"
    return 1
  fi

  rm -f "$err_file"
  return 0
}

scan_album_dir_merged() {
  local dir="$1"
  local genre_profile="${2:-standard}"
  local prior_recode_source_profile="${3:-}"
  SCAN_LAST_OUT=""

  local files=()
  collect_qty_audio_files "$dir" files
  [[ ${#files[@]} -gt 0 ]] || return 2

  local source_quality bitrate_label codec_name has_lossy
  local -A album_summary=()
  audio_album_summary files album_summary
  source_quality="${album_summary[source_quality]:-?}"
  bitrate_label="${album_summary[bitrate_label]:-}"
  codec_name="${album_summary[codec_name]:-unknown}"
  has_lossy="${album_summary[has_lossy]:-0}"
  [[ -n "$source_quality" ]] || source_quality="?"
  [[ -n "$bitrate_label" ]] || bitrate_label="?"
  [[ -n "$codec_name" ]] || codec_name="unknown"

  local prior_source_quality=""
  prior_source_quality="$(profile_normalize "$prior_recode_source_profile" || true)"

  # ── audlint-value: DR14 + spectral recode target ─────────────────────────
  local audvalue_failed=0
  if ! audvalue_scan_album "$dir" "$genre_profile"; then
    audvalue_failed=1
  fi

  # Edge containers must still surface an actionable recode profile even when
  # audlint-value fails (e.g. dr14meter parse/report issues on WAV-only albums).
  if ((audvalue_failed == 1)); then
    local fallback_recode
    fallback_recode=""
    if album_has_force_recode_source_ext files; then
      fallback_recode="$(resolve_analyze_recode_target "$dir" || true)"
      if [[ "$fallback_recode" =~ ^[0-9]+/[0-9]+$ ]]; then
        AUDVALUE_RECODE_TO="$fallback_recode"
        AUDVALUE_DR=""
        AUDVALUE_GRADE="?"
      fi
    fi
    if [[ ! "$AUDVALUE_RECODE_TO" =~ ^[0-9]+/[0-9]+$ ]]; then
      MERGE_LAST_ERROR="audlint-value scan failed"
      return 1
    fi
  fi

  local grade="$AUDVALUE_GRADE"
  local dr="$AUDVALUE_DR"
  # quality_score is legacy; keep fresh writes empty and rely on dynamic_range_score.
  local score=""

  # ── RECODE determination ──────────────────────────────────────────────────
  local recode_rec needs_recode
  local recode_fields
  local force_recode_any_sr=0
  if album_has_force_recode_source_ext files; then
    force_recode_any_sr=1
  fi
  recode_fields="$(build_recode_fields "$source_quality" "$AUDVALUE_RECODE_TO" "$force_recode_any_sr" "$prior_source_quality")"
  recode_rec="$(printf '%s\n' "$recode_fields" | head -n1)"
  needs_recode="$(printf '%s\n' "$recode_fields" | tail -n1)"
  [[ "$needs_recode" =~ ^[01]$ ]] || needs_recode=0

  # Lossy source overrides recode logic.
  local rec="Keep"
  local hit=0
  if ((has_lossy == 1)); then
    needs_recode=0
    case "$grade" in
    C | F)
      hit=1
      rec="Replace with Lossless Rip"
      recode_rec="Replace with lossless"
      ;;
    *)
      rec="Keep"
      recode_rec="Keep as-is"
      ;;
    esac
  fi

  printf -v SCAN_LAST_OUT '%s\n' \
    "HIT=$hit" \
    "GRADE=$grade" \
    "SCORE=$score" \
    "DYN=$dr" \
    "UPS=0" \
    "REC=$rec" \
    "CURR=$source_quality" \
    "BITRATE=$bitrate_label" \
    "CODEC=$codec_name" \
    "RECODE=$recode_rec" \
    "NEEDS_RECODE=$needs_recode" \
    "GENRE_PROFILE=$genre_profile" \
    "RECODE_SOURCE_PROFILE=$prior_source_quality"

  return 0
}

lookup_album_quality_recode_context() {
  local source_path="$1"
  local artist="$2"
  local album="$3"
  local year="$4"
  local row=""
  local row_sep=$'\x1f'

  if [[ -n "$source_path" ]]; then
    row="$(
      sqlite3 -separator "$row_sep" -noheader "$DB_PATH" \
        "SELECT
           COALESCE(current_quality,''),
           COALESCE(recode_source_profile,''),
           COALESCE(last_recoded_at,0)
         FROM album_quality
         WHERE source_path='$(sql_escape "$source_path")'
         LIMIT 1;" 2>/dev/null || true
    )"
  fi

  if [[ -z "$row" ]]; then
    local artist_lc album_lc
    artist_lc="$(norm_lc "$artist")"
    album_lc="$(norm_lc "$album")"
    [[ "$year" =~ ^[0-9]{4}$ ]] || year=0
    row="$(
      sqlite3 -separator "$row_sep" -noheader "$DB_PATH" \
        "SELECT
           COALESCE(current_quality,''),
           COALESCE(recode_source_profile,''),
           COALESCE(last_recoded_at,0)
         FROM album_quality
         WHERE artist_lc='$(sql_escape "$artist_lc")'
           AND album_lc='$(sql_escape "$album_lc")'
           AND year_int=$year
         LIMIT 1;" 2>/dev/null || true
    )"
  fi

  [[ -n "$row" ]] || return 1
  printf '%s\n' "$row"
}

run_purge_missing() {
  local dry_run="${1:-false}"
  local db="$2"
  local root="$3"

  # Safety: root must be readable+writable — guards against unmounted volumes.
  if [[ ! -d "$root" || ! -r "$root" || ! -w "$root" ]]; then
    printf 'Abort: library root is not readable/writable: %s\n' "$root" >&2
    return 1
  fi

  # Fetch all rows that have a source_path set.
  local rows
  rows="$(sqlite3 -separator $'\t' -noheader "$db" \
    "SELECT id, artist, album, year_int, source_path FROM album_quality WHERE source_path IS NOT NULL AND source_path != '';" \
    2>/dev/null || true)"

  if [[ -z "$rows" ]]; then
    printf 'No rows with source_path found.\n'
    return 0
  fi

  local -a missing_ids=()
  local -a missing_labels=()
  local id artist album year src

  while IFS=$'\t' read -r id artist album year src; do
    [[ -n "$id" ]] || continue
    if [[ ! -d "$src" ]]; then
      missing_ids+=("$id")
      missing_labels+=("$(printf '%s - %s (%s)  [%s]' "$artist" "$album" "$year" "$src")")
    fi
  done <<< "$rows"

  local total_missing="${#missing_ids[@]}"
  if ((total_missing == 0)); then
    printf 'All source paths exist on disk. Nothing to purge.\n'
    return 0
  fi

  printf 'Missing source paths (%d):\n' "$total_missing"
  local i
  for ((i = 0; i < total_missing; i++)); do
    printf '  %s\n' "${missing_labels[$i]}"
  done

  if [[ "$dry_run" == true ]]; then
    printf '\nDry run — no rows deleted.\n'
    return 0
  fi

  printf '\nDelete these %d rows from album_quality? [y/N] ' "$total_missing"
  local answer=""
  tty_read_line answer || true
  if [[ "${answer,,}" != "y" ]]; then
    printf 'Aborted.\n'
    return 0
  fi

  # Build comma-separated id list for DELETE.
  local id_list
  id_list="$(IFS=,; printf '%s' "${missing_ids[*]}")"
  sqlite3 "$db" "DELETE FROM album_quality WHERE id IN ($id_list);" >/dev/null \
    || { printf 'Error: sqlite3 DELETE failed.\n' >&2; return 1; }

  printf 'Deleted %d rows.\n' "$total_missing"
}

scan_roadmap_next_item() {
  local row=""

  row="$(
    sqlite3 -separator $'\t' -noheader "$DB_PATH" \
      "SELECT id, artist, year_int, album, source_path, scan_kind
         FROM scan_roadmap
        WHERE scan_kind='new'
        ORDER BY enqueued_at ASC, id ASC
        LIMIT 1;" 2>/dev/null || true
  )"
  if [[ -n "$row" ]]; then
    printf '%s\n' "$row"
    return 0
  fi

  sqlite3 -separator $'\t' -noheader "$DB_PATH" \
    "SELECT id, artist, year_int, album, source_path, scan_kind
       FROM scan_roadmap
      WHERE scan_kind='changed'
      ORDER BY enqueued_at ASC, id ASC
      LIMIT 1;" 2>/dev/null || true
}

record_scan_failure() {
  local artist="$1"
  local year="$2"
  local album="$3"
  local source_path="$4"
  local checked_at="$5"
  local reason="$6"

  album_quality_upsert \
    "$DB_PATH" \
    "$artist" \
    "$year" \
    "$album" \
    "" \
    "" \
    "" \
    "" \
    "" \
    "0" \
    "$source_path" \
    "$checked_at" \
    "1" \
    "$reason" \
    "" \
    "" \
    "" \
    "" \
    "0"
}

record_mixed_content_failure() {
  local artist="$1"
  local year="$2"
  local album="$3"
  local source_path="$4"
  local checked_at="$5"
  local codec_label="$6"
  local bitrate_label="$7"
  local reason="$8"

  album_quality_upsert \
    "$DB_PATH" \
    "$artist" \
    "$year" \
    "$album" \
    "" \
    "" \
    "" \
    "" \
    "Replace with Lossless Rip" \
    "1" \
    "$source_path" \
    "$checked_at" \
    "1" \
    "$reason" \
    "mixed" \
    "$bitrate_label" \
    "$codec_label" \
    "Mixed content detected -> replace source" \
    "1"
}

roadmap_album_key() {
  local artist_lc="$1"
  local album_lc="$2"
  local year="$3"
  printf '%s|%s|%s' "$artist_lc" "$album_lc" "$year"
}

load_album_quality_cache() {
  AQ_LAST_CHECKED=()
  AQ_SCAN_FAILED=()
  AQ_SOURCE_PATH_CHECKED=()
  local rows
  rows="$(
    sqlite3 -separator $'\t' -noheader "$DB_PATH" \
      "SELECT artist_lc, album_lc, year_int, COALESCE(last_checked_at,0), COALESCE(scan_failed,0), COALESCE(source_path,'') FROM album_quality;" 2>/dev/null || true
  )"
  [[ -n "$rows" ]] || return 0

  local artist_lc album_lc year_int last_checked scan_failed source_path key
  while IFS=$'\t' read -r artist_lc album_lc year_int last_checked scan_failed source_path; do
    [[ -n "$artist_lc" && -n "$album_lc" ]] || continue
    [[ "$year_int" =~ ^[0-9]+$ ]] || year_int=0
    [[ "$last_checked" =~ ^[0-9]+$ ]] || last_checked=0
    [[ "$scan_failed" =~ ^[0-9]+$ ]] || scan_failed=0
    key="$(roadmap_album_key "$artist_lc" "$album_lc" "$year_int")"
    AQ_LAST_CHECKED["$key"]="$last_checked"
    AQ_SCAN_FAILED["$key"]="$scan_failed"
    # Store last_checked only for non-failed rows; failed rows must still reach
    # the AQ_SCAN_FAILED hold logic so they are correctly counted/skipped there.
    if [[ -n "$source_path" && "$scan_failed" == "0" ]]; then
      AQ_SOURCE_PATH_CHECKED["$source_path"]="$last_checked"
    fi
  done <<< "$rows"
}

scan_roadmap_count() {
  local count
  count="$(sqlite3 -noheader "$DB_PATH" "SELECT COUNT(*) FROM scan_roadmap;" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "$count"
}

scan_roadmap_enqueue() {
  local artist="$1"
  local artist_lc="$2"
  local album="$3"
  local album_lc="$4"
  local year="$5"
  local source_path="$6"
  local album_mtime="$7"
  local scan_kind="$8"

  local now
  now="$(date +%s)"
  sqlite3 "$DB_PATH" \
    "INSERT INTO scan_roadmap (
       artist, artist_lc, album, album_lc, year_int, source_path, album_mtime, scan_kind, enqueued_at
     ) VALUES (
       '$(sql_escape "$artist")',
       '$(sql_escape "$artist_lc")',
       '$(sql_escape "$album")',
       '$(sql_escape "$album_lc")',
       $year,
       '$(sql_escape "$source_path")',
       $album_mtime,
       '$(sql_escape "$scan_kind")',
       $now
     )
     ON CONFLICT(artist_lc, album_lc, year_int) DO UPDATE SET
       artist=excluded.artist,
       album=excluded.album,
       source_path=excluded.source_path,
       album_mtime=excluded.album_mtime,
       scan_kind=excluded.scan_kind,
       enqueued_at=excluded.enqueued_at;" >/dev/null 2>&1
}

prune_stale_source_path_keys() {
  local source_path="$1"
  local artist="$2"
  local album="$3"
  local year="$4"
  [[ -n "$source_path" ]] || return 0

  local artist_lc album_lc source_path_sql artist_lc_sql album_lc_sql
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"
  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0
  source_path_sql="$(sql_escape "$source_path")"
  artist_lc_sql="$(sql_escape "$artist_lc")"
  album_lc_sql="$(sql_escape "$album_lc")"

  # If metadata/tag year changed for the same folder, remove stale rows keyed
  # under the old triplet so one source_path resolves to one canonical album key.
  sqlite3 "$DB_PATH" \
    "DELETE FROM album_quality
      WHERE source_path='${source_path_sql}'
        AND (artist_lc!='${artist_lc_sql}' OR album_lc!='${album_lc_sql}' OR year_int!=$year);" >/dev/null 2>&1 || true

  # Drain all pending queue rows for this folder now; this item is the canonical
  # in-flight scan for the source_path and prevents duplicate same-folder scans.
  sqlite3 "$DB_PATH" \
    "DELETE FROM scan_roadmap
      WHERE source_path='${source_path_sql}';" >/dev/null 2>&1 || true
}

mark_scan_kind_done() {
  local scan_kind="$1"
  if [[ "$scan_kind" == "new" ]]; then
    ALBUMS_NEW_DONE=$((ALBUMS_NEW_DONE + 1))
  else
    ALBUMS_CHANGED_DONE=$((ALBUMS_CHANGED_DONE + 1))
  fi
}

discover_scan_roadmap_item() {
  local dir="$1"
  ALBUMS_SCANNED=$((ALBUMS_SCANNED + 1))
  local dir_mtime=0
  dir_mtime="$(stat_epoch_mtime "$dir" || echo 0)"
  [[ "$dir_mtime" =~ ^[0-9]+$ ]] || dir_mtime=0

  # Fast-path: if this directory's mtime hasn't advanced past its last_checked_at
  # timestamp we know no file inside it changed.  Skip ffprobe and file globbing
  # entirely — one stat(2) on the directory inode is all we need.
  if [[ -n "${AQ_SOURCE_PATH_CHECKED["$dir"]+x}" ]]; then
    local _dir_last_checked
    _dir_last_checked="${AQ_SOURCE_PATH_CHECKED["$dir"]}"
    [[ "$_dir_last_checked" =~ ^[0-9]+$ ]] || _dir_last_checked=0
    if ((dir_mtime > 0 && _dir_last_checked > 0 && dir_mtime <= _dir_last_checked)); then
      ALBUMS_SKIPPED_UNCHANGED=$((ALBUMS_SKIPPED_UNCHANGED + 1))
      return 0
    fi
  fi

  local files=()
  collect_qty_audio_files "$dir" files
  [[ ${#files[@]} -gt 0 ]] || return 0
  local probe_file="${files[0]}"

  local meta_payload artist year album
  meta_payload="$(ffprobe_album_key "$probe_file" || true)"
  artist="$(kv_get "ARTIST" "$meta_payload")"
  year="$(kv_get "YEAR" "$meta_payload")"
  album="$(kv_get "ALBUM" "$meta_payload")"
  if [[ -z "$artist" || -z "$album" ]]; then
    ALBUMS_SKIPPED_NO_KEY=$((ALBUMS_SKIPPED_NO_KEY + 1))
    return 0
  fi

  local album_mtime
  album_mtime="$(album_max_mtime_from_files files || echo 0)"
  [[ "$album_mtime" =~ ^[0-9]+$ ]] || album_mtime=0
  local content_mtime="$album_mtime"
  if ((dir_mtime > content_mtime)); then
    content_mtime="$dir_mtime"
  fi

  local artist_lc album_lc
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"
  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0

  local row_key
  row_key="$(roadmap_album_key "$artist_lc" "$album_lc" "$year")"
  local in_db=0 row_checked=0 row_failed=0
  if [[ -n "${AQ_LAST_CHECKED["$row_key"]+x}" ]]; then
    in_db=1
    row_checked="${AQ_LAST_CHECKED["$row_key"]}"
    row_failed="${AQ_SCAN_FAILED["$row_key"]:-0}"
  fi
  [[ "$row_checked" =~ ^[0-9]+$ ]] || row_checked=0
  [[ "$row_failed" =~ ^[0-9]+$ ]] || row_failed=0

  if ((in_db == 1 && row_failed == 1)); then
    if ((row_checked > 0 && content_mtime > row_checked)); then
      :
    else
    # Re-queue failed albums only after SCAN_FAIL_RETRY_SEC seconds have elapsed
    # since last_checked_at, to avoid hammering chronic failures every run.
      local _now _retry_eligible=0
      _now="$(date +%s)"
      [[ "$_now" =~ ^[0-9]+$ ]] || _now=0
      if ((_now > 0 && row_checked > 0 && (_now - row_checked) >= SCAN_FAIL_RETRY_SEC)); then
        _retry_eligible=1
      fi
      if ((_retry_eligible == 0)); then
        ALBUMS_SKIPPED_FAIL_HOLD=$((ALBUMS_SKIPPED_FAIL_HOLD + 1))
        return 0
      fi
      # Retry window has elapsed — fall through to re-queue as "changed".
    fi
  fi
  if ((in_db == 1 && row_checked > 0 && content_mtime <= row_checked)); then
    ALBUMS_SKIPPED_UNCHANGED=$((ALBUMS_SKIPPED_UNCHANGED + 1))
    return 0
  fi

  local scan_kind="new"
  if ((in_db == 1)); then
    scan_kind="changed"
  fi

  scan_roadmap_enqueue "$artist" "$artist_lc" "$album" "$album_lc" "$year" "$dir" "$content_mtime" "$scan_kind" || return 1
  if [[ "$scan_kind" == "new" ]]; then
    ROADMAP_ENQUEUED_NEW=$((ROADMAP_ENQUEUED_NEW + 1))
  else
    ROADMAP_ENQUEUED_CHANGED=$((ROADMAP_ENQUEUED_CHANGED + 1))
  fi
}

discover_scan_roadmap() {
  load_album_quality_cache

  # Incremental mode: if a discovery cache file exists and --full-discovery was
  # not requested, prioritize albums touched since the cache timestamp.
  # We include both directory mtimes and newer audio files because file metadata
  # edits often do not update the containing directory mtime.
  local use_incremental=false
  if [[ "$FULL_DISCOVERY" == false && -f "$DISCOVERY_CACHE_FILE" ]]; then
    use_incremental=true
  fi

  if [[ "$use_incremental" == true ]]; then
    log "Discovery: incremental (cache=$DISCOVERY_CACHE_FILE)"
    local cand dir
    local -A seen_dirs=()
    local -a audio_find_pred=()
    read -r -a audio_find_pred <<< "$(audio_find_iname_args)"
    while IFS= read -r -d '' cand <&3; do
      if [[ -d "$cand" ]]; then
        dir="$cand"
      else
        dir="$(dirname "$cand")"
      fi
      [[ -n "${seen_dirs["$dir"]+x}" ]] && continue
      seen_dirs["$dir"]=1
      discover_scan_roadmap_item "$dir"
      local cb_status=$?
      case "$cb_status" in
      0 | 1) ;;
      *) return "$cb_status" ;;
      esac
    done 3< <(find "$ROOT" \
      -type d \( -name "before-recode" -prune \) \
      -o \( -type d -newer "$DISCOVERY_CACHE_FILE" -print0 \) \
      -o \( -type f \( "${audio_find_pred[@]}" \) -newer "$DISCOVERY_CACHE_FILE" -print0 \))
  else
    if [[ "$FULL_DISCOVERY" == true ]]; then
      log "Discovery: full (--full-discovery requested)"
    else
      log "Discovery: full (no cache file yet)"
    fi
    seek_walk_dirs "$ROOT" discover_scan_roadmap_item "before-recode"
  fi

  # Write/update the discovery cache timestamp so the next run can go incremental.
  touch "$DISCOVERY_CACHE_FILE" 2>/dev/null || true
}

scan_roadmap_delete_item() {
  local roadmap_id="$1"
  [[ "$roadmap_id" =~ ^[0-9]+$ ]] || return 1
  sqlite3 "$DB_PATH" "DELETE FROM scan_roadmap WHERE id=$roadmap_id;" >/dev/null 2>&1
}

process_scan_roadmap_item() {
  local artist="$1"
  local year="$2"
  local album="$3"
  local source_path="$4"
  local scan_kind="$5"
  local display_name source_path_sql
  display_name="$artist - $album"
  source_path_sql="$(sql_escape "$source_path")"

  if [[ ! -d "$source_path" || ! -r "$source_path" ]]; then
    log "Purge missing: $display_name -> $source_path"
    sqlite3 "$DB_PATH" "DELETE FROM album_quality WHERE source_path='${source_path_sql}';" >/dev/null 2>&1 || true
    return 0
  fi

  local files=()
  collect_qty_audio_files "$source_path" files
  if [[ ${#files[@]} -eq 0 ]]; then
    log "Purge missing (no audio): $display_name -> $source_path"
    sqlite3 "$DB_PATH" "DELETE FROM album_quality WHERE source_path='${source_path_sql}';" >/dev/null 2>&1 || true
    return 0
  fi

  local probe_payload probe_artist probe_album probe_year
  probe_payload="$(ffprobe_album_key "${files[0]}" 2>/dev/null || true)"
  probe_artist="$(kv_get "ARTIST" "$probe_payload")"
  probe_album="$(kv_get "ALBUM" "$probe_payload")"
  probe_year="$(kv_get "YEAR" "$probe_payload")"
  if [[ -n "$probe_artist" && -n "$probe_album" ]]; then
    artist="$probe_artist"
    album="$probe_album"
  fi
  if [[ "$probe_year" =~ ^[0-9]{4}$ ]]; then
    year="$probe_year"
  elif [[ ! "$year" =~ ^[0-9]{4}$ ]]; then
    year=0
  fi
  display_name="$artist - $album"
  prune_stale_source_path_keys "$source_path" "$artist" "$album" "$year"

  local prev_recode_source_profile="" recode_context=""
  recode_context="$(lookup_album_quality_recode_context "$source_path" "$artist" "$album" "$year" || true)"
  if [[ -n "$recode_context" ]]; then
    IFS=$'\x1f' read -r _prev_current_quality prev_recode_source_profile _prev_last_recoded <<< "$recode_context"
  fi

  ALBUMS_ANALYZED=$((ALBUMS_ANALYZED + 1))
  local checked_at item_start
  checked_at="$(date +%s)"
  item_start="$checked_at"
  LAST_ANALYZED_ELAPSED_SEC=0

  local q_curr_profile q_bitrate_profile q_codec_profile
  local -A q_album_summary=()
  audio_album_summary files q_album_summary
  q_curr_profile="${q_album_summary[source_quality]:-}"
  q_bitrate_profile="${q_album_summary[bitrate_label]:-}"
  q_codec_profile="${q_album_summary[codec_name]:-}"
  [[ -n "$q_curr_profile" ]] || q_curr_profile="?"
  [[ -n "$q_bitrate_profile" ]] || q_bitrate_profile="?"
  [[ -n "$q_codec_profile" ]] || q_codec_profile="unknown"

  if [[ "$q_curr_profile" == "mixed" || "$q_codec_profile" == "mixed" ]]; then
    local mixed_reason
    mixed_reason="mixed content detected: source_quality=$q_curr_profile codec=$q_codec_profile; replace source"
    record_mixed_content_failure "$artist" "$year" "$album" "$source_path" "$checked_at" "$q_codec_profile" "$q_bitrate_profile" "$mixed_reason"
    ALBUMS_SCAN_FAILED=$((ALBUMS_SCAN_FAILED + 1))
    ALBUMS_HIT=$((ALBUMS_HIT + 1))
    ROWS_UPSERTED=$((ROWS_UPSERTED + 1))
    mark_scan_kind_done "$scan_kind"
    local mixed_info
    mixed_info="$(task_album_info_text "$q_codec_profile" "$q_curr_profile")"
    local mixed_elapsed
    mixed_elapsed="$(( $(date +%s) - item_start ))"
    LAST_ANALYZED_ELAPSED_SEC="$mixed_elapsed"
    printf '%s[%s]%s [%02d] %-55s  %s  [%sFail%s]  %s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$C_RESET" "$ALBUMS_ANALYZED" "$display_name" "$mixed_info" "$C_YELLOW" "$C_RESET" \
      "$(task_elapsed_text "$mixed_elapsed")"
    return 0
  fi

  # Resolve genre profile: embedded tag takes priority (free, instant).
  # If no embedded tag exists, query MusicBrainz/Last.fm and write the
  # fetched genre tag back to every file in the album so future rescans
  # don't need a network call.
  local q_genre_profile="standard"
  local embedded_genre
  embedded_genre="$(kv_get "GENRE" "$probe_payload")"
  if [[ -n "$embedded_genre" ]]; then
    q_genre_profile="$(classify_genre_tag "$embedded_genre")"
  elif [[ -f "$GENRE_LOOKUP" ]]; then
    local _genre_lookup_out
    _genre_lookup_out="$("$PYTHON_BIN" "$GENRE_LOOKUP" "$artist" "$album" 2>/dev/null || true)"
    q_genre_profile="$(printf '%s\n' "$_genre_lookup_out" | head -n 1)"
    local _raw_genre_tag
    _raw_genre_tag="$(printf '%s\n' "$_genre_lookup_out" | sed -n '2p')"
    [[ "$q_genre_profile" =~ ^(audiophile|high_energy|standard)$ ]] || q_genre_profile="standard"
    # Write genre tag back to all album files so future rescans use embedded tag.
    # Re-stamp checked_at AFTER the tag writes so last_checked_at >= any file
    # mtime produced by the write, preventing the album from being re-queued
    # as "changed" on the next discovery pass.
    if [[ -n "$_raw_genre_tag" ]] && declare -f tag_write >/dev/null 2>&1; then
      if ! secure_backup_album_tracks_once "$source_path" "audlint-task genre-tag writeback"; then
        local backup_reason="${SECURE_BACKUP_LAST_ERROR:-secure backup failed before genre writeback}"
        record_scan_failure "$artist" "$year" "$album" "$source_path" "$checked_at" "$backup_reason"
        ALBUMS_SCAN_FAILED=$((ALBUMS_SCAN_FAILED + 1))
        ROWS_UPSERTED=$((ROWS_UPSERTED + 1))
        mark_scan_kind_done "$scan_kind"
        local backup_elapsed
        local backup_info
        backup_elapsed="$(( $(date +%s) - item_start ))"
        backup_info="$(task_album_info_text "$q_codec_profile" "$q_curr_profile")"
        LAST_ANALYZED_ELAPSED_SEC="$backup_elapsed"
        printf '%s[%s]%s [%02d] %-55s  %s  [%sFail%s]  %s\n' \
          "$C_CYAN" "$(date +%H:%M:%S)" "$C_RESET" "$ALBUMS_ANALYZED" "$display_name" \
          "$backup_info" "$C_YELLOW" "$C_RESET" \
          "$(task_elapsed_text "$backup_elapsed")"
        printf '%s          reason: %s%s\n' "$C_YELLOW" "$backup_reason" "$C_RESET"
        return 0
      fi
      local _f
      for _f in "${files[@]}"; do
        tag_write "$_f" "GENRE" "$_raw_genre_tag" 2>/dev/null || true
      done
      checked_at="$(date +%s)"
    fi
  fi

  local scan_out
  if ! scan_album_dir_merged "$source_path" "$q_genre_profile" "$prev_recode_source_profile" 2>/dev/null; then
    local failure_reason="$MERGE_LAST_ERROR"
    [[ -n "$failure_reason" ]] || failure_reason="quality scan failed"
    record_scan_failure "$artist" "$year" "$album" "$source_path" "$checked_at" "$failure_reason"
    ALBUMS_SCAN_FAILED=$((ALBUMS_SCAN_FAILED + 1))
    ROWS_UPSERTED=$((ROWS_UPSERTED + 1))
    mark_scan_kind_done "$scan_kind"
    local failure_elapsed
    local failure_info
    failure_elapsed="$(( $(date +%s) - item_start ))"
    failure_info="$(task_album_info_text "$q_codec_profile" "$q_curr_profile")"
    LAST_ANALYZED_ELAPSED_SEC="$failure_elapsed"
    printf '%s[%s]%s [%02d] %-55s  %s  [%sFail%s]  %s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$C_RESET" "$ALBUMS_ANALYZED" "$display_name" \
      "$failure_info" "$C_YELLOW" "$C_RESET" \
      "$(task_elapsed_text "$failure_elapsed")"
    printf '%s          reason: %s%s\n' "$C_YELLOW" "$failure_reason" "$C_RESET"
    return 0
  fi
  scan_out="$SCAN_LAST_OUT"

  local hit q_grade q_score q_dyn q_ups q_rec q_curr q_bitrate q_codec q_recode q_needs_recode q_genre q_recode_source_profile needs_replace
  hit="$(kv_get "HIT" "$scan_out")"
  q_grade="$(kv_get "GRADE" "$scan_out")"
  q_score="$(kv_get "SCORE" "$scan_out")"
  q_dyn="$(kv_get "DYN" "$scan_out")"
  q_ups="$(kv_get "UPS" "$scan_out")"
  q_rec="$(kv_get "REC" "$scan_out")"
  q_curr="$(kv_get "CURR" "$scan_out")"
  q_bitrate="$(kv_get "BITRATE" "$scan_out")"
  q_codec="$(kv_get "CODEC" "$scan_out")"
  q_recode="$(kv_get "RECODE" "$scan_out")"
  q_needs_recode="$(kv_get "NEEDS_RECODE" "$scan_out")"
  q_genre="$(kv_get "GENRE_PROFILE" "$scan_out")"
  q_recode_source_profile="$(kv_get "RECODE_SOURCE_PROFILE" "$scan_out")"
  [[ "$q_needs_recode" =~ ^[01]$ ]] || q_needs_recode=0
  [[ "$q_genre" =~ ^(audiophile|high_energy|standard)$ ]] || q_genre="$q_genre_profile"

  # DSD/ultra-hires source policy: flag as upscaled if DSD or >192k profile.
  if source_policy_force_upscale files "$q_curr"; then
    q_ups="1"
  fi

  # Stamp last_checked_at after the full scan path completes so discovery does
  # not immediately re-queue the same album when scan-side writes bump the
  # directory mtime during the run.
  checked_at="$(date +%s)"

  needs_replace=0
  if [[ "$hit" == "1" ]]; then
    needs_replace=1
  fi

  album_quality_upsert \
    "$DB_PATH" \
    "$artist" \
    "$year" \
    "$album" \
    "$q_grade" \
    "$q_score" \
    "$q_dyn" \
    "$q_ups" \
    "$q_rec" \
    "$needs_replace" \
    "$source_path" \
    "$checked_at" \
    "0" \
    "" \
    "$q_curr" \
    "$q_bitrate" \
    "$q_codec" \
    "$q_recode" \
    "$q_needs_recode" \
    "$q_genre" \
    "$q_recode_source_profile"

  ROWS_UPSERTED=$((ROWS_UPSERTED + 1))
  mark_scan_kind_done "$scan_kind"
  # Build a concise hint for the recode/action field (trim to keep lines readable).
  local _hint=""
  if [[ -n "$q_recode" && "$q_recode" != "Keep as-is" && "$q_recode" != "Keep"* ]]; then
    _hint="$(task_arrow_hint_text "$q_recode")"
  elif [[ -n "$q_rec" && "$q_rec" != "Keep"* ]]; then
    _hint="$(task_arrow_hint_text "$q_rec")"
  fi

  local _elapsed=$(( $(date +%s) - item_start ))
  local _info
  _info="$(task_album_info_text "$q_codec" "$q_curr" "$_hint")"
  LAST_ANALYZED_ELAPSED_SEC="$_elapsed"
  if [[ "$needs_replace" == "1" ]]; then
    ALBUMS_HIT=$((ALBUMS_HIT + 1))
    printf '%s[%s]%s [%02d] %-55s  %s  [%s%s%s]  %s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$C_RESET" "$ALBUMS_ANALYZED" "$display_name" \
      "$_info" "$C_YELLOW" "$q_grade" "$C_RESET" "$(task_elapsed_text "$_elapsed")"
  else
    ALBUMS_OK=$((ALBUMS_OK + 1))
    printf '%s[%s]%s [%02d] %-55s  %s  [%s%s%s]  %s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$C_RESET" "$ALBUMS_ANALYZED" "$display_name" \
      "$_info" "$C_GREEN" "$q_grade" "$C_RESET" "$(task_elapsed_text "$_elapsed")"
  fi
}

# deadline_reached — returns 0 (true) when MAX_TIME is set and fewer than
# DEADLINE_FINISH_BUFFER_SEC remain in the window.
deadline_remaining_sec() {
  ((MAX_TIME > 0)) || {
    printf '0\n'
    return 0
  }
  local now elapsed remaining
  now="$(date +%s)"
  elapsed=$(( now - T_START ))
  remaining=$(( MAX_TIME - elapsed ))
  printf '%s\n' "$remaining"
}

deadline_next_album_budget_sec() {
  local budget="$DEADLINE_NEXT_ALBUM_BUDGET_SEC"
  if [[ "$LAST_ANALYZED_ELAPSED_SEC" =~ ^[0-9]+$ ]] && ((LAST_ANALYZED_ELAPSED_SEC > budget)); then
    budget="$LAST_ANALYZED_ELAPSED_SEC"
  fi
  printf '%s\n' "$budget"
}

deadline_reached() {
  ((MAX_TIME > 0)) || return 1
  local remaining
  remaining="$(deadline_remaining_sec)"
  [[ "$remaining" =~ ^-?[0-9]+$ ]] || remaining=0
  ((remaining <= DEADLINE_FINISH_BUFFER_SEC))
}

# deadline_batch_guard_reached — returns 0 (true) when MAX_TIME is set and
# there is not enough time left to safely start another album.
deadline_batch_guard_reached() {
  ((MAX_TIME > 0)) || return 1
  local remaining next_budget required
  remaining="$(deadline_remaining_sec)"
  [[ "$remaining" =~ ^-?[0-9]+$ ]] || remaining=0
  next_budget="$(deadline_next_album_budget_sec)"
  [[ "$next_budget" =~ ^[0-9]+$ ]] || next_budget="$DEADLINE_NEXT_ALBUM_BUDGET_SEC"
  required=$(( DEADLINE_FINISH_BUFFER_SEC + next_budget + DEADLINE_MARGIN_SEC ))
  DEADLINE_GUARD_LAST_REMAINING="$remaining"
  DEADLINE_GUARD_LAST_REQUIRED="$required"
  DEADLINE_GUARD_LAST_NEXT_BUDGET="$next_budget"
  (( remaining <= required ))
}

process_scan_roadmap_batch() {
  local batch_limit="${1:-$MAX_ALBUMS}"
  local pending_count skipped_now
  if [[ ! "$batch_limit" =~ ^[0-9]+$ ]] || ((batch_limit <= 0)); then
    batch_limit="$MAX_ALBUMS"
  fi
  if [[ ! "$batch_limit" =~ ^[0-9]+$ ]] || ((batch_limit <= 0)); then
    return 0
  fi

  pending_count="$(scan_roadmap_count)"
  if ((pending_count <= 0)); then
    return 0
  fi
  if ((pending_count > batch_limit)); then
    skipped_now=$((pending_count - batch_limit))
    if ((skipped_now > ALBUMS_SKIPPED_LIMIT)); then
      ALBUMS_SKIPPED_LIMIT="$skipped_now"
    fi
  fi

  # Process one item at a time so purged slots are immediately refilled
  # and the deadline check can stop cleanly between albums.
  local roadmap_id artist year album source_path scan_kind row
  local analyzed_this_batch=0
  while ((analyzed_this_batch < batch_limit)); do
    if deadline_batch_guard_reached; then
      log "Deadline pacing guard reached (remaining=${DEADLINE_GUARD_LAST_REMAINING}s required=${DEADLINE_GUARD_LAST_REQUIRED}s finish_buffer=${DEADLINE_FINISH_BUFFER_SEC}s next_budget=${DEADLINE_GUARD_LAST_NEXT_BUDGET}s margin=${DEADLINE_MARGIN_SEC}s). Stopping batch cleanly."
      break
    fi

    row="$(scan_roadmap_next_item)"
    [[ -n "$row" ]] || break

    IFS=$'\t' read -r roadmap_id artist year album source_path scan_kind <<< "$row"
    [[ "$roadmap_id" =~ ^[0-9]+$ ]] || break
    [[ "$year" =~ ^[0-9]+$ ]] || year=0
    [[ -n "$scan_kind" ]] || scan_kind="changed"

    local _before_analyzed="$ALBUMS_ANALYZED"
    process_scan_roadmap_item "$artist" "$year" "$album" "$source_path" "$scan_kind" || return 1
    scan_roadmap_delete_item "$roadmap_id" || return 1
    if ((ALBUMS_ANALYZED > _before_analyzed)); then
      analyzed_this_batch=$(( analyzed_this_batch + 1 ))
    fi
  done
}

if [[ "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
  --help)
    show_help
    exit 0
    ;;
  --max-albums)
    shift
    value="${1:-}"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ || "$value" == "0" ]]; then
      echo "Error: --max-albums requires integer >= 1" >&2
      exit 2
    fi
    MAX_ALBUMS="$value"
    ;;
  --max-albums=*)
    value="${1#*=}"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ || "$value" == "0" ]]; then
      echo "Error: --max-albums requires integer >= 1" >&2
      exit 2
    fi
    MAX_ALBUMS="$value"
    ;;
  --max-time)
    shift
    value="${1:-}"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
      echo "Error: --max-time requires integer >= 0" >&2
      exit 2
    fi
    MAX_TIME="$value"
    ;;
  --max-time=*)
    value="${1#*=}"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
      echo "Error: --max-time requires integer >= 0" >&2
      exit 2
    fi
    MAX_TIME="$value"
    ;;
  --purge-missing)
    PURGE_MISSING=true
    ;;
  --dry-run)
    DRY_RUN=true
    ;;
  --full-discovery)
    FULL_DISCOVERY=true
    ;;
  -* )
    show_help
    exit 2
    ;;
  *)
    if [[ -n "$ROOT" ]]; then
      show_help
      exit 2
    fi
    ROOT="$1"
    ;;
  esac
  shift || true
done

if [[ -z "$ROOT" ]]; then
  show_help
  exit 2
fi

normalize_nonneg_int DEADLINE_FINISH_BUFFER_SEC 120
normalize_nonneg_int DEADLINE_NEXT_ALBUM_BUDGET_SEC 120
normalize_nonneg_int DEADLINE_MARGIN_SEC 10

DB_PATH="$(resolve_library_db_path || true)"
if [[ -z "$DB_PATH" ]]; then
  echo "Error: AUDL_DB_PATH is not set. Example: AUDL_DB_PATH='\$AUDL_PATH/library.sqlite'" >&2
  exit 2
fi

if [[ ! -d "$ROOT" || ! -r "$ROOT" || ! -w "$ROOT" ]]; then
  log "Skip: library root unavailable/unwritable: $ROOT"
  exit 0
fi

DB_DIR="$(dirname "$DB_PATH")"
if [[ ! -d "$DB_DIR" || ! -r "$DB_DIR" || ! -w "$DB_DIR" ]]; then
  log "Skip: DB directory unavailable/unwritable: $DB_DIR"
  exit 0
fi

if [[ -e "$DB_PATH" ]]; then
  if [[ ! -r "$DB_PATH" || ! -w "$DB_PATH" ]]; then
    log "Skip: DB file unavailable/unwritable: $DB_PATH"
    exit 0
  fi
fi

if ! has_bin sqlite3; then
  echo "Error: sqlite3 not found" >&2
  exit 1
fi
for dep in ffmpeg ffprobe; do
  has_bin "$dep" || {
    echo "Error: $dep not found" >&2
    exit 1
  }
done

select_python_with_numpy
if ! album_quality_db_init "$DB_PATH"; then
  echo "Error: failed to initialize album_quality in DB: $DB_PATH" >&2
  exit 1
fi
if ! scan_roadmap_db_init "$DB_PATH"; then
  echo "Error: failed to initialize scan_roadmap in DB: $DB_PATH" >&2
  exit 1
fi
album_quality_db_backup "$DB_PATH" "${ALBUM_QUALITY_DB_SCHEMA_CHANGED:-0}" || {
  echo "Error: DB integrity check failed — aborting to protect backups." >&2
  exit 1
}

# Expand configured cache path (if provided) and otherwise derive a stable
# per-DB cache path next to the DB so it survives reboot/temp cleanup.
if [[ -n "$DISCOVERY_CACHE_FILE" ]]; then
  DISCOVERY_CACHE_FILE="$(env_expand_value "$DISCOVERY_CACHE_FILE")"
fi
if [[ -z "$DISCOVERY_CACHE_FILE" ]]; then
  _db_cache_dir="$(dirname "$DB_PATH")"
  _db_cache_base="$(basename "$DB_PATH")"
  DISCOVERY_CACHE_FILE="${_db_cache_dir}/.audlint_task_last_discovery_${_db_cache_base}"
  unset _db_cache_dir _db_cache_base
fi

if [[ "$PURGE_MISSING" == true ]]; then
  run_purge_missing "$DRY_RUN" "$DB_PATH" "$ROOT"
  exit $?
fi

if ! acquire_scan_lock_or_skip; then
  exit 0
fi

# Optional throughput profile for backlog catch-up: reduce audlint-analyze FFT
# workload by lowering window count and window duration.
[[ "$FFT_FAST_MAX_WINDOWS" =~ ^[0-9]+$ ]] || FFT_FAST_MAX_WINDOWS=8
if ((FFT_FAST_MAX_WINDOWS <= 0)); then
  FFT_FAST_MAX_WINDOWS=8
fi
if [[ ! "$FFT_FAST_WINDOW_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  FFT_FAST_WINDOW_SEC=6
fi
case "${FFT_FAST_MODE,,}" in
1 | true | yes | on)
  FFT_FAST_MODE=1
  export AUDLINT_ANALYZE_MAX_WINDOWS="$FFT_FAST_MAX_WINDOWS"
  export AUDLINT_ANALYZE_WINDOW_SEC="$FFT_FAST_WINDOW_SEC"
  ;;
*)
  FFT_FAST_MODE=0
  ;;
esac

T_START="$(date +%s)"
log "Start. root=$(path_resolve "$ROOT" 2>/dev/null || printf '%s' "$ROOT") db=$DB_PATH max_albums=$MAX_ALBUMS max_time=${MAX_TIME}s"
if ((MAX_TIME > 0)); then
  log "Deadline pacing: finish_buffer=${DEADLINE_FINISH_BUFFER_SEC}s next_album_budget=${DEADLINE_NEXT_ALBUM_BUDGET_SEC}s margin=${DEADLINE_MARGIN_SEC}s"
fi
if [[ "$FFT_FAST_MODE" == "1" ]]; then
  log "FFT fast mode enabled: AUDLINT_ANALYZE_MAX_WINDOWS=$AUDLINT_ANALYZE_MAX_WINDOWS AUDLINT_ANALYZE_WINDOW_SEC=$AUDLINT_ANALYZE_WINDOW_SEC"
fi

ALBUMS_SCANNED=0
ALBUMS_ANALYZED=0
ALBUMS_NEW_DONE=0
ALBUMS_CHANGED_DONE=0
ALBUMS_OK=0
ALBUMS_HIT=0
ALBUMS_SCAN_FAILED=0
ALBUMS_SKIPPED_UNCHANGED=0
ALBUMS_SKIPPED_FAIL_HOLD=0
ALBUMS_SKIPPED_LIMIT=0
ALBUMS_SKIPPED_NO_KEY=0
ROWS_UPSERTED=0
ROADMAP_ENQUEUED_NEW=0
ROADMAP_ENQUEUED_CHANGED=0
ROADMAP_DISCOVERY_RUN=0

pending_before="$(scan_roadmap_count)"
[[ "$pending_before" =~ ^[0-9]+$ ]] || pending_before=0
pending_after_initial="$pending_before"
remaining_budget="$MAX_ALBUMS"
[[ "$remaining_budget" =~ ^[0-9]+$ ]] || remaining_budget=0

T_BATCH1_START="$(date +%s)"
if ((pending_before > 0)); then
  log "Phase 1/3: roadmap batch. pending=$pending_before elapsed=$(elapsed_s)s"
  if ! process_scan_roadmap_batch "$remaining_budget"; then
    exit 1
  fi
  remaining_budget=$((MAX_ALBUMS - ALBUMS_ANALYZED))
  if ((remaining_budget < 0)); then
    remaining_budget=0
  fi
  pending_after_initial="$(scan_roadmap_count)"
  [[ "$pending_after_initial" =~ ^[0-9]+$ ]] || pending_after_initial=0
  log "Phase 1/3: roadmap batch done. analyzed=$ALBUMS_ANALYZED remaining_budget=$remaining_budget elapsed=$(elapsed_s)s phase_elapsed=$(( $(date +%s) - T_BATCH1_START ))s"
else
  log "Phase 1/3: roadmap batch skipped (queue empty). elapsed=$(elapsed_s)s"
fi

pending_after_discovery="$pending_after_initial"
if deadline_reached; then
  log "Phase 2/3: discovery skipped (deadline reached). elapsed=$(elapsed_s)s"
else
  ROADMAP_DISCOVERY_RUN=1
  T_DISCOVERY_START="$(date +%s)"
  log "Phase 2/3: discovery pass. elapsed=$(elapsed_s)s"
  if ! discover_scan_roadmap; then
    exit 1
  fi

  pending_after_discovery="$(scan_roadmap_count)"
  [[ "$pending_after_discovery" =~ ^[0-9]+$ ]] || pending_after_discovery=0
  log "Phase 2/3: discovery done. roadmap_pending=$pending_after_discovery new_enqueued=$ROADMAP_ENQUEUED_NEW changed_enqueued=$ROADMAP_ENQUEUED_CHANGED skipped_unchanged=$ALBUMS_SKIPPED_UNCHANGED elapsed=$(elapsed_s)s phase_elapsed=$(( $(date +%s) - T_DISCOVERY_START ))s"
fi

T_BATCH2_START="$(date +%s)"
newly_discovered=$(( ROADMAP_ENQUEUED_NEW + ROADMAP_ENQUEUED_CHANGED ))
if deadline_reached; then
  log "Phase 3/3: skipped (deadline reached). elapsed=$(elapsed_s)s"
elif ((remaining_budget > 0 && (pending_after_discovery > 0) && (pending_before == 0 || newly_discovered > 0))); then
  log "Phase 3/3: post-discovery batch. pending=$pending_after_discovery newly_discovered=$newly_discovered budget=$remaining_budget elapsed=$(elapsed_s)s"
  if ! process_scan_roadmap_batch "$remaining_budget"; then
    exit 1
  fi
  log "Phase 3/3: post-discovery batch done. analyzed=$ALBUMS_ANALYZED elapsed=$(elapsed_s)s phase_elapsed=$(( $(date +%s) - T_BATCH2_START ))s"
else
  log "Phase 3/3: skipped (no new items discovered or budget exhausted). elapsed=$(elapsed_s)s"
fi

pending_after_run="$(scan_roadmap_count)"
[[ "$pending_after_run" =~ ^[0-9]+$ ]] || pending_after_run=0

log "Done. elapsed=$(elapsed_s)s albums_scanned=$ALBUMS_SCANNED albums_analyzed=$ALBUMS_ANALYZED albums_new_done=$ALBUMS_NEW_DONE albums_changed_done=$ALBUMS_CHANGED_DONE albums_ok=$ALBUMS_OK albums_hit(replace)=$ALBUMS_HIT albums_scan_failed=$ALBUMS_SCAN_FAILED albums_skipped(unchanged)=$ALBUMS_SKIPPED_UNCHANGED albums_skipped(fail_hold)=$ALBUMS_SKIPPED_FAIL_HOLD albums_skipped(no_key)=$ALBUMS_SKIPPED_NO_KEY albums_skipped(limit)=$ALBUMS_SKIPPED_LIMIT rows_upserted=$ROWS_UPSERTED roadmap_pending=$pending_after_run roadmap_discovery_run=$ROADMAP_DISCOVERY_RUN"
