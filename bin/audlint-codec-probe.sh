#!/usr/bin/env bash
# audlint-codec-probe.sh - Print backend capability matrix for common codecs.

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
source "$BOOTSTRAP_DIR/../lib/sh/deps.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/codec_caps.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"

show_help() {
  cat <<'EOF'
Usage:
  audlint-codec-probe.sh
  audlint-codec-probe.sh --codecs "flac,m4a,opus"

Options:
  --codecs <csv>  Comma-separated codec/extension list to probe.
  -h, --help      Show this help.

Notes:
  - This command prints capability/routing from the shared codec library.
  - Current known quirk: SoX_ng may fail Opus autodetect unless forced via -t ffmpeg.
EOF
}

codecs_csv="flac,m4a,opus,ogg,mp3,aac,wav,aiff,dsf,dff"
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  --codecs)
    shift
    codecs_csv="${1:-}"
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    printf 'Unknown argument: %s\n' "${1:-}" >&2
    show_help >&2
    exit 2
    ;;
  esac
  shift || true
done

codec_caps_init

sox_ver="missing"
ffmpeg_ver="missing"
if _codec_caps_has_bin sox; then
  sox_ver="$(sox --version 2>/dev/null | sed 's/^[[:space:]]*//')"
fi
if _codec_caps_has_bin ffmpeg; then
  ffmpeg_ver="$(ffmpeg -version 2>/dev/null | head -n 1 | sed 's/^[[:space:]]*//')"
fi

printf '%s\n' "Codec Capability Probe"
printf '%s\n' "  sox:    $sox_ver"
printf '%s\n' "  ffmpeg: $ffmpeg_ver"
printf '\n'
printf '%-8s %-8s %-10s %-11s %-15s %-15s\n' \
  "codec" "sox-in" "sox-ff-in" "sox-out" "decode-backend" "flac-encode"
printf '%-8s %-8s %-10s %-11s %-15s %-15s\n' \
  "-----" "------" "---------" "-------" "--------------" "-----------"

IFS=',' read -r -a codecs <<<"$codecs_csv"
for raw in "${codecs[@]}"; do
  codec="$(codec_caps_normalize_codec "$raw")"
  [[ -n "$codec" ]] || continue
  sox_in="no"
  sox_ff_in="no"
  sox_out="no"
  codec_caps_can_decode_with_sox_autodetect "$codec" && sox_in="yes"
  codec_caps_can_decode_with_sox_ffmpeg_bridge "$codec" && sox_ff_in="yes"
  codec_caps_can_encode_with_sox "$codec" && sox_out="yes"
  decode_backend="$(codec_caps_recommend_decode_backend "$codec")"
  flac_backend="$(codec_caps_recommend_flac_encode_backend "$codec")"

  printf '%-8s %-8s %-10s %-11s %-15s %-15s\n' \
    "$codec" "$sox_in" "$sox_ff_in" "$sox_out" "$decode_backend" "$flac_backend"
done

printf '\n'
printf '%s\n' "Legend:"
printf '%s\n' "  sox-in      = direct SoX input autodetect path"
printf '%s\n' "  sox-ff-in   = SoX input forced via '-t ffmpeg'"
printf '%s\n' "  sox-out     = direct SoX output support for that codec/container"
