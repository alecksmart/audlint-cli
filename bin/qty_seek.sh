#!/opt/homebrew/bin/bash
# qty_seek.sh - Cron-oriented library quality scanner.
# Scans albums, merges tracks to a temporary stream, evaluates quality,
# and upserts album_quality rows in LIBRARY_DB.

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

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path

PY_HELPER="${SCRIPT_DIR}/spectre_eval.py"
GENRE_LOOKUP="${SCRIPT_DIR}/../lib/py/genre_lookup.py"
TAG_WRITER="${SCRIPT_DIR}/tag_writer.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"
# shellcheck source=/dev/null
[[ -f "$TAG_WRITER" ]] && source "$TAG_WRITER"
NO_COLOR="${NO_COLOR:-}"
MAX_ALBUMS=50
ROOT=""
PURGE_MISSING=false
DRY_RUN=false
FULL_DISCOVERY=false
# Discovery timestamp cache: written after each successful discovery pass so the
# next run can skip dirs whose mtime predates it (incremental walk).
# Override via env var; includes a DB-path suffix to avoid collisions.
DISCOVERY_CACHE_FILE=""   # resolved at runtime after DB_PATH is known
# How many seconds to hold off re-queuing a scan_failed album (default 7 days).
SCAN_FAIL_RETRY_SEC="${QTY_SEEK_SCAN_FAIL_RETRY_SEC:-$((7 * 86400))}"
LOCK_DIR="${QTY_SEEK_LOCK_DIR:-${TMPDIR:-/tmp}/qty_seek.lock}"
LOCK_ACQUIRED=false
MERGE_LAST_ERROR=""
SCAN_LAST_OUT=""
MERGE_PCM_MAX_BYTES="${QTY_SEEK_MERGE_PCM_MAX_BYTES:-3800000000}"
MERGE_SAMPLE_RATIO="${QTY_SEEK_MERGE_SAMPLE_RATIO:-0.25}"
MERGE_SAMPLE_MIN_TRACKS="${QTY_SEEK_MERGE_SAMPLE_MIN_TRACKS:-4}"
MERGE_SAMPLE_MAX_TRACKS="${QTY_SEEK_MERGE_SAMPLE_MAX_TRACKS:-5}"
declare -A AQ_LAST_CHECKED=()
declare -A AQ_SCAN_FAILED=()
declare -A AQ_SOURCE_PATH_CHECKED=()  # source_path → last_checked_at; used for dir-mtime fast-path

show_help() {
  cat <<EOF_HELP
Quick use:
  $(basename "$0") --max-albums 15 /Volumes/Music/Library

Usage:
  $(basename "$0") [--max-albums N] [--full-discovery] <library_root>
  $(basename "$0") --purge-missing [--dry-run] <library_root>

Mode:
  Cron scan only. This script is intended for scheduled library scans.
  Quality is evaluated from merged album streams only (no per-track fallback).
  Albums are scanned in priority order:
    1) albums not present in album_quality
    2) albums changed since album row last_checked_at

Discovery:
  By default, after the first run a timestamp cache file is written to
  /tmp/qty_seek_last_discovery_<db-slug>. Subsequent runs use
  'find -newer <cache>' to walk only directories modified since the last
  discovery pass, greatly reducing disk I/O on large libraries.
  Use --full-discovery to force a complete walk (e.g. after adding
  a large batch of albums or when the cache file is stale/missing).

  Failed albums (scan_failed=1) are held for QTY_SEEK_SCAN_FAIL_RETRY_SEC
  seconds (default: 7 days) before being re-queued, to avoid hammering
  chronic scan failures on every cron run.

Purge mode (--purge-missing):
  Remove album_quality rows whose source_path no longer exists on disk.
  Requires the library root to be readable and writable (guards against
  unmounted volumes). Prompts for confirmation before deleting.
  Use --dry-run to preview without making any changes.

Cron example:
  PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ; ~/bin/qty_seek.sh --max-albums 15 /Volumes/Music/Library >> "\$HOME/qty_seek.log" 2>&1
EOF_HELP
}

log() { log_ts "$@"; }
elapsed_s() { echo $(( $(date +%s) - T_START )); }

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
else
  C_RESET=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

kv_get() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | awk -v k="$key" '$0 ~ ("^" k "=") { sub("^[^=]*=", "", $0); print; exit }'
}

# classify_genre_tag is provided by lib/sh/audio.sh (audio_classify_genre_tag).
# Local alias for backward compatibility within this script.
classify_genre_tag() { audio_classify_genre_tag "$@"; }

# Aliases — canonical implementations live in lib/sh/audio.sh.
is_lossy_codec()             { audio_is_lossy_codec "$@"; }
source_quality_label()       { audio_source_quality_label "$@"; }

source_bitrate_kbps() {
  local in="$1"
  local raw
  raw="$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  raw="${raw%%,*}"
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ ! "$raw" =~ ^[0-9]+$ || "$raw" == "0" ]]; then
    raw="$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
    raw="${raw%%,*}"
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  if [[ "$raw" =~ ^[0-9]+$ && "$raw" != "0" ]]; then
    printf '%s\n' "$(((raw + 500) / 1000))"
    return 0
  fi
  printf ''
}

album_bitrate_label() {
  local files_var="$1"
  local -n files_ref="$files_var"
  local f kbps total=0 count=0 avg=0
  for f in "${files_ref[@]}"; do
    kbps="$(source_bitrate_kbps "$f" || true)"
    if [[ "$kbps" =~ ^[0-9]+$ && "$kbps" != "0" ]]; then
      total=$((total + kbps))
      count=$((count + 1))
    fi
  done
  if ((count == 0)); then
    printf ''
    return 0
  fi
  avg=$(((total + (count / 2)) / count))
  printf '%sk\n' "$avg"
}

album_source_quality_label() { audio_album_source_quality_label "$@"; }

album_codec_label() {
  local files_var="$1"
  local -n files_ref="$files_var"
  local first="" codec f
  for f in "${files_ref[@]}"; do
    codec="$(audio_codec_name "$f")"
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

album_has_lossy_codec() {
  local files_var="$1"
  local -n files_ref="$files_var"
  local codec f
  for f in "${files_ref[@]}"; do
    codec="$(audio_codec_name "$f")"
    if is_lossy_codec "$codec"; then
      return 0
    fi
  done
  return 1
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

profile_triggers_forced_upscale() {
  local profile="$1"
  local sr_label bit_label bit_norm
  if [[ "$profile" != */* ]]; then
    return 1
  fi

  sr_label="${profile%%/*}"
  bit_label="${profile##*/}"
  sr_label="$(printf '%s' "$sr_label" | tr -d '[:space:]')"
  bit_label="$(printf '%s' "$bit_label" | tr -d '[:space:]')"
  bit_norm="${bit_label,,}"

  # 32f (float FLAC) is a lossless container semantically equivalent to 24-bit;
  # it is commonly produced by DAW exports and does not indicate upsampling.
  case "$bit_norm" in
  32 | 64 | 64f) return 0 ;;
  esac
  if [[ "$bit_norm" =~ ^[0-9]+$ ]] && ((bit_norm > 24)); then
    return 0
  fi

  # Hi-res sample rate with 16-bit depth is almost certainly an upsampled CD.
  if [[ "$bit_norm" == "16" ]]; then
    if awk -v s="$sr_label" 'BEGIN{ exit (!(s ~ /^[0-9]+([.][0-9]+)?$/ && s >= 88.2)) }'; then
      return 0
    fi
  fi

  awk -v s="$sr_label" 'BEGIN{ exit (!(s ~ /^[0-9]+([.][0-9]+)?$/ && s > 192.0)) }'
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
  local raw="${LIBRARY_DB:-}"
  if [[ -z "$raw" && -n "${SRC:-}" ]]; then
    raw="$SRC/library.sqlite"
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

  log "Skip: previous qty_seek run still in progress (lock: $LOCK_DIR)"
  return 1
}

ffmpeg_concat_escape_path() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

stat_epoch_mtime() {
  local path="$1"
  local out=""
  if out="$(stat -f '%m' "$path" 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi
  if out="$(stat -c '%Y' "$path" 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
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
  case "$1" in
  s16 | s16p) printf '16' ;;
  s24 | s24p) printf '24' ;;
  s32 | s32p) printf '32' ;;
  flt | fltp) printf '32' ;;
  dbl | dblp) printf '64' ;;
  *) printf '24' ;;
  esac
}

source_bit_depth_bits() {
  local in="$1"
  local bps sfmt
  bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  bps="${bps%%,*}"
  if [[ "$bps" =~ ^[0-9]+$ ]] && ((bps > 0)); then
    printf '%s\n' "$bps"
    return 0
  fi
  sfmt="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  sfmt="${sfmt%%,*}"
  sample_fmt_to_bits "$sfmt"
}

source_duration_seconds() {
  local in="$1"
  local dur
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  dur="${dur%%,*}"
  if [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "$dur"
  else
    printf '0\n'
  fi
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
  sr_hz="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$first" </dev/null 2>/dev/null || true)"
  sr_hz="${sr_hz%%,*}"
  ch="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$first" </dev/null 2>/dev/null || true)"
  ch="${ch%%,*}"
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

is_replace_recommendation() {
  case "$1" in
  Keep) return 1 ;;
  *) return 0 ;;
  esac
}

quality_requires_replacement() {
  local grade="$1"
  local rec="$2"
  if [[ -n "$rec" ]] && is_replace_recommendation "$rec"; then
    return 0
  fi
  case "$grade" in
  C | F) return 0 ;;
  *) return 1 ;;
  esac
}

recode_is_actionable() {
  local recode="$1"
  [[ -n "$recode" ]] || return 1
  case "$recode" in
  "Keep as-is" | "Mastering issue"* | "Pending rescan"*) return 1 ;;
  *) return 0 ;;
  esac
}

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

merged_spectral_recommendation() {
  local merged_file="$1"
  local tmpdir="$2"

  local sr dur start_sec excerpt eval_out rec
  sr="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$merged_file" </dev/null 2>/dev/null || true)"
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$merged_file" </dev/null 2>/dev/null || true)"
  sr="${sr%%,*}"
  dur="${dur%%,*}"
  [[ "$sr" =~ ^[0-9]+$ ]] || return 1

  start_sec="$(awk -v d="${dur:-0}" 'BEGIN{s=(d>60)?(d/2 - 30):0; printf "%.3f", s}')"
  excerpt="$tmpdir/merged-excerpt.wav"
  ffmpeg -y -hide_banner -loglevel error -nostdin -ss "$start_sec" -t 60 -i "$merged_file" -ac 1 -c:a pcm_s24le "$excerpt" </dev/null || return 1

  eval_out="$("$PYTHON_BIN" "$PY_HELPER" "$excerpt" "$sr" "0" </dev/null 2>/dev/null || true)"
  rec="$(kv_get "RECOMMEND" "$eval_out")"
  [[ -n "$rec" ]] || return 1
  printf '%s\n' "$rec"
}

scan_album_dir_merged() {
  local dir="$1"
  local genre_profile="${2:-standard}"
  SCAN_LAST_OUT=""
  local files=()
  collect_qty_audio_files "$dir" files
  [[ ${#files[@]} -gt 0 ]] || return 2
  local merge_files=()
  merge_files=("${files[@]}")
  select_merge_sample_files files merge_files || true

  local tmpdir=""
  tmpdir="$(mktemp -d 2>/dev/null || true)"
  [[ -n "$tmpdir" && -d "$tmpdir" ]] || {
    MERGE_LAST_ERROR="mktemp -d failed"
    return 1
  }

  local concat_list="$tmpdir/concat.txt"
  local merged_file="$tmpdir/album-merged.wav"
  local f escaped

  for f in "${merge_files[@]}"; do
    escaped="$(ffmpeg_concat_escape_path "$f")"
    printf "file '%s'\n" "$escaped" >>"$concat_list"
  done

  if ! run_ffmpeg_concat_merge "$concat_list" "$merged_file"; then
    local _merge_err="$MERGE_LAST_ERROR"
    # Probe each file individually to identify the bad track.
    local _bad_track=""
    for f in "${merge_files[@]}"; do
      if ! ffprobe -v error -i "$f" -select_streams a -show_entries stream=codec_name -of default=noprint_wrappers=1 </dev/null >/dev/null 2>&1; then
        _bad_track="$(basename "$f")"
        break
      fi
    done
    if [[ -n "$_bad_track" ]]; then
      MERGE_LAST_ERROR="ffmpeg merge failed at track: $_bad_track (${_merge_err:-ffmpeg error})"
    else
      [[ -n "$MERGE_LAST_ERROR" ]] || MERGE_LAST_ERROR="${_merge_err:-ffmpeg merge failed (all tracks probe ok — format incompatibility?)}"
    fi
    rm -rf "$tmpdir"
    return 1
  fi
  if [[ ! -s "$merged_file" ]]; then
    [[ -n "$MERGE_LAST_ERROR" ]] || MERGE_LAST_ERROR="ffmpeg produced empty output"
    rm -rf "$tmpdir"
    return 1
  fi

  local out=""
  if ! out=$("$PYTHON_BIN" "$PY_HELPER" --quality "$merged_file" "--genre-profile=${genre_profile}" </dev/null 2>/dev/null); then
    MERGE_LAST_ERROR="quality evaluation failed"
    rm -rf "$tmpdir"
    return 1
  fi

  local grade score dyn ups rec hit recode_rec source_quality bitrate_label codec_name has_lossy
  grade="$(kv_get "MASTERING_GRADE" "$out")"
  score="$(kv_get "QUALITY_SCORE" "$out")"
  dyn="$(kv_get "DYNAMIC_RANGE_SCORE" "$out")"
  ups="$(kv_get "IS_UPSCALED" "$out")"
  rec="$(kv_get "RECOMMENDATION" "$out")"
  recode_rec="$(merged_spectral_recommendation "$merged_file" "$tmpdir" || true)"
  source_quality="$(album_source_quality_label files || true)"
  bitrate_label="$(album_bitrate_label files || true)"
  codec_name="$(album_codec_label files || true)"
  has_lossy=0
  if album_has_lossy_codec files; then
    has_lossy=1
  fi
  [[ -n "$source_quality" ]] || source_quality="?"
  [[ -n "$bitrate_label" ]] || bitrate_label="?"
  [[ -n "$codec_name" ]] || codec_name="unknown"

  # Adjust recode bit depth: don't suggest /24 when source is 16-bit lossless.
  if [[ "$source_quality" == *"/16" && -n "$recode_rec" && "$recode_rec" == *"/24"* ]]; then
    recode_rec="${recode_rec//\/24/\/16}"
  fi

  # Suppress no-op recode when lossless source already matches the target profile.
  # Normalize 32f (float FLAC) to 24-bit for comparison purposes: a 44.1/32f source
  # is functionally identical to 44.1/24 and should not be recoded to 24-bit.
  if [[ -n "$recode_rec" && "$recode_rec" == *"Store as "* && "$source_quality" != "?" ]]; then
    local recode_target="${recode_rec##*Store as }"
    recode_target="${recode_target%%[[:space:]]*}"
    local source_quality_norm="${source_quality//\/32f/\/24}"
    if [[ "$recode_target" == "$source_quality_norm" ]]; then
      if [[ "$rec" == "Trash" || "$grade" == "F" ]]; then
        recode_rec="Mastering issue — recode won't help"
      else
        recode_rec="Keep as-is"
      fi
    fi
  fi

  hit=0
  if quality_requires_replacement "$grade" "$rec"; then
    hit=1
  fi
  if ((has_lossy == 1)); then
    hit=1
    rec="Replace with Lossless Rip"
    [[ -n "$recode_rec" ]] || recode_rec="Lossy source detected -> replace with lossless rip"
  fi

  local needs_recode=0
  if recode_is_actionable "$recode_rec"; then
    needs_recode=1
  fi

  printf -v SCAN_LAST_OUT '%s\n' \
    "HIT=$hit" \
    "GRADE=$grade" \
    "SCORE=$score" \
    "DYN=$dyn" \
    "UPS=$ups" \
    "REC=$rec" \
    "CURR=$source_quality" \
    "BITRATE=$bitrate_label" \
    "CODEC=$codec_name" \
    "RECODE=$recode_rec" \
    "NEEDS_RECODE=$needs_recode" \
    "GENRE_PROFILE=$genre_profile"

  rm -rf "$tmpdir"
  return 0
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
  IFS= read -r answer </dev/tty || true
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
    "Mixed content detected -> replace source (merge disabled)" \
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

  # Fast-path: if this directory's mtime hasn't advanced past its last_checked_at
  # timestamp we know no file inside it changed.  Skip ffprobe and file globbing
  # entirely — one stat(2) on the directory inode is all we need.
  if [[ -n "${AQ_SOURCE_PATH_CHECKED["$dir"]+x}" ]]; then
    local _dir_mtime _dir_last_checked
    _dir_mtime="$(stat_epoch_mtime "$dir" || echo 0)"
    [[ "$_dir_mtime" =~ ^[0-9]+$ ]] || _dir_mtime=0
    _dir_last_checked="${AQ_SOURCE_PATH_CHECKED["$dir"]}"
    [[ "$_dir_last_checked" =~ ^[0-9]+$ ]] || _dir_last_checked=0
    if ((_dir_mtime > 0 && _dir_last_checked > 0 && _dir_mtime <= _dir_last_checked)); then
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
  if ((in_db == 1 && row_checked > 0 && album_mtime <= row_checked)); then
    ALBUMS_SKIPPED_UNCHANGED=$((ALBUMS_SKIPPED_UNCHANGED + 1))
    return 0
  fi

  local scan_kind="new"
  if ((in_db == 1)); then
    scan_kind="changed"
  fi

  scan_roadmap_enqueue "$artist" "$artist_lc" "$album" "$album_lc" "$year" "$dir" "$album_mtime" "$scan_kind" || return 1
  if [[ "$scan_kind" == "new" ]]; then
    ROADMAP_ENQUEUED_NEW=$((ROADMAP_ENQUEUED_NEW + 1))
  else
    ROADMAP_ENQUEUED_CHANGED=$((ROADMAP_ENQUEUED_CHANGED + 1))
  fi
}

discover_scan_roadmap() {
  load_album_quality_cache

  # Incremental mode: if a discovery cache file exists and --full-discovery was
  # not requested, only walk directories whose mtime is newer than the cache
  # timestamp.  This avoids a full stat(2) pass on large libraries every cron run.
  local use_incremental=false
  if [[ "$FULL_DISCOVERY" == false && -f "$DISCOVERY_CACHE_FILE" ]]; then
    use_incremental=true
  fi

  if [[ "$use_incremental" == true ]]; then
    log "Discovery: incremental (cache=$DISCOVERY_CACHE_FILE)"
    local dir
    while IFS= read -r -d '' dir <&3; do
      discover_scan_roadmap_item "$dir"
      local cb_status=$?
      case "$cb_status" in
      0 | 1) ;;
      *) return "$cb_status" ;;
      esac
    done 3< <(find "$ROOT" -type d \( -name ".__qty_seek_no_prune__" -prune \) \
                  -o -type d -newer "$DISCOVERY_CACHE_FILE" -print0)
  else
    [[ "$FULL_DISCOVERY" == true ]] && log "Discovery: full (--full-discovery requested)" \
      || log "Discovery: full (no cache file yet)"
    seek_walk_dirs "$ROOT" discover_scan_roadmap_item ".__qty_seek_no_prune__"
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
  local display_name
  display_name="$artist - $album"

  if [[ ! -d "$source_path" || ! -r "$source_path" ]]; then
    log "Skip queue item (path unavailable): $display_name -> $source_path"
    return 0
  fi

  local files=()
  collect_qty_audio_files "$source_path" files
  if [[ ${#files[@]} -eq 0 ]]; then
    log "Skip queue item (no audio now): $display_name -> $source_path"
    return 0
  fi

  ALBUMS_ANALYZED=$((ALBUMS_ANALYZED + 1))
  local checked_at
  checked_at="$(date +%s)"

  local q_curr_profile q_bitrate_profile q_codec_profile
  q_curr_profile="$(album_source_quality_label files || true)"
  q_bitrate_profile="$(album_bitrate_label files || true)"
  q_codec_profile="$(album_codec_label files || true)"
  [[ -n "$q_curr_profile" ]] || q_curr_profile="?"
  [[ -n "$q_bitrate_profile" ]] || q_bitrate_profile="?"
  [[ -n "$q_codec_profile" ]] || q_codec_profile="unknown"

  if [[ "$q_curr_profile" == "mixed" || "$q_codec_profile" == "mixed" ]]; then
    local mixed_reason
    mixed_reason="mixed content detected: source_quality=$q_curr_profile codec=$q_codec_profile; merge disabled; replace source"
    record_mixed_content_failure "$artist" "$year" "$album" "$source_path" "$checked_at" "$q_codec_profile" "$q_bitrate_profile" "$mixed_reason"
    ALBUMS_SCAN_FAILED=$((ALBUMS_SCAN_FAILED + 1))
    ALBUMS_HIT=$((ALBUMS_HIT + 1))
    ROWS_UPSERTED=$((ROWS_UPSERTED + 1))
    mark_scan_kind_done "$scan_kind"
    local mixed_info="${q_codec_profile} ${q_curr_profile}"
    printf '%s[%s] [%02d] %-55s  %s  [%sMixed/Fail%s]%s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$ALBUMS_ANALYZED" "$display_name" "$mixed_info" "$C_YELLOW" "$C_RESET" "$C_RESET"
    return 0
  fi

  # Resolve genre profile: embedded tag takes priority (free, instant).
  # If no embedded tag exists, query MusicBrainz/Last.fm and write the
  # fetched genre tag back to every file in the album so future rescans
  # don't need a network call.
  local q_genre_profile="standard"
  local embedded_genre
  embedded_genre="$(kv_get "GENRE" "$(ffprobe_album_key "${files[0]}" 2>/dev/null || true)")"
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
      local _f
      for _f in "${files[@]}"; do
        tag_write "$_f" "GENRE" "$_raw_genre_tag" 2>/dev/null || true
      done
      checked_at="$(date +%s)"
    fi
  fi

  local scan_out
  if ! scan_album_dir_merged "$source_path" "$q_genre_profile" 2>/dev/null; then
    local failure_reason="$MERGE_LAST_ERROR"
    [[ -n "$failure_reason" ]] || failure_reason="merged quality scan failed"
    record_scan_failure "$artist" "$year" "$album" "$source_path" "$checked_at" "$failure_reason"
    ALBUMS_SCAN_FAILED=$((ALBUMS_SCAN_FAILED + 1))
    ROWS_UPSERTED=$((ROWS_UPSERTED + 1))
    mark_scan_kind_done "$scan_kind"
    printf '%s[%s] [%02d] %-55s  %s %s  [%sFail%s]%s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$ALBUMS_ANALYZED" "$display_name" \
      "$q_codec_profile" "$q_curr_profile" \
      "$C_YELLOW" "$C_RESET" "$C_RESET"
    printf '%s          reason: %s%s\n' "$C_YELLOW" "$failure_reason" "$C_RESET"
    return 0
  fi
  scan_out="$SCAN_LAST_OUT"

  local hit q_grade q_score q_dyn q_ups q_rec q_curr q_bitrate q_codec q_recode q_needs_recode q_genre needs_replace
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
  [[ "$q_needs_recode" =~ ^[01]$ ]] || q_needs_recode=0
  [[ "$q_genre" =~ ^(audiophile|high_energy|standard)$ ]] || q_genre="$q_genre_profile"

  if source_policy_force_upscale files "$q_curr"; then
    q_ups="1"
  fi

  # MX2: Cascade downgrade guard.
  # If this album was previously recoded (last_recoded_at > 0) and the new
  # recommendation is to downgrade the sample rate further, suppress it.
  # A file already brought down from hi-res should not be automatically
  # downgraded again — that's a sign of a spectral confidence loop, not a
  # genuine quality problem.
  if ((q_needs_recode == 1)) && [[ "$q_recode" == *"Store as "* ]]; then
    local last_recoded_at_db
    last_recoded_at_db="$(sqlite3 -noheader "$DB_PATH" \
      "SELECT COALESCE(last_recoded_at, 0) FROM album_quality
       WHERE artist_lc='$(sql_escape "$(norm_lc "$artist")")' AND album_lc='$(sql_escape "$(norm_lc "$album")")' AND year_int='$(sql_escape "$year")'
       LIMIT 1;" 2>/dev/null || echo 0)"
    [[ "$last_recoded_at_db" =~ ^[0-9]+$ ]] || last_recoded_at_db=0

    if ((last_recoded_at_db > 0)); then
      local recode_target_sr current_sr
      recode_target_sr="${q_recode##*Store as }"
      recode_target_sr="${recode_target_sr%%/*}"
      recode_target_sr="${recode_target_sr%%[[:space:]]*}"
      current_sr="${q_curr%%/*}"
      # Suppress if target sample rate is lower than current (downgrade on already-recoded album).
      if [[ "$recode_target_sr" =~ ^[0-9.]+$ && "$current_sr" =~ ^[0-9.]+$ ]]; then
        if awk -v t="$recode_target_sr" -v c="$current_sr" 'BEGIN{exit !(t < c)}'; then
          q_recode="Keep as-is — cascade-downgrade suppressed (album already recoded from higher SR)"
          q_needs_recode=0
        fi
      fi
    fi
  fi

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
    ""

  ROWS_UPSERTED=$((ROWS_UPSERTED + 1))
  mark_scan_kind_done "$scan_kind"
  # Build a concise hint for the recode/action field (trim to keep lines readable).
  local _hint=""
  if [[ -n "$q_recode" && "$q_recode" != "Keep as-is" && "$q_recode" != "Keep"* ]]; then
    _hint="  → ${q_recode}"
  elif [[ -n "$q_rec" && "$q_rec" != "Keep"* ]]; then
    _hint="  → ${q_rec}"
  fi

  if [[ "$needs_replace" == "1" ]]; then
    ALBUMS_HIT=$((ALBUMS_HIT + 1))
    printf '%s[%s] [%02d] %-55s  %s %s%s  [%s%s%s  Replace%s]%s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$ALBUMS_ANALYZED" "$display_name" \
      "$q_codec" "$q_curr" "$_hint" \
      "$C_YELLOW" "$q_grade" "$C_RESET" "$C_RESET" "$C_RESET"
  else
    ALBUMS_OK=$((ALBUMS_OK + 1))
    printf '%s[%s] [%02d] %-55s  %s %s  [%s%s%s  OK%s]%s\n' \
      "$C_CYAN" "$(date +%H:%M:%S)" "$ALBUMS_ANALYZED" "$display_name" \
      "$q_codec" "$q_curr" \
      "$C_GREEN" "$q_grade" "$C_RESET" "$C_RESET" "$C_RESET"
  fi
}

process_scan_roadmap_batch() {
  local batch_limit="${1:-$MAX_ALBUMS}"
  local pending_count rows skipped_now
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

  rows="$(
    sqlite3 -separator $'\t' -noheader "$DB_PATH" \
      "SELECT id, artist, year_int, album, source_path, scan_kind
       FROM scan_roadmap
       ORDER BY CASE scan_kind WHEN 'new' THEN 0 ELSE 1 END ASC, enqueued_at ASC, id ASC
       LIMIT $batch_limit;" 2>/dev/null || true
  )"
  [[ -n "$rows" ]] || return 0

  local roadmap_id artist year album source_path scan_kind
  while IFS=$'\t' read -r roadmap_id artist year album source_path scan_kind; do
    [[ "$roadmap_id" =~ ^[0-9]+$ ]] || continue
    [[ "$year" =~ ^[0-9]+$ ]] || year=0
    [[ -n "$scan_kind" ]] || scan_kind="changed"
    process_scan_roadmap_item "$artist" "$year" "$album" "$source_path" "$scan_kind" || return 1
    scan_roadmap_delete_item "$roadmap_id" || return 1
  done <<< "$rows"
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

DB_PATH="$(resolve_library_db_path || true)"
if [[ -z "$DB_PATH" ]]; then
  echo "Error: LIBRARY_DB is not set. Example: LIBRARY_DB='\$SRC/library.sqlite'" >&2
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

# Derive a stable per-DB discovery cache path so multiple libraries on the
# same machine don't share a single timestamp file.
if [[ -z "$DISCOVERY_CACHE_FILE" ]]; then
  _db_slug="$(printf '%s' "$DB_PATH" | tr -cs 'A-Za-z0-9_-' '_')"
  DISCOVERY_CACHE_FILE="${TMPDIR:-/tmp}/qty_seek_last_discovery_${_db_slug}"
  unset _db_slug
fi

if [[ "$PURGE_MISSING" == true ]]; then
  run_purge_missing "$DRY_RUN" "$DB_PATH" "$ROOT"
  exit $?
fi

if ! acquire_scan_lock_or_skip; then
  exit 0
fi

T_START="$(date +%s)"
log "Start. root=$(realpath "$ROOT") db=$DB_PATH max_albums=$MAX_ALBUMS"

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

ROADMAP_DISCOVERY_RUN=1
T_DISCOVERY_START="$(date +%s)"
log "Phase 2/3: discovery pass. elapsed=$(elapsed_s)s"
if ! discover_scan_roadmap; then
  exit 1
fi

pending_after_discovery="$(scan_roadmap_count)"
[[ "$pending_after_discovery" =~ ^[0-9]+$ ]] || pending_after_discovery=0
log "Phase 2/3: discovery done. queued=$pending_after_discovery new_enqueued=$ROADMAP_ENQUEUED_NEW changed_enqueued=$ROADMAP_ENQUEUED_CHANGED skipped_unchanged=$ALBUMS_SKIPPED_UNCHANGED elapsed=$(elapsed_s)s phase_elapsed=$(( $(date +%s) - T_DISCOVERY_START ))s"

T_BATCH2_START="$(date +%s)"
if ((remaining_budget > 0 && (pending_before == 0 || pending_after_initial == 0))); then
  log "Phase 3/3: post-discovery batch. pending=$pending_after_discovery budget=$remaining_budget elapsed=$(elapsed_s)s"
  if ! process_scan_roadmap_batch "$remaining_budget"; then
    exit 1
  fi
  log "Phase 3/3: post-discovery batch done. analyzed=$ALBUMS_ANALYZED elapsed=$(elapsed_s)s phase_elapsed=$(( $(date +%s) - T_BATCH2_START ))s"
else
  log "Phase 3/3: skipped (backlog remains or budget exhausted; newly discovered items stay queued for next run). elapsed=$(elapsed_s)s"
fi

pending_after_run="$(scan_roadmap_count)"
[[ "$pending_after_run" =~ ^[0-9]+$ ]] || pending_after_run=0

log "Done. elapsed=$(elapsed_s)s albums_scanned=$ALBUMS_SCANNED albums_analyzed=$ALBUMS_ANALYZED albums_new_done=$ALBUMS_NEW_DONE albums_changed_done=$ALBUMS_CHANGED_DONE albums_ok=$ALBUMS_OK albums_hit(replace)=$ALBUMS_HIT albums_scan_failed=$ALBUMS_SCAN_FAILED albums_skipped(unchanged)=$ALBUMS_SKIPPED_UNCHANGED albums_skipped(fail_hold)=$ALBUMS_SKIPPED_FAIL_HOLD albums_skipped(no_key)=$ALBUMS_SKIPPED_NO_KEY albums_skipped(limit)=$ALBUMS_SKIPPED_LIMIT rows_upserted=$ROWS_UPSERTED roadmap_pending=$pending_after_run roadmap_discovery_run=$ROADMAP_DISCOVERY_RUN"
