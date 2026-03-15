#!/usr/bin/env bash
# audlint-doctor.sh - Environment diagnostics for audlint-cli runtime.

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
deps_ensure_common_path

STRICT=false
ENV_FILE_OVERRIDE=""
LOADED_ENV_FILE=""
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

CRON_BLOCK_BEGIN="# >>> audlint-cli maintain >>>"
CRON_BLOCK_END="# <<< audlint-cli maintain <<<"

show_help() {
  cat <<'EOF'
Quick use:
  audlint-doctor.sh
  audlint-doctor.sh --strict
  audlint-doctor.sh --env /path/to/.env

Usage:
  audlint-doctor.sh [--strict] [--env <path>]

Checks:
  - Bash/runtime basics
  - Key binaries on PATH
  - .env presence and required values
  - Required path readability/writability
  - Maintenance cron availability/status

Options:
  --strict      Treat warnings as failures (exit non-zero on WARN).
  --env <path>  Use a specific .env file instead of auto-discovery.
  -h, --help    Show this help.
EOF
}

note() {
  printf '%s\n' "$*"
}

report_ok() {
  local label="$1"
  local detail="$2"
  OK_COUNT=$((OK_COUNT + 1))
  printf '[OK]   %s: %s\n' "$label" "$detail"
}

report_warn() {
  local label="$1"
  local detail="$2"
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s: %s\n' "$label" "$detail"
}

report_fail() {
  local label="$1"
  local detail="$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s: %s\n' "$label" "$detail"
}

load_env_file() {
  local env_file
  for env_file in "$@"; do
    [[ -n "$env_file" ]] || continue
    [[ -f "$env_file" ]] || continue
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    LOADED_ENV_FILE="$env_file"
    return 0
  done
  return 1
}

check_bin_required() {
  local name="$1"
  if has_bin "$name"; then
    report_ok "bin:$name" "$(command -v "$name")"
  else
    report_fail "bin:$name" "missing from PATH"
  fi
}

check_bin_optional() {
  local name="$1"
  if has_bin "$name"; then
    report_ok "bin:$name" "$(command -v "$name")"
  else
    report_warn "bin:$name" "not found (feature may be unavailable)"
  fi
}

check_env_required() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    report_fail "env:$name" "missing"
  else
    report_ok "env:$name" "$value"
  fi
}

check_env_optional() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "$value" ]]; then
    report_ok "env:$name" "$value"
  else
    report_warn "env:$name" "unset"
  fi
}

check_int_ge() {
  local name="$1"
  local min="$2"
  local raw="${!name:-}"
  if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
    report_fail "env:$name" "expected integer >= $min"
    return
  fi
  if ((raw < min)); then
    report_fail "env:$name" "expected integer >= $min (got $raw)"
    return
  fi
  report_ok "env:$name" "$raw"
}

check_dir_readable() {
  local label="$1"
  local raw="$2"
  local expanded
  expanded="$(env_expand_value "$raw")"
  if [[ -d "$expanded" && -r "$expanded" ]]; then
    report_ok "$label" "$expanded"
  else
    report_fail "$label" "directory missing/unreadable: $expanded"
  fi
}

check_dir_writable() {
  local label="$1"
  local raw="$2"
  local expanded
  expanded="$(env_expand_value "$raw")"
  if [[ -d "$expanded" && -w "$expanded" ]]; then
    report_ok "$label" "$expanded"
  else
    report_fail "$label" "directory missing/unwritable: $expanded"
  fi
}

check_path_parent_writable() {
  local label="$1"
  local raw="$2"
  local expanded parent
  expanded="$(env_expand_value "$raw")"
  parent="$(dirname "$expanded")"
  if [[ -d "$parent" && -w "$parent" ]]; then
    report_ok "$label" "$expanded"
  else
    report_fail "$label" "parent missing/unwritable: $parent"
  fi
}

check_file_readable_if_set() {
  local label="$1"
  local raw="$2"
  [[ -n "$raw" ]] || {
    report_warn "$label" "unset"
    return
  }
  local expanded
  expanded="$(env_expand_value "$raw")"
  if [[ -f "$expanded" && -r "$expanded" ]]; then
    report_ok "$label" "$expanded"
  else
    report_fail "$label" "file missing/unreadable: $expanded"
  fi
}

check_python_import() {
  local py_bin="$1"
  local module="$2"
  local label="$3"
  if "$py_bin" -c "import $module" >/dev/null 2>&1; then
    report_ok "$label" "module '$module' available"
  else
    report_warn "$label" "module '$module' missing"
  fi
}

check_cron_status() {
  if ! has_bin crontab; then
    report_warn "cron" "crontab not installed"
    return
  fi
  local current
  current="$(crontab -l 2>/dev/null || true)"
  if grep -Fqx "$CRON_BLOCK_BEGIN" <<<"$current" && grep -Fqx "$CRON_BLOCK_END" <<<"$current"; then
    report_ok "cron" "audlint managed cron block installed"
  else
    report_warn "cron" "audlint managed cron block not installed"
  fi
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  --strict)
    STRICT=true
    ;;
  --env)
    shift || true
    ENV_FILE_OVERRIDE="${1:-}"
    if [[ -z "$ENV_FILE_OVERRIDE" ]]; then
      printf 'Error: --env requires a path\n' >&2
      exit 2
    fi
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    printf 'Error: unknown argument: %s\n' "${1:-}" >&2
    show_help >&2
    exit 2
    ;;
  esac
  shift || true
done

note "audlint-doctor"
note "=============="
note "repo: $REPO_ROOT"
note "script: $SCRIPT_PATH"
note ""

if (( BASH_VERSINFO[0] >= 5 )); then
  report_ok "bash" "$BASH ($BASH_VERSION)"
else
  report_fail "bash" "requires Bash >= 5 (current: $BASH_VERSION)"
fi

if [[ -n "$ENV_FILE_OVERRIDE" ]]; then
  if load_env_file "$ENV_FILE_OVERRIDE"; then
    report_ok "env file" "$LOADED_ENV_FILE"
  else
    report_fail "env file" "cannot load: $ENV_FILE_OVERRIDE"
  fi
else
  if load_env_file "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env"; then
    report_ok "env file" "$LOADED_ENV_FILE"
  else
    report_fail "env file" "not found (checked $SCRIPT_DIR/../.env and $SCRIPT_DIR/.env)"
  fi
fi

note ""
note "Binary checks"
note "-------------"
check_bin_required ffmpeg
check_bin_required ffprobe
check_bin_required sqlite3
check_bin_required rsync
check_bin_optional sox
check_bin_optional soxi
check_bin_optional metaflac
check_bin_optional dr14meter
check_bin_optional curl
check_bin_optional jq
check_bin_optional zip
check_bin_optional unzip
check_bin_optional eyeD3
check_bin_optional AtomicParsley
check_bin_optional tail

note ""
note "Environment checks"
note "------------------"
check_env_required AUDL_PATH
check_env_required AUDL_DB_PATH
check_env_required AUDL_PYTHON_BIN
check_env_required AUDL_CRON_INTERVAL_MIN
check_env_required AUDL_TASK_MAX_ALBUMS
check_env_required AUDL_TASK_MAX_TIME_SEC
check_env_required AUDL_TASK_LOG_PATH
check_env_required AUDL_CUE2FLAC_OUTPUT_DIR
check_env_optional AUDL_SYNC_DEST
check_env_optional AUDL_MEDIA_PLAYER_PATH
check_env_optional AUDL_LASTFM_API_KEY

check_int_ge AUDL_CRON_INTERVAL_MIN 1
check_int_ge AUDL_TASK_MAX_ALBUMS 1
check_int_ge AUDL_TASK_MAX_TIME_SEC 0

if [[ -n "${AUDL_PATH:-}" ]]; then
  check_dir_readable "path:AUDL_PATH" "${AUDL_PATH:-}"
fi
if [[ -n "${AUDL_DB_PATH:-}" ]]; then
  check_path_parent_writable "path:AUDL_DB_PATH" "${AUDL_DB_PATH:-}"
  db_expanded="$(env_expand_value "${AUDL_DB_PATH:-}")"
  if [[ -f "$db_expanded" ]]; then
    if [[ -r "$db_expanded" ]]; then
      report_ok "path:AUDL_DB_PATH file" "$db_expanded"
    else
      report_fail "path:AUDL_DB_PATH file" "not readable: $db_expanded"
    fi
  else
    report_warn "path:AUDL_DB_PATH file" "does not exist yet: $db_expanded"
  fi
fi
if [[ -n "${AUDL_TASK_LOG_PATH:-}" ]]; then
  check_path_parent_writable "path:AUDL_TASK_LOG_PATH" "${AUDL_TASK_LOG_PATH:-}"
fi
if [[ -n "${AUDL_CUE2FLAC_OUTPUT_DIR:-}" ]]; then
  check_dir_writable "path:AUDL_CUE2FLAC_OUTPUT_DIR" "${AUDL_CUE2FLAC_OUTPUT_DIR:-}"
fi
if [[ -n "${AUDL_SYNC_DEST:-}" ]]; then
  check_dir_writable "path:AUDL_SYNC_DEST" "${AUDL_SYNC_DEST:-}"
fi
if [[ -n "${AUDL_MEDIA_PLAYER_PATH:-}" ]]; then
  check_dir_readable "path:AUDL_MEDIA_PLAYER_PATH" "${AUDL_MEDIA_PLAYER_PATH:-}"
fi

if [[ -n "${AUDL_PYTHON_BIN:-}" ]]; then
  if has_bin "$AUDL_PYTHON_BIN"; then
    report_ok "python:AUDL_PYTHON_BIN" "$(command -v "$AUDL_PYTHON_BIN")"
    check_python_import "$AUDL_PYTHON_BIN" numpy "python:numpy"
    check_python_import "$AUDL_PYTHON_BIN" rich "python:rich"
  else
    report_fail "python:AUDL_PYTHON_BIN" "command not found: $AUDL_PYTHON_BIN"
  fi
fi

note ""
note "Scheduler checks"
note "----------------"
check_cron_status

note ""
note "Summary"
note "-------"
printf 'ok=%d warn=%d fail=%d\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
if [[ "$STRICT" == true && "$WARN_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
