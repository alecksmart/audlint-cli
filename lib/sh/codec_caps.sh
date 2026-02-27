#!/usr/bin/env bash
# codec_caps.sh - Shared codec/container capability helpers.
#
# Purpose:
# - Centralize runtime capability checks for sox/sox_ng/ffmpeg routing.
# - Expose stable helpers for deciding decode/encode backend per codec.
# - Keep known platform quirks (for now: Opus autodetect in SoX_ng) in one place.

_codec_caps_has_bin() {
  if declare -F has_bin >/dev/null 2>&1; then
    has_bin "$1"
  else
    command -v "$1" >/dev/null 2>&1
  fi
}

codec_caps_init() {
  if [[ "${CODEC_CAPS_INIT_DONE:-0}" == "1" ]]; then
    return 0
  fi
  CODEC_CAPS_INIT_DONE=1
  CODEC_CAPS_HAS_SOX=0
  CODEC_CAPS_HAS_FFMPEG=0
  CODEC_CAPS_SOX_FORMATS=""

  _codec_caps_has_bin sox && CODEC_CAPS_HAS_SOX=1
  _codec_caps_has_bin ffmpeg && CODEC_CAPS_HAS_FFMPEG=1

  if ((CODEC_CAPS_HAS_SOX == 1)); then
    local formats_line
    formats_line="$(
      (sox --help-format 2>/dev/null || sox --help 2>/dev/null || true) |
        awk '
          /AUDIO FILE FORMATS:/ {
            sub(/^.*AUDIO FILE FORMATS:[[:space:]]*/, "", $0)
            print $0
            exit
          }
        '
    )"
    formats_line="$(printf '%s' "$formats_line" | tr '[:upper:]' '[:lower:]')"
    # Keep sentinel spaces for simple token membership checks.
    CODEC_CAPS_SOX_FORMATS=" ${formats_line} "
  fi
}

codec_caps_normalize_codec() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
  *.flac) raw="flac" ;;
  *.alac) raw="alac" ;;
  *.m4a) raw="m4a" ;;
  *.mp4) raw="mp4" ;;
  *.wav) raw="wav" ;;
  *.aif | *.aiff | *.aifc) raw="aiff" ;;
  *.caf) raw="caf" ;;
  *.dsf) raw="dsf" ;;
  *.dff) raw="dff" ;;
  *.wv) raw="wv" ;;
  *.ape) raw="ape" ;;
  *.mp3) raw="mp3" ;;
  *.aac | *.adts) raw="aac" ;;
  *.ogg | *.oga) raw="ogg" ;;
  *.opus) raw="opus" ;;
  esac
  case "$raw" in
  libvorbis | vorbis) raw="ogg" ;;
  alac) raw="m4a" ;; # operationally ALAC is handled as m4a container
  esac
  printf '%s' "$raw"
}

codec_caps_sox_has_format() {
  codec_caps_init
  ((CODEC_CAPS_HAS_SOX == 1)) || return 1
  local token
  for token in "$@"; do
    [[ -n "$token" ]] || continue
    token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
    if [[ "$CODEC_CAPS_SOX_FORMATS" == *" ${token} "* ]]; then
      return 0
    fi
  done
  return 1
}

codec_caps_can_decode_with_sox_autodetect() {
  local codec
  codec="$(codec_caps_normalize_codec "${1:-}")"
  [[ -n "$codec" ]] || return 1
  codec_caps_init
  ((CODEC_CAPS_HAS_SOX == 1)) || return 1

  # Known quirk in SoX_ng v14.7.1 (observed locally): raw ".opus" autodetect fails.
  if [[ "$codec" == "opus" ]]; then
    return 1
  fi

  case "$codec" in
  aiff) codec_caps_sox_has_format aiff aif aifc ;;
  ogg) codec_caps_sox_has_format ogg vorbis ;;
  *) codec_caps_sox_has_format "$codec" ;;
  esac
}

codec_caps_can_decode_with_sox_ffmpeg_bridge() {
  codec_caps_init
  ((CODEC_CAPS_HAS_SOX == 1)) || return 1
  ((CODEC_CAPS_HAS_FFMPEG == 1)) || return 1
  codec_caps_sox_has_format ffmpeg
}

codec_caps_can_decode_with_ffmpeg() {
  codec_caps_init
  ((CODEC_CAPS_HAS_FFMPEG == 1))
}

codec_caps_can_encode_with_sox() {
  local codec
  codec="$(codec_caps_normalize_codec "${1:-}")"
  [[ -n "$codec" ]] || return 1
  codec_caps_init
  ((CODEC_CAPS_HAS_SOX == 1)) || return 1

  # Known non-writable formats in our current SoX_ng path.
  case "$codec" in
  m4a | opus | mp4 | aac) return 1 ;;
  esac

  case "$codec" in
  aiff) codec_caps_sox_has_format aiff aif aifc ;;
  ogg) codec_caps_sox_has_format ogg vorbis ;;
  *) codec_caps_sox_has_format "$codec" ;;
  esac
}

codec_caps_recommend_decode_backend() {
  local codec="${1:-}"
  if codec_caps_can_decode_with_sox_autodetect "$codec"; then
    printf 'sox'
    return 0
  fi
  if codec_caps_can_decode_with_sox_ffmpeg_bridge "$codec"; then
    printf 'sox(ffmpeg-in)'
    return 0
  fi
  if codec_caps_can_decode_with_ffmpeg "$codec"; then
    printf 'ffmpeg'
    return 0
  fi
  printf 'none'
}

codec_caps_recommend_flac_encode_backend() {
  local src_codec="${1:-}"
  if codec_caps_can_encode_with_sox flac; then
    if codec_caps_can_decode_with_sox_autodetect "$src_codec"; then
      printf 'sox'
      return 0
    fi
    if codec_caps_can_decode_with_sox_ffmpeg_bridge "$src_codec"; then
      printf 'sox(ffmpeg-in)'
      return 0
    fi
  fi
  if codec_caps_can_decode_with_ffmpeg; then
    printf 'ffmpeg'
    return 0
  fi
  printf 'none'
}

