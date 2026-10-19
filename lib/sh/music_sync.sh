#!/usr/bin/env bash

# The selected adapter supplies a destination, rsync options, and a preflight.
# The file selection and rsync invocation remain shared.
music_sync_select() {
  MUSIC_SYNC_TRANSPORT="${AUDL_SYNC_TRANSPORT:-ssh}"
  MUSIC_SYNC_DEST=""
  MUSIC_SYNC_ADAPTER_OPTS=()

  case "$MUSIC_SYNC_TRANSPORT" in
    nfs)
      MUSIC_SYNC_DEST="${AUDL_SYNC_DEST:-}"
      [[ -n "$MUSIC_SYNC_DEST" ]] || { echo 'ERROR: AUDL_SYNC_DEST is required for nfs' >&2; return 1; }
      MUSIC_SYNC_ADAPTER_OPTS=("--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r")
      ;;
    ssh)
      MUSIC_SYNC_SSH_ALIAS="${AUDL_SYNC_SSH_ALIAS:-serv}"
      MUSIC_SYNC_SSH_PATH="${AUDL_SYNC_SSH_PATH:-/pub/a/music}"
      [[ "$MUSIC_SYNC_SSH_ALIAS" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'ERROR: invalid AUDL_SYNC_SSH_ALIAS' >&2; return 1; }
      [[ "$MUSIC_SYNC_SSH_PATH" == /* && "$MUSIC_SYNC_SSH_PATH" != *$'\n'* && "$MUSIC_SYNC_SSH_PATH" != *$'\r'* ]] || { echo 'ERROR: AUDL_SYNC_SSH_PATH must be an absolute path' >&2; return 1; }
      MUSIC_SYNC_SSH_PATH="${MUSIC_SYNC_SSH_PATH%/}"
      [[ -n "$MUSIC_SYNC_SSH_PATH" ]] || MUSIC_SYNC_SSH_PATH=/
      MUSIC_SYNC_DEST="${MUSIC_SYNC_SSH_ALIAS}:${MUSIC_SYNC_SSH_PATH}/"
      MUSIC_SYNC_ADAPTER_OPTS=(--no-owner -s -e 'ssh -o BatchMode=yes -o ConnectTimeout=10')
      ;;
    *) echo "ERROR: invalid AUDL_SYNC_TRANSPORT '$MUSIC_SYNC_TRANSPORT' (expected ssh or nfs)" >&2; return 1 ;;
  esac
}

music_sync_validate_nfs() {
  local mounted_entry="" entry write_probe
  [[ -d "$MUSIC_SYNC_DEST" && ! -L "$MUSIC_SYNC_DEST" ]] || { echo "ERROR: Destination must be an existing directory: $MUSIC_SYNC_DEST" >&2; return 1; }
  while IFS= read -r entry; do
    if [[ "$entry" == *" on $MUSIC_SYNC_DEST ("* || "$entry" == *" on $MUSIC_SYNC_DEST type "*" ("* ]]; then
      mounted_entry="$entry"
      break
    fi
  done < <(mount)
  [[ -n "$mounted_entry" ]] || { echo "ERROR: Destination is not a mounted filesystem: $MUSIC_SYNC_DEST" >&2; return 1; }
  if [[ -n "${AUDL_SYNC_MOUNT_SOURCE:-}" && "$mounted_entry" != "${AUDL_SYNC_MOUNT_SOURCE} on $MUSIC_SYNC_DEST ("* && "$mounted_entry" != "${AUDL_SYNC_MOUNT_SOURCE} on $MUSIC_SYNC_DEST type "* ]]; then
    echo "ERROR: Expected mount ${AUDL_SYNC_MOUNT_SOURCE} is not active at $MUSIC_SYNC_DEST" >&2
    return 1
  fi
  if [[ "$1" != 1 ]]; then
    write_probe="$(mktemp "$MUSIC_SYNC_DEST/.audlint-write-test.XXXXXX" 2>/dev/null)" || { echo "ERROR: Destination is not writable: $MUSIC_SYNC_DEST" >&2; return 1; }
    rm -f "$write_probe" || { echo "ERROR: Could not remove write probe: $write_probe" >&2; return 1; }
  fi
}

music_sync_validate_ssh() {
  local remote_path="'" local_version remote_version char i
  # Quote the configurable path for the remote login shell.
  for ((i = 0; i < ${#MUSIC_SYNC_SSH_PATH}; i++)); do
    char="${MUSIC_SYNC_SSH_PATH:i:1}"
    if [[ "$char" == "'" ]]; then
      remote_path+="'\"'\"'"
    else
      remote_path+="$char"
    fi
  done
  remote_path+="'"
  local_version="$(rsync --version)" || { echo 'ERROR: local rsync version check failed' >&2; return 1; }
  if ! music_sync_is_rsync_35 "$local_version"; then
    echo 'ERROR: SSH sync requires local rsync 3.5 or newer' >&2
    return 1
  fi
  if ! remote_version="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$MUSIC_SYNC_SSH_ALIAS" "test -d $remote_path && test -w $remote_path && rsync --version")"; then
    echo "ERROR: SSH destination unavailable or not writable: $MUSIC_SYNC_DEST" >&2
    return 1
  fi
  if ! music_sync_is_rsync_35 "$remote_version"; then
    echo 'ERROR: SSH sync requires remote rsync 3.5 or newer' >&2
    return 1
  fi
}

music_sync_is_rsync_35() {
  local version="$1" major minor
  [[ "$version" =~ version[[:space:]]+([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  ((major > 3 || (major == 3 && minor >= 5)))
}

music_sync_validate() {
  case "$MUSIC_SYNC_TRANSPORT" in
    nfs) music_sync_validate_nfs "$1" ;;
    ssh) music_sync_validate_ssh ;;
  esac
}

music_sync_run() {
  local src="$1" dry_run="$2" no_delete="$3"
  local target="${MUSIC_SYNC_DEST%/}/"
  local -a opts=(
    -a --no-perms -O --no-group -v -h
    --progress --stats --partial
    --exclude='._*' --exclude='.DS_Store'
  )
  [[ "$no_delete" == 1 ]] || opts+=(--delete)
  opts+=("${MUSIC_SYNC_ADAPTER_OPTS[@]}")
  [[ "$dry_run" == 1 ]] && opts+=(--dry-run)
  rsync "${opts[@]}" "${src}/" "$target"
}
