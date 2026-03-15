#!/usr/bin/env bash
# Shared terminal UI helpers for interactive audlint scripts.

ui_init_colors() {
  local use_color=true
  local force_color="${FORCE_COLOR:-${CLICOLOR_FORCE:-}}"
  local _red _green _yellow _blue _cyan _dim _reset
  if [[ -n "${NO_COLOR:-}" ]]; then
    use_color=false
  elif [[ "$force_color" == "1" || "$force_color" == "true" || "$force_color" == "yes" ]]; then
    use_color=true
  elif [[ ! -t 1 ]]; then
    use_color=false
  fi

  if [[ "$use_color" == true ]]; then
    if command -v tput >/dev/null 2>&1 \
      && _red="$(tput setaf 1 2>/dev/null)" \
      && _green="$(tput setaf 2 2>/dev/null)" \
      && _yellow="$(tput setaf 3 2>/dev/null)" \
      && _blue="$(tput setaf 4 2>/dev/null)" \
      && _cyan="$(tput setaf 6 2>/dev/null)" \
      && _dim="$(tput dim 2>/dev/null)" \
      && _reset="$(tput sgr0 2>/dev/null)"; then
      RED="$_red" GREEN="$_green" YELLOW="$_yellow" BLUE="$_blue" CYAN="$_cyan" DIM="$_dim" RESET="$_reset"
    else
      RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m' CYAN=$'\033[36m' DIM=$'\033[2m' RESET=$'\033[0m'
    fi
  else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM="" RESET=""
  fi
  : "${RED}${GREEN}${YELLOW}${BLUE}${CYAN}${DIM}${RESET}"
}

ui_wrap() {
  local color="${1-}"
  local text="${2-}"
  printf '%s%s%s' "$color" "$text" "$RESET"
}

ui_value_text() {
  ui_wrap "$CYAN" "${1-}"
}

ui_warn_text() {
  ui_wrap "$YELLOW" "${1-}"
}

ui_input_path_text() {
  ui_wrap "$BLUE" "${1-}"
}

ui_output_path_text() {
  ui_wrap "$GREEN" "${1-}"
}

ui_arrow_text() {
  ui_wrap "$DIM" '->'
}

ui_gain_text() {
  local gain="${1-}"
  case "$gain" in
  -*)
    ui_wrap "$YELLOW" "$gain"
    ;;
  +*)
    ui_wrap "$GREEN" "$gain"
    ;;
  *)
    ui_wrap "$CYAN" "$gain"
    ;;
  esac
}

log_ts() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

color_text_hex() {
  local hex="$1"
  local text="$2"
  local weight="${3:-normal}"
  hex="${hex#\#}"
  if [[ ${#hex} -ne 6 ]]; then
    printf '%s' "$text"
    return
  fi
  local r g b
  r=$((16#${hex:0:2}))
  g=$((16#${hex:2:2}))
  b=$((16#${hex:4:2}))
  if [[ "$weight" == "bold" ]]; then
    printf '\033[1;38;2;%d;%d;%dm%s\033[0m' "$r" "$g" "$b" "$text"
  else
    printf '\033[38;2;%d;%d;%dm%s\033[0m' "$r" "$g" "$b" "$text"
  fi
}

menu_choice_label() {
  local idx="$1"
  local code=0
  local ch=""
  [[ "$idx" =~ ^[0-9]+$ ]] || return 1
  if ((idx <= 9)); then
    printf '%s' "$idx"
    return 0
  fi
  if ((idx <= 35)); then
    code=$((97 + idx - 10))
    printf -v ch '%b' "\\$(printf '%03o' "$code")"
    printf '%s' "$ch"
    return 0
  fi
  printf '%s' "$idx"
}

menu_choice_range_hint() {
  local max_idx="$1"
  [[ "$max_idx" =~ ^[0-9]+$ ]] || {
    printf '0'
    return 0
  }
  if ((max_idx <= 9)); then
    printf '0-%s' "$max_idx"
    return 0
  fi
  if ((max_idx <= 35)); then
    printf '0-9,a-%s' "$(menu_choice_label "$max_idx")"
    return 0
  fi
  printf '0-9,a-z,36-%s' "$max_idx"
}

menu_choice_index_from_key() {
  local key="$1"
  local max_idx="$2"
  local ord=0
  local idx=0

  [[ "$max_idx" =~ ^[0-9]+$ ]] || return 1

  if [[ "$key" =~ ^[0-9]$ ]]; then
    idx=$((10#$key))
  elif [[ "$key" =~ ^[[:alpha:]]$ ]]; then
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    ord=$(printf '%d' "'$key")
    if ((ord < 97 || ord > 122)); then
      return 1
    fi
    idx=$((ord - 97 + 10))
  else
    return 1
  fi

  if ((idx < 0 || idx > max_idx)); then
    return 1
  fi
  printf '%s' "$idx"
}

read_menu_choice_immediate() {
  local max_idx="$1"
  local key="" choice=""
  local line=""
  local max_num=0
  [[ "$max_idx" =~ ^[0-9]+$ ]] || {
    printf ''
    return 0
  }
  max_num=$((10#$max_idx))

  if ((max_num > 35)); then
    if ! tty_read_line line; then
      printf ''
      return 1
    fi
    if declare -f normalize_search_query >/dev/null 2>&1; then
      line="$(normalize_search_query "$line")"
    else
      line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    fi
    if [[ "$line" =~ ^[0-9]+$ ]]; then
      choice=$((10#$line))
      if ((choice >= 0 && choice <= max_num)); then
        printf '%s' "$choice"
        return 0
      fi
    fi
    printf ''
    return 0
  fi

  if ! tty_read_key key 1; then
    printf ''
    return 1
  fi

  if [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
    printf ''
    return 0
  fi

  choice="$(menu_choice_index_from_key "$key" "$max_num" || true)"
  printf '%s' "$choice"
}

print_single_select_options_compact() {
  local values_var="$1"
  local counts_var="$2"
  local label_fn="$3"
  local max_cols="${4:-3}"
  local -n values_ref="$values_var"
  local -n counts_ref="$counts_var"
  local -a option_lines=()
  local -a col_widths=()
  local idx=0
  local line=""
  local term_cols=0
  local cols=1
  local min_cols=1
  local total=0
  local rows=0
  local row=0
  local col=0
  local pos=0
  local line_len=0
  local needed_width=0
  local last_col=-1
  local pad_width=0
  local label=""
  local choice_label=""

  while ((idx < ${#values_ref[@]})); do
    label="$("$label_fn" "${values_ref[$idx]}")"
    choice_label="$(menu_choice_label "$idx")"
    line="$(printf '%s) %s (%s)' "$choice_label" "$label" "${counts_ref[$idx]}")"
    option_lines+=("$line")
    idx=$((idx + 1))
  done

  total=${#option_lines[@]}
  ((total > 0)) || return 0

  if [[ "$max_cols" =~ ^[0-9]+$ ]] && ((max_cols > 0)); then
    cols="$max_cols"
  fi
  if ((cols > total)); then
    cols=$total
  fi
  if ((total >= 4 && cols >= 2)); then
    min_cols=2
  fi

  if [[ -t 1 ]]; then
    term_cols="$(term_cols_value)"
    [[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=0
  fi

  if ((term_cols > 0 && cols > min_cols)); then
    while ((cols > min_cols)); do
      rows=$(((total + cols - 1) / cols))
      col_widths=()
      for ((col = 0; col < cols; col++)); do
        col_widths+=("0")
      done
      for ((row = 0; row < rows; row++)); do
        for ((col = 0; col < cols; col++)); do
          pos=$((row + (col * rows)))
          ((pos < total)) || continue
          line_len=${#option_lines[$pos]}
          if ((line_len > col_widths[$col])); then
            col_widths[$col]=$line_len
          fi
        done
      done
      needed_width=0
      for ((col = 0; col < cols; col++)); do
        needed_width=$((needed_width + col_widths[$col]))
        if ((col < cols - 1)); then
          needed_width=$((needed_width + 2))
        fi
      done
      if ((needed_width <= term_cols)); then
        break
      fi
      cols=$((cols - 1))
    done
  fi

  if ((cols <= 1 || total == 1)); then
    for line in "${option_lines[@]}"; do
      printf '%s\n' "$line"
    done
    return 0
  fi

  rows=$(((total + cols - 1) / cols))
  col_widths=()
  for ((col = 0; col < cols; col++)); do
    col_widths+=("0")
  done
  for ((row = 0; row < rows; row++)); do
    for ((col = 0; col < cols; col++)); do
      pos=$((row + (col * rows)))
      ((pos < total)) || continue
      line_len=${#option_lines[$pos]}
      if ((line_len > col_widths[$col])); then
        col_widths[$col]=$line_len
      fi
    done
  done

  for ((row = 0; row < rows; row++)); do
    last_col=-1
    for ((col = cols - 1; col >= 0; col--)); do
      pos=$((row + (col * rows)))
      if ((pos < total)); then
        last_col=$col
        break
      fi
    done
    ((last_col >= 0)) || continue

    for ((col = 0; col <= last_col; col++)); do
      pos=$((row + (col * rows)))
      line="${option_lines[$pos]}"
      if ((col < last_col)); then
        pad_width=$((col_widths[$col] + 2))
        printf '%-*s' "$pad_width" "$line"
      else
        printf '%s' "$line"
      fi
    done
    printf '\n'
  done
}

view_button() {
  local key="$1"
  local label="$2"
  local view="$3"
  local force_active="${4:-}"
  local suffix=""
  local is_active=0
  if [[ "${ACTIVE_VIEW:-}" == "$view" || "$force_active" == "1" ]]; then
    suffix="*"
    is_active=1
  fi
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '[%s %s%s]' "$key" "$label" "$suffix"
    return
  fi
  local bracket_color="#aee8ff"
  local key_color="#ffffff"
  local label_color="#aee8ff"
  if ((is_active == 1)); then
    key_color="#fff0b3"
    label_color="#4da3ff"
  fi
  printf '%b%b%b%b' \
    "$(color_text_hex "$bracket_color" "[")" \
    "$(color_text_hex "$key_color" "$key" bold)" \
    "$(color_text_hex "$label_color" " ${label}${suffix}")" \
    "$(color_text_hex "$bracket_color" "]")"
}

hint_button() {
  local key="$1"
  local label="$2"
  local active="${3:-0}"
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf '[%s %s]' "$key" "$label"
    return
  fi
  local bracket_color="#aee8ff"
  local key_color="#ffffff"
  local label_color="#aee8ff"
  if [[ "$active" == "1" ]]; then
    key_color="#fff0b3"
    label_color="#b9f6a5"
  fi
  printf '%b%b%b%b' \
    "$(color_text_hex "$bracket_color" "[")" \
    "$(color_text_hex "$key_color" "$key" bold)" \
    "$(color_text_hex "$label_color" " ${label}")" \
    "$(color_text_hex "$bracket_color" "]")"
}

nav_separator() {
  if [[ "${USE_COLOR:-false}" != true ]]; then
    printf ' | '
    return
  fi
  printf '%b' "$(color_text_hex "#aee8ff" " | ")"
}

print_hint_buttons_line() {
  local first=1
  local btn
  for btn in "$@"; do
    if ((first == 1)); then
      printf '%s' "$btn"
      first=0
    else
      printf ' %s' "$btn"
    fi
  done
  printf '\n'
}

render_prompt_text() {
  local msg="$1"
  if [[ "${USE_COLOR:-false}" == true ]]; then
    printf '%b' "$(color_text_hex "#ffd98f" "$msg" bold)"
    return 0
  fi
  printf '%s' "$msg"
}

ui_prompt_key() {
  local prompt="$1"
  local out_var="$2"
  local silent="${3:-0}"
  local pad_top="${4:-1}"
  tty_prompt_key "$(render_prompt_text "$prompt")" "$out_var" "$silent" "$pad_top"
}

ui_prompt_line() {
  local prompt="$1"
  local out_var="$2"
  local pad_top="${3:-1}"
  tty_prompt_line "$(render_prompt_text "$prompt")" "$out_var" "$pad_top"
}
