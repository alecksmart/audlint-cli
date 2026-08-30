#!/usr/bin/env bash
# Developer-only source-control safety gate.  Do not source project bootstrap.
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  BASE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  TARGET="$(readlink "$SOURCE")"
  [[ "$TARGET" = /* ]] && SOURCE="$TARGET" || SOURCE="$BASE_DIR/$TARGET"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
PYTHON_BIN="${AUDL_PYTHON_BIN:-python3}"

if [[ "${1:-}" = "--help" && $# -eq 1 ]]; then
  printf '%s\n' 'Usage: bin/audlint-source-audit.sh [--prospective|--help]'
  exit 0
fi
exec "$PYTHON_BIN" "$ROOT/lib/py/audlint_source_audit.py" --root "$ROOT" "$@"
