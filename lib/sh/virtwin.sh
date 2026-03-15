#!/usr/bin/env bash
# virtwin.sh - Virtual window for running commands below a preserved header.

# virtwin_run_command <start_line> <term_lines> <term_cols> <title> [--no-wait] <command> [args...]
#
# Preserves the first <start_line> rows of the terminal as a frozen header.
# Sets a scroll region from <start_line> to <term_lines>-2 (reserving 2 rows
# for a result footer), prints a title separator, and runs <command> with
# output confined to that region.  On completion shows a status message and
# waits for a keypress.  The caller's main loop is expected to redraw the
# full screen afterward.
#
# <start_line> is 0-based (0 = full screen, 5 = freeze top 5 rows).
# <term_lines> and <term_cols> are the caller's known terminal dimensions.
virtwin_run_command() {
  local start_line="$1"
  local term_lines="$2"
  local term_cols="$3"
  local title="$4"
  shift 4

  local wait_for_key=1
  if [[ "${1:-}" == "--no-wait" ]]; then
    wait_for_key=0
    shift
  fi

  local right_title="${VIRTWIN_RIGHT_TITLE:-}"
  right_title="${right_title//$'\n'/ }"
  right_title="${right_title//$'\r'/ }"
  local plain_title=0
  if [[ "${VIRTWIN_TITLE_PLAIN:-0}" == "1" ]]; then
    plain_title=1
  fi

  # Title separator — printed in the gap between header and scroll region.
  local title_row=$((start_line + 1))
  printf '\033[%d;1H' "$title_row"
  printf '\033[J'
  local left_title=""
  if ((plain_title == 1)); then
    left_title="$title"
  else
    left_title="$title | running..."
  fi
  if [[ "${USE_COLOR:-}" == true ]] && declare -f color_text_hex >/dev/null 2>&1; then
    if ((plain_title == 1)); then
      printf '%b' "$(color_text_hex "#ff8c00" "$title" bold)"
    else
      printf '%b' "$(color_text_hex "#ff8c00" "$title" bold) | $(color_text_hex "#ffc24a" "running..." bold)"
    fi
  else
    printf '%s' "$left_title"
  fi
  local available_right=$((term_cols - ${#left_title} - 3))
  if [[ -n "$right_title" && $available_right -gt 0 ]]; then
    local right_shown="$right_title"
    if ((${#right_shown} > available_right)); then
      right_shown="${right_shown:0:available_right}"
    fi
    local right_col=$((term_cols - ${#right_shown} + 1))
    if ((right_col > ${#left_title} + 3)); then
      printf '\033[%d;%dH' "$title_row" "$right_col"
      if [[ "${USE_COLOR:-}" == true ]] && declare -f color_text_hex >/dev/null 2>&1; then
        local part1 part2 part3 rest right_rendered
        if [[ "$right_shown" == *" | "* ]]; then
          part1="${right_shown%% | *}"
          rest="${right_shown#* | }"
          if [[ "$rest" == *" | "* ]]; then
            part2="${rest%% | *}"
            part3="${rest#* | }"
            right_rendered="$(color_text_hex "#4da3ff" "$part1" bold)"
            right_rendered+="$(color_text_hex "#6f8dff" " | " bold)"
            right_rendered+="$(color_text_hex "#8e6df5" "$part2" bold)"
            right_rendered+="$(color_text_hex "#b38cff" " | " bold)"
            right_rendered+="$(color_text_hex "#d0b3ff" "$part3" bold)"
            printf '%b' "$right_rendered"
          else
            printf '%b' "$(color_text_hex "#b185db" "$right_shown" bold)"
          fi
        else
          printf '%b' "$(color_text_hex "#b185db" "$right_shown" bold)"
        fi
      else
        printf '%s' "$right_shown"
      fi
    fi
  fi
  printf '\033[%d;1H' "$((title_row + 1))"
  printf -- '─%.0s' $(seq 1 "$term_cols")
  printf '\n'

  # Scroll region: starts 2 rows below the separator, ends 2 rows above bottom.
  # This keeps the title + separator frozen alongside the header.
  local sr_top=$((start_line + 4))
  if [[ "${VIRTWIN_COMPACT_TOP:-0}" == "1" ]]; then
    sr_top=$((start_line + 3))
  fi
  local sr_bot=$((term_lines - 2))
  printf '\033[%d;%dr' "$sr_top" "$sr_bot"
  printf '\033[%d;1H' "$sr_top"

  # Run the command; capture exit code without triggering errexit.
  local rc=0
  if [[ -n "${VIRTWIN_LOG_FILE:-}" ]]; then
    VIRTWIN_TITLE_ROW="$title_row" VIRTWIN_TERM_COLS="$term_cols" "$@" 2>&1 | tee "$VIRTWIN_LOG_FILE" || rc=${PIPESTATUS[0]}
  else
    VIRTWIN_TITLE_ROW="$title_row" VIRTWIN_TERM_COLS="$term_cols" "$@" 2>&1 || rc=$?
  fi

  # Reset scroll region to full terminal, then draw status + prompt in the footer.
  printf '\033[;r'
  local footer_status_row=$((term_lines - 1))
  local footer_prompt_row="$term_lines"
  printf '\033[%d;1H' "$footer_status_row"
  printf '\033[2K'
  if ((rc == 0)); then
    if [[ "${USE_COLOR:-}" == true ]] && declare -f color_text_hex >/dev/null 2>&1; then
      printf '%b' "$(color_text_hex "#00e676" "✔ $title completed." bold)"
    else
      printf '✔ %s completed.' "$title"
    fi
  else
    if [[ "${USE_COLOR:-}" == true ]] && declare -f color_text_hex >/dev/null 2>&1; then
      printf '%b' "$(color_text_hex "#ff5252" "✘ $title failed (exit $rc)." bold)"
  else
      printf '✘ %s failed (exit %d).' "$title" "$rc"
    fi
  fi
  printf '\n'

  if ((wait_for_key == 1)); then
    printf '\033[%d;1H' "$footer_prompt_row"
    printf '\033[2K'
    if [[ "${USE_COLOR:-}" == true ]] && declare -f color_text_hex >/dev/null 2>&1; then
      printf '%b' "$(color_text_hex "#ffd98f" "[any key Continue] > " bold)"
    else
      printf '%s' '[any key Continue] > '
    fi
    if declare -f tty_prompt_key >/dev/null 2>&1; then
      tty_prompt_key "" _ 1 0 || true
    elif declare -f tty_read_key >/dev/null 2>&1; then
      tty_read_key _ 1 || true
      printf '\n'
    else
      IFS= read -r -n 1 -s _ </dev/tty || true
      printf '\n'
    fi
  else
    printf '\033[%d;1H' "$footer_prompt_row"
    printf '\033[2K'
    printf '\n'
  fi
  return "$rc"
}
