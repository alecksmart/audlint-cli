#!/usr/bin/env bash
# audlint-analyze — Spectral bandwidth analysis: determines the ideal recode
# target profile (SR/bits) for an album directory by inspecting actual source
# files via FFT-based frequency cutoff detection.
#
# Output (stdout):
#   On success: SR/bits e.g. "48000/24"
#   On no-recode-needed: "Re-encoding not needed" (exit 0)
#
# Cache:
#   Writes .sox_album_profile in the album dir after analysis.
#   Writes .sox_album_done when all files match the target (no-recode guard).
#
# Algorithm:
#   For each track, samples up to MAX_WINDOWS windows of WINDOW_SEC seconds,
#   computes FFT magnitude spectrum, finds the highest frequency bin above
#   THRESH_REL_DB dB relative to the spectral peak, applies HEADROOM_HZ
#   headroom, and maps to the nearest standard SR tier (44100, 48000, 96000,
#   192000) without ever upsampling above the source SR.
#   Album target SR = max of per-track targets. Album bits = min(24, max_src_bits).
#
# Dependencies: sox (sox_ng recommended), soxi, python3 (with numpy)
# Optional:     ffprobe — used as duration fallback for containers where soxi
#               reports 0 duration (ALAC/AAC in M4A with older sox builds)

set -euo pipefail

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

SCRIPT_RULESET="v2"
HEADROOM_HZ="${AUDLINT_ANALYZE_HEADROOM_HZ:-500}"
THRESH_REL_DB="${AUDLINT_ANALYZE_THRESH_REL_DB:--55}"
WINDOW_SEC="${AUDLINT_ANALYZE_WINDOW_SEC:-8}"
MAX_WINDOWS="${AUDLINT_ANALYZE_MAX_WINDOWS:-12}"
FINGERPRINT_SAMPLE_BYTES="${AUDLINT_ANALYZE_FINGERPRINT_SAMPLE_BYTES:-65536}"
FINGERPRINT_MODE="meta+headtail-v1"

PYTHON_BIN="${PYTHON_BIN:-python3}"

show_help() {
  cat <<'EOF'
Usage: audlint-analyze [--json] FILE_OR_ALBUM_DIR

Determine the ideal recode target profile (SR/bits) for an album directory
by inspecting actual source files via FFT-based spectral cutoff detection.

Output:
  default:
    SR/bits e.g. "48000/24"               — recode target
    "Re-encoding not needed"              — all files already match target
  --json:
    JSON payload with album target + per-track spectral cutoff details

Cache files written into the album directory:
  .sox_album_profile   — RULESET/TARGET_SR/TARGET_BITS + fingerprint hashes
  .sox_album_done      — written when no recode is needed

Environment overrides:
  AUDLINT_ANALYZE_HEADROOM_HZ    Hz of headroom below spectral cutoff (default: 500)
  AUDLINT_ANALYZE_THRESH_REL_DB  dB threshold relative to spectral peak (default: -55)
  AUDLINT_ANALYZE_WINDOW_SEC     analysis window length in seconds (default: 8)
  AUDLINT_ANALYZE_MAX_WINDOWS    maximum analysis windows per track (default: 12)
  AUDLINT_ANALYZE_FINGERPRINT_SAMPLE_BYTES
                                bytes sampled from file head+tail for content hash
                                (default: 65536)

Dependencies: sox (sox_ng recommended), soxi, python3 (with numpy)
Optional:     ffprobe — duration fallback for ALAC/AAC-in-M4A containers
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

if [[ $# -eq 1 && ("${1:-}" == "-h" || "${1:-}" == "--help") ]]; then
  show_help
  exit 0
fi

OUTPUT_MODE="profile"
if [[ "${1:-}" == "--json" ]]; then
  OUTPUT_MODE="json"
  shift
fi

[[ $# -eq 1 ]] || { show_help >&2; exit 2; }

if ! have "$PYTHON_BIN"; then
  echo "Missing dep: python3" >&2
  exit 1
fi
if ! { have sox && have soxi; } && ! have ffmpeg; then
  echo "Missing deps: require sox+soxi or ffmpeg for audio decode" >&2
  exit 1
fi

IN="$1"
if [[ -d "$IN" ]]; then
  ALBUM_DIR="$(cd "$IN" && pwd)"
else
  [[ -f "$IN" ]] || { echo "Not found: $IN" >&2; exit 1; }
  ALBUM_DIR="$(cd "$(dirname "$IN")" && pwd)"
fi

PROFILE_FILE="$ALBUM_DIR/.sox_album_profile"
DONE_FILE="$ALBUM_DIR/.sox_album_done"

profile_get() {
  local key="$1"
  grep -E "^${key}=" "$PROFILE_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

compute_source_fingerprint() {
  "$PYTHON_BIN" - "$ALBUM_DIR" "$FINGERPRINT_SAMPLE_BYTES" "${FILES[@]}" <<'PY'
import hashlib
import os
import sys

album_dir = sys.argv[1]
sample_bytes = int(sys.argv[2])
files = sorted(sys.argv[3:])

h = hashlib.sha256()
h.update(b"audlint-analyze-source-fingerprint-v1\0")
h.update(str(sample_bytes).encode("ascii", "strict"))
h.update(b"\0")

for path in files:
    rel = os.path.relpath(path, album_dir)
    st = os.stat(path, follow_symlinks=True)
    h.update(rel.encode("utf-8", "surrogateescape"))
    h.update(b"\0")
    h.update(str(st.st_size).encode("ascii", "strict"))
    h.update(b"\0")
    h.update(str(st.st_mtime_ns).encode("ascii", "strict"))
    h.update(b"\0")

    with open(path, "rb") as fh:
        head = fh.read(sample_bytes)
        if st.st_size > sample_bytes:
            fh.seek(max(0, st.st_size - sample_bytes))
            tail = fh.read(sample_bytes)
        else:
            tail = b""

    h.update(hashlib.blake2b(head, digest_size=16).digest())
    h.update(hashlib.blake2b(tail, digest_size=16).digest())

print(h.hexdigest())
PY
}

compute_config_fingerprint() {
  "$PYTHON_BIN" - "$SCRIPT_RULESET" "$HEADROOM_HZ" "$THRESH_REL_DB" "$WINDOW_SEC" "$MAX_WINDOWS" "$FINGERPRINT_SAMPLE_BYTES" "$FINGERPRINT_MODE" <<'PY'
import hashlib
import sys

parts = [
    "audlint-analyze-config-fingerprint-v1",
    f"ruleset={sys.argv[1]}",
    f"headroom_hz={sys.argv[2]}",
    f"thresh_rel_db={sys.argv[3]}",
    f"window_sec={sys.argv[4]}",
    f"max_windows={sys.argv[5]}",
    f"fp_sample_bytes={sys.argv[6]}",
    f"fp_mode={sys.argv[7]}",
]
joined = "\n".join(parts).encode("utf-8", "strict")
print(hashlib.sha256(joined).hexdigest())
PY
}

album_matches_target_profile() {
  local target_sr="$1"
  local target_bits="$2"
  local f sr bits
  for f in "${FILES[@]}"; do
    sr="$(soxi -r "$f" 2>/dev/null || true)"
    bits="$(soxi -b "$f" 2>/dev/null || true)"
    sr="${sr%%.*}"
    bits="${bits%%.*}"

    if [[ ! "$sr" =~ ^[0-9]+$ || "$sr" -le 0 ]]; then
      sr="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nokey=1:noprint_wrappers=1 "$f" </dev/null 2>/dev/null | head -n1 || true)"
      sr="${sr%%.*}"
    fi
    if [[ ! "$bits" =~ ^[0-9]+$ || "$bits" -le 0 ]]; then
      bits="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample,bits_per_sample -of default=nokey=1:noprint_wrappers=1 "$f" </dev/null 2>/dev/null | awk 'NF{print; exit}' || true)"
      bits="${bits%%.*}"
    fi
    [[ "$sr" =~ ^[0-9]+$ && "$bits" =~ ^[0-9]+$ ]] || return 1
    [[ "$sr" == "$target_sr" ]] || return 1
    (( bits >= target_bits )) || return 1
  done
  return 0
}

# collect audio files (non-recursive)
mapfile -t FILES < <(
  # shellcheck disable=SC2046
  find "$ALBUM_DIR" -maxdepth 1 -type f \( $(audio_find_iname_args) \) -print | sort
)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No audio files found in: $ALBUM_DIR" >&2
  exit 1
fi

CURRENT_SOURCE_FINGERPRINT="$(compute_source_fingerprint)"
CURRENT_CONFIG_FINGERPRINT="$(compute_config_fingerprint)"

# If already profiled and marked done, verify and short-circuit.
# JSON mode always performs a fresh analysis because callers expect per-track details.
if [[ "$OUTPUT_MODE" != "json" && -f "$PROFILE_FILE" && -f "$DONE_FILE" ]]; then
  PROFILE_RULESET="$(profile_get RULESET)"
  PROFILE_TARGET_SR="$(profile_get TARGET_SR)"
  PROFILE_TARGET_BITS="$(profile_get TARGET_BITS)"
  PROFILE_SOURCE_FINGERPRINT="$(profile_get SOURCE_FINGERPRINT)"
  PROFILE_CONFIG_FINGERPRINT="$(profile_get CONFIG_FINGERPRINT)"
  PROFILE_FINGERPRINT_MODE="$(profile_get FINGERPRINT_MODE)"

  if [[ "$PROFILE_RULESET" == "$SCRIPT_RULESET" \
    && -n "$PROFILE_TARGET_SR" \
    && -n "$PROFILE_TARGET_BITS" \
    && -n "$PROFILE_SOURCE_FINGERPRINT" \
    && -n "$PROFILE_CONFIG_FINGERPRINT" \
    && "$PROFILE_FINGERPRINT_MODE" == "$FINGERPRINT_MODE" \
    && "$PROFILE_SOURCE_FINGERPRINT" == "$CURRENT_SOURCE_FINGERPRINT" \
    && "$PROFILE_CONFIG_FINGERPRINT" == "$CURRENT_CONFIG_FINGERPRINT" ]]; then
    echo "Re-encoding not needed"
    exit 0
  fi
fi

# Analyse all tracks → choose album target.
tmpjson="$(mktemp -t sox_analyze.XXXXXX)"

# shellcheck disable=SC2016
"$PYTHON_BIN" - "${FILES[@]}" "$HEADROOM_HZ" "$THRESH_REL_DB" "$WINDOW_SEC" "$MAX_WINDOWS" <<'PY' >"$tmpjson"
import sys, subprocess, statistics, json, shutil

files = sys.argv[1:-4]
HEADROOM_HZ = int(sys.argv[-4])
THRESH_REL_DB = float(sys.argv[-3])
WINDOW_SEC = float(sys.argv[-2])
MAX_WINDOWS = int(sys.argv[-1])

HAS_FFPROBE = shutil.which("ffprobe") is not None
HAS_FFMPEG  = shutil.which("ffmpeg") is not None

def soxi(field, path):
    p = subprocess.run(["soxi", field, path], capture_output=True, text=True)
    if p.returncode != 0:
        return None
    try:
        return float(p.stdout.strip())
    except Exception:
        return None

def ffprobe_stream(path, field):
    if not HAS_FFPROBE:
        return None
    p = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0",
         "-show_entries", f"stream={field}",
         "-of", "default=nokey=1:noprint_wrappers=1", path],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        return None
    for line in p.stdout.splitlines():
        try:
            v = float(line.strip())
            return v if v > 0 else None
        except Exception:
            pass
    return None

def ffprobe_duration(path):
    if not HAS_FFPROBE:
        return None
    p = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nokey=1:noprint_wrappers=1", path],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        return None
    for line in p.stdout.splitlines():
        try:
            return float(line.strip())
        except Exception:
            pass
    return None

def audio_meta(path):
    sr   = soxi("-r", path)
    dur  = soxi("-D", path)
    bits = soxi("-b", path)
    # soxi returns None or 0 for formats it cannot handle (e.g. opus, AAC-in-M4A).
    if not sr or sr <= 0:
        sr = ffprobe_stream(path, "sample_rate")
    if dur is None or dur <= 0:
        dur = ffprobe_duration(path)
    if not bits or bits <= 0:
        bits = ffprobe_stream(path, "bits_per_raw_sample") or ffprobe_stream(path, "bits_per_sample")
    return sr, dur, bits

def decode_window(path, sr, t0):
    """Return raw f32le mono bytes for one analysis window, trying sox then ffmpeg."""
    cmd = ["sox", path, "-t", "f32", "-c", "1", "-r", str(int(sr)), "-", "trim", f"{t0}", f"{WINDOW_SEC}"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    raw = p.stdout.read()
    p.wait()
    if p.returncode == 0 and raw:
        return raw
    if HAS_FFMPEG:
        cmd = ["ffmpeg", "-v", "error", "-ss", f"{t0}", "-t", f"{WINDOW_SEC}",
               "-i", path, "-ac", "1", "-ar", str(int(sr)), "-f", "f32le", "-"]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        raw = p.stdout.read()
        p.wait()
        if p.returncode == 0 and raw:
            return raw
    return b""

def analyze_cutoff(path):
    sr, dur, _ = audio_meta(path)
    if not sr or not dur:
        return None, None, None

    nwin = min(MAX_WINDOWS, max(1, int(dur // WINDOW_SEC)))
    starts = []
    if nwin == 1:
        starts = [max(0.0, (dur - WINDOW_SEC) * 0.5)]
    else:
        for i in range(nwin):
            t = (dur - WINDOW_SEC) * (0.1 + 0.8 * (i / (nwin - 1)))
            starts.append(max(0.0, min(t, max(0.0, dur - WINDOW_SEC))))

    cutoffs = []
    try:
        import numpy as np
    except Exception:
        return sr, dur, None

    for t0 in starts:
        raw = decode_window(path, sr, t0)
        if not raw:
            continue

        x = np.frombuffer(raw, dtype=np.float32)
        if x.size < int(sr):  # too short
            continue
        x = x - np.mean(x)
        w = np.hanning(x.size)
        X = np.fft.rfft(x * w)
        mag = np.abs(X)
        peak = mag.max() if mag.size else 0.0
        if peak <= 0:
            continue

        db = 20.0 * np.log10(np.maximum(mag / peak, 1e-12))
        idx = (db >= THRESH_REL_DB).nonzero()[0]
        if idx.size == 0:
            continue
        k = int(idx.max())
        # rfft has N/2+1 bins; Nyquist is sr/2 at last bin
        f = (k / (mag.size - 1)) * (sr / 2.0)
        cutoffs.append(float(f))

    if not cutoffs:
        return sr, dur, None
    return sr, dur, float(statistics.median(cutoffs))

def map_to_target_sr(cutoff_hz, sr_in):
    if cutoff_hz is None:
        return int(sr_in)
    eff = max(0.0, cutoff_hz + HEADROOM_HZ)
    if eff <= 22050:
        tgt = 44100
    elif eff <= 24000:
        tgt = 48000
    elif eff <= 48000:
        tgt = 96000
    else:
        tgt = 192000
    return int(min(tgt, sr_in))  # never upsample

tracks = []
for f in files:
    sr_in, _, bits_in = audio_meta(f)
    sr, dur, cutoff = analyze_cutoff(f)
    if sr is None:
        continue
    tgt_sr = map_to_target_sr(cutoff, sr)
    tracks.append({
        "file": f,
        "sr_in": int(sr_in) if sr_in else None,
        "bits_in": int(bits_in) if bits_in else None,
        "cutoff_hz": cutoff,
        "tgt_sr": tgt_sr,
    })

if not tracks:
    print(json.dumps({"error": "no_tracks"}))
    sys.exit(0)

album_sr = max(t["tgt_sr"] for t in tracks if t["tgt_sr"] is not None)

bits_list = [t["bits_in"] for t in tracks if t["bits_in"]]
album_bits = 24
if bits_list:
    album_bits = min(24, max(bits_list))
    album_bits = 16 if album_bits < 16 else album_bits

print(json.dumps({"album_sr": int(album_sr), "album_bits": int(album_bits), "tracks": tracks}))
PY

if ! grep -q '"album_sr"' "$tmpjson"; then
  echo "Analysis failed." >&2
  rm -f "$tmpjson"
  exit 1
fi

TARGET_SR="$("$PYTHON_BIN" -c 'import json;print(json.load(open("'"$tmpjson"'"))["album_sr"])')"
TARGET_BITS="$("$PYTHON_BIN" -c 'import json;print(json.load(open("'"$tmpjson"'"))["album_bits"])')"

cat >"$PROFILE_FILE" <<EOF
RULESET=$SCRIPT_RULESET
TARGET_SR=$TARGET_SR
TARGET_BITS=$TARGET_BITS
SOURCE_FINGERPRINT=$CURRENT_SOURCE_FINGERPRINT
CONFIG_FINGERPRINT=$CURRENT_CONFIG_FINGERPRINT
FINGERPRINT_MODE=$FINGERPRINT_MODE
EOF

if album_matches_target_profile "$TARGET_SR" "$TARGET_BITS"; then
  : > "$DONE_FILE"
else
  rm -f "$DONE_FILE"
fi

if [[ "$OUTPUT_MODE" == "json" ]]; then
  cat "$tmpjson"
  rm -f "$tmpjson"
  exit 0
fi

rm -f "$tmpjson"
echo "${TARGET_SR}/${TARGET_BITS}"
