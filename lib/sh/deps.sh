#!/usr/bin/env bash

has_bin() {
  command -v "$1" >/dev/null 2>&1
}

deps_ensure_common_path() {
  local dir
  for dir in "${AUDL_BIN_PATH:-$HOME/.local/bin}" /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
    dir="${dir/#\~/$HOME}"
    dir="${dir//\$HOME/$HOME}"
    [[ -d "$dir" ]] || continue
    case ":${PATH:-}:" in
    *":$dir:"*) ;;
    *)
      if [[ -n "${PATH:-}" ]]; then
        PATH="$dir:$PATH"
      else
        PATH="$dir"
      fi
      ;;
    esac
  done
  export PATH
}

require_bins() {
  local missing=0
  local bin
  for bin in "$@"; do
    if ! has_bin "$bin"; then
      printf 'Missing dependency: %s\n' "$bin" >&2
      missing=1
    fi
  done
  ((missing == 0))
}
