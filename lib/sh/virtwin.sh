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

  # Title separator — printed in the gap between header and scroll region.
  local title_row=$((start_line + 1))
  printf '\033[%d;1H' "$title_row"
  printf '\033[J'
  local left_title="$title | running..."
  if [[ "${USE_COLOR:-}" == true ]] && declare -f color_text_hex >/dev/null 2>&1; then
    printf '%b' "$(color_text_hex "#ff8c00" "$title" bold) | $(color_text_hex "#ffc24a" "running..." bold)"
  else
    printf '%s' "$left_title"
  fi
  if [[ -n "$right_title" ]] && ((${#right_title} < term_cols)); then
    local right_col=$((term_cols - ${#right_title} + 1))
    if ((right_col > ${#left_title} + 3)); then
      printf '\033[%d;%dH' "$title_row" "$right_col"
      if [[ "${USE_COLOR:-}" == true ]] && declare -f color_text_hex >/dev/null 2>&1; then
        local part1 part2 part3 rest right_rendered
        if [[ "$right_title" == *" | "* ]]; then
          part1="${right_title%% | *}"
          rest="${right_title#* | }"
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
            printf '%b' "$(color_text_hex "#b185db" "$right_title" bold)"
          fi
        else
          printf '%b' "$(color_text_hex "#b185db" "$right_title" bold)"
        fi
      else
        printf '%s' "$right_title"
      fi
    fi
  fi
  printf '\033[%d;1H' "$((title_row + 1))"
  printf -- '─%.0s' $(seq 1 "$term_cols")
  printf '\n'

  # Scroll region: starts 2 rows below the separator, ends 2 rows above bottom.
  # This keeps the title + separator frozen alongside the header.
  local sr_top=$((start_line + 4))
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

  # Reset scroll region to full terminal, then jump to the footer area.
  printf '\033[;r'
  printf '\033[%d;1H' "$((term_lines - 1))"
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

  if ((wait_for_key == 1)); then
    printf ' Press any key to return.'
    if declare -f tty_read_key >/dev/null 2>&1; then
      tty_read_key _ 1 || true
    else
      IFS= read -r -n 1 -s _ </dev/tty || true
    fi
  fi
  return "$rc"
}
