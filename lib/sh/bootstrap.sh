#!/opt/homebrew/bin/bash

bootstrap_resolve_paths() {
  local entry="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
  local script_path="$entry"

  if command -v realpath >/dev/null 2>&1; then
    script_path="$(realpath "$script_path" 2>/dev/null || printf '%s' "$script_path")"
  elif command -v readlink >/dev/null 2>&1; then
    local link_target
    link_target="$(readlink "$script_path" 2>/dev/null || true)"
    if [[ -n "$link_target" ]]; then
      if [[ "$link_target" = /* ]]; then
        script_path="$link_target"
      else
        script_path="$(cd "$(dirname "$script_path")" && pwd)/$link_target"
      fi
    fi
  fi

  local script_dir
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"

  local repo_root=""
  if command -v git >/dev/null 2>&1; then
    repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$script_dir/.." && pwd)"
  fi

  SCRIPT_PATH="$script_path" SCRIPT_DIR="$script_dir" REPO_ROOT="$repo_root"
  : "${SCRIPT_PATH}${SCRIPT_DIR}${REPO_ROOT}"
}
