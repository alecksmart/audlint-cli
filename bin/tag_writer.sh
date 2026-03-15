#!/usr/bin/env bash
# tag_writer.sh — Write metadata tags to audio files across all supported formats.
#
# Supported formats and tools:
#   FLAC          → metaflac  (Vorbis comment tags, lossless in-place)
#   MP3           → eyeD3     (ID3v2 frames)
#   M4A / MP4     → AtomicParsley (iTunes atom tags)
#   OGG / Opus    → vorbiscomment (Vorbis comment tags)
#   WavPack (.wv) → wvtag     (APEv2 tags)
#   WAV / AIFF    → ffmpeg    (INFO / ID3 chunks — rewrites container)
#   DSF / DFF     → ffmpeg    (ID3 chunks — rewrites container)
#   WMA           → ffmpeg    (ASF attributes — rewrites container)
#   Unknown       → ffmpeg    (best-effort, rewrites container)
#
# Public API:
#   tag_write FILE TAG VALUE   — write a single tag to FILE
#   tag_write_map FILE MAP_VAR — write all tags from an associative array
#
# TAG names follow the canonical Vorbis/ID3 convention (case-insensitive):
#   GENRE, ARTIST, ALBUM, TITLE, DATE, TRACKNUMBER, COMMENT, LYRICS, etc.
#
# Exit codes:
#   0  — tag written successfully
#   1  — unsupported format or required tool missing
#   2  — file not found or not readable

_TW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_TW_SCRIPT_DIR/../lib/sh/secure_backup.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_TW_SCRIPT_DIR/../lib/sh/secure_backup.sh"
fi
if [[ -f "$_TW_SCRIPT_DIR/../lib/sh/audio.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_TW_SCRIPT_DIR/../lib/sh/audio.sh"
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_tw_has_bin() { command -v "$1" >/dev/null 2>&1; }

# Map a canonical Vorbis tag name to the ID3v2 frame used by eyeD3.
_tw_id3_frame() {
  local tag="${1^^}"
  case "$tag" in
  GENRE)         printf 'TPE1'; return ;;   # override below
  ARTIST)        printf 'TPE1'; return ;;
  ALBUMARTIST)   printf 'TPE2'; return ;;
  ALBUM)         printf 'TALB'; return ;;
  TITLE)         printf 'TIT2'; return ;;
  DATE|YEAR)     printf 'TDRC'; return ;;
  TRACKNUMBER)   printf 'TRCK'; return ;;
  DISCNUMBER)    printf 'TPOS'; return ;;
  COMMENT)       printf 'COMM'; return ;;
  LYRICS)        printf 'USLT'; return ;;
  COMPOSER)      printf 'TCOM'; return ;;
  GENRE)         printf 'TCON'; return ;;
  *)             printf 'TXXX'; return ;;
  esac
}

# Correct the genre frame mapping (TCON, not TPE1).
_tw_id3_flag_for_tag() {
  local tag="${1^^}"
  local val="$2"
  case "$tag" in
  GENRE)        printf -- '--genre=%s' "$val" ;;
  ARTIST)       printf -- '--artist=%s' "$val" ;;
  ALBUMARTIST)  printf -- '--album-artist=%s' "$val" ;;
  ALBUM)        printf -- '--album=%s' "$val" ;;
  TITLE)        printf -- '--title=%s' "$val" ;;
  DATE|YEAR)    printf -- '--recording-date=%s' "$val" ;;
  TRACKNUMBER)  printf -- '--track=%s' "$val" ;;
  DISCNUMBER)   printf -- '--disc-num=%s' "$val" ;;
  COMMENT)      printf -- '--comment=::%s' "$val" ;;
  COMPOSER)     printf -- '--text-frame=TCOM:%s' "$val" ;;
  *)            printf -- '--text-frame=%s:%s' "${tag}" "$val" ;;
  esac
}

# Map a canonical tag name to the ffmpeg metadata key.
_tw_ffmpeg_key() {
  local tag="${1,,}"
  case "$tag" in
  albumartist) printf 'album_artist' ;;
  tracknumber) printf 'track' ;;
  discnumber)  printf 'disc' ;;
  date|year)   printf 'date' ;;
  *)           printf '%s' "$tag" ;;
  esac
}

# ---------------------------------------------------------------------------
# Format-specific writers (single tag)
# ---------------------------------------------------------------------------

_tw_write_flac() {
  local file="$1" tag="${2^^}" val="$3"
  if ! _tw_has_bin metaflac; then
    printf '[tag_writer] metaflac not found; cannot tag FLAC: %s\n' "$file" >&2
    return 1
  fi
  metaflac --remove-tag="$tag" --set-tag="${tag}=${val}" "$file" 2>/dev/null
}

_tw_write_mp3() {
  local file="$1" tag="${2^^}" val="$3"
  if ! _tw_has_bin eyeD3; then
    printf '[tag_writer] eyeD3 not found; cannot tag MP3: %s\n' "$file" >&2
    return 1
  fi
  local flag
  flag="$(_tw_id3_flag_for_tag "$tag" "$val")"
  eyeD3 "$flag" --no-color "$file" >/dev/null 2>&1
}

_tw_write_m4a() {
  local file="$1" tag="${2^^}" val="$3"
  if ! _tw_has_bin AtomicParsley; then
    printf '[tag_writer] AtomicParsley not found; cannot tag M4A: %s\n' "$file" >&2
    return 1
  fi
  local ap_flag
  case "$tag" in
  GENRE)        ap_flag="--genre" ;;
  ARTIST)       ap_flag="--artist" ;;
  ALBUMARTIST)  ap_flag="--albumArtist" ;;
  ALBUM)        ap_flag="--album" ;;
  TITLE)        ap_flag="--title" ;;
  DATE|YEAR)    ap_flag="--year" ;;
  TRACKNUMBER)  ap_flag="--tracknum" ;;
  DISCNUMBER)   ap_flag="--disk" ;;
  COMMENT)      ap_flag="--comment" ;;
  LYRICS)       ap_flag="--lyrics" ;;
  COMPOSER)     ap_flag="--composer" ;;
  *)
    # AtomicParsley does not support arbitrary atoms easily; skip unknown tags.
    printf '[tag_writer] AtomicParsley: unsupported tag %s for %s; skipped\n' "$tag" "$file" >&2
    return 0
    ;;
  esac
  AtomicParsley "$file" "$ap_flag" "$val" --overWrite >/dev/null 2>&1
}

_tw_write_ogg_opus() {
  local file="$1" tag="${2^^}" val="$3"
  if _tw_has_bin vorbiscomment; then
    # vorbiscomment replaces all tags; append mode with a temp file approach.
    local tmp
    tmp="$(mktemp "${file}.XXXXXX.tmp" 2>/dev/null)" || { return 1; }
    # Export current tags, update or add the target tag, reimport.
    {
      vorbiscomment -l "$file" 2>/dev/null | grep -vi "^${tag}=" || true
      printf '%s=%s\n' "${tag}" "$val"
    } | vorbiscomment -w -c - "$file" "$tmp" 2>/dev/null && mv -f "$tmp" "$file" || {
      rm -f "$tmp"; return 1
    }
  elif _tw_has_bin ffmpeg; then
    _tw_write_ffmpeg "$file" "$tag" "$val"
  else
    printf '[tag_writer] vorbiscomment or ffmpeg required for OGG/Opus: %s\n' "$file" >&2
    return 1
  fi
}

_tw_write_wavpack() {
  local file="$1" tag="${2^^}" val="$3"
  if ! _tw_has_bin wvtag; then
    # Fall back to ffmpeg for WavPack if wvtag unavailable.
    if _tw_has_bin ffmpeg; then
      _tw_write_ffmpeg "$file" "$tag" "$val"
    else
      printf '[tag_writer] wvtag not found; cannot tag WavPack: %s\n' "$file" >&2
      return 1
    fi
    return
  fi
  wvtag -q -w "${tag}=${val}" "$file" 2>/dev/null
}

_tw_write_ffmpeg() {
  local file="$1" tag="$2" val="$3"
  if ! _tw_has_bin ffmpeg; then
    printf '[tag_writer] ffmpeg not found; cannot tag: %s\n' "$file" >&2
    return 1
  fi
  local key tmp ext
  key="$(_tw_ffmpeg_key "$tag")"
  ext="${file##*.}"
  tmp="$(mktemp "${file}.XXXXXX.${ext}" 2>/dev/null)" || return 1
  if ffmpeg -y -hide_banner -loglevel error -nostdin \
      -i "$file" -map 0 -codec copy \
      -metadata "${key}=${val}" \
      "$tmp" </dev/null 2>/dev/null; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Codec detection (reuse ffprobe if available, fall back to extension)
# ---------------------------------------------------------------------------

_tw_detect_format() {
  local file="$1"
  local ext="${file##*.}"
  ext="${ext,,}"
  local codec=""
  if _tw_has_bin ffprobe; then
    codec="$(audio_codec_name "$file" || true)"
  fi
  # Normalise codec name; fall back to extension.
  case "${codec,,}" in
  flac)               printf 'flac' ;;
  mp3)                printf 'mp3' ;;
  aac)                printf 'm4a' ;;
  vorbis)             printf 'ogg' ;;
  opus)               printf 'opus' ;;
  wavpack)            printf 'wavpack' ;;
  dsd_lsbf|dsd_msbf) printf 'dsf' ;;
  wmav1|wmav2|wmapro) printf 'wma' ;;
  pcm_*)              printf 'wav' ;;
  *)
    # Codec unknown — use extension.
    case "$ext" in
    flac)          printf 'flac' ;;
    mp3)           printf 'mp3' ;;
    m4a|mp4|aac)   printf 'm4a' ;;
    ogg)           printf 'ogg' ;;
    opus)          printf 'opus' ;;
    wv)            printf 'wavpack' ;;
    dsf|dff)       printf 'dsf' ;;
    wma)           printf 'wma' ;;
    wav|aif|aiff)  printf 'wav' ;;
    *)             printf 'unknown' ;;
    esac
    ;;
  esac
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

# tag_write FILE TAG VALUE
#   Write a single tag to a file.  Returns 0 on success, non-zero on error.
tag_write() {
  local file="$1"
  local tag="$2"
  local val="$3"

  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf '[tag_writer] File not found or not readable: %s\n' "$file" >&2
    return 2
  fi
  if [[ -z "$tag" ]]; then
    printf '[tag_writer] Empty tag name for: %s\n' "$file" >&2
    return 1
  fi

  if declare -F secure_backup_album_tracks_once >/dev/null 2>&1; then
    local album_dir
    album_dir="$(dirname "$file")"
    if ! secure_backup_album_tracks_once "$album_dir" "tag write"; then
      printf '[tag_writer] %s\n' "${SECURE_BACKUP_LAST_ERROR:-secure backup failed}" >&2
      return 1
    fi
  fi

  local fmt
  fmt="$(_tw_detect_format "$file")"

  case "$fmt" in
  flac)    _tw_write_flac    "$file" "$tag" "$val" ;;
  mp3)     _tw_write_mp3     "$file" "$tag" "$val" ;;
  m4a)     _tw_write_m4a     "$file" "$tag" "$val" ;;
  ogg)     _tw_write_ogg_opus "$file" "$tag" "$val" ;;
  opus)    _tw_write_ogg_opus "$file" "$tag" "$val" ;;
  wavpack) _tw_write_wavpack  "$file" "$tag" "$val" ;;
  dsf|wma|wav|unknown) _tw_write_ffmpeg "$file" "$tag" "$val" ;;
  *)       _tw_write_ffmpeg  "$file" "$tag" "$val" ;;
  esac
}

# tag_write_map FILE MAP_VAR
#   Write multiple tags from an associative array.
#   MAP_VAR is the name of a declared associative array (passed by name).
#   Example:
#     declare -A tags=([GENRE]="Rock" [ARTIST]="AC/DC")
#     tag_write_map "/path/to/file.flac" tags
tag_write_map() {
  local file="$1"
  local -n _tw_map="$2"
  local tag rc=0
  for tag in "${!_tw_map[@]}"; do
    tag_write "$file" "$tag" "${_tw_map[$tag]}" || rc=$?
  done
  return $rc
}
