#!/usr/bin/env bash

AUDIO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$AUDIO_LIB_DIR/profile.sh"

audio_collect_files() {
  local dir="${1:-.}"
  local out_var="${2:-AUDIO_FILES}"
  # shellcheck disable=SC2178  # nameref for array; SC2178 is a false positive here
  local -n out_ref="$out_var"
  local had_nullglob=0
  local had_nocaseglob=0

  shopt -q nullglob && had_nullglob=1
  shopt -q nocaseglob && had_nocaseglob=1

  shopt -s nullglob nocaseglob
  if [[ "$dir" == "." ]]; then
    out_ref=(
      *.flac
      *.alac
      *.m4a
      *.wav
      *.aiff *.aif *.aifc
      *.caf
      *.dsf
      *.dff
      *.wv
      *.ape
      *.dts
      *.dca
      *.mp4
      *.mp3
      *.aac
      *.ogg
      *.opus
    )
  else
    out_ref=(
      "$dir"/*.flac
      "$dir"/*.alac
      "$dir"/*.m4a
      "$dir"/*.wav
      "$dir"/*.aiff "$dir"/*.aif "$dir"/*.aifc
      "$dir"/*.caf
      "$dir"/*.dsf
      "$dir"/*.dff
      "$dir"/*.wv
      "$dir"/*.ape
      "$dir"/*.dts
      "$dir"/*.dca
      "$dir"/*.mp4
      "$dir"/*.mp3
      "$dir"/*.aac
      "$dir"/*.ogg
      "$dir"/*.opus
    )
  fi
  ((had_nullglob == 1)) || shopt -u nullglob
  ((had_nocaseglob == 1)) || shopt -u nocaseglob
  : "${#out_ref[@]}"
}

# audio_find_iname_args — print the canonical -iname predicate fragment for find.
#
# Splice into any find command:
#   find DIR -maxdepth 1 -type f \( $(audio_find_iname_args) \) -print
#
# The list is the authoritative set of audio extensions recognised by audlint.
# Keep this in sync with audio_collect_files above.
audio_find_iname_args() {
  printf '%s ' \
    '-iname' '*.flac' \
    '-o' '-iname' '*.alac' \
    '-o' '-iname' '*.m4a' \
    '-o' '-iname' '*.wav' \
    '-o' '-iname' '*.aiff' \
    '-o' '-iname' '*.aif' \
    '-o' '-iname' '*.aifc' \
    '-o' '-iname' '*.caf' \
    '-o' '-iname' '*.dsf' \
    '-o' '-iname' '*.dff' \
    '-o' '-iname' '*.wv' \
    '-o' '-iname' '*.ape' \
    '-o' '-iname' '*.dts' \
    '-o' '-iname' '*.dca' \
    '-o' '-iname' '*.mp4' \
    '-o' '-iname' '*.mp3' \
    '-o' '-iname' '*.aac' \
    '-o' '-iname' '*.ogg' \
    '-o' '-iname' '*.opus'
}

audio_has_files() {
  local dir="${1:-.}"
  local files=()
  audio_collect_files "$dir" files
  ((${#files[@]} > 0))
}

_audio_ffprobe_meta_cache_init() {
  if ! declare -p AUDIO_FFPROBE_META_CACHE >/dev/null 2>&1; then
    declare -gA AUDIO_FFPROBE_META_CACHE=()
  fi
}

_audio_ffprobe_meta_key() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g;s/__*/_/g;s/^_//;s/_$//'
}

_audio_ffprobe_meta_parse() {
  local raw="$1"
  local section="" line key val normalized_key

  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
    "[STREAM]"*) section="stream" ;;
    "[/STREAM]"*) section="" ;;
    "[FORMAT]"*) section="format" ;;
    "[/FORMAT]"*) section="" ;;
    TAG:*=*)
      key="${line%%=*}"
      val="${line#*=}"
      normalized_key="$(_audio_ffprobe_meta_key "${key#TAG:}")"
      [[ -n "$normalized_key" ]] || continue
      [[ -n "$section" ]] || section="format"
      printf '%s_tag_%s=%s\n' "$section" "$normalized_key" "$val"
      ;;
    *=*)
      [[ -n "$section" ]] || continue
      key="${line%%=*}"
      val="${line#*=}"
      normalized_key="$(_audio_ffprobe_meta_key "$key")"
      [[ -n "$normalized_key" ]] || continue
      printf '%s_%s=%s\n' "$section" "$normalized_key" "$val"
      ;;
    esac
  done <<< "$raw"
}

audio_ffprobe_meta_dump() {
  local in="$1"
  local raw normalized

  _audio_ffprobe_meta_cache_init
  if [[ -v AUDIO_FFPROBE_META_CACHE["$in"] ]]; then
    printf '%s' "${AUDIO_FFPROBE_META_CACHE["$in"]}"
    return 0
  fi

  raw="$(
    ffprobe -v error -select_streams a:0 \
      -show_entries stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics \
      -of default=noprint_wrappers=0:nokey=0 \
      "$in" </dev/null 2>/dev/null || true
  )"
  normalized="$(_audio_ffprobe_meta_parse "$raw")"
  AUDIO_FFPROBE_META_CACHE["$in"]="$normalized"
  printf '%s' "$normalized"
}

audio_ffprobe_meta_prime() {
  audio_ffprobe_meta_dump "$1" >/dev/null
}

audio_ffprobe_meta_get() {
  local in="$1"
  local key="$2"
  local normalized_key metadata line

  normalized_key="$(_audio_ffprobe_meta_key "$key")"
  [[ -n "$normalized_key" ]] || {
    printf ''
    return 0
  }

  metadata="$(audio_ffprobe_meta_dump "$in")"
  while IFS= read -r line; do
    [[ "$line" == "$normalized_key="* ]] || continue
    printf '%s' "${line#*=}"
    return 0
  done <<< "$metadata"
  printf ''
}

audio_probe_tag_value() {
  local in="$1"
  local tag_key
  tag_key="$(_audio_ffprobe_meta_key "${2:-}")"
  [[ -n "$tag_key" ]] || {
    printf ''
    return 0
  }
  audio_ffprobe_meta_get "$in" "format_tag_${tag_key}"
}

audio_probe_sample_rate_hz() {
  local in="$1"
  local sr
  audio_ffprobe_meta_prime "$in"
  sr="$(audio_ffprobe_meta_get "$in" "stream_sample_rate")"
  sr="$(printf '%s' "$sr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$sr" =~ ^[0-9]+$ ]] && ((sr > 0)); then
    printf '%s' "$sr"
  else
    printf '0'
  fi
}

audio_sample_fmt_to_bits() {
  case "${1:-}" in
  s16 | s16p) printf '16' ;;
  s24 | s24p) printf '24' ;;
  s32 | s32p | flt | fltp) printf '32' ;;
  dbl | dblp) printf '64' ;;
  *) printf '0' ;;
  esac
}

audio_sample_fmt_to_bit_label() {
  case "${1:-}" in
  s16 | s16p) printf '16' ;;
  s24 | s24p) printf '24' ;;
  s32 | s32p) printf '32' ;;
  flt | fltp) printf '32f' ;;
  dbl | dblp) printf '64f' ;;
  *) printf '' ;;
  esac
}

audio_is_dsd_codec() {
  case "${1:-}" in
  dsd*) return 0 ;;
  *) return 1 ;;
  esac
}

audio_normalize_source_bit_depth() {
  local codec="${1:-}"
  local bit_depth="${2:-}"

  if audio_is_dsd_codec "$codec"; then
    # DSD can probe as 1-bit; keep the PCM recode ceiling at 24-bit.
    if [[ ! "$bit_depth" =~ ^[0-9]+$ ]] || ((bit_depth < 24)); then
      printf '24'
      return 0
    fi
  fi

  if [[ "$bit_depth" =~ ^[0-9]+$ ]] && ((bit_depth > 0)); then
    printf '%s' "$bit_depth"
  else
    printf '0'
  fi
}

audio_probe_bit_depth_label() {
  local in="$1"
  local codec="${2:-}"
  local bps bps_fallback sfmt label

  audio_ffprobe_meta_prime "$in"
  if [[ -z "$codec" ]]; then
    codec="$(audio_codec_name "$in" || true)"
  fi

  bps="$(audio_ffprobe_meta_get "$in" "stream_bits_per_raw_sample")"
  bps="$(printf '%s' "$bps" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$bps" =~ ^[0-9]+$ ]] && ((bps > 0)); then
    label="$bps"
  else
    bps_fallback="$(audio_ffprobe_meta_get "$in" "stream_bits_per_sample")"
    bps_fallback="$(printf '%s' "$bps_fallback" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "$bps_fallback" =~ ^[0-9]+$ ]] && ((bps_fallback > 0)); then
      label="$bps_fallback"
    else
      sfmt="$(audio_ffprobe_meta_get "$in" "stream_sample_fmt")"
      sfmt="$(printf '%s' "$sfmt" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      label="$(audio_sample_fmt_to_bit_label "$sfmt")"
    fi
  fi

  if audio_is_dsd_codec "$codec"; then
    if [[ ! "$label" =~ ^[0-9]+$ ]] || ((label < 24)); then
      label="24"
    fi
  fi

  printf '%s' "$label"
}

audio_probe_bitrate_bps() {
  local in="$1"
  local raw
  audio_ffprobe_meta_prime "$in"
  raw="$(audio_ffprobe_meta_get "$in" "stream_bit_rate")"
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ ! "$raw" =~ ^[0-9]+$ || "$raw" == "0" ]]; then
    raw="$(audio_ffprobe_meta_get "$in" "format_bit_rate")"
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw > 0)); then
    printf '%s\n' "$raw"
  else
    printf '0\n'
  fi
}

audio_probe_duration_seconds() {
  local in="$1"
  local dur
  audio_ffprobe_meta_prime "$in"
  dur="$(audio_ffprobe_meta_get "$in" "format_duration")"
  dur="$(printf '%s' "$dur" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "$dur"
  else
    printf '0\n'
  fi
}

audio_probe_channels() {
  local in="$1"
  local ch
  audio_ffprobe_meta_prime "$in"
  ch="$(audio_ffprobe_meta_get "$in" "stream_channels")"
  ch="$(printf '%s' "$ch" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$ch" =~ ^[0-9]+$ ]] && ((ch > 0)); then
    printf '%s\n' "$ch"
  else
    printf '0\n'
  fi
}

audio_probe_bit_depth_bits() {
  local in="$1"
  local codec="${2:-}"
  local label

  label="$(audio_probe_bit_depth_label "$in" "$codec")"
  case "$label" in
  32f) printf '32' ;;
  64f) printf '64' ;;
  *)
    if [[ "$label" =~ ^[0-9]+$ ]] && ((label > 0)); then
      printf '%s' "$label"
    else
      printf '0'
    fi
    ;;
  esac
}

audio_dsd_max_pcm_profile() {
  local src_sr_hz="$1"
  local max_sr_hz="176400"
  local family_label="fallback"
  local target_sr_hz=""
  local policy_label="max-ceiling"

  if [[ "$src_sr_hz" =~ ^[0-9]+$ ]] && ((src_sr_hz > 0)); then
    if ((src_sr_hz % 44100 == 0)); then
      max_sr_hz="176400"
      family_label="44.1k-family"
    elif ((src_sr_hz % 48000 == 0)); then
      max_sr_hz="192000"
      family_label="48k-family"
    fi
  fi

  target_sr_hz="$max_sr_hz"
  if [[ "$src_sr_hz" =~ ^[0-9]+$ ]] && ((src_sr_hz > 0 && src_sr_hz < max_sr_hz)); then
    target_sr_hz="$src_sr_hz"
    policy_label="no-upscale"
  fi

  printf '%s|24|%s|%s' "$target_sr_hz" "$family_label" "$policy_label"
}

audio_is_float_number() {
  [[ "${1:-}" =~ ^[-+]?[0-9]+([.][0-9]+)?$ ]]
}

audio_float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'
}

audio_float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'
}

audio_float_abs_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{if (a < 0) a = -a; if (b < 0) b = -b; exit !(a>=b)}'
}

audio_db_gain_label() {
  local gain="$1"
  local precision="${2:-3}"
  awk -v v="$gain" -v p="$precision" 'BEGIN{
    n = v + 0
    fmt = sprintf("%%.%df", p)
    if (n >= 0) fmt = "+" fmt
    printf fmt, n
  }'
}

audio_auto_boost_target_true_peak_db() {
  # Resampling can introduce a few new overs after source-side true-peak analysis,
  # so boosted recodes keep a conservative finished-file ceiling.
  printf '%s' '-1.5'
}

audio_auto_boost_min_apply_db() {
  printf '%s' '0.3'
}

audio_probe_true_peak_db() {
  local in="$1"
  local out peak line tail
  out="$(ffmpeg -hide_banner -nostdin -i "$in" -af "loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary" -vn -sn -dn -f null /dev/null 2>&1 || true)"
  peak=""
  while IFS= read -r line; do
    case "$line" in
    *"Input True Peak:"*)
      tail="${line#*Input True Peak:}"
      # Parse the first token after the marker (e.g. "-2.0" from "-2.0 dBTP")
      # without awk, so UTF-8 filenames in ffmpeg logs do not break parsing.
      read -r peak _ <<<"$tail"
      break
      ;;
    esac
  done <<<"$out"
  peak="${peak#+}"
  if audio_is_float_number "$peak"; then
    printf '%s' "$peak"
  else
    printf ''
  fi
}

audio_detect_cpu_cores() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [[ "$n" =~ ^[0-9]+$ ]] && ((n > 0)); then
    printf '%s' "$n"
    return 0
  fi
  n="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"
  if [[ "$n" =~ ^[0-9]+$ ]] && ((n > 0)); then
    printf '%s' "$n"
    return 0
  fi
  printf '1'
}

audio_probe_file_stat_signature() {
  local in="$1"
  local out mtime size
  out="$(stat -f '%m	%z' "$in" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    out="$(stat -c '%Y	%s' "$in" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || return 1
  IFS=$'\t' read -r mtime size <<<"$out"
  if [[ "$mtime" =~ ^[0-9]+$ ]] && [[ "$size" =~ ^[0-9]+$ ]]; then
    printf '%s\t%s' "$mtime" "$size"
    return 0
  fi
  return 1
}

audio_true_peak_cache_key() {
  local path="$1"
  local mtime="$2"
  local size="$3"
  local sep="${4:-$'\037'}"
  printf '%s%s%s%s%s' "$path" "$sep" "$mtime" "$sep" "$size"
}

audio_load_true_peak_cache() {
  local file="$1"
  local out_var="$2"
  local sep="${3:-$'\037'}"
  # shellcheck disable=SC2178  # nameref for associative array; SC2178 is a false positive here
  local -n out_ref="$out_var"
  local path mtime size true_peak key
  [[ -f "$file" ]] || return 0
  while IFS=$'\t' read -r path mtime size true_peak; do
    [[ -n "$path" ]] || continue
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    audio_is_float_number "$true_peak" || continue
    key="$(audio_true_peak_cache_key "$path" "$mtime" "$size" "$sep")"
    out_ref["$key"]="$true_peak"
  done <"$file"
}

# Classify a single genre segment (no semicolons) into a profile rank:
#   2 = high_energy, 1 = audiophile, 0 = standard
_audio_classify_genre_segment() {
  local seg="${1,,}"
  # shellcheck disable=SC2221,SC2222  # *"hip hop"* vs *"hip-hop"*: space vs dash, both needed
  case "$seg" in
  *metal* | *punk* | *hardcore* | *grunge* | *noise*)
    printf '2'
    return
    ;;
  *rock* | *alternative* | *indie*)
    printf '2'
    return
    ;;
  *electronic* | *electro* | *synth* | *edm* | *house* | *techno* | *trance* | *dubstep* | *industrial*)
    printf '2'
    return
    ;;
  *"drum and bass"* | *dnb* | *"hip hop"* | *"hip-hop"* | *rap* | *trap* | *grime*)
    printf '2'
    return
    ;;
  *classical* | *classic* | *orchestra* | *symphony* | *chamber* | *opera* | *baroque* | *romantic* | *choral* | *choir*)
    printf '1'
    return
    ;;
  *jazz* | *bebop* | *swing* | *bossa* | *blues*)
    printf '1'
    return
    ;;
  *folk* | *acoustic* | *"new age"* | *meditation*)
    printf '1'
    return
    ;;
  *)
    printf '0'
    return
    ;;
  esac
}

# Classify a raw genre tag string (from embedded metadata) into one of the three
# quality-threshold profiles.  Handles Picard-style multi-value tags (semicolon-
# separated, e.g. "Ambient;Electronic;Rock").  Returns the highest-energy profile
# found across all segments: high_energy > audiophile > standard.
# Outputs one of: "audiophile", "high_energy", "standard".
audio_classify_genre_tag() {
  local raw_tag="$1"
  local best=0
  local segment rank
  while IFS= read -r segment; do
    segment="$(printf '%s' "$segment" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$segment" ]] || continue
    rank="$(_audio_classify_genre_segment "$segment")"
    ((rank > best)) && best="$rank"
    ((best >= 2)) && break # short-circuit: can't go higher
  done < <(printf '%s\n' "${raw_tag//;/$'\n'}")
  case "$best" in
  2) printf 'high_energy' ;;
  1) printf 'audiophile' ;;
  *) printf 'standard' ;;
  esac
}

# Codec name normalisation — returns a lowercase codec identifier for a file.
# Handles edge cases where codec_name is unavailable (some containers) by
# falling back to codec_tag, codec_long_name, file extension, and profile.
audio_codec_name() {
  local in="$1"
  local codec codec_tag codec_long profile raw_meta ext detail audio_stream_idx base
  local has_stream_detail=0
  local -a detail_parts=()
  audio_ffprobe_meta_prime "$in"
  codec="$(audio_ffprobe_meta_get "$in" "stream_codec_name")"
  codec="$(printf '%s' "$codec" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$codec" in
  mpegaudio | mpeg_audio | mpeg_layer_3 | mpeg1layer3) codec="mp3" ;;
  libvorbis) codec="vorbis" ;;
  wmav1 | wmav2 | wmavoice) codec="wma" ;;
  esac
  case "$codec" in
  "" | "n/a" | "none" | "unknown") codec="" ;;
  esac
  if [[ -n "$codec" ]]; then
    printf '%s' "$codec"
    return 0
  fi

  audio_stream_idx="$(audio_ffprobe_meta_get "$in" "stream_index")"
  audio_stream_idx="$(printf '%s' "$audio_stream_idx" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ ! "$audio_stream_idx" =~ ^[0-9]+$ ]]; then
    printf ''
    return 0
  fi

  raw_meta="$(audio_ffprobe_meta_dump "$in")"
  [[ -n "$raw_meta" ]] || { printf ''; return 0; }
  codec_tag="$(audio_ffprobe_meta_get "$in" "stream_codec_tag_string")"
  codec_long="$(audio_ffprobe_meta_get "$in" "stream_codec_long_name")"
  profile="$(audio_ffprobe_meta_get "$in" "stream_profile")"

  codec_tag="$(printf '%s' "$codec_tag" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[^a-z0-9._+-]/_/g;s/__*/_/g')"
  codec_long="$(printf '%s' "$codec_long" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\+/_/g;s/[^a-z0-9._+-]/_/g;s/__*/_/g')"
  profile="$(printf '%s' "$profile" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\+/_/g;s/[^a-z0-9._+-]/_/g;s/__*/_/g')"

  base="$(basename "$in")"
  ext=""
  if [[ "$base" == *.* && "$base" != .* ]]; then
    ext="${base##*.}"
  fi
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._+-]/_/g;s/__*/_/g')"

  if [[ "$codec_long" == *"mpeg_audio_layer_3"* || "$codec_tag" == "0x0055" || "$ext" == "mp3" ]]; then
    printf 'mp3'; return 0
  fi
  if [[ "$codec_long" == *"vorbis"* ]]; then
    printf 'vorbis'; return 0
  fi
  if [[ "$codec_long" == *"opus"* || "$ext" == "opus" ]]; then
    printf 'opus'; return 0
  fi
  if [[ "$codec_long" == *"advanced_audio_coding"* || "$codec_long" == *"aac"* || "$profile" == *"aac"* ]]; then
    printf 'aac'; return 0
  fi
  if [[ "$codec_long" == *"windows_media_audio"* || "$ext" == "wma" ]]; then
    printf 'wma'; return 0
  fi

  if [[ -n "$codec_tag" && "$codec_tag" != "0x0000" && "$codec_tag" != "[0][0][0][0]" ]]; then
    has_stream_detail=1; detail_parts+=("tag=$codec_tag")
  fi
  if [[ -n "$codec_long" && "$codec_long" != "unknown" && "$codec_long" != "n_a" ]]; then
    has_stream_detail=1; detail_parts+=("name=$codec_long")
  fi
  if [[ -n "$profile" && "$profile" != "unknown" && "$profile" != "n_a" ]]; then
    has_stream_detail=1; detail_parts+=("profile=$profile")
  fi
  if ((has_stream_detail == 0)); then
    printf ''; return 0
  fi
  [[ -n "$ext" ]] && detail_parts+=("ext=$ext")
  detail=""
  if ((${#detail_parts[@]} > 0)); then
    detail="$(IFS=';'; printf '%s' "${detail_parts[*]}")"
    printf 'unknown{%s}' "$detail"; return 0
  fi
  printf 'unknown'
}

# Returns true (0) for known lossy codec families.
audio_is_lossy_codec() {
  local codec="$1"
  case "$codec" in
  mp2 | mp3 | aac | vorbis | opus | ac3 | eac3 | dca | dts | wma | wmav1 | wmav2 | wmavoice | amr_nb | amr_wb | gsm | g722 | g723_1 | g726 | g729 | qcelp | cook | ra_144 | ra_288 | atrac1 | atrac3 | atrac3al | atrac3p | speex | nellymoser | qdm2 | alaw | mulaw | adpcm_*)
    return 0 ;;
  *) return 1 ;;
  esac
}

# Returns the source quality label for a single audio file in canonical format
# SR_HZ/BITS (e.g. "44100/24", "96000/24", "44100/32f").
# Uses the shared ffprobe-based probe path so recode planners and UI agree.
audio_source_quality_label() {
  local in="$1"
  local sr bit_label normalized codec
  sr="$(audio_probe_sample_rate_hz "$in")"
  codec="$(audio_codec_name "$in" || true)"
  bit_label="$(audio_probe_bit_depth_label "$in" "$codec")"
  if [[ "$sr" =~ ^[0-9]+$ ]] && ((sr > 0)) && [[ -n "$bit_label" ]]; then
    normalized="$(profile_normalize "${sr}/${bit_label}" || true)"
    if [[ -n "$normalized" ]]; then
      printf '%s\n' "$normalized"
      return 0
    fi
    printf '%s/%s\n' "$sr" "$bit_label"
    return 0
  fi
  if [[ "$sr" =~ ^[0-9]+$ ]] && ((sr > 0)); then
    printf '%s/??\n' "$sr"
    return 0
  fi
  printf '?/??\n'
}

# Returns the source quality label for an album (array of files).
# Returns "mixed" if tracks have differing quality profiles, "?" if all fail.
audio_album_source_quality_label() {
  local files_var="$1"
  local -n _aasql_files="$files_var"
  local first="" label f
  for f in "${_aasql_files[@]}"; do
    label="$(audio_source_quality_label "$f" || true)"
    [[ -n "$label" ]] || label="?"
    if [[ -z "$first" ]]; then
      first="$label"
    elif [[ "$label" != "$first" ]]; then
      printf 'mixed\n'
      return 0
    fi
  done
  [[ -n "$first" ]] || first="?"
  printf '%s\n' "$first"
}

audio_album_summary() {
  local files_var="$1"
  local out_var="${2:-AUDIO_ALBUM_SUMMARY}"
  # shellcheck disable=SC2178
  local -n files_ref="$files_var"
  # shellcheck disable=SC2178
  local -n out_ref="$out_var"
  local first_quality="" first_codec="" quality codec bitrate_bps bitrate_kbps
  local total_kbps=0 bitrate_count=0 has_lossy=0 file_count=0
  local f

  out_ref=()
  out_ref[source_quality]="?"
  out_ref[bitrate_label]=""
  out_ref[codec_name]="unknown"
  out_ref[has_lossy]="0"
  out_ref[file_count]="0"

  for f in "${files_ref[@]}"; do
    audio_ffprobe_meta_prime "$f"
    quality="$(audio_source_quality_label "$f" || true)"
    [[ -n "$quality" ]] || quality="?"
    codec="$(audio_codec_name "$f" || true)"
    [[ -n "$codec" ]] || codec="unknown"
    bitrate_bps="$(audio_probe_bitrate_bps "$f" || true)"
    bitrate_kbps=0
    if [[ "$bitrate_bps" =~ ^[0-9]+$ ]] && ((bitrate_bps > 0)); then
      bitrate_kbps=$(((bitrate_bps + 500) / 1000))
      total_kbps=$((total_kbps + bitrate_kbps))
      bitrate_count=$((bitrate_count + 1))
    fi
    if audio_is_lossy_codec "$codec"; then
      has_lossy=1
    fi

    if [[ -z "$first_quality" ]]; then
      first_quality="$quality"
    elif [[ "$quality" != "$first_quality" ]]; then
      first_quality="mixed"
    fi

    if [[ -z "$first_codec" ]]; then
      first_codec="$codec"
    elif [[ "$codec" != "$first_codec" ]]; then
      first_codec="mixed"
    fi

    file_count=$((file_count + 1))
  done

  if ((file_count > 0)); then
    out_ref[file_count]="$file_count"
  fi
  if [[ -n "$first_quality" ]]; then
    out_ref[source_quality]="$first_quality"
  fi
  if [[ -n "$first_codec" ]]; then
    out_ref[codec_name]="$first_codec"
  fi
  if ((bitrate_count > 0)); then
    out_ref[bitrate_label]="$(((total_kbps + (bitrate_count / 2)) / bitrate_count))k"
  fi
  out_ref[has_lossy]="$has_lossy"
}

# Remove tab, newline, and carriage-return characters from a string (for safe
# use as a TSV cell value or Rich table cell).
audio_sanitize_cell() {
  local s="$1"
  s="${s//$'\t'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  printf '%s\n' "$s"
}

audio_save_true_peak_cache() {
  local file="$1"
  local in_var="$2"
  local sep="${3:-$'\037'}"
  local -n in_ref="$in_var"
  local tmp key path mtime size true_peak
  tmp="${file}.tmp.$$"
  : >"$tmp"
  for key in "${!in_ref[@]}"; do
    IFS="$sep" read -r path mtime size <<<"$key"
    true_peak="${in_ref[$key]}"
    printf '%s\t%s\t%s\t%s\n' "$path" "$mtime" "$size" "$true_peak" >>"$tmp"
  done
  mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# audvalue_scan_album — DR14 + spectral recode analysis via audlint-value.
#
# Calls audlint-value on ALBUM_DIR and populates the following globals:
#   AUDVALUE_RECODE_TO   — raw SR/bits e.g. "48000/24"
#   AUDVALUE_FAKE_UPSCALE — 1 when audlint-analyze marked fake upscale, else 0
#   AUDVALUE_HAS_FAKE_TRACKS — 1 when any track looked fake-upscaled, else 0
#   AUDVALUE_FAMILY_SR_HZ — resolved 44.1k / 48k family when fake (or "")
#   AUDVALUE_ANALYZE_DECISION — audlint-analyze decision summary
#   AUDVALUE_DR          — DR14 integer
#   AUDVALUE_GRADE       — mastering grade S/A/B/C/F
#   AUDVALUE_GENRE       — genre profile used (audiophile|high_energy|standard)
#   AUDVALUE_SR_HZ       — sampling rate from dr14meter report (or "")
#   AUDVALUE_BITRATE_KBS — average bitrate from dr14meter report (or "")
#   AUDVALUE_BITS        — bits per sample from dr14meter report (or "")
#
# Usage:
#   audvalue_scan_album "/path/to/album" [genre_profile]
#   Returns 0 on success, 1 on failure.
#
# The RECODE column value and needs_recode flag should be computed by the
# caller from AUDVALUE_RECODE_TO vs the source profile (CURR column).
# ---------------------------------------------------------------------------
audvalue_scan_album() {
  local album_dir="$1"
  local genre_profile="${2:-standard}"

  AUDVALUE_RECODE_TO=""
  AUDVALUE_FAKE_UPSCALE="0"
  AUDVALUE_HAS_FAKE_TRACKS="0"
  AUDVALUE_FAMILY_SR_HZ=""
  AUDVALUE_ANALYZE_DECISION=""
  AUDVALUE_DR=""
  AUDVALUE_GRADE=""
  AUDVALUE_GENRE="$genre_profile"
  AUDVALUE_SR_HZ=""
  AUDVALUE_BITRATE_KBS=""
  AUDVALUE_BITS=""

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local audlint_value_bin="${AUDLINT_VALUE_BIN:-$script_dir/../../bin/audlint-value.sh}"
  if [[ ! -x "$audlint_value_bin" ]]; then
    # Fallback: search relative to this lib file's location.
    audlint_value_bin="$(cd "$script_dir" && cd ../../bin 2>/dev/null && pwd)/audlint-value.sh"
  fi

  [[ -x "$audlint_value_bin" ]] || return 1

  # AUDLINT_VALUE_PYTHON_BIN allows tests to override python3 for JSON parsing
  # independently of AUDL_PYTHON_BIN.
  local python_bin="${AUDLINT_VALUE_PYTHON_BIN:-${PYTHON_BIN:-python3}}"
  local json_out
  json_out="$(GENRE_PROFILE="$genre_profile" "$audlint_value_bin" "$album_dir" 2>/dev/null)" || return 1

  # Parse JSON fields with python3 (already a required dep).
  local parsed
  parsed="$("$python_bin" - "$json_out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
def s(v): return str(v) if v is not None else ""
print(data.get("recodeTo",""))
print("1" if data.get("fakeUpscale") else "0")
print("1" if data.get("hasFakeUpscaleTracks") else "0")
print(s(data.get("familySampleRateHz","")))
print(s(data.get("analyzeDecision","")))
print(s(data.get("drTotal","")))
print(data.get("grade",""))
print(data.get("genreProfile","standard"))
print(s(data.get("samplingRateHz","")))
print(s(data.get("averageBitrateKbs","")))
print(s(data.get("bitsPerSample","")))
PY
  )" || return 1

  {
    IFS= read -r AUDVALUE_RECODE_TO
    IFS= read -r AUDVALUE_FAKE_UPSCALE
    IFS= read -r AUDVALUE_HAS_FAKE_TRACKS
    IFS= read -r AUDVALUE_FAMILY_SR_HZ
    IFS= read -r AUDVALUE_ANALYZE_DECISION
    IFS= read -r AUDVALUE_DR
    IFS= read -r AUDVALUE_GRADE
    IFS= read -r AUDVALUE_GENRE
    IFS= read -r AUDVALUE_SR_HZ
    IFS= read -r AUDVALUE_BITRATE_KBS
    IFS= read -r AUDVALUE_BITS
  } <<< "$parsed"

  [[ "$AUDVALUE_FAKE_UPSCALE" =~ ^[01]$ ]] || AUDVALUE_FAKE_UPSCALE="0"
  [[ "$AUDVALUE_HAS_FAKE_TRACKS" =~ ^[01]$ ]] || AUDVALUE_HAS_FAKE_TRACKS="0"
  [[ -n "$AUDVALUE_RECODE_TO" && -n "$AUDVALUE_DR" && -n "$AUDVALUE_GRADE" ]] || return 1
  return 0
}

# Normalize a profile string into canonical SR_HZ/BITS format.
audvalue_format_profile() {
  local raw="$1"
  local normalized
  normalized="$(profile_normalize "$raw" || true)"
  if [[ -n "$normalized" ]]; then
    printf '%s\n' "$normalized"
  else
    printf '%s\n' "$raw"
  fi
}
