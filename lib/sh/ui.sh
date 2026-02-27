#!/usr/bin/env bash

ui_init_colors() {
  local use_color=true
  if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    use_color=false
  fi

  if [[ "$use_color" == true ]] && command -v tput >/dev/null 2>&1; then
    RED="$(tput setaf 1)" GREEN="$(tput setaf 2)" YELLOW="$(tput setaf 3)" BLUE="$(tput setaf 4)" CYAN="$(tput setaf 6)" DIM="$(tput dim)" RESET="$(tput sgr0)"
  else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM="" RESET=""
  fi
  : "${RED}${GREEN}${YELLOW}${BLUE}${CYAN}${DIM}${RESET}"
}

log_ts() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}
