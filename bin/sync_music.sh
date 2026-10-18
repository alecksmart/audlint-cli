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
if [[ -n "$DRY_RUN" ]]; then
  log "Dry-run: yes"
else
  log "Dry-run: no"
fi
log "Debug  : $DEBUG"

# A missing mount must never turn the mirror destination into a local directory.
[[ -d "$SYNC_DEST" && ! -L "$SYNC_DEST" ]] || error_exit "Destination must be an existing directory: $SYNC_DEST"

mounted_entry=""
while IFS= read -r entry; do
  if [[ "$entry" == *" on $SYNC_DEST ("* || "$entry" == *" on $SYNC_DEST type "*" ("* ]]; then
    mounted_entry="$entry"
    break
  fi
done < <(mount)
[[ -n "$mounted_entry" ]] || error_exit "Destination is not a mounted filesystem: $SYNC_DEST"

if [[ -n "${AUDL_SYNC_MOUNT_SOURCE:-}" ]]; then
  if [[ "$mounted_entry" != "${AUDL_SYNC_MOUNT_SOURCE} on $SYNC_DEST ("* && "$mounted_entry" != "${AUDL_SYNC_MOUNT_SOURCE} on $SYNC_DEST type "* ]]; then
    error_exit "Expected mount ${AUDL_SYNC_MOUNT_SOURCE} is not active at $SYNC_DEST"
  fi
fi

if [[ -z "$DRY_RUN" ]]; then
  write_probe="$(mktemp "$SYNC_DEST/.audlint-write-test.XXXXXX" 2>/dev/null)" || error_exit "Destination is not writable: $SYNC_DEST"
  rm -f "$write_probe" || error_exit "Could not remove write probe: $write_probe"
fi

# rsync options tuned for a mounted destination directory
RSYNC_OPTS=(
  -a             # archive mode (preserves most metadata)
  --no-perms     # do not preserve permissions
  "--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r"  # normalized readable dirs/files on destination
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
