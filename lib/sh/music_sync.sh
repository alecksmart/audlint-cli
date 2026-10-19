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
      # --no-perms leaves existing modes alone.  The chmod rules set the
      # incoming mode; the receiver umask then gives new files 0644 and new
      # directories 0755 unless a destination default ACL is more restrictive.
      MUSIC_SYNC_ADAPTER_OPTS=(
        --no-owner
        '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r'
        --rsync-path='umask 022; exec rsync'
        -s -e 'ssh -o BatchMode=yes -o ConnectTimeout=10'
      )
      ;;
    *) echo "ERROR: invalid AUDL_SYNC_TRANSPORT '$MUSIC_SYNC_TRANSPORT' (expected ssh or nfs)" >&2; return 1 ;;
  esac
}

music_sync_mounted_entry() {
  local mount_path="$1" entry
  while IFS= read -r entry; do
    if [[ "$entry" == *" on $mount_path ("* || "$entry" == *" on $mount_path type "*" ("* ]]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done < <(mount)
  return 1
}

music_sync_validate_nfs() {
  local mounted_entry write_probe
  [[ -d "$MUSIC_SYNC_DEST" && ! -L "$MUSIC_SYNC_DEST" ]] || { echo "ERROR: Destination must be an existing directory: $MUSIC_SYNC_DEST" >&2; return 1; }
  mounted_entry="$(music_sync_mounted_entry "$MUSIC_SYNC_DEST")" || { echo "ERROR: Destination is not a mounted filesystem: $MUSIC_SYNC_DEST" >&2; return 1; }
  if [[ -n "${AUDL_SYNC_MOUNT_SOURCE:-}" && "$mounted_entry" != "${AUDL_SYNC_MOUNT_SOURCE} on $MUSIC_SYNC_DEST ("* && "$mounted_entry" != "${AUDL_SYNC_MOUNT_SOURCE} on $MUSIC_SYNC_DEST type "* ]]; then
    echo "ERROR: Expected mount ${AUDL_SYNC_MOUNT_SOURCE} is not active at $MUSIC_SYNC_DEST" >&2
    return 1
  fi
  if [[ "$1" != 1 ]]; then
    write_probe="$(mktemp "$MUSIC_SYNC_DEST/.audlint-write-test.XXXXXX" 2>/dev/null)" || { echo "ERROR: Destination is not writable: $MUSIC_SYNC_DEST" >&2; return 1; }
    rm -f "$write_probe" || { echo "ERROR: Could not remove write probe: $write_probe" >&2; return 1; }
  fi
}

music_sync_validate_source_for_delete() {
  local src="${1%/}" expected_mount source_device mount_device sample
  [[ -n "$src" ]] || src=/
  [[ "$src" == /* && -d "$src" && ! -L "$src" ]] || { echo "ERROR: Delete blocked: source must be an existing absolute directory: $src" >&2; return 1; }
  if [[ -n "${AUDL_SYNC_SOURCE_MOUNT:-}" ]]; then
    expected_mount="$AUDL_SYNC_SOURCE_MOUNT"
  else
    expected_mount="$(dirname "$src")"
  fi
  expected_mount="${expected_mount%/}"
  [[ -n "$expected_mount" ]] || expected_mount=/
  [[ "$expected_mount" == /* && -d "$expected_mount" && ! -L "$expected_mount" ]] || { echo "ERROR: Delete blocked: invalid source mount: $expected_mount" >&2; return 1; }
  if [[ "$expected_mount" != / && "$src" != "$expected_mount" && "$src" != "$expected_mount/"* ]]; then
    echo "ERROR: Delete blocked: source is outside expected mount: $expected_mount" >&2
    return 1
  fi
  music_sync_mounted_entry "$expected_mount" >/dev/null || { echo "ERROR: Delete blocked: source volume is not mounted at $expected_mount" >&2; return 1; }
  if ! source_device="$(stat -c '%d' "$src" 2>/dev/null)" || ! mount_device="$(stat -c '%d' "$expected_mount" 2>/dev/null)"; then
    source_device="$(stat -f '%d' "$src" 2>/dev/null)" && mount_device="$(stat -f '%d' "$expected_mount" 2>/dev/null)" || { echo "ERROR: Delete blocked: cannot verify source filesystem: $src" >&2; return 1; }
  fi
  [[ "$source_device" == "$mount_device" ]] || { echo "ERROR: Delete blocked: source is on another filesystem than $expected_mount" >&2; return 1; }
  sample="$(find "$src" -type f ! -name '._*' \( \
    -iname '*.flac' -o -iname '*.alac' -o -iname '*.m4a' -o -iname '*.wav' \
    -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.aifc' -o -iname '*.caf' \
    -o -iname '*.dsf' -o -iname '*.dff' -o -iname '*.wv' -o -iname '*.ape' \
    -o -iname '*.dts' -o -iname '*.dca' -o -iname '*.mp4' -o -iname '*.mp3' \
    -o -iname '*.aac' -o -iname '*.adts' -o -iname '*.ogg' -o -iname '*.oga' \
    -o -iname '*.opus' \
  \) -print -quit 2>/dev/null)" || { echo "ERROR: Delete blocked: cannot inspect source library: $src" >&2; return 1; }
  [[ -n "$sample" ]] || { echo "ERROR: Delete blocked: source library has no audio files: $src" >&2; return 1; }
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
  local src="$1" dry_run="$2" delete="$3"
  local target="${MUSIC_SYNC_DEST%/}/"
  local -a opts=(
    -a --no-perms -O --no-group -v -h
    --progress --stats --partial
    --exclude='._*' --exclude='.DS_Store'
  )
  [[ "$delete" == 1 ]] && opts+=(--delete)
  opts+=("${MUSIC_SYNC_ADAPTER_OPTS[@]}")
  [[ "$dry_run" == 1 ]] && opts+=(--dry-run)
  rsync "${opts[@]}" "${src}/" "$target"
}
