#!/opt/homebrew/bin/bash
# PROMPT: macOS/Bash 3.2. Hybrid normalizer with Technical Pre-Audit & Final Cleanup.
# Logic: Bake high-res; Tag lossy; Handle Opus/Ogg cover errors; 100% Audit; Optional Cleanup.

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
source "$BOOTSTRAP_DIR/../lib/sh/encoder.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/table.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$REPO_ROOT/.env" "$SCRIPT_DIR/.env" || true
ui_init_colors

# 1. Setup
AUTO_YES=false
USE_LOUDNORM=false

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")
  $(basename "$0") -y

Usage: $(basename "$0") [-y]

Options:
  -y   Auto-confirm prompts.
  -l   Use loudnorm analysis (true-peak + R128 gains).
  -h   Show this help message.
EOF
}

collect_boost_audio_files() {
  local out_var="${1:-FILES}"
  local -n out_ref="$out_var"
  local all_files=()
  local f ext
  out_ref=()
  audio_collect_files "." all_files
  for f in "${all_files[@]}"; do
    ext="${f##*.}"
    ext="${ext,,}"
    case "$ext" in
    flac | alac | m4a | wav | mp4 | mp3 | ogg | opus) out_ref+=("$f") ;;
    esac
  done
}

for bin in ffmpeg ffprobe bc; do
  if ! has_bin "$bin"; then
    echo "${RED}Missing dependency:${RESET} $bin"
    exit 2
  fi
done
table_require_rich || {
  echo "${RED}Missing dependency:${RESET} python rich (or set RICH_TABLE_CMD)." >&2
  exit 2
}
HAS_METAFLAC=false
if has_bin metaflac; then
  HAS_METAFLAC=true
fi
if [ "${1:-}" = "--help" ]; then
  show_help
  exit 0
fi

while getopts ":ylh" opt; do
  case "$opt" in
    y) AUTO_YES=true ;;
    l) USE_LOUDNORM=true ;;
    h) show_help; exit 0 ;;
    \?) show_help; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
collect_boost_audio_files FILES
BACKUP_DIR="before-recode"
SAFETY_MARGIN="-0.3"
MAP_FILE=".file_map.tmp"
FAIL_FILE=".failures.tmp"
FAIL_SUMMARY=".boost_failures.txt"
LOUDNORM_FILE=".loudnorm.tmp"
CUE_FILE=".cuesheet.tmp"
rm -f "$MAP_FILE"
rm -f "$FAIL_FILE"
rm -f "$FAIL_SUMMARY"
rm -f "$LOUDNORM_FILE"
rm -f "$CUE_FILE"

if [ ${#FILES[@]} -eq 0 ]; then
  echo "${YELLOW}No audio files found.${RESET}"
  exit 1
fi

# 2. Step 1: Technical Pre-Audit & Peak Analysis
echo "${BLUE}Step 1: Technical Pre-Audit & Analysis...${RESET}"
PRE_AUDIT_ROWS=()

MAX_PEAK="-100.0"
MAX_TRUE_PEAK="-100.0"
MIXED_CODECS=false
FIRST_CODEC=""
PEAK_MISSING=false
LOUDNESS_SUM="0"
LOUDNESS_DUR="0"
CUE_PRESENT=false

for f in "${FILES[@]}"; do
  CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$f")
  EXT="${f##*.}"

  NOTE="OK"
  if [[ "$CODEC" == "alac" && ( "$EXT" == "mp4" || "$EXT" == "MP4" ) ]]; then
      NOTE="FIX CONTAINER"
  elif [[ "$EXT" == "mp4" || "$EXT" == "MP4" ]]; then
      NOTE="LOSSLESS?"
  fi

  if [ -z "$FIRST_CODEC" ]; then FIRST_CODEC="$CODEC"; fi
  if [ "$CODEC" != "$FIRST_CODEC" ]; then MIXED_CODECS=true; fi

  HAS_CUE=false
  if [ "$CODEC" = "flac" ] && [ "$HAS_METAFLAC" = true ]; then
    CUE_DATA=$(metaflac --export-cuesheet-to=- "$f" 2>/dev/null)
    if [ -n "$CUE_DATA" ]; then
      HAS_CUE=true
    fi
  fi
  if [ "$HAS_CUE" = false ]; then
    CUE_TAG=$(ffprobe -v error -show_entries format_tags=CUESHEET -of default=noprint_wrappers=1:nokey=1 "$f")
    if [ -n "$CUE_TAG" ]; then
      HAS_CUE=true
    fi
  fi
  if [ "$HAS_CUE" = true ]; then
    CUE_PRESENT=true
    echo "$f" >> "$CUE_FILE"
    if [ "$NOTE" = "OK" ]; then
      NOTE="CUESHEET"
    else
      NOTE="${NOTE},CUESHEET"
    fi
  fi

  if [ "$USE_LOUDNORM" = true ]; then
    LN_OUT=$(ffmpeg -hide_banner -i "$f" -af "loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary" -vn -sn -dn -f null /dev/null 2>&1)
    TRUE_PEAK=$(printf "%s\n" "$LN_OUT" | grep "Input True Peak" | awk '{print $(NF-1)}')
    INPUT_I=$(printf "%s\n" "$LN_OUT" | grep "Input Integrated" | awk '{print $(NF-1)}')
    if [ -n "$TRUE_PEAK" ] && [ -n "$INPUT_I" ]; then
      echo "$f|$INPUT_I|$TRUE_PEAK" >> "$LOUDNORM_FILE"
      if (( $(echo "$TRUE_PEAK > $MAX_TRUE_PEAK" | bc -l) )); then MAX_TRUE_PEAK=$TRUE_PEAK; fi
      DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
      if [[ "$DURATION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        LOUDNESS_SUM=$(echo "scale=6; $LOUDNESS_SUM + ($INPUT_I * $DURATION)" | bc -l)
        LOUDNESS_DUR=$(echo "scale=6; $LOUDNESS_DUR + $DURATION" | bc -l)
      fi
    else
      PEAK_MISSING=true
    fi
  else
    PEAK=$(ffmpeg -hide_banner -i "$f" -af "volumedetect" -vn -sn -dn -f null /dev/null 2>&1 | grep "max_volume" | awk '{print $5}')
    if [ -n "$PEAK" ]; then
      if (( $(echo "$PEAK > $MAX_PEAK" | bc -l) )); then MAX_PEAK=$PEAK; fi
    else
      PEAK_MISSING=true
    fi
  fi

  PRE_AUDIT_ROWS+=("${f}"$'\t'"${CODEC}"$'\t'"${EXT}"$'\t'"${NOTE}")
done

if ((${#PRE_AUDIT_ROWS[@]} > 0)); then
  printf '%s\n' "${PRE_AUDIT_ROWS[@]}" | table_render_tsv \
    "Filename,Codec,Ext,Notes" \
    "35,10,8,22"
else
  printf '' | table_render_tsv "Filename,Codec,Ext,Notes" "35,10,8,22"
fi

if [ "$PEAK_MISSING" = true ]; then
  echo "${RED}Error:${RESET} Could not read max_volume for one or more files. Aborting."
  exit 2
fi

if [ "$USE_LOUDNORM" = true ]; then
  if (( $(echo "$LOUDNESS_DUR == 0" | bc -l) )); then
    echo "${RED}Error:${RESET} Loudnorm duration sum is zero. Aborting."
    exit 2
  fi
  ALBUM_I=$(echo "scale=6; $LOUDNESS_SUM / $LOUDNESS_DUR" | bc -l)
  POSSIBLE_GAIN=$(echo "scale=1; $SAFETY_MARGIN - ($MAX_TRUE_PEAK)" | bc -l)
  ALBUM_R128_GAIN=$(echo "scale=3; -23 - ($ALBUM_I)" | bc -l)
  ALBUM_PEAK_LINEAR=$(echo "scale=6; e(l(10)*($MAX_TRUE_PEAK)/20)" | bc -l)
else
  POSSIBLE_GAIN=$(echo "scale=1; $SAFETY_MARGIN - ($MAX_PEAK)" | bc -l)
  ALBUM_PEAK_LINEAR=$(echo "scale=6; e(l(10)*($MAX_PEAK)/20)" | bc -l)
fi

echo "------------------------------------------------"
if [ "$USE_LOUDNORM" = true ]; then
  echo "Highest TruePk:  ${MAX_TRUE_PEAK} dBTP"
  echo "Album LUFS:      ${ALBUM_I} LUFS"
else
  echo "Highest Peak:    ${MAX_PEAK} dB"
fi
echo "Net Gain:        +${POSSIBLE_GAIN} dB"
[[ "$MIXED_CODECS" = true ]] && echo "${YELLOW}Warning:         Mixed codecs detected in album!${RESET}"
echo "------------------------------------------------"

APPLY_GAIN=true
if (( $(echo "$POSSIBLE_GAIN < 0.3" | bc -l) )); then
  APPLY_GAIN=false
  if [ "$CUE_PRESENT" = false ]; then
    echo "${YELLOW}Gain is negligible. Exiting.${RESET}"
    exit 0
  else
    echo "${YELLOW}Gain is negligible, but cuesheets were found. Cleaning cuesheets only.${RESET}"
  fi
fi

if [ "$AUTO_YES" = true ]; then
  CONFIRM="y"
  echo "Execute Hybrid Normalization & Audit? (y/n): y"
else
  printf "Execute Hybrid Normalization & Audit? (y/n): "
  read CONFIRM
fi
[[ "$CONFIRM" != "y" ]] && exit 0

mkdir -p "$BACKUP_DIR"

# 3. Processing Loop
for f in "${FILES[@]}"; do
  CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$f")
  BIT_DEPTH=$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of default=noprint_wrappers=1:nokey=1 "$f")
  [[ -z "$BIT_DEPTH" || "$BIT_DEPTH" == "N/A" ]] && BIT_DEPTH=24

  BITRATE_RAW=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$f")
  if [[ "$BITRATE_RAW" =~ ^[0-9]+$ ]]; then BITRATE=$BITRATE_RAW; else BITRATE=0; fi

  EXT="${f##*.}"
  IS_TRUE_LOSSLESS=false
  if [[ "$CODEC" == "flac" || "$CODEC" == "alac" ]]; then
      if [ "$BITRATE" -gt 500000 ] || [ "$BITRATE" -eq 0 ]; then
          IS_TRUE_LOSSLESS=true
      fi
  fi

  HAS_CUE=false
  if [[ -f "$CUE_FILE" ]] && grep -Fxq "$f" "$CUE_FILE"; then
    HAS_CUE=true
  fi

  if [ "$IS_TRUE_LOSSLESS" = true ] && [ "$APPLY_GAIN" = true ]; then
      echo "${BLUE}[BAKING]${RESET} $f"
      OUT_EXT="$EXT"
      [[ "$CODEC" == "alac" ]] && OUT_EXT="m4a"

      CALC_DEPTH=24
      [[ "$BIT_DEPTH" -gt 24 ]] && CALC_DEPTH=32

      BASENAME="${f%.*}"
      NEW_NAME="$BASENAME.$OUT_EXT"
      echo "$f|$NEW_NAME" >> "$MAP_FILE"

      mv "$f" "$BACKUP_DIR/"
      if [[ "$CODEC" == "alac" ]]; then
        # ALAC: sox cannot write ALAC; stay on ffmpeg path.
        ffmpeg -hide_banner -strict experimental -i "$BACKUP_DIR/$f" \
          -af "volume=${POSSIBLE_GAIN}dB" \
          -c:a alac -sample_fmt s32p \
          -c:v copy -map_metadata 0 -metadata CUESHEET= "$NEW_NAME" -y </dev/null
        bake_rc=$?
      else
        encoder_bake_gain_flac \
          --in "$BACKUP_DIR/$f" --out "$NEW_NAME" \
          --bits "$CALC_DEPTH" --gain "$POSSIBLE_GAIN"
        bake_rc=$?
      fi
      if [[ $bake_rc -ne 0 ]]; then
        echo "${RED}FAILED:${RESET} $f"
        echo "$f" >> "$FAIL_FILE"
        continue
      fi
  else
      if [ "$APPLY_GAIN" = false ] && [ "$HAS_CUE" = false ]; then
        continue
      fi
      echo "${BLUE}[TAGGING]${RESET} $f"
      echo "$f|$f" >> "$MAP_FILE"

      if [ "$USE_LOUDNORM" = true ]; then
        TRACK_PEAK_DB=$(awk -F'|' -v f="$f" '$1==f{print $3}' "$LOUDNORM_FILE")
        TRACK_I=$(awk -F'|' -v f="$f" '$1==f{print $2}' "$LOUDNORM_FILE")
        if [ -n "$TRACK_I" ]; then
          TRACK_R128_GAIN=$(echo "scale=3; -23 - ($TRACK_I)" | bc -l)
        else
          TRACK_R128_GAIN="$POSSIBLE_GAIN"
        fi
      else
        TRACK_PEAK_DB=$(ffmpeg -hide_banner -i "$f" -af "volumedetect" -vn -sn -dn -f null /dev/null 2>&1 | grep "max_volume" | awk '{print $5}')
      fi
      if [ -n "$TRACK_PEAK_DB" ]; then
        TRACK_PEAK_LINEAR=$(echo "scale=6; e(l(10)*($TRACK_PEAK_DB)/20)" | bc -l)
      else
        TRACK_PEAK_LINEAR="1.0"
      fi

      if [ "$USE_LOUDNORM" = true ]; then
        TRACK_R128_Q=$(echo "scale=0; if ($TRACK_R128_GAIN>=0) $TRACK_R128_GAIN*256+0.5 else $TRACK_R128_GAIN*256-0.5" | bc -l)
        ALBUM_R128_Q=$(echo "scale=0; if ($ALBUM_R128_GAIN>=0) $ALBUM_R128_GAIN*256+0.5 else $ALBUM_R128_GAIN*256-0.5" | bc -l)
      fi

      ffmpeg -hide_banner -i "$f" -c copy -map 0 \
        -metadata REPLAYGAIN_TRACK_GAIN="${POSSIBLE_GAIN} dB" \
        -metadata REPLAYGAIN_TRACK_PEAK="${TRACK_PEAK_LINEAR}" \
        -metadata REPLAYGAIN_ALBUM_GAIN="${POSSIBLE_GAIN} dB" \
        -metadata REPLAYGAIN_ALBUM_PEAK="${ALBUM_PEAK_LINEAR}" \
        -metadata CUESHEET= \
        "temp_$f" -y </dev/null 2>/dev/null

      if [ $? -eq 0 ] && [ "$USE_LOUDNORM" = true ]; then
        if [ "$CODEC" = "opus" ]; then
          ffmpeg -hide_banner -i "temp_$f" -c copy -map 0 \
            -metadata R128_TRACK_GAIN="${TRACK_R128_Q}" \
            -metadata R128_ALBUM_GAIN="${ALBUM_R128_Q}" \
            -metadata REPLAYGAIN_TRACK_GAIN= \
            -metadata REPLAYGAIN_TRACK_PEAK= \
            -metadata REPLAYGAIN_ALBUM_GAIN= \
            -metadata REPLAYGAIN_ALBUM_PEAK= \
            "temp_${f}.r128" -y </dev/null 2>/dev/null
        elif [ "$CODEC" = "vorbis" ]; then
          ffmpeg -hide_banner -i "temp_$f" -c copy -map 0 \
            -metadata R128_TRACK_GAIN="${TRACK_R128_Q}" \
            -metadata R128_ALBUM_GAIN="${ALBUM_R128_Q}" \
            "temp_${f}.r128" -y </dev/null 2>/dev/null
        fi
        if [ -f "temp_${f}.r128" ]; then
          mv "temp_${f}.r128" "temp_$f"
        fi
      fi

      if [ $? -eq 0 ]; then
          mv "$f" "$BACKUP_DIR/"
          mv "temp_$f" "$f"
      else
          echo "  ${YELLOW}[!] Container issue; stripping cover art...${RESET}"
          ffmpeg -hide_banner -i "$f" -c:a copy -map 0:a \
            -metadata REPLAYGAIN_TRACK_GAIN="${POSSIBLE_GAIN} dB" \
            -metadata REPLAYGAIN_TRACK_PEAK="${TRACK_PEAK_LINEAR}" \
            -metadata REPLAYGAIN_ALBUM_GAIN="${POSSIBLE_GAIN} dB" \
            -metadata REPLAYGAIN_ALBUM_PEAK="${ALBUM_PEAK_LINEAR}" \
            -metadata CUESHEET= \
            "temp_$f" -y </dev/null
          if [ $? -eq 0 ] && [ "$USE_LOUDNORM" = true ]; then
            if [ "$CODEC" = "opus" ]; then
              ffmpeg -hide_banner -i "temp_$f" -c copy -map 0 \
                -metadata R128_TRACK_GAIN="${TRACK_R128_Q}" \
                -metadata R128_ALBUM_GAIN="${ALBUM_R128_Q}" \
                -metadata REPLAYGAIN_TRACK_GAIN= \
                -metadata REPLAYGAIN_TRACK_PEAK= \
                -metadata REPLAYGAIN_ALBUM_GAIN= \
                -metadata REPLAYGAIN_ALBUM_PEAK= \
                "temp_${f}.r128" -y </dev/null 2>/dev/null
            elif [ "$CODEC" = "vorbis" ]; then
              ffmpeg -hide_banner -i "temp_$f" -c copy -map 0 \
                -metadata R128_TRACK_GAIN="${TRACK_R128_Q}" \
                -metadata R128_ALBUM_GAIN="${ALBUM_R128_Q}" \
                "temp_${f}.r128" -y </dev/null 2>/dev/null
            fi
            if [ -f "temp_${f}.r128" ]; then
              mv "temp_${f}.r128" "temp_$f"
            fi
          fi
          if [ $? -eq 0 ]; then
             mv "$f" "$BACKUP_DIR/"
             mv "temp_$f" "$f"
          else
             echo "  ${RED}[FATAL] Failed:${RESET} $f"
             rm -f "temp_$f"
             echo "$f" >> "$FAIL_FILE"
             continue
          fi
      fi

      if [ "$HAS_CUE" = true ]; then
        if [ "$CODEC" = "flac" ] && [ "$HAS_METAFLAC" = true ]; then
          echo "${BLUE}[CUESHEET]${RESET} $f (removed)"
          metaflac --remove --block-type=CUESHEET "$f" >/dev/null 2>&1
          if [[ $? -ne 0 ]]; then
            echo "${RED}FAILED:${RESET} $f"
            echo "$f" >> "$FAIL_FILE"
            continue
          fi
        elif [ "$CODEC" != "flac" ]; then
          echo "${BLUE}[CUESHEET]${RESET} $f (removed)"
          ffmpeg -hide_banner -i "$f" -c copy -map 0 -map_metadata 0 -metadata CUESHEET= \
            "temp_$f" -y </dev/null 2>/dev/null
          if [ $? -eq 0 ]; then
            mv "$f" "$BACKUP_DIR/"
            mv "temp_$f" "$f"
          else
            echo "  ${YELLOW}[!] Cue cleanup failed; stripping cover art...${RESET}"
            ffmpeg -hide_banner -i "$f" -c:a copy -map 0:a -map_metadata 0 -metadata CUESHEET= \
              "temp_$f" -y </dev/null 2>/dev/null
            if [ $? -eq 0 ]; then
              mv "$f" "$BACKUP_DIR/"
              mv "temp_$f" "$f"
            else
              echo "  ${RED}[FATAL] Failed:${RESET} $f"
              rm -f "temp_$f"
              echo "$f" >> "$FAIL_FILE"
              continue
            fi
          fi
        fi
      fi
  fi
done

# 3.5 Cuesheet Verification
echo ""
echo "${BLUE}Step 1.5: Cuesheet Verification...${RESET}"
echo "--------------------------------------------------------------------------------"
CUE_REMAINING=false
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    continue
  fi
  HAS_CUE=false
  if [ "$HAS_METAFLAC" = true ]; then
    CUE_DATA=$(metaflac --export-cuesheet-to=- "$f" 2>/dev/null)
    if [ -n "$CUE_DATA" ]; then
      HAS_CUE=true
    fi
  fi
  if [ "$HAS_CUE" = false ]; then
    CUE_TAG=$(ffprobe -v error -show_entries format_tags=CUESHEET -of default=noprint_wrappers=1:nokey=1 "$f")
    if [ -n "$CUE_TAG" ]; then
      HAS_CUE=true
    fi
  fi
  if [ "$HAS_CUE" = true ]; then
    echo "${RED}[CUESHEET]${RESET} Still present: $f"
    CUE_REMAINING=true
    echo "$f" >> "$FAIL_FILE"
  fi
done
if [ "$CUE_REMAINING" = true ]; then
  echo "${RED}Cuesheet verification failed. See failures list.${RESET}"
fi

# 4. Step 2: Verification Audit & Cleanup
echo ""
echo "${BLUE}Step 2: Verification Audit...${RESET}"
VERIFY_ROWS=()

ANY_FAILURES=false
if [ -f "$MAP_FILE" ]; then
  while IFS="|" read -r orig_name new_file; do
    orig_path="$BACKUP_DIR/$orig_name"
    if [[ -f "$new_file" ]]; then
        s_new=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$new_file")
        d_new=$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of default=noprint_wrappers=1:nokey=1 "$new_file")

        # For the status, we just verify the file exists and is readable
        STATUS="PASS"
        [[ ! -s "$new_file" ]] && { STATUS="FAIL"; ANY_FAILURES=true; }
        if [[ -f "$FAIL_FILE" ]] && grep -Fxq "$orig_name" "$FAIL_FILE"; then
          STATUS="FAIL"
          ANY_FAILURES=true
        fi

        VERIFY_ROWS+=("${orig_name}"$'\t'"${STATUS}"$'\t'"${s_new}"$'\t'"${d_new}")
    fi
  done < "$MAP_FILE"
  rm -f "$MAP_FILE"
else
  echo "${YELLOW}No files were processed; skipping audit.${RESET}"
fi
if ((${#VERIFY_ROWS[@]} > 0)); then
  printf '%s\n' "${VERIFY_ROWS[@]}" | table_render_tsv \
    "Original Filename,Status,Samplerate,Bitdepth" \
    "35,12,10,8"
else
  printf '' | table_render_tsv \
    "Original Filename,Status,Samplerate,Bitdepth" \
    "35,12,10,8"
fi

if [ "$ANY_FAILURES" = false ]; then
    if [ "$AUTO_YES" = true ]; then
        DELETE_CONFIRM="y"
        printf "%sAudit 100%% Successful. Delete backup folder '%s'? (y/n): y%s\n" "$GREEN" "$BACKUP_DIR" "$RESET"
    else
        printf "%sAudit 100%% Successful. Delete backup folder '%s'? (y/n): %s" "$GREEN" "$BACKUP_DIR" "$RESET"
        read DELETE_CONFIRM
    fi
    if [[ "$DELETE_CONFIRM" == "y" ]]; then
        rm -rf "$BACKUP_DIR"
        echo "${GREEN}Cleanup complete. Album is ready for Plexamp.${RESET}"
    fi
else
    echo "${YELLOW}Caution: Some files did not pass audit. Backups preserved in '$BACKUP_DIR'.${RESET}"
fi

if [ "$ANY_FAILURES" = true ]; then
    printf "%sERRORS DETECTED. Backup folder preserved at: %s/%s%s\n" "$RED" "$(pwd)" "$BACKUP_DIR" "$RESET"
    {
      echo "Backup folder: $(pwd)/$BACKUP_DIR"
      echo "Failed files:"
      [[ -f "$FAIL_FILE" ]] && cat "$FAIL_FILE"
    } > "$FAIL_SUMMARY"
else
    rm -f "$FAIL_SUMMARY"
fi
rm -f "$FAIL_FILE"
rm -f "$LOUDNORM_FILE"
rm -f "$CUE_FILE"
