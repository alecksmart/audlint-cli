#!/usr/bin/env bash
set -euo pipefail

# Usage: sync-music.sh [--dry-run] [--debug]
DRY_RUN=""
DEBUG=0

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

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
ui_init_colors

# Load .env configuration (repo root)
ENV_FILE="${REPO_ROOT}/.env"
if ! env_load_files "$ENV_FILE"; then
  echo "ERROR: Missing .env file at ${ENV_FILE}" >&2
  echo "Create it from .env-sample at the repo root and edit your settings." >&2
  exit 1
fi

# Required config values from .env
SRC="${SRC:-}"
DST_USER_HOST="${DST_USER_HOST:-}"
DST_PATH="${DST_PATH:-}"
SSH_KEY="${SSH_KEY:-}"

[[ -n "$SRC" ]] || {
  echo "ERROR: SRC is not set in .env" >&2
  exit 1
}
[[ -n "$DST_USER_HOST" ]] || {
  echo "ERROR: DST_USER_HOST is not set in .env" >&2
  exit 1
}
[[ -n "$DST_PATH" ]] || {
  echo "ERROR: DST_PATH is not set in .env" >&2
  exit 1
}
if [[ -n "$SSH_KEY" && ! -r "$SSH_KEY" ]]; then
  echo "ERROR: SSH_KEY is set but not readable: $SSH_KEY" >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS=(-i "$SSH_KEY" "${SSH_OPTS[@]}")
fi

show_help() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--debug]
  --dry-run   : show what would happen without making changes
  --debug     : enable trace mode (set -x) and extra verbose logging

Notes:
- Config comes from .env in this folder.
- Destination is reached via SSH as: \$DST_USER_HOST:\$DST_PATH
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run)
    DRY_RUN="--dry-run"
    shift
    ;;
  --debug)
    DEBUG=1
    shift
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    show_help >&2
    exit 2
    ;;
  esac
done

# Enable debug trace if requested
if [[ $DEBUG -eq 1 ]]; then
  echo "⚙️  Debug mode enabled" >&2
  set -x
fi

require_bins ssh rsync >/dev/null || exit 2

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error_exit() {
  echo "ERROR: $*" >&2
  exit 1
}

rsync_supports_flag() {
  local flag="$1"
  local help_out
  help_out="$(rsync --help 2>/dev/null || true)"
  [[ -n "$help_out" ]] || return 1
  printf '%s\n' "$help_out" | grep -Fq -- "$flag"
}

# Ensure source exists (destination is remote now; don't test with [[ -d ]])
[[ -d "$SRC" ]] || error_exit "Source directory '$SRC' does not exist. Aborting."

log "Starting music sync"
log "Source : $SRC"
log "Dest   : ${DST_USER_HOST}:${DST_PATH}"
if [[ -n "$SSH_KEY" ]]; then
  log "SSH key: $SSH_KEY"
else
  log "SSH key: <default identity>"
fi
log "Dry-run: ${DRY_RUN:+yes}${DRY_RUN:-no}"
log "Debug  : $DEBUG"

# Clean macOS metadata on SOURCE only (use portable -exec … +)
clean_metadata() {
  local base="$1"
  log "Cleaning macOS metadata in $base"
  find "$base" -type f -name '._*' -exec rm -f {} +
  find "$base" -type f -name '.DS_Store' -exec rm -f {} +
}
clean_metadata "$SRC"

# Verify SSH connectivity & ensure remote dir exists (or create if missing)
if [[ -n "$DRY_RUN" ]]; then
  # In dry-run, just test SSH connectivity and presence
  if ! ssh "${SSH_OPTS[@]}" "$DST_USER_HOST" "test -d '$DST_PATH'"; then
    log "Remote path does not exist (dry-run): $DST_PATH"
  fi
else
  # Create the remote directory if it doesn't exist
  ssh "${SSH_OPTS[@]}" "$DST_USER_HOST" "mkdir -p '$DST_PATH'"
fi

# rsync options tuned for SSH transport
RSYNC_OPTS=(
  -a             # archive mode (preserves most metadata)
  --no-perms     # do not preserve permissions
  -O             # omit directory times
  --no-group     # do not preserve group
  -v             # verbose
  -h             # human-readable
  --delete       # delete files removed from source
  --progress     # show progress
  --stats        # summary
  --partial      # keep partials if interrupted
  --exclude='._*'
  --exclude='.DS_Store'
)

if rsync_supports_flag "--secluded-args"; then
  RSYNC_OPTS+=(--secluded-args)
elif rsync_supports_flag "--protect-args"; then
  RSYNC_OPTS+=(--protect-args)
else
  log "Notice: rsync lacks --secluded-args/--protect-args; continuing without protected-args mode."
fi

# Use SSH transport with key
RSYNC_RSH=(--rsh="ssh ${SSH_OPTS[*]}")

log "Invoking rsync over SSH…"
# IMPORTANT: trailing slashes to copy contents of SRC into DST_PATH
rsync "${RSYNC_OPTS[@]}" "${RSYNC_RSH[@]}" $DRY_RUN \
  "${SRC}/" "${DST_USER_HOST}:${DST_PATH}/"

log "Music sync complete"
