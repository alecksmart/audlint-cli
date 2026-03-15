#!/usr/bin/env bash

# secure_backup.sh - strict pre-write album backup guard (AUDL_PARANOIA_MODE=1).

SECURE_BACKUP_LAST_ERROR=""

_secure_fail() {
  SECURE_BACKUP_LAST_ERROR="${1:-secure backup failed}"
  printf '%s\n' "$SECURE_BACKUP_LAST_ERROR" >&2
  return 1
}

_secure_has_bin() {
  if declare -F has_bin >/dev/null 2>&1; then
    has_bin "$1"
  else
    command -v "$1" >/dev/null 2>&1
  fi
}

_secure_expand_path() {
  local raw="${1:-}"
  if declare -F env_expand_value >/dev/null 2>&1; then
    env_expand_value "$raw"
    return 0
  fi
  raw="${raw/#\~/$HOME}"
  raw="${raw//\$HOME/$HOME}"
  printf '%s' "$raw"
}

_secure_abs_dir() {
  local raw="${1:-}"
  local expanded
  expanded="$(_secure_expand_path "$raw")"
  [[ -d "$expanded" ]] || return 1
  (cd "$expanded" && pwd -P)
}

secure_mode_enabled() {
  case "${AUDL_PARANOIA_MODE:-0}" in
  1 | true | TRUE | yes | YES | on | ON) return 0 ;;
  *) return 1 ;;
  esac
}

secure_require_backup_config() {
  secure_mode_enabled || return 0

  local src_raw="${AUDL_PATH:-}"
  local backup_raw="${AUDL_BACKUP_PATH:-}"
  local rsync_bin="${SECURE_BACKUP_RSYNC_BIN:-${RSYNC_BIN:-rsync}}"

  [[ -n "$src_raw" ]] || _secure_fail "Secure mode error: AUDL_PATH is not set."
  [[ -n "$backup_raw" ]] || _secure_fail "Secure mode error: AUDL_BACKUP_PATH is not set."

  local src_abs backup_abs
  src_abs="$(_secure_abs_dir "$src_raw")" || _secure_fail "Secure mode error: AUDL_PATH is not a readable directory: $src_raw"
  backup_abs="$(_secure_abs_dir "$backup_raw")" || _secure_fail "Secure mode error: AUDL_BACKUP_PATH is not an existing readable directory: $backup_raw"

  [[ -w "$backup_abs" ]] || _secure_fail "Secure mode error: AUDL_BACKUP_PATH is not writable: $backup_abs"
  _secure_has_bin "$rsync_bin" || _secure_fail "Secure mode error: rsync binary not found: $rsync_bin"
}

_secure_album_has_audio_tracks() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  find "$dir" -maxdepth 1 -type f \( \
    -iname '*.flac' -o -iname '*.alac' -o -iname '*.m4a' -o -iname '*.wav' \
    -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.aifc' -o -iname '*.caf' \
    -o -iname '*.dsf' -o -iname '*.dff' -o -iname '*.wv' -o -iname '*.ape' \
    -o -iname '*.mp4' -o -iname '*.mp3' -o -iname '*.aac' -o -iname '*.ogg' -o -iname '*.opus' \
  \) -print -quit | grep -q .
}

secure_backup_album_tracks_once() {
  local album_dir="${1:-}"
  local action="${2:-write-op}"
  SECURE_BACKUP_LAST_ERROR=""

  secure_mode_enabled || return 0
  secure_require_backup_config || return 1

  [[ -n "$album_dir" ]] || _secure_fail "Secure mode error: album path is empty before $action."

  local album_abs src_abs backup_abs rsync_bin rel_path backup_album_dir
  album_abs="$(_secure_abs_dir "$album_dir")" || _secure_fail "Secure mode error: album directory not readable: $album_dir"
  src_abs="$(_secure_abs_dir "${AUDL_PATH:-}")" || _secure_fail "Secure mode error: AUDL_PATH is invalid."
  backup_abs="$(_secure_abs_dir "${AUDL_BACKUP_PATH:-}")" || _secure_fail "Secure mode error: AUDL_BACKUP_PATH is invalid."
  rsync_bin="${SECURE_BACKUP_RSYNC_BIN:-${RSYNC_BIN:-rsync}}"

  if [[ "$album_abs" == "$src_abs" ]]; then
    rel_path="."
  elif [[ "$album_abs" == "$src_abs/"* ]]; then
    rel_path="${album_abs#"$src_abs"/}"
  else
    _secure_fail "Secure mode error: album is outside AUDL_PATH ($album_abs not under $src_abs)."
    return 1
  fi

  if [[ -z "$rel_path" || "$rel_path" == "." ]]; then
    backup_album_dir="$backup_abs"
  else
    backup_album_dir="$backup_abs/$rel_path"
  fi

  # Single source of truth: existing backup album dir with audio tracks.
  if _secure_album_has_audio_tracks "$backup_album_dir"; then
    return 0
  fi

  mkdir -p "$backup_album_dir" || _secure_fail "Secure mode error: cannot create backup directory: $backup_album_dir"

  local -a src_tracks=()
  local track
  while IFS= read -r -d '' track; do
    src_tracks+=("$track")
  done < <(find "$album_abs" -maxdepth 1 -type f \( \
    -iname '*.flac' -o -iname '*.alac' -o -iname '*.m4a' -o -iname '*.wav' \
    -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.aifc' -o -iname '*.caf' \
    -o -iname '*.dsf' -o -iname '*.dff' -o -iname '*.wv' -o -iname '*.ape' \
    -o -iname '*.mp4' -o -iname '*.mp3' -o -iname '*.aac' -o -iname '*.ogg' -o -iname '*.opus' \
  \) -print0)

  if ((${#src_tracks[@]} == 0)); then
    _secure_fail "Secure mode error: no track files found in album before $action: $album_abs"
    return 1
  fi

  if ! "$rsync_bin" -a -- "${src_tracks[@]}" "$backup_album_dir/"; then
    _secure_fail "Secure mode error: rsync backup failed for album: $album_abs"
    return 1
  fi

  if ! _secure_album_has_audio_tracks "$backup_album_dir"; then
    _secure_fail "Secure mode error: backup verification failed for album: $backup_album_dir"
    return 1
  fi
}
