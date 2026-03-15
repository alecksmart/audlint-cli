#!/usr/bin/env bash

path_resolve() {
  local target="${1:-}"
  local resolved=""
  local link_target=""
  local parent=""
  local base=""

  [[ -n "$target" ]] || return 1

  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$target" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  if command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$target" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi

    link_target="$(readlink "$target" 2>/dev/null || true)"
    if [[ -n "$link_target" ]]; then
      if [[ "$link_target" = /* ]]; then
        printf '%s\n' "$link_target"
      else
        parent="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
        printf '%s/%s\n' "$parent" "$link_target"
      fi
      return 0
    fi
  fi

  if [[ -d "$target" ]]; then
    (cd "$target" 2>/dev/null && pwd -P)
    return $?
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    parent="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename "$target")"
    printf '%s/%s\n' "$parent" "$base"
    return 0
  fi

  printf '%s\n' "$target"
}

stat_epoch_mtime() {
  local path="$1"
  local out=""
  if out="$(stat -f '%m' "$path" 2>/dev/null)"; then
    if [[ "$out" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  if out="$(stat -c '%Y' "$path" 2>/dev/null)"; then
    if [[ "$out" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  return 1
}

stat_size_bytes() {
  local path="$1"
  local out=""
  if out="$(stat -f '%z' "$path" 2>/dev/null)"; then
    if [[ "$out" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  if out="$(stat -c '%s' "$path" 2>/dev/null)"; then
    if [[ "$out" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  return 1
}

date_format_epoch() {
  local epoch="${1:-}"
  local format="${2:-}"
  local out=""

  [[ "$epoch" =~ ^-?[0-9]+$ ]] || return 1
  [[ -n "$format" ]] || return 2

  if out="$(date -r "$epoch" "$format" 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  if out="$(date -d "@$epoch" "$format" 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

bootstrap_resolve_paths() {
  local entry="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
  local script_path="$entry"

  script_path="$(path_resolve "$script_path")"

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

tty_ensure_line_mode() {
  if [[ -t 0 ]]; then
    stty sane <&0 2>/dev/null || true
    stty echo icanon icrnl <&0 2>/dev/null || true
  elif [[ -r /dev/tty ]]; then
    stty sane </dev/tty 2>/dev/null || true
    stty echo icanon icrnl </dev/tty 2>/dev/null || true
  fi
}

tty_print_text() {
  local text="${1-}"
  if ! { printf '%s' "$text" >/dev/tty; } 2>/dev/null; then
    printf '%s' "$text"
  fi
}

tty_print_line() {
  tty_print_text "${1-}"
  tty_print_text $'\n'
}

tty_read_line() {
  local out_var="${1:-}"
  local saved_stdin_fd=""
  local _tty_line=""
  local rc=1

  [[ -n "$out_var" ]] || return 2

  if [[ ! -t 0 ]]; then
    [[ -r /dev/tty ]] || {
      printf -v "$out_var" '%s' "$_tty_line"
      return 1
    }
    exec {saved_stdin_fd}<&0 || {
      printf -v "$out_var" '%s' "$_tty_line"
      return 1
    }
    if ! exec </dev/tty; then
      exec 0<&$saved_stdin_fd
      exec {saved_stdin_fd}<&-
      printf -v "$out_var" '%s' "$_tty_line"
      return 1
    fi
  fi

  tty_ensure_line_mode
  if IFS= read -r _tty_line 2>/dev/null; then
    rc=0
  fi
  tty_ensure_line_mode

  if [[ -n "$saved_stdin_fd" ]]; then
    exec 0<&$saved_stdin_fd
    exec {saved_stdin_fd}<&-
  fi

  printf -v "$out_var" '%s' "$_tty_line"
  return "$rc"
}

tty_read_key() {
  local out_var="${1:-}"
  local silent="${2:-0}"
  local _tty_key=""
  local rc=1
  local saved_stdin_fd=""
  local tty_state=""

  [[ -n "$out_var" ]] || return 2

  if [[ ! -t 0 ]]; then
    [[ -r /dev/tty ]] || {
      printf -v "$out_var" '%s' "$_tty_key"
      return 1
    }
    exec {saved_stdin_fd}<&0 || {
      printf -v "$out_var" '%s' "$_tty_key"
      return 1
    }
    if ! exec </dev/tty; then
      exec 0<&$saved_stdin_fd
      exec {saved_stdin_fd}<&-
      printf -v "$out_var" '%s' "$_tty_key"
      return 1
    fi
  fi

  tty_state="$(stty -g <&0 2>/dev/null || true)"
  if [[ -n "$tty_state" ]]; then
    if [[ "$silent" == "1" ]]; then
      stty -echo -icanon min 1 time 0 <&0 2>/dev/null || true
    else
      stty echo -icanon min 1 time 0 <&0 2>/dev/null || true
    fi
    if IFS= read -r -n 1 _tty_key 2>/dev/null; then
      rc=0
    fi
    stty "$tty_state" <&0 2>/dev/null || true
  else
    tty_ensure_line_mode
    if [[ "$silent" == "1" ]]; then
      if IFS= read -r -n 1 -s _tty_key 2>/dev/null; then
        rc=0
      fi
    else
      if IFS= read -r -n 1 _tty_key 2>/dev/null; then
        rc=0
      fi
    fi
    tty_ensure_line_mode
  fi

  if ((rc != 0)) && [[ -z "$_tty_key" ]]; then
    local line_fallback=""
    if IFS= read -r line_fallback 2>/dev/null; then
      _tty_key="${line_fallback:0:1}"
      [[ -n "$_tty_key" ]] && rc=0
    fi
  fi
  if ((rc == 0)) && [[ -z "$_tty_key" ]]; then
    _tty_key=$'\n'
  fi

  if [[ -n "$saved_stdin_fd" ]]; then
    exec 0<&$saved_stdin_fd
    exec {saved_stdin_fd}<&-
  fi

  printf -v "$out_var" '%s' "$_tty_key"
  return "$rc"
}

tty_prompt_line() {
  local prompt="${1:-}"
  local out_var="${2:-}"
  local pad_top="${3:-0}"

  [[ -n "$out_var" ]] || return 2
  if [[ "$pad_top" == "1" ]]; then
    tty_print_text $'\n'
  fi
  tty_print_text "$prompt"
  tty_read_line "$out_var"
}

tty_prompt_key() {
  local prompt="${1:-}"
  local out_var="${2:-}"
  local silent="${3:-0}"
  local pad_top="${4:-0}"
  local rc=1

  [[ -n "$out_var" ]] || return 2
  if [[ "$pad_top" == "1" ]]; then
    tty_print_text $'\n'
  fi
  tty_print_text "$prompt"
  if tty_read_key "$out_var" "$silent"; then
    rc=0
  fi
  tty_print_text $'\n'
  return "$rc"
}
