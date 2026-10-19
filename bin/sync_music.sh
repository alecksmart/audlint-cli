#!/usr/bin/env bash
set -euo pipefail

# Usage: sync_music.sh [--dry-run] [--delete|--no-delete] [--debug]
DRY_RUN=0
DELETE_MODE=auto
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
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/music_sync.sh"

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

[[ -n "$SRC" ]] || {
  echo "ERROR: AUDL_PATH is not set in .env" >&2
  exit 1
}
show_help() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--delete|--no-delete] [--debug]
  --dry-run   : show what would happen without making changes
  --delete    : allow destination deletion after source mount checks
  --no-delete : preserve files already at the destination
  --debug     : enable trace mode (set -x) and extra verbose logging

Notes:
- Config comes from .env in this folder.
- AUDL_SYNC_TRANSPORT selects ssh (default) or nfs.
- NFS uses AUDL_SYNC_DEST; SSH uses AUDL_SYNC_SSH_ALIAS and AUDL_SYNC_SSH_PATH.
- SSH defaults to no deletion; NFS keeps its existing deletion default.
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  --no-delete)
    [[ "$DELETE_MODE" != delete ]] || { echo 'ERROR: --delete and --no-delete cannot be combined' >&2; exit 2; }
    DELETE_MODE=keep
    shift
    ;;
  --delete)
    [[ "$DELETE_MODE" != keep ]] || { echo 'ERROR: --delete and --no-delete cannot be combined' >&2; exit 2; }
    DELETE_MODE=delete
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
music_sync_select || exit 1
DELETE=0
if [[ "$DELETE_MODE" == delete || ( "$DELETE_MODE" == auto && "$MUSIC_SYNC_TRANSPORT" == nfs ) ]]; then
  DELETE=1
fi

log "Starting music sync"
log "Source : $SRC"
log "Dest   : $MUSIC_SYNC_DEST"
log "Transport: $MUSIC_SYNC_TRANSPORT"
if [[ "$DRY_RUN" == 1 ]]; then
  log "Dry-run: yes"
else
  log "Dry-run: no"
fi
log "Debug  : $DEBUG"
log "Delete: $([[ "$DELETE" == 1 ]] && printf 'yes' || printf 'no')"
if [[ "$DELETE" == 1 ]]; then
  music_sync_validate_source_for_delete "$SRC" || exit 1
fi
music_sync_validate "$DRY_RUN" || exit 1
log "Invoking rsync to $MUSIC_SYNC_TRANSPORT destination…"
music_sync_run "$SRC" "$DRY_RUN" "$DELETE"

log "Music sync complete"
