#!/opt/homebrew/bin/bash

seek_walk_dirs() {
  local root="${1:-.}"
  local callback="${2:-}"
  local prune_name="${3:-before-recode}"
  local dir callback_status

  [[ -d "$root" ]] || return 1
  [[ -n "$callback" ]] || return 2
  declare -F "$callback" >/dev/null 2>&1 || return 2

  while IFS= read -r -d '' dir <&3; do
    "$callback" "$dir"
    callback_status=$?
    case "$callback_status" in
    0 | 1) ;;
    *) return "$callback_status" ;;
    esac
  done 3< <(find "$root" -type d \( -name "$prune_name" -prune \) -o -type d -print0)

  return 0
}

seek_walk_albums() {
  local root="${1:-.}"
  local callback="${2:-}"
  local prune_name="${3:-before-recode}"
  local has_audio_fn="${4:-audio_has_files}"
  local dir callback_status

  [[ -d "$root" ]] || return 1
  [[ -n "$callback" ]] || return 2
  declare -F "$callback" >/dev/null 2>&1 || return 2
  declare -F "$has_audio_fn" >/dev/null 2>&1 || return 2

  while IFS= read -r -d '' dir <&3; do
    "$has_audio_fn" "$dir" || continue
    "$callback" "$dir"
    callback_status=$?
    case "$callback_status" in
    0 | 1) ;;
    *) return "$callback_status" ;;
    esac
  done 3< <(find "$root" -type d \( -name "$prune_name" -prune \) -o -type d -print0)

  return 0
}
