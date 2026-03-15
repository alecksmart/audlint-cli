#!/usr/bin/env bash

table_resolve_python_bin() {
  local candidate=""
  local -a candidates=()
  local seen=$'\n'

  [[ -n "${AUDL_PYTHON_BIN:-}" ]] && candidates+=("$AUDL_PYTHON_BIN")
  candidates+=(python3.13 python3.12 python3.11 python3)

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    [[ "$seen" == *$'\n'"$candidate"$'\n'* ]] && continue
    seen+="$candidate"$'\n'
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" - <<'PY' >/dev/null 2>&1
import rich  # noqa
PY
    then
      printf '%s' "$candidate"
      return 0
    fi
  done

  echo "Error: python interpreter with rich not found. Checked AUDL_PYTHON_BIN, python3.13, python3.12, python3.11, python3" >&2
  return 1
}

table_render_tsv() {
  local columns="$1"
  local widths="${2:-}"
  local title="${3:-}"
  local align="${4:-}"
  local cmd=()

  if [[ -n "${RICH_TABLE_CMD:-}" ]]; then
    cmd=("$RICH_TABLE_CMD")
  else
    local py_bin=""
    local renderer="${REPO_ROOT}/lib/py/rich_table.py"
    if ! py_bin="$(table_resolve_python_bin)"; then
      return 1
    fi
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

  local py_bin=""
  local renderer="${REPO_ROOT}/lib/py/rich_table.py"
  if ! py_bin="$(table_resolve_python_bin)"; then
    return 1
  fi
  [[ -f "$renderer" ]] || {
    echo "Error: rich table renderer not found: $renderer" >&2
    return 1
  }
  return 0
}
