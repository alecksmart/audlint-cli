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
    done < <(find "$dir" \( -type f -o -type l \) \( $(audio_find_iname_args) \) -print0 | sort -z)
    return 0
  fi

  audio_collect_files "$dir" discovered_files
  for f in "${discovered_files[@]}"; do
    out_ref+=("$f")
  done
}

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

  if ! generate_spectrogram_png "$merged_file" "$album_png"; then
    rm -rf "$tmpdir"
    log "Album spectrogram generation failed."
    return 1
  fi

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
