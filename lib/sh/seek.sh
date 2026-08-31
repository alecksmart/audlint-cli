#!/usr/bin/env bash

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

# Walk only the directory positions that can identify Player Content albums.
# The walk deliberately stops at depth three: descendants of an album are
# payload and must not become selector entries or be inspected for membership.
# A temporary NUL-delimited stream lets callers observe find failures instead
# of losing them in process substitution.
seek_walk_player_content() {
  local root="${1:-.}"
  local callback="${2:-}"
  local inventory_file=""
  local dir callback_status walk_status=0

  [[ -d "$root" && -r "$root" ]] || return 1
  [[ -n "$callback" ]] || return 2
  declare -F "$callback" >/dev/null 2>&1 || return 2
  root="$(cd "$root" 2>/dev/null && pwd -P)" || return 1

  inventory_file="$(mktemp "${TMPDIR:-/tmp}/audlint_player_inventory.XXXXXX" 2>/dev/null || true)"
  [[ -n "$inventory_file" ]] || return 3
  if ! find "$root" -mindepth 2 -maxdepth 3 -type d -print0 >"$inventory_file" 2>/dev/null; then
    rm -f "$inventory_file"
    return 3
  fi

  while IFS= read -r -d '' dir; do
    if "$callback" "$dir" "$root"; then
      callback_status=0
    else
      callback_status=$?
    fi
    case "$callback_status" in
    0 | 1) ;;
    *) walk_status="$callback_status"; break ;;
    esac
  done <"$inventory_file"
  rm -f "$inventory_file"
  return "$walk_status"
}
