#!/usr/bin/env bash

table_render_tsv() {
  local columns="$1"
  local widths="${2:-}"
  local title="${3:-}"
  local align="${4:-}"
  local cmd=()

  if [[ -n "${RICH_TABLE_CMD:-}" ]]; then
    cmd=("$RICH_TABLE_CMD")
  else
    local py_bin="${TABLE_PYTHON_BIN:-${PYTHON_BIN:-python3}}"
    local renderer="${REPO_ROOT}/lib/py/rich_table.py"
    command -v "$py_bin" >/dev/null 2>&1 || {
      echo "Error: python interpreter not found: $py_bin" >&2
      return 1
    }
    [[ -f "$renderer" ]] || {
      echo "Error: rich table renderer not found: $renderer" >&2
      return 1
    }
    cmd=("$py_bin" "$renderer")
  fi

  cmd+=(--columns "$columns")
  [[ -n "$widths" ]] && cmd+=(--widths "$widths")
  [[ -n "$title" ]] && cmd+=(--title "$title")
  [[ -n "$align" ]] && cmd+=(--align "$align")
  "${cmd[@]}"
}

table_require_rich() {
  if [[ -n "${RICH_TABLE_CMD:-}" ]]; then
    command -v "$RICH_TABLE_CMD" >/dev/null 2>&1 || {
      echo "Error: RICH_TABLE_CMD is set but not executable: $RICH_TABLE_CMD" >&2
      return 1
    }
    return 0
  fi

  local py_bin="${TABLE_PYTHON_BIN:-${PYTHON_BIN:-python3}}"
  local renderer="${REPO_ROOT}/lib/py/rich_table.py"
  command -v "$py_bin" >/dev/null 2>&1 || {
    echo "Error: python interpreter not found: $py_bin" >&2
    return 1
  }
  [[ -f "$renderer" ]] || {
    echo "Error: rich table renderer not found: $renderer" >&2
    return 1
  }
  "$py_bin" - <<'PY' >/dev/null 2>&1
import rich  # noqa
PY
}
