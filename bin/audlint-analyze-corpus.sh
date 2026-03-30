#!/usr/bin/env bash
# audlint-analyze-corpus.sh - run audlint-analyze against a labeled corpus manifest.

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

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env" || true

PYTHON_BIN="${AUDL_PYTHON_BIN:-python3}"
AUDLINT_ANALYZE_CORPUS_PY="${AUDLINT_ANALYZE_CORPUS_PY:-$SCRIPT_DIR/../lib/py/audlint_analyze_corpus.py}"
export AUDLINT_ANALYZE_BIN="${AUDLINT_ANALYZE_BIN:-$SCRIPT_DIR/audlint-analyze.sh}"

if [[ ! -f "$AUDLINT_ANALYZE_CORPUS_PY" ]]; then
  echo "Missing helper: $AUDLINT_ANALYZE_CORPUS_PY" >&2
  exit 1
fi

exec "$PYTHON_BIN" "$AUDLINT_ANALYZE_CORPUS_PY" "$@"
