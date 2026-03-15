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
SRC="${AUDL_PATH:-}"
SYNC_DEST="${AUDL_SYNC_DEST:-}"

[[ -n "$SRC" ]] || {
  echo "ERROR: AUDL_PATH is not set in .env" >&2
  exit 1
}
[[ -n "$SYNC_DEST" ]] || {
  echo "ERROR: AUDL_SYNC_DEST is not set in .env" >&2
  exit 1
}

show_help() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--debug]
  --dry-run   : show what would happen without making changes
  --debug     : enable trace mode (set -x) and extra verbose logging

Notes:
- Config comes from .env in this folder.
- Destination is synced locally via rsync to: \$AUDL_SYNC_DEST
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

require_bins rsync >/dev/null || exit 2

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error_exit() {
  echo "ERROR: $*" >&2
  exit 1
}

# Ensure source exists.
[[ -d "$SRC" ]] || error_exit "Source directory '$SRC' does not exist. Aborting."

log "Starting music sync"
log "Source : $SRC"
log "Dest   : $SYNC_DEST"
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

# Ensure destination exists and is writable.
if [[ -d "$SYNC_DEST" ]]; then
  [[ -w "$SYNC_DEST" ]] || error_exit "Destination directory '$SYNC_DEST' is not writable. Aborting."
elif [[ -n "$DRY_RUN" ]]; then
  log "Destination path does not exist (dry-run): $SYNC_DEST"
else
  mkdir -p "$SYNC_DEST"
  [[ -w "$SYNC_DEST" ]] || error_exit "Destination directory '$SYNC_DEST' is not writable after creation. Aborting."
fi

# rsync options tuned for a mounted destination directory
RSYNC_OPTS=(
  -a             # archive mode (preserves most metadata)
  --no-perms     # do not preserve permissions
  --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r  # normalized readable dirs/files on destination
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

log "Invoking rsync to mounted destination…"
# IMPORTANT: trailing slashes to copy contents of SRC into SYNC_DEST
rsync "${RSYNC_OPTS[@]}" $DRY_RUN \
  "${SRC}/" "${SYNC_DEST}/"

log "Music sync complete"
