#!/usr/bin/env bash

env_load_files() {
  local env_file
  for env_file in "$@"; do
    [[ -f "$env_file" ]] || continue
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    return 0
  done
  return 1
}

env_expand_value() {
  local raw="$1"
  if [[ "$raw" == *'$'* ]]; then
    eval "printf '%s' \"$raw\""
  else
    printf '%s' "$raw"
  fi
}

env_require_vars() {
  local missing=0
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      printf 'Missing required env var: %s\n' "$name" >&2
      missing=1
    fi
  done
  ((missing == 0))
}
