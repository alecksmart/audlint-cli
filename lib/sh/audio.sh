#!/opt/homebrew/bin/bash

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
      *.dsf
      *.dff
      *.wv
      *.ape
      *.mp4
      *.mp3
      *.ogg
      *.opus
    )
  else
    out_ref=(
      "$dir"/*.flac
      "$dir"/*.alac
      "$dir"/*.m4a
      "$dir"/*.wav
      "$dir"/*.dsf
      "$dir"/*.dff
      "$dir"/*.wv
      "$dir"/*.ape
      "$dir"/*.mp4
      "$dir"/*.mp3
      "$dir"/*.ogg
      "$dir"/*.opus
    )
  fi
  ((had_nullglob == 1)) || shopt -u nullglob
  ((had_nocaseglob == 1)) || shopt -u nocaseglob
  : "${#out_ref[@]}"
}

audio_has_files() {
  local dir="${1:-.}"
  local files=()
  audio_collect_files "$dir" files
  ((${#files[@]} > 0))
}

audio_probe_sample_rate_hz() {
  local in="$1"
  local sr
  sr="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  sr="${sr%%,*}"
  sr="$(printf '%s' "$sr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$sr" =~ ^[0-9]+$ ]] && ((sr > 0)); then
    printf '%s' "$sr"
  else
    printf '0'
  fi
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

audio_probe_true_peak_db() {
  local in="$1"
  local out peak
  out="$(ffmpeg -hide_banner -nostdin -i "$in" -af "loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary" -vn -sn -dn -f null /dev/null 2>&1 || true)"
  peak="$(printf '%s\n' "$out" | awk '/Input True Peak/ {print $(NF-1); exit}')"
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
  codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  codec="${codec%%,*}"
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

  audio_stream_idx="$(ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  audio_stream_idx="${audio_stream_idx%%,*}"
  audio_stream_idx="$(printf '%s' "$audio_stream_idx" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ ! "$audio_stream_idx" =~ ^[0-9]+$ ]]; then
    printf ''
    return 0
  fi

  raw_meta="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_tag_string,codec_long_name,profile -of default=noprint_wrappers=1:nokey=0 "$in" </dev/null 2>/dev/null || true)"
  [[ -n "$raw_meta" ]] || { printf ''; return 0; }
  codec_tag="$(printf '%s\n' "$raw_meta" | awk -F'=' '/^codec_tag_string=/{print $2; exit}')"
  codec_long="$(printf '%s\n' "$raw_meta" | awk -F'=' '/^codec_long_name=/{print $2; exit}')"
  profile="$(printf '%s\n' "$raw_meta" | awk -F'=' '/^profile=/{print $2; exit}')"

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

# Returns the source quality label for a single audio file (e.g. "44.1/24", "96/24", "44.1/32f").
# Uses three separate ffprobe fields: sample_rate, bits_per_raw_sample, sample_fmt.
audio_source_quality_label() {
  local in="$1"
  local sr bps sfmt bit_label src_label
  sr="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  sfmt="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of csv=p=0 "$in" </dev/null 2>/dev/null || true)"
  sr="${sr%%,*}"
  bps="${bps%%,*}"
  sfmt="${sfmt%%,*}"
  bit_label=""
  if [[ -n "$bps" && "$bps" != "N/A" ]]; then
    bit_label="$bps"
  else
    case "$sfmt" in
    s16 | s16p) bit_label="16" ;;
    s24 | s24p) bit_label="24" ;;
    s32 | s32p) bit_label="32" ;;
    flt | fltp) bit_label="32f" ;;
    dbl | dblp) bit_label="64f" ;;
    *) bit_label="" ;;
    esac
  fi
  if [[ -n "$sr" && "$sr" =~ ^[0-9]+$ ]]; then
    src_label="$(awk -v s="$sr" 'BEGIN{printf "%.1f", s/1000.0}')"
    src_label="${src_label%.0}"
  else
    src_label="?"
  fi
  if [[ -n "$bit_label" ]]; then
    printf '%s/%s\n' "$src_label" "$bit_label"
  else
    printf '%s/??\n' "$src_label"
  fi
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
