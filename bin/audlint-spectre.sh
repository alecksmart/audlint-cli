#!/usr/bin/env bash
# audlint-spectre.sh - OCR + spectrogram cutoff reader for exported images.

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
source "$BOOTSTRAP_DIR/../lib/sh/env.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true
deps_ensure_common_path

PYTHON_BIN="${PYTHON_BIN:-python3}"
PY_HELPER="$REPO_ROOT/lib/py/spectre_image.py"

print_optional_install_guidance() {
  printf '\nInstall guidance (optional; needed only for audlint-spectre.sh):\n' >&2
  if command -v brew >/dev/null 2>&1; then
    printf '  brew install tesseract\n' >&2
  elif command -v apt-get >/dev/null 2>&1; then
    printf '  sudo apt update && sudo apt install -y tesseract-ocr\n' >&2
  elif command -v dnf >/dev/null 2>&1; then
    printf '  sudo dnf install -y tesseract\n' >&2
  else
    printf '  Install tesseract with your package manager.\n' >&2
  fi
  printf '  %s -m pip install opencv-python numpy pytesseract\n' "$PYTHON_BIN" >&2
}

check_optional_deps() {
  local ok=1
  local -a missing_bins=()
  local -a missing_py=()
  local mod

  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    missing_bins+=("$PYTHON_BIN")
    ok=0
  fi

  if ! command -v tesseract >/dev/null 2>&1; then
    missing_bins+=("tesseract")
    ok=0
  fi

  if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    for mod in cv2 numpy pytesseract; do
      if ! "$PYTHON_BIN" -c "import $mod" >/dev/null 2>&1; then
        missing_py+=("$mod")
        ok=0
      fi
    done
  fi

  if [[ "$ok" -eq 1 ]]; then
    printf 'OK: audlint-spectre optional dependencies are available.\n'
    return 0
  fi

  printf 'Missing optional dependencies for audlint-spectre.sh:\n' >&2
  if ((${#missing_bins[@]} > 0)); then
    printf '  binaries: %s\n' "${missing_bins[*]}" >&2
  fi
  if ((${#missing_py[@]} > 0)); then
    printf '  python modules (%s): %s\n' "$PYTHON_BIN" "${missing_py[*]}" >&2
  fi
  print_optional_install_guidance
  return 1
}

show_help() {
  cat <<'EOF'
Usage:
  audlint-spectre.sh [options] IMAGE_PATH
  audlint-spectre.sh --check-deps

Read an exported spectrogram image and estimate the high-frequency cutoff.
OCR is applied to the stats region (top-left by default) to extract labels such
as Peak Amplitude and Dynamic Range. Default output is compact JSON.

Options:
  --check-deps                   Check optional spectre dependencies and exit.
  --full                         Emit full JSON payload.
  --json                         Backward-compatible alias for --full.
  --explain                      Show weighted quality scoring breakdown (default: on).
  --no-explain                   Hide weighted quality scoring breakdown.
  --show-metrics                 Legacy option (ignored in JSON mode).
  --show-ocr                     Legacy option (ignored in compact JSON mode).
  --stats-roi Y0:Y1,X0:X1        OCR crop region in pixel coordinates.
                                 Default: 0:500,0:400
  --top-scan-fraction N          Fraction of image height scanned from top.
                                 Default: 0.5
  --brightness-threshold N       Grayscale threshold for cutoff detection.
                                 Default: 35
  --max-khz N                    Top-of-image frequency scale in kHz.
                                 Default: 96
  -h, --help                     Show this help.

Dependencies:
  - python3 with: opencv-python (cv2), numpy, pytesseract
  - tesseract binary on PATH
  - jq (optional; prettifies default compact JSON output)

Convenience alias after `make install`: `aus`
EOF
}

CHECK_DEPS_ONLY=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -h|--help)
      show_help
      exit 0
      ;;
    --check-deps)
      CHECK_DEPS_ONLY=1
      ;;
    *)
      ARGS+=("$1")
      ;;
  esac
  shift
done

if [[ ! -f "$PY_HELPER" ]]; then
  printf 'Error: helper not found: %s\n' "$PY_HELPER" >&2
  exit 1
fi

if [[ "$CHECK_DEPS_ONLY" -eq 1 ]]; then
  check_optional_deps
  exit $?
fi

if ((${#ARGS[@]} == 0)); then
  show_help >&2
  exit 2
fi

if ! check_optional_deps >/dev/null; then
  printf '\naudlint-spectre.sh is an optional utility; install deps to enable it.\n' >&2
  exit 1
fi

FULL_MODE=0
for arg in "${ARGS[@]}"; do
  case "$arg" in
    --full|--json)
      FULL_MODE=1
      break
      ;;
  esac
done

if [[ "$FULL_MODE" -eq 0 ]] && command -v jq >/dev/null 2>&1; then
  "$PYTHON_BIN" "$PY_HELPER" "${ARGS[@]}" | jq '{image, likely_profile, confidence, quality_class}'
  exit $?
fi

exec "$PYTHON_BIN" "$PY_HELPER" "${ARGS[@]}"
