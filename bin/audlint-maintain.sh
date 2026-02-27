#!/usr/bin/env bash
# audlint-maintain.sh - Maintenance control window for audlint task/cron actions.

set -Eeuo pipefail

BOOTSTRAP_SOURCE="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  BOOTSTRAP_SOURCE="$(realpath "$BOOTSTRAP_SOURCE" 2>/dev/null || printf '%s' "$BOOTSTRAP_SOURCE")"
elif command -v readlink >/dev/null 2>&1; then
  LINK_TARGET="$(readlink "$BOOTSTRAP_SOURCE" 2>/dev/null || true)"
  if [[ -n "$LINK_TARGET" ]]; then
    if [[ "$LINK_TARGET" = /* ]]; then
      BOOTSTRAP_SOURCE="$LINK_TARGET"
    else
      BOOTSTRAP_SOURCE="$(cd "$(dirname "$BOOTSTRAP_SOURCE")" && pwd)/$LINK_TARGET"
    fi
  fi
fi
BOOTSTRAP_DIR="$(cd "$(dirname "$BOOTSTRAP_SOURCE")" && pwd)"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/bootstrap.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"

AUDLINT_TASK_BIN="${AUDLINT_TASK_BIN:-$SCRIPT_DIR/audlint-task.sh}"
AUDLINT_TASK_MAX_ALBUMS="${AUDLINT_TASK_MAX_ALBUMS:-30}"
AUDLINT_TASK_MAX_TIME_SEC="${AUDLINT_TASK_MAX_TIME_SEC:-0}"
AUDLINT_TASK_LOG="${AUDLINT_TASK_LOG:-$HOME/audlint-task.log}"
AUDLINT_LIBRARY_ROOT="${AUDLINT_LIBRARY_ROOT:-${LIBRARY_ROOT:-${SRC:-}}}"
AUDLINT_CRON_INTERVAL_MIN="${AUDLINT_CRON_INTERVAL_MIN:-20}"
AUDLINT_BOOST_SEEK_BIN="${AUDLINT_BOOST_SEEK_BIN:-$SCRIPT_DIR/boost_seek.sh}"
NO_COLOR="${NO_COLOR:-}"
USE_COLOR=false
C_RESET=""
C_TITLE=""
C_LABEL=""
C_VALUE=""
C_ACTION=""
C_RESULT=""
C_SELECT=""
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  USE_COLOR=true
  C_RESET=$'\033[0m'
  C_TITLE=$'\033[1;36m'
  C_LABEL=$'\033[1;37m'
  C_VALUE=$'\033[0;36m'
  C_ACTION=$'\033[1;33m'
  C_RESULT=$'\033[1;32m'
  C_SELECT=$'\033[1;31m'
fi

CRON_BLOCK_BEGIN="# >>> audlint-cli maintain >>>"
CRON_BLOCK_END="# <<< audlint-cli maintain <<<"
BOOST_SELECT_KEYS="123456789abcdefghijklmnopqrstuvwxyz"

paint() {
  local color="$1"
  local text="$2"
  if [[ "$USE_COLOR" == true ]]; then
    printf '%s%s%s' "$color" "$text" "$C_RESET"
  else
    printf '%s' "$text"
  fi
}

virtwin_set_right_hint() {
  local text="$1"
  [[ "${VIRTWIN_TITLE_ROW:-}" =~ ^[0-9]+$ ]] || return 0
  [[ "${VIRTWIN_TERM_COLS:-}" =~ ^[0-9]+$ ]] || return 0
  local row cols plain col rendered
  row="$VIRTWIN_TITLE_ROW"
  cols="$VIRTWIN_TERM_COLS"
  plain="${text//$'\n'/ }"
  plain="${plain//$'\r'/ }"
  (( ${#plain} > 0 )) || return 0
  (( ${#plain} < cols )) || return 0
  col=$(( cols - ${#plain} + 1 ))
  (( col >= 1 )) || col=1
  rendered="$(paint "$C_RESULT" "$plain")"
  printf '\033[s\033[%s;%sH%s\033[u' "$row" "$col" "$rendered"
}

pause_with_result() {
  local result="$1"
  printf '\n%s press any key to continue' "$(paint "$C_RESULT" "$result")"
  local _key=""
  if declare -f tty_read_key >/dev/null 2>&1; then
    tty_read_key _key 1 || true
  else
    IFS= read -r -n 1 -s _key </dev/tty || true
  fi
  exit 0
}

shell_quote_sh() {
  local raw="$1"
  raw="${raw//\'/\'\\\'\'}"
  printf "'%s'" "$raw"
}

int_ge() {
  local raw="$1"
  local min="$2"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  ((raw >= min))
}

read_crontab_raw() {
  crontab -l 2>/dev/null || true
}

strip_managed_cron_block() {
  awk -v begin="$CRON_BLOCK_BEGIN" -v end="$CRON_BLOCK_END" '
    $0 == begin { in_block=1; next }
    $0 == end { in_block=0; next }
    in_block == 0 { print }
  '
}

cron_is_installed() {
  command -v crontab >/dev/null 2>&1 || return 1
  local current
  current="$(read_crontab_raw)"
  grep -Fqx "$CRON_BLOCK_BEGIN" <<<"$current" && grep -Fqx "$CRON_BLOCK_END" <<<"$current"
}

cron_schedule_for_interval() {
  local interval="$1"
  if ! int_ge "$interval" 1; then
    return 1
  fi
  if ((interval < 60)); then
    printf '*/%s * * * *' "$interval"
    return 0
  fi
  if ((interval == 60)); then
    printf '0 * * * *'
    return 0
  fi
  if ((interval == 1440)); then
    printf '0 0 * * *'
    return 0
  fi
  if ((interval > 60 && interval < 1440 && interval % 60 == 0)); then
    printf '0 */%s * * *' "$((interval / 60))"
    return 0
  fi
  return 1
}

cron_max_time_for_interval() {
  local interval_min="$1"
  if int_ge "$AUDLINT_TASK_MAX_TIME_SEC" 1; then
    printf '%s' "$AUDLINT_TASK_MAX_TIME_SEC"
    return 0
  fi
  if ! int_ge "$interval_min" 1; then
    printf '0'
    return 0
  fi
  local interval_sec
  interval_sec=$((interval_min * 60))
  if ((interval_sec > 120)); then
    printf '%s' "$((interval_sec - 120))"
  else
    printf '%s' "$interval_sec"
  fi
}

render_managed_cron_block() {
  local schedule="$1"
  local cron_max_time="$2"
  local task_q root_q log_q
  task_q="$(shell_quote_sh "$AUDLINT_TASK_BIN")"
  root_q="$(shell_quote_sh "$AUDLINT_LIBRARY_ROOT")"
  log_q="$(shell_quote_sh "$AUDLINT_TASK_LOG")"
  printf '%s\n' "$CRON_BLOCK_BEGIN"
  printf '%s PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ; %s --max-albums %s --max-time %s %s >> %s 2>&1\n' \
    "$schedule" "$task_q" "$AUDLINT_TASK_MAX_ALBUMS" "$cron_max_time" "$root_q" "$log_q"
  printf '%s\n' "$CRON_BLOCK_END"
}

install_cron_block() {
  if ! command -v crontab >/dev/null 2>&1; then
    pause_with_result "Install failed: crontab binary not found."
  fi
  if [[ ! -x "$AUDLINT_TASK_BIN" ]]; then
    pause_with_result "Install failed: task runner not executable ($AUDLINT_TASK_BIN)."
  fi
  if [[ -z "$AUDLINT_LIBRARY_ROOT" || ! -d "$AUDLINT_LIBRARY_ROOT" ]]; then
    pause_with_result "Install failed: AUDLINT_LIBRARY_ROOT is missing or invalid."
  fi
  if ! int_ge "$AUDLINT_TASK_MAX_ALBUMS" 1; then
    pause_with_result "Install failed: AUDLINT_TASK_MAX_ALBUMS must be >= 1."
  fi

  local schedule
  if ! schedule="$(cron_schedule_for_interval "$AUDLINT_CRON_INTERVAL_MIN")"; then
    pause_with_result "Install failed: unsupported AUDLINT_CRON_INTERVAL_MIN ($AUDLINT_CRON_INTERVAL_MIN)."
  fi

  local cron_max_time
  cron_max_time="$(cron_max_time_for_interval "$AUDLINT_CRON_INTERVAL_MIN")"
  if ! int_ge "$cron_max_time" 1; then
    pause_with_result "Install failed: invalid cron max-time ($cron_max_time)."
  fi

  local current stripped block new_crontab
  current="$(read_crontab_raw)"
  stripped="$(printf '%s\n' "$current" | strip_managed_cron_block)"
  block="$(render_managed_cron_block "$schedule" "$cron_max_time")"
  if [[ -n "$stripped" ]]; then
    new_crontab="$(printf '%s\n%s\n' "$stripped" "$block")"
  else
    new_crontab="$(printf '%s\n' "$block")"
  fi

  if printf '%s\n' "$new_crontab" | crontab -; then
    pause_with_result "Cron installed."
  fi
  pause_with_result "Install failed: unable to write crontab."
}

uninstall_cron_block() {
  if ! command -v crontab >/dev/null 2>&1; then
    pause_with_result "Uninstall failed: crontab binary not found."
  fi
  local current stripped
  current="$(read_crontab_raw)"
  stripped="$(printf '%s\n' "$current" | strip_managed_cron_block)"
  if printf '%s\n' "$stripped" | crontab -; then
    pause_with_result "Cron uninstalled."
  fi
  pause_with_result "Uninstall failed: unable to write crontab."
}

run_manual_maintain_once() {
  if [[ ! -x "$AUDLINT_TASK_BIN" ]]; then
    pause_with_result "Run failed: task runner not executable ($AUDLINT_TASK_BIN)."
  fi
  if [[ -z "$AUDLINT_LIBRARY_ROOT" || ! -d "$AUDLINT_LIBRARY_ROOT" ]]; then
    pause_with_result "Run failed: AUDLINT_LIBRARY_ROOT is missing or invalid."
  fi
  if ! int_ge "$AUDLINT_TASK_MAX_ALBUMS" 1; then
    pause_with_result "Run failed: AUDLINT_TASK_MAX_ALBUMS must be >= 1."
  fi

  local task_log_dir
  task_log_dir="$(dirname "$AUDLINT_TASK_LOG")"
  if [[ ! -d "$task_log_dir" || ! -w "$task_log_dir" ]]; then
    pause_with_result "Run failed: log directory unavailable ($task_log_dir)."
  fi

  local -a cmd
  cmd=("$AUDLINT_TASK_BIN" "--max-albums" "$AUDLINT_TASK_MAX_ALBUMS")
  if int_ge "$AUDLINT_TASK_MAX_TIME_SEC" 1; then
    cmd+=("--max-time" "$AUDLINT_TASK_MAX_TIME_SEC")
  fi
  cmd+=("$AUDLINT_LIBRARY_ROOT")

  printf 'Running maintenance task...\n\n'
  if "${cmd[@]}" 2>&1 | tee -a "$AUDLINT_TASK_LOG"; then
    pause_with_result "Maintenance run completed."
  fi
  pause_with_result "Maintenance run failed."
}

view_task_log() {
  if [[ ! -f "$AUDLINT_TASK_LOG" || ! -r "$AUDLINT_TASK_LOG" ]]; then
    pause_with_result "No log yet: $AUDLINT_TASK_LOG"
  fi
  printf 'Task log (live): %s\n' "$AUDLINT_TASK_LOG"
  printf -- '-----------\n'
  printf 'Press any key to stop live view.\n\n'

  if ! command -v tail >/dev/null 2>&1; then
    cat "$AUDLINT_TASK_LOG"
    pause_with_result "Live log unavailable: tail command not found."
  fi

  virtwin_set_right_hint "press any key to exit"
  tail -n 120 -F "$AUDLINT_TASK_LOG" &
  local tail_pid=$!
  local _key=""
  if declare -f tty_read_key >/dev/null 2>&1; then
    tty_read_key _key 1 || true
  else
    IFS= read -r -n 1 -s _key </dev/tty || true
  fi
  kill "$tail_pid" >/dev/null 2>&1 || true
  wait "$tail_pid" 2>/dev/null || true
  printf '\n%s\n' "$(paint "$C_RESULT" "Live log stopped.")"
  exit 0
}

run_boost_gain_for_dir() {
  local selected_dir="$1"
  if [[ ! -x "$AUDLINT_BOOST_SEEK_BIN" ]]; then
    pause_with_result "Boost failed: boost_seek not executable ($AUDLINT_BOOST_SEEK_BIN)."
  fi

  printf 'Boost Gain target: %s\n' "$selected_dir"
  printf -- '-----------\n'
  local rc=0
  (
    cd "$selected_dir" || exit 2
    "$AUDLINT_BOOST_SEEK_BIN" -y
  ) || rc=$?

  if ((rc == 0)); then
    pause_with_result "Boost gain completed."
  fi
  pause_with_result "Boost gain failed (exit $rc)."
}

print_boost_choice_grid() {
  local dirs_var="$1"
  local count="$2"
  local -n dirs_ref="$dirs_var"
  local max_cols line_len idx key base plain token
  max_cols="${VIRTWIN_TERM_COLS:-${COLUMNS:-120}}"
  [[ "$max_cols" =~ ^[0-9]+$ ]] || max_cols=120
  (( max_cols < 40 )) && max_cols=40
  line_len=0

  for ((idx=0; idx<count; idx++)); do
    key="${BOOST_SELECT_KEYS:idx:1}"
    base="$(basename "${dirs_ref[$idx]}")"
    plain="[$key] $base"
    token="$(paint "$C_SELECT" "[$key]") $(paint "$C_VALUE" "$base")"

    if ((line_len > 0 && line_len + 2 + ${#plain} > max_cols)); then
      printf '\n'
      line_len=0
    fi
    if ((line_len > 0)); then
      printf '  '
      line_len=$((line_len + 2))
    fi
    printf '%s' "$token"
    line_len=$((line_len + ${#plain}))
  done
  printf '\n'
}

boost_gain_page() {
  if [[ -z "$AUDLINT_LIBRARY_ROOT" || ! -d "$AUDLINT_LIBRARY_ROOT" ]]; then
    pause_with_result "Boost failed: AUDLINT_LIBRARY_ROOT is missing or invalid."
  fi

  local -a dirs=()
  while IFS= read -r -d '' dir; do
    dirs+=("$dir")
  done < <(find "$AUDLINT_LIBRARY_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | LC_ALL=C sort -z)

  if ((${#dirs[@]} == 0)); then
    pause_with_result "Boost skipped: no directories under library root."
  fi

  # Clear current viewport so the action prompt from the parent menu doesn't
  # remain on screen above the boost page.
  printf '\033[2J\033[H'
  printf '%s\n' "$(paint "$C_TITLE" "Boost Gain")"
  printf -- '%s\n' "$(paint "$C_TITLE" "-----------")"
  printf '%s %s\n\n' "$(paint "$C_LABEL" "Library Root:")" "$(paint "$C_VALUE" "$AUDLINT_LIBRARY_ROOT")"

  local max_choices="${#BOOST_SELECT_KEYS}"
  local show_count="${#dirs[@]}"
  if ((show_count > max_choices)); then
    show_count="$max_choices"
  fi

  local -a picked=()
  local idx key base
  for ((idx=0; idx<show_count; idx++)); do
    key="${BOOST_SELECT_KEYS:idx:1}"
    picked+=("${dirs[$idx]}")
  done
  print_boost_choice_grid picked "$show_count"
  if ((${#dirs[@]} > max_choices)); then
    printf '\nShowing first %d directories (of %d).\n' "$max_choices" "${#dirs[@]}"
  fi
  printf '%s %s\n' "$(paint "$C_SELECT" "[q]")" "$(paint "$C_LABEL" "Cancel")"
  printf '\nselect directory > '

  local sel=""
  if declare -f tty_read_key >/dev/null 2>&1; then
    tty_read_key sel 1 || sel="q"
  else
    IFS= read -r -n 1 -s sel </dev/tty || sel="q"
  fi
  sel="${sel,,}"
  printf '\n'

  if [[ "$sel" == "q" ]]; then
    return 0
  fi

  local prefix sel_idx
  if [[ "$BOOST_SELECT_KEYS" != *"$sel"* ]]; then
    return 0
  fi
  prefix="${BOOST_SELECT_KEYS%%"$sel"*}"
  sel_idx="${#prefix}"
  if ((sel_idx < 0 || sel_idx >= show_count)); then
    return 0
  fi

  run_boost_gain_for_dir "${picked[$sel_idx]}"
}

print_menu() {
  local cron_state="$1"
  printf '%s\n' "$(paint "$C_TITLE" "Maintenance")"
  printf -- '%s\n' "$(paint "$C_TITLE" "-----------")"
  printf '%s %s\n' "$(paint "$C_LABEL" "Task:")" "$(paint "$C_VALUE" "$AUDLINT_TASK_BIN")"
  printf '%s %s\n' "$(paint "$C_LABEL" "Library Root:")" "$(paint "$C_VALUE" "${AUDLINT_LIBRARY_ROOT:--}")"
  printf '%s %s\n' "$(paint "$C_LABEL" "Cron interval:")" "$(paint "$C_VALUE" "${AUDLINT_CRON_INTERVAL_MIN} min")"
  printf '\n'
  if [[ "$cron_state" == "installed" ]]; then
    printf '%s\n' "$(paint "$C_ACTION" "[u Uninstall Cron]")"
  else
    printf '%s\n' "$(paint "$C_ACTION" "[m Run Maintainance]")"
    printf '%s\n' "$(paint "$C_ACTION" "[i Install Cron]")"
  fi
  printf '%s\n' "$(paint "$C_ACTION" "[b Boost Gain]")"
  printf '%s\n' "$(paint "$C_ACTION" "[l View Log]")"
  printf '%s\n' "$(paint "$C_ACTION" "[q Exit to Main Window]")"
  printf '\n%s ' "$(paint "$C_LABEL" "choice >")"
}

main() {
  while true; do
    local cron_state="stopped"
    if cron_is_installed; then
      cron_state="installed"
    fi

    print_menu "$cron_state"
    local key=""
    if declare -f tty_read_key >/dev/null 2>&1; then
      tty_read_key key 1 || key="q"
    else
      IFS= read -r -n 1 -s key </dev/tty || key="q"
    fi
    printf '\n'

    case "${key,,}" in
    m)
      if [[ "$cron_state" == "installed" ]]; then
        pause_with_result "Run skipped: cron is installed."
      fi
      run_manual_maintain_once
      ;;
    i)
      if [[ "$cron_state" == "installed" ]]; then
        pause_with_result "Install skipped: cron already installed."
      fi
      install_cron_block
      ;;
    u)
      if [[ "$cron_state" != "installed" ]]; then
        pause_with_result "Uninstall skipped: cron is not installed."
      fi
      uninstall_cron_block
      ;;
    b)
      boost_gain_page
      ;;
    l)
      view_task_log
      ;;
    q)
      exit 0
      ;;
    *)
      pause_with_result "Unknown action."
      ;;
    esac
  done
}

main "$@"
