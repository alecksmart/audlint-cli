#!/opt/homebrew/bin/bash
# encoder.sh - Encoder abstraction layer: sox (preferred) or ffmpeg (fallback).
#
# Sox produces superior dithered sample-rate conversion.
# ffmpeg is used when sox is unavailable (or for non-FLAC source metadata injection).
#
# Depends on: deps.sh (has_bin), and externally: sox, metaflac, ffmpeg.

encoder_has_sox() {
  has_bin sox
}

encoder_backend() {
  if encoder_has_sox; then
    printf 'sox'
  else
    printf 'ffmpeg'
  fi
}

encoder_log_backend() {
  if encoder_has_sox; then
    printf 'sox'
  else
    printf 'ffmpeg (fallback)'
  fi
}

# _encoder_sample_fmt <bits>
# Returns the ffmpeg sample_fmt string for the given bit depth.
_encoder_sample_fmt() {
  case "$1" in
  16) printf 's16' ;;
  24 | 32) printf 's32' ;;
  *) printf 's32' ;;
  esac
}

# _encoder_sr_khz <sr_hz>
# Converts Hz to a sox-compatible kHz token (e.g. 96000 -> 96k, 44100 -> 44100).
_encoder_sr_khz() {
  local sr_hz="$1"
  if ((sr_hz % 1000 == 0)); then
    printf '%sk' "$((sr_hz / 1000))"
  else
    printf '%s' "$sr_hz"
  fi
}

# _encoder_copy_flac_tags <src_flac> <dst_flac>
# Copies Vorbis comments from src to dst using metaflac.
# Returns non-zero if metaflac fails.
_encoder_copy_flac_tags() {
  local src="$1"
  local dst="$2"
  local tmp_tags
  tmp_tags="$(mktemp "${TMPDIR:-/tmp}/encoder_tags.XXXXXX")"
  metaflac --export-tags-to="$tmp_tags" "$src" 2>/dev/null || {
    rm -f "$tmp_tags"
    return 1
  }
  metaflac --remove-all-tags --import-tags-from="$tmp_tags" "$dst" 2>/dev/null || {
    rm -f "$tmp_tags"
    return 1
  }
  rm -f "$tmp_tags"
}

# _encoder_inject_metadata_ffmpeg <src> <audio_flac> <out_flac>
# Copies metadata from src into audio_flac using ffmpeg -c copy.
# Used for non-FLAC sources (WAV, ALAC, DSD) where metaflac cannot read tags.
_encoder_inject_metadata_ffmpeg() {
  local src="$1"
  local audio_flac="$2"
  local out_flac="$3"
  local tmp_tagged
  tmp_tagged="$(mktemp "${TMPDIR:-/tmp}/encoder_meta.XXXXXX.flac")"
  if ffmpeg -hide_banner -loglevel error -nostdin -y \
    -i "$src" -i "$audio_flac" \
    -map 1:a -c copy -map_metadata 0 \
    "$tmp_tagged" </dev/null; then
    mv -f "$tmp_tagged" "$out_flac"
  else
    rm -f "$tmp_tagged"
    return 1
  fi
}

# _encoder_inject_tags_metaflac <dst_flac> <tag_lines...>
# Writes explicit TAG=value lines into dst_flac via metaflac.
# tag_lines format: "TAG=value" one per argument.
_encoder_inject_tags_metaflac() {
  local dst="$1"
  shift
  local tmp_tags
  tmp_tags="$(mktemp "${TMPDIR:-/tmp}/encoder_tags.XXXXXX")"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$tmp_tags"
  done
  metaflac --remove-all-tags --import-tags-from="$tmp_tags" "$dst" 2>/dev/null || {
    rm -f "$tmp_tags"
    return 1
  }
  rm -f "$tmp_tags"
}

# encoder_to_flac --in <src> --out <dst> --sr <hz> --bits <16|24|32>
#                 [--gain <dB>]
#                 [--src-is-flac <0|1>]
#                 [--tags <TAG=value> ...]
#
# Encodes src to dst.flac at the given sample rate and bit depth.
# Optional --gain applies a gain (dB) before SRC (sox path) or via filter (ffmpeg path).
# --src-is-flac: 1 (default) means use metaflac for tag copy; 0 uses ffmpeg metadata pass.
# --tags: explicit TAG=value pairs for metaflac injection (used when src has no Vorbis comments).
#
# Returns non-zero on failure.
encoder_to_flac() {
  local in="" out="" sr_hz="" bits="" gain_db="" src_is_flac=1
  local -a extra_tags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --in)   shift; in="$1" ;;
    --out)  shift; out="$1" ;;
    --sr)   shift; sr_hz="$1" ;;
    --bits) shift; bits="$1" ;;
    --gain) shift; gain_db="$1" ;;
    --src-is-flac) shift; src_is_flac="$1" ;;
    --tags) shift; extra_tags+=("$1") ;;
    *) printf 'encoder_to_flac: unknown argument: %s\n' "$1" >&2; return 1 ;;
    esac
    shift
  done

  [[ -n "$in" && -n "$out" && -n "$sr_hz" && -n "$bits" ]] || {
    printf 'encoder_to_flac: --in, --out, --sr, --bits are required\n' >&2
    return 1
  }

  if encoder_has_sox; then
    if ! has_bin metaflac && ((src_is_flac == 1)); then
      printf 'encoder_to_flac: sox is active but metaflac is not on PATH (required for tag copy)\n' >&2
      return 1
    fi

    local sr_k
    sr_k="$(_encoder_sr_khz "$sr_hz")"

    local sox_cmd=()
    sox_cmd=(sox "$in" -b "$bits" --compression 8 "$out")

    # gain before rate conversion (sox chain order matters)
    if [[ -n "$gain_db" ]] && awk -v g="$gain_db" 'BEGIN{exit !(g+0 != 0)}'; then
      sox_cmd+=(gain "$gain_db")
    fi

    sox_cmd+=(rate -v -s -L "$sr_k" dither -s)

    if ! "${sox_cmd[@]}"; then
      return 1
    fi

    # Metadata
    if ((${#extra_tags[@]} > 0)); then
      _encoder_inject_tags_metaflac "$out" "${extra_tags[@]}" || return 1
    elif ((src_is_flac == 1)); then
      _encoder_copy_flac_tags "$in" "$out" || return 1
    else
      _encoder_inject_metadata_ffmpeg "$in" "$out" "$out" || return 1
    fi

  else
    # ffmpeg fallback
    local sample_fmt
    sample_fmt="$(_encoder_sample_fmt "$bits")"
    local -a filter_args=()
    if [[ -n "$gain_db" ]] && awk -v g="$gain_db" 'BEGIN{exit !(g+0 != 0)}'; then
      filter_args=(-af "volume=${gain_db}dB")
    fi

    ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$in" \
      "${filter_args[@]}" \
      -map 0:a:0 \
      -map_metadata 0 \
      -c:a flac \
      -f flac \
      -ar "$sr_hz" \
      -sample_fmt "$sample_fmt" \
      -bits_per_raw_sample "$bits" \
      -compression_level 8 \
      "$out" </dev/null || return 1
  fi
}

# encoder_bake_gain_flac --in <src_backup> --out <dst.flac> --bits <16|24|32> --gain <dB>
#
# Applies a gain to a FLAC file without changing sample rate.
# Source must be FLAC (metaflac tag copy is used on sox path).
# Returns non-zero on failure.
encoder_bake_gain_flac() {
  local in="" out="" bits="" gain_db=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --in)   shift; in="$1" ;;
    --out)  shift; out="$1" ;;
    --bits) shift; bits="$1" ;;
    --gain) shift; gain_db="$1" ;;
    *) printf 'encoder_bake_gain_flac: unknown argument: %s\n' "$1" >&2; return 1 ;;
    esac
    shift
  done

  [[ -n "$in" && -n "$out" && -n "$bits" && -n "$gain_db" ]] || {
    printf 'encoder_bake_gain_flac: --in, --out, --bits, --gain are required\n' >&2
    return 1
  }

  if encoder_has_sox; then
    if ! has_bin metaflac; then
      printf 'encoder_bake_gain_flac: sox is active but metaflac is not on PATH\n' >&2
      return 1
    fi

    if ! sox "$in" -b "$bits" --compression 8 "$out" gain "$gain_db" dither -s; then
      return 1
    fi

    _encoder_copy_flac_tags "$in" "$out" || return 1

  else
    # ffmpeg fallback (current boost_album.sh logic)
    local sample_fmt
    sample_fmt="$(_encoder_sample_fmt "$bits")"
    local strict_flag=""
    ((bits > 24)) && strict_flag="-strict experimental"

    # shellcheck disable=SC2086
    ffmpeg -hide_banner $strict_flag \
      -i "$in" \
      -af "volume=${gain_db}dB" \
      -c:a flac -bits_per_raw_sample "$bits" -compression_level 8 \
      -c:v copy -map_metadata 0 -metadata CUESHEET= \
      "$out" -y </dev/null || return 1
  fi
}
