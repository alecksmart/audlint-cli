#!/usr/bin/env bash

select_python_with_numpy() {
  local candidates=("${AUDL_PYTHON_BIN:-python3}" python3.13 python3.12 python3.11 python3)
  local p
  for p in "${candidates[@]}"; do
    if command -v "$p" >/dev/null 2>&1; then
      if "$p" - <<'PY' >/dev/null 2>&1; then
import numpy  # noqa
PY
        AUDL_PYTHON_BIN="$p"
        return 0
      fi
    fi
  done
  echo "Error: python with numpy not found. Set AUDL_PYTHON_BIN to a python that can import numpy." >&2
  return 1
}
