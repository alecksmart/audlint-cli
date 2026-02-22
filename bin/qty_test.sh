#!/opt/homebrew/bin/bash

# A tool that checks for the "soul" of the music (DR), the safety of the signal (True Peak), the honesty of the container (Bit-Depth), and the authenticity of the source (Frequency Cutoff).
# Final Pro-Tips for your 1,000+ Album Journey:
#
#    The "Fake" Hunt: Keep a close eye on that FREQ column for your 96kHz and 192kHz files. If you see anything consistently below 22050, you've found an upsampled "fake" that is just wasting hard drive space.
#
#    The Clipping Verdict: If you see ISP CLIPPING DETECTED on an album with a high DR (like DR12+), it usually means it was a great master that was simply transferred too "hot" during the final digital stage.
#
#    Performance: Since we’re doing deep True Peak analysis on 192kHz files, it might take a few seconds per track. If you're doing the whole library, it might be a "run it while you sleep" situation.


# Required check
for cmd in ffmpeg sox bc ffprobe; do
    if ! command -v "$cmd" &> /dev/null; then echo "Error: $cmd not found."; exit 1; fi
done

analyze_file() {
    local file="$1"
    
    # 1. Detect Genre for Thresholds
    local genre_tag
    genre_tag=$(ffprobe -v error -show_entries format_tags=genre -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    if [[ "$genre_tag" =~ (classical|jazz|blues|folk|acoustic) ]]; then
        s_thr=15; a_thr=12; b_thr=10; c_thr=7; profile="Audiophile"
    elif [[ "$genre_tag" =~ (metal|punk|techno|edm|dubstep|rap|hip) ]]; then
        s_thr=10; a_thr=8;  b_thr=6;  c_thr=4; profile="High-Energy"
    else
        s_thr=13; a_thr=10; b_thr=8;  c_thr=5; profile="Standard"
    fi

    # 2. Extract DR Score
    local dr_val
    dr_val=$(ffmpeg -i "$file" -af drmeter -f null - 2>&1 | grep "Overall DR" | awk '{print $NF}')
    [[ -z "$dr_val" ]] && dr_val="0.00"
    
    # 3. Get TRUE PEAK (dBTP)
    local tp_db
    tp_db=$(ffmpeg -i "$file" -af ebur128=peak=true -f null - 2>&1 | grep "True peak" | awk 'NR==1{print $3}')
    [[ -z "$tp_db" ]] && tp_db="0.00"

    # 4. Frequency Cutoff & Bit Depth via SoX
    local sox_out cutoff bit_info
    sox_out=$(sox "$file" -n stat stats 2>&1)
    cutoff=$(echo "$sox_out" | grep "Rough frequency" | awk '{print $4}')
    bit_info=$(echo "$sox_out" | grep "Bit-depth" | awk '{print $3}')
    
    [[ -z "$cutoff" ]] && cutoff="N/A"
    [[ -z "$bit_info" ]] && bit_info="??"

    # 5. Track Grading
    local grade="F"; local color="\033[0;31m"
    if (( $(echo "$dr_val >= $s_thr" | bc -l) )) && (( $(echo "$tp_db < -0.10" | bc -l) )); then
        grade="S"; color="\033[0;35m"
    elif (( $(echo "$dr_val >= $a_thr" | bc -l) )); then
        grade="A"; color="\033[0;32m"
    elif (( $(echo "$dr_val >= $b_thr" | bc -l) )); then
        grade="B"; color="\033[0;34m"
    elif (( $(echo "$dr_val >= $c_thr" | bc -l) )); then
        grade="C"; color="\033[0;33m"
    fi

    local track_name
    track_name=$(basename "$file")
    printf "%-25.25s | %-6s | %-6s | %-6s | %-7s | %b%-3s\033[0m\n" \
           "$track_name" "$dr_val" "$tp_db" "$bit_info" "$cutoff" "$color" "$grade"

    # Export data for album-wide stats
    echo "$dr_val|$tp_db|$s_thr|$a_thr|$b_thr|$c_thr"
}

target="$1"
[[ -z "$target" ]] && { echo "Usage: $0 /path/to/Music"; exit 1; }

# Recursive Directory Search
find "$target" -type d | while read -r subdir; do
    mapfile -d $'\0' audio_files < <(find "$subdir" -maxdepth 1 -type f \( -iname "*.flac" -o -iname "*.wav" -o -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.opus" -o -iname "*.dsf" -o -iname "*.dff" \) -print0 | sort -zV)

    if [ ${#audio_files[@]} -gt 0 ]; then
        album_total_dr=0; album_count=0; album_clipping=false
        # Defaults for album grading if no genre found
        s_t=13; a_t=10; b_t=8; c_t=5

        echo -e "\n\033[1;37mAlbum: $(basename "$subdir")\033[0m"
        echo "-----------------------------------------------------------------------------------------"
        printf "%-25s | %-6s | %-6s | %-6s | %-7s | %-5s\n" "TRACK NAME" "DR" "T-PK" "BITS" "FREQ" "GRADE"
        echo "-----------------------------------------------------------------------------------------"
        
        for audio_file in "${audio_files[@]}"; do
            # Capture the function output
            output=$(analyze_file "$audio_file" < /dev/null)
            
            # Print the table row (first line of output)
            echo "$output" | head -n 1
            
            # Parse the variables (second line of output)
            data=$(echo "$output" | tail -n 1)
            if [[ "$data" == *"|"* ]]; then
                v_dr=$(echo "$data" | cut -d'|' -f1)
                v_tp=$(echo "$data" | cut -d'|' -f2)
                s_t=$(echo "$data" | cut -d'|' -f3)
                a_t=$(echo "$data" | cut -d'|' -f4)
                b_t=$(echo "$data" | cut -d'|' -f5)
                c_t=$(echo "$data" | cut -d'|' -f6)

                album_total_dr=$(echo "$album_total_dr + $v_dr" | bc)
                ((album_count++))
                if (( $(echo "$v_tp >= 0.00" | bc -l) )); then album_clipping=true; fi
            fi
        done

        # FINAL ALBUM SUMMARY
        if [ "$album_count" -gt 0 ]; then
            avg_dr=$(echo "scale=2; $album_total_dr / $album_count" | bc)
            alb_grade="F"; alb_color="\033[0;31m"
            
            if (( $(echo "$avg_dr >= $s_t" | bc -l) )); then alb_grade="S"; alb_color="\033[0;35m"
            elif (( $(echo "$avg_dr >= $a_t" | bc -l) )); then alb_grade="A"; alb_color="\033[0;32m"
            elif (( $(echo "$avg_dr >= $b_t" | bc -l) )); then alb_grade="B"; alb_color="\033[0;34m"
            elif (( $(echo "$avg_dr >= $c_t" | bc -l) )); then alb_grade="C"; alb_color="\033[0;33m"
            fi

            echo "-----------------------------------------------------------------------------------------"
            echo -ne "ALBUM AVG DR: $avg_dr | FINAL GRADE: ${alb_color}${alb_grade}\033[0m"
            [[ "$album_clipping" == true ]] && echo -e " \033[0;33m(ISP CLIPPING DETECTED)\033[0m" || echo -e " \033[0;32m(CLEAN)\033[0m"
            echo "-----------------------------------------------------------------------------------------"
        fi
    fi
done