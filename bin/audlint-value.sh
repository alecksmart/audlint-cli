#!/usr/bin/env bash
# audlint-value — DR14 dynamic range + recode target analysis for an album.
#
# Combines:
#   audlint-analyze  — spectral FFT recode target (SR/bits, cascade-free)
#   dr14meter        — DR14 dynamic range measurement
#   dr_grade.py      — DR14 integer → mastering grade (preset-adaptive)
#
# Output (stdout): JSON
#   {
#     "recodeTo":          "48000/24",   raw SR/bits from audlint-analyze
#     "fakeUpscale":       true,         audlint-analyze fake-upscale verdict
#     "familySampleRateHz":48000,        resolved 44.1k/48k family when fake
#     "analyzeDecision":   "downgrade_fake_upscale",
#     "drTotal":           9,            DR14 album total
#     "grade":             "B",          mastering grade (S/A/B/C/F)
#     "genreProfile":      "standard",   scoring preset used for grading
#     "samplingRateHz":    96000,        from dr14meter report
#     "averageBitrateKbs": 2116,         from dr14meter report (null if absent)
#     "bitsPerSample":     24,           from dr14meter report (null if absent)
#     "tracks":            { "01 Track.flac": 10, ... }
#   }
#
# Scoring presets (DR14 thresholds → grade):
#
#   audiophile  (Classical, Jazz, Blues, Acoustic, Folk, Ambient, New-Age)
#     DR≥14→S  DR≥12→A  DR≥9→B  DR≥6→C  DR<6→F
#     Expects wide dynamic range; a rock-normal DR7 master gets C here.
#
#   high_energy (Rock, Metal, Punk, EDM, Hip-Hop, Electronic, Trap)
#     DR≥11→S  DR≥9→A  DR≥7→B  DR≥4→C  DR<4→F
#     Intentional loudness is stylistic convention; only defective masters fail.
#
#   standard    (Pop, R&B, Country, World, Unknown)
#     DR≥12→S  DR≥9→A  DR≥7→B  DR≥5→C  DR<5→F
#     Moderate thresholds that work across a broad range of recorded music.
#
# Dependencies: audlint-analyze, dr14meter, python3
# Optional:     GENRE_PROFILE env var (audiophile|high_energy|standard)

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
source "$BOOTSTRAP_DIR/../lib/sh/profile.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path

PYTHON_BIN="${AUDL_PYTHON_BIN:-python3}"
AUDLINT_ANALYZE_BIN="${AUDLINT_ANALYZE_BIN:-$SCRIPT_DIR/audlint-analyze.sh}"
DR14METER_BIN="${DR14METER_BIN:-dr14meter}"
DR_GRADE_PY="${DR_GRADE_PY:-$SCRIPT_DIR/../lib/py/dr_grade.py}"

show_help() {
  cat <<'EOF'
Usage: audlint-value ALBUM_DIR

Print DR14 dynamic range + recode target analysis as JSON.

Output fields:
  recodeTo          — target profile from spectral analysis e.g. "48000/24"
  fakeUpscale       — whether audlint-analyze marked the album as fake upscale
  familySampleRateHz — resolved 44.1k / 48k family when fake (or null)
  analyzeDecision   — audlint-analyze decision summary
  drTotal           — DR14 album total (integer)
  grade             — mastering grade: S / A / B / C / F
  genreProfile      — scoring preset used: audiophile | high_energy | standard
  samplingRateHz    — from dr14meter report (null if not detected)
  averageBitrateKbs — from dr14meter report (null if not detected)
  bitsPerSample     — from dr14meter report (null if not detected)
  tracks            — map of filename → per-track DR14 value

Scoring presets and DR14 thresholds:

  audiophile  (Classical, Jazz, Blues, Acoustic, Folk, Ambient, New-Age)
    DR≥14→S  DR≥12→A  DR≥9→B  DR≥6→C  DR<6→F
    Expects wide dynamic range.

  high_energy (Rock, Metal, Punk, EDM, Hip-Hop, Electronic, Trap)
    DR≥11→S  DR≥9→A  DR≥7→B  DR≥4→C  DR<4→F
    Intentional loudness is stylistic convention.

  standard    (Pop, R&B, Country, World, Unknown)
    DR≥12→S  DR≥9→A  DR≥7→B  DR≥5→C  DR<5→F

Override scoring preset:
  GENRE_PROFILE=audiophile audlint-value /path/to/album

Dependencies: audlint-analyze, dr14meter, python3
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

resolve_album_dir() {
  local raw="$1"
  local candidate=""
  local -a candidates=()

  candidates+=("$raw")
  candidates+=("${raw//\\\'/\'}")
  if [[ "$raw" == *\\ ]]; then
    candidates+=("${raw%\\}'")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      (cd "$candidate" && pwd)
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  -h | --help)
    show_help
    exit 0
    ;;
  -*)
    show_help >&2
    exit 2
    ;;
  *)
    break
    ;;
  esac
done
[[ $# -eq 1 ]] || { show_help >&2; exit 2; }

ALBUM_DIR="$1"
ALBUM_DIR="$(resolve_album_dir "$ALBUM_DIR")" || { echo "Not a directory: $1" >&2; exit 1; }

# Validate dependencies
[[ -x "$AUDLINT_ANALYZE_BIN" ]] || { echo "Missing executable: $AUDLINT_ANALYZE_BIN" >&2; exit 1; }
[[ -f "$DR_GRADE_PY" ]] || { echo "Missing: $DR_GRADE_PY" >&2; exit 1; }

if [[ "$DR14METER_BIN" == */* ]]; then
  [[ -x "$DR14METER_BIN" ]] || { echo "Missing executable dr14meter: $DR14METER_BIN" >&2; exit 1; }
else
  have "$DR14METER_BIN" || { echo "Missing dependency: dr14meter" >&2; exit 1; }
fi
have "$PYTHON_BIN" || { echo "Missing dependency: python3" >&2; exit 1; }

# ── Step 1: spectral recode target ─────────────────────────────────────────
analyze_cmd=("$AUDLINT_ANALYZE_BIN")
analyze_cmd+=("$ALBUM_DIR")
recode_to="$("${analyze_cmd[@]}")"
if [[ ! "$recode_to" =~ ^[0-9]+/[0-9]+$ ]]; then
  # Fallback: read profile cache directly (handles "Re-encoding not needed").
  recode_to="$(profile_cache_target_profile "$ALBUM_DIR" || true)"
fi
[[ "$recode_to" =~ ^[0-9]+/[0-9]+$ ]] || {
  echo "Unable to resolve recode target from audlint-analyze output" >&2
  exit 1
}
fake_upscale_raw="$(profile_cache_get "$ALBUM_DIR" "ALBUM_FAKE_UPSCALE" || true)"
has_fake_tracks_raw="$(profile_cache_get "$ALBUM_DIR" "ALBUM_HAS_FAKE_UPSCALE_TRACKS" || true)"
family_sr_raw="$(profile_cache_get "$ALBUM_DIR" "ALBUM_FAMILY_SR" || true)"
analyze_decision_raw="$(profile_cache_get "$ALBUM_DIR" "ALBUM_DECISION" || true)"
[[ "$fake_upscale_raw" =~ ^(0|1)$ ]] || fake_upscale_raw="0"
[[ "$has_fake_tracks_raw" =~ ^(0|1)$ ]] || has_fake_tracks_raw="0"
[[ "$family_sr_raw" =~ ^[0-9]+$ ]] || family_sr_raw=""

# ── Step 2: DR14 measurement ───────────────────────────────────────────────
tmp_out="$(mktemp -t audvalue_dr14.XXXXXX)"
report_file=""

cleanup() {
  rm -f "$tmp_out"
  if [[ -n "${report_file:-}" ]]; then
    rm -f "$report_file"
  fi
}
trap cleanup EXIT

dr14_rc=0
if "$DR14METER_BIN" -n -p "$ALBUM_DIR" >"$tmp_out" 2>&1; then
  dr14_rc=0
else
  dr14_rc=$?
fi

if grep -Eiq 'Official DR value:|^[[:space:]]*DR[[:space:]]*=|Total DR:|Album DR:' "$tmp_out"; then
  report_file="$tmp_out"
fi

report_name="$(grep -Eo 'dr14[^[:space:]]+\.txt' "$tmp_out" | tail -n1 || true)"

if [[ -z "$report_file" ]]; then
  report_file="$(
    "$PYTHON_BIN" - "$ALBUM_DIR" "$report_name" <<'PY'
import glob, os, sys
album_dir = sys.argv[1]
hint_name = sys.argv[2]
if hint_name:
    hinted = os.path.join(album_dir, hint_name)
    if os.path.isfile(hinted):
        print(hinted)
        raise SystemExit(0)
candidates = glob.glob(os.path.join(album_dir, "dr14*.txt"))
if not candidates:
    raise SystemExit(1)
candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
print(candidates[0])
PY
  )" || true
fi

if [[ -z "$report_file" || ! -f "$report_file" ]]; then
  echo "dr14meter failed for: $ALBUM_DIR" >&2
  if [[ -s "$tmp_out" ]]; then
    cat "$tmp_out" >&2
  elif [[ "$dr14_rc" -ne 0 ]]; then
    echo "dr14meter exited with status: $dr14_rc" >&2
  else
    echo "dr14meter produced no parseable report output" >&2
  fi
  exit 1
fi

# ── Step 3: parse report + grade ───────────────────────────────────────────
# Scoring preset: env var > standard (normalized in dr_grade.py)
genre_profile="${GENRE_PROFILE:-standard}"

"$PYTHON_BIN" - "$recode_to" "$report_file" "$ALBUM_DIR" "$genre_profile" "$DR_GRADE_PY" "$fake_upscale_raw" "$family_sr_raw" "$analyze_decision_raw" "$has_fake_tracks_raw" <<'PY'
import json, os, re, sys, importlib.util

recode_to   = sys.argv[1]
report_path = sys.argv[2]
album_dir   = sys.argv[3]
genre_profile = sys.argv[4]
dr_grade_py = sys.argv[5]
fake_upscale_raw = sys.argv[6]
family_sr_raw = sys.argv[7]
analyze_decision_raw = sys.argv[8]
has_fake_tracks_raw = sys.argv[9]

# Load dr_grade module from lib/py/
spec = importlib.util.spec_from_file_location("dr_grade", dr_grade_py)
dr_grade_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dr_grade_mod)
genre_profile = dr_grade_mod.normalize_genre_profile(genre_profile)

with open(report_path, "r", encoding="utf-8", errors="replace") as f:
    lines = [line.rstrip("\n") for line in f]

def as_number(raw: str):
    val = float(raw)
    if val.is_integer():
        return int(val)
    return val

dr_total          = None
sampling_rate_hz  = None
average_bitrate_kbs = None
bits_per_sample   = None
tracks            = {}

album_files = {}
for entry in os.listdir(album_dir):
    path = os.path.join(album_dir, entry)
    if os.path.isfile(path):
        album_files[entry.lower()] = entry

def normalize_song_name(raw_name: str) -> str:
    name = raw_name.strip()
    if "/" in name:
        name = os.path.basename(name)
    name = re.sub(r"\s+", " ", name)
    key = name.lower()
    if key in album_files:
        return album_files[key]
    no_index = re.sub(r"^\d+\.\s*", "", name).strip()
    no_index_key = no_index.lower()
    if no_index_key in album_files:
        return album_files[no_index_key]
    return name

track_patterns = [
    re.compile(r"^\s*(?P<name>\d+\.\s*.+?):\s*DR\s*(?P<dr>\d+(?:\.\d+)?)\s*$"),
    re.compile(r"^\s*DR(?P<dr>\d+(?:\.\d+)?)\s+[-+]?\d+(?:\.\d+)?\s+dB\s+[-+]?\d+(?:\.\d+)?\s+dB\s+(?P<name>.+?)\s*$"),
    re.compile(r"^\s*DR(?P<dr>\d+(?:\.\d+)?)\s+\S+\s+\S+\s+(?P<name>.+?)\s*$"),
]

total_patterns = [
    re.compile(r"^\s*DR\s*=\s*(?P<dr>\d+(?:\.\d+)?)\s*$", re.IGNORECASE),
    re.compile(r"Official DR value:\s*DR(?P<dr>\d+(?:\.\d+)?)", re.IGNORECASE),
    re.compile(r"Total DR:\s*DR?(?P<dr>\d+(?:\.\d+)?)", re.IGNORECASE),
    re.compile(r"Album DR:\s*DR?(?P<dr>\d+(?:\.\d+)?)", re.IGNORECASE),
]

sampling_rate_pattern    = re.compile(r"Sampling rate:\s*(?P<val>\d+)\s*Hz", re.IGNORECASE)
average_bitrate_pattern  = re.compile(r"Average bitrate:\s*(?P<val>\d+)\s*kbs", re.IGNORECASE)
bits_per_sample_pattern  = re.compile(r"Bits per sample:\s*(?P<val>\d+)\s*bit", re.IGNORECASE)

for line in lines:
    m = sampling_rate_pattern.search(line)
    if m:
        sampling_rate_hz = int(m.group("val"))
    m = average_bitrate_pattern.search(line)
    if m:
        average_bitrate_kbs = int(m.group("val"))
    m = bits_per_sample_pattern.search(line)
    if m:
        bits_per_sample = int(m.group("val"))

    for pat in total_patterns:
        m = pat.search(line)
        if m:
            dr_total = as_number(m.group("dr"))
            break
    for pat in track_patterns:
        m = pat.match(line)
        if not m:
            continue
        name = normalize_song_name(m.group("name"))
        tracks[name] = as_number(m.group("dr"))
        break

if dr_total is None:
    raise SystemExit("Failed to parse total DR from dr14meter output")

grade = dr_grade_mod.grade_from_dr(dr_total, genre_profile)
fake_upscale = fake_upscale_raw == "1"
has_fake_tracks = has_fake_tracks_raw == "1"
family_sr = int(family_sr_raw) if family_sr_raw.isdigit() else None
analyze_decision = analyze_decision_raw or None

result = {
    "recodeTo":          recode_to,
    "fakeUpscale":       fake_upscale,
    "hasFakeUpscaleTracks": has_fake_tracks,
    "familySampleRateHz": family_sr,
    "analyzeDecision":   analyze_decision,
    "drTotal":           dr_total,
    "grade":             grade,
    "genreProfile":      genre_profile,
    "samplingRateHz":    sampling_rate_hz,
    "averageBitrateKbs": average_bitrate_kbs,
    "bitsPerSample":     bits_per_sample,
    "tracks":            tracks,
}
print(json.dumps(result, indent=2, sort_keys=False))
PY
