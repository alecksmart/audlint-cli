#!/usr/bin/env bash

rich_escape() {
  printf '%s' "$1" | sed -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

rich_style_grade() {
  local value="$1"
  local escaped
  escaped="$(rich_escape "$value")"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '%s' "$escaped"
    return
  fi
  case "$value" in
  S | A) printf '[green]%s[/]' "$escaped" ;;
  B | C) printf '[yellow]%s[/]' "$escaped" ;;
  F) printf '[red]%s[/]' "$escaped" ;;
  *) printf '%s' "$escaped" ;;
  esac
}

rich_style_spec_rec() {
  local value="$1"
  local escaped
  escaped="$(rich_escape "$value")"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '%s' "$escaped"
    return
  fi
  case "$value" in
  LOSSY* | Trash*) printf '[bold red]%s[/]' "$escaped" ;;
  Upsample* | "Replace with CD Rip" | "Replace with Lossless Rip") printf '[yellow]%s[/]' "$escaped" ;;
  Keep*) printf '[green]%s[/]' "$escaped" ;;
  Store\ as*) printf '[cyan]%s[/]' "$escaped" ;;
  *) printf '[magenta]%s[/]' "$escaped" ;;
  esac
}

rich_style_album1() {
  local value="$1"
  local escaped
  escaped="$(rich_escape "$value")"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '%s' "$escaped"
    return
  fi
  printf '[bold cyan]%s[/]' "$escaped"
}

rich_style_album2() {
  local value="$1"
  local escaped
  escaped="$(rich_escape "$value")"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '%s' "$escaped"
    return
  fi
  printf '[bold dark_orange3]%s[/]' "$escaped"
}

rich_style_score() {
  local value="$1"
  local escaped
  escaped="$(rich_escape "$value")"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '%s' "$escaped"
    return
  fi
  printf '[bold green]%s[/]' "$escaped"
}

rich_style_profile() {
  local value="$1"
  local escaped
  escaped="$(rich_escape "$value")"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '%s' "$escaped"
    return
  fi
  printf '[bold #f6e58d]%s[/]' "$escaped"
}

rich_style_codec() {
  local value="$1"
  local escaped
  escaped="$(rich_escape "$value")"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '%s' "$escaped"
    return
  fi
  printf '[bold #ff9ff3]%s[/]' "$escaped"
}
