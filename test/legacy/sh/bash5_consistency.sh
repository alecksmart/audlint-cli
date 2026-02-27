#!/usr/bin/env bash
#
# bash5_consistency.sh
# Development guard for Bash 5 migration consistency.
#
# Checks:
# 1) Required Bash binary exists and is >= 5.
# 2) Core Bash 5 features work.
# 3) Shebang policy for selected scripts is consistent.
# 4) Selected scripts pass shell parse check (-n).
#
# Usage:
#   tests/sh/bash5_consistency.sh
#   tests/sh/bash5_consistency.sh lib/sh bin
#
# Env overrides:
#   EXPECTED_BASH=/absolute/path/to/bash
#
# shellcheck disable=SC2016
# SC2016 is expected here because this script intentionally passes literal
# command snippets to "$EXPECTED_BASH -c ..." for feature probes.

set -euo pipefail

EXPECTED_BASH="${EXPECTED_BASH:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF_PATH="${ROOT_DIR}/tests/sh/bash5_consistency.sh"

declare -a TARGETS
if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  # Default scope for development consistency checks.
  TARGETS=(
    "lib/sh"
  )
fi

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  printf 'PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_cmd() {
  local name="$1"
  local code="$2"
  if "$EXPECTED_BASH" -c "$code" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name"
  fi
}

resolve_expected_bash() {
  if [[ -n "$EXPECTED_BASH" ]]; then
    return 0
  fi
  local candidate=""
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)" /bin/bash; do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate" ]]; then
      EXPECTED_BASH="$candidate"
      return 0
    fi
  done
}

assert_bash_runtime() {
  if [[ ! -x "$EXPECTED_BASH" ]]; then
    fail "Expected Bash binary is missing or not executable: $EXPECTED_BASH"
    return
  fi
  pass "Expected Bash binary exists: $EXPECTED_BASH"

  local major
  major="$("$EXPECTED_BASH" -c 'printf "%s" "${BASH_VERSINFO[0]}"' 2>/dev/null || printf "0")"
  if [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 5)); then
    pass "Bash major version is >= 5 ($("$EXPECTED_BASH" --version | head -n1))"
  else
    fail "Bash major version is < 5 ($("$EXPECTED_BASH" --version | head -n1))"
  fi
}

assert_bash5_features() {
  check_cmd "Associative arrays" 'declare -A m=([k]=v); [[ "${m[k]}" == "v" ]]'
  check_cmd "Nameref (local -n)" 'f(){ local x="ok"; local -n ref=x; [[ "$ref" == "ok" ]]; }; f'
  check_cmd "mapfile/readarray" 'mapfile -t a < <(printf "a\nb\n"); [[ "${#a[@]}" -eq 2 && "${a[1]}" == "b" ]]'
  check_cmd "Lowercase expansion \${var,,}" 'v="AbC"; [[ "${v,,}" == "abc" ]]'
  check_cmd "Uppercase expansion \${var^^}" 'v="AbC"; [[ "${v^^}" == "ABC" ]]'
  check_cmd "globstar recursion" 'shopt -s globstar; [[ "$(printf "%s" "**")" == "**" ]]'
}

collect_sh_files() {
  local target="$1"
  local resolved="${ROOT_DIR}/${target}"

  if [[ -f "$resolved" ]]; then
    if [[ "$resolved" == *.sh ]]; then
      printf '%s\n' "$resolved"
    fi
    return
  fi

  if [[ -d "$resolved" ]]; then
    find "$resolved" -type f -name '*.sh' -print
    return
  fi

  fail "Target path does not exist: $target"
}

assert_shebang_and_parse() {
  local any_files=0
  local f first_line
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    any_files=1

    if [[ "$f" == "$SELF_PATH" ]]; then
      pass "Shebang policy (self): $f"
    else
      first_line="$(head -n1 "$f" 2>/dev/null || true)"
      if [[ "$first_line" == "#!/usr/bin/env bash" || "$first_line" == "#!${EXPECTED_BASH}" ]]; then
        pass "Shebang policy: $f"
      else
        fail "Shebang mismatch: $f (found: ${first_line:-<none>})"
      fi
    fi

    if "$EXPECTED_BASH" -n "$f" >/dev/null 2>&1; then
      pass "Parse check: $f"
    else
      fail "Parse check failed: $f"
    fi
  done < <(
    local t
    for t in "${TARGETS[@]}"; do
      collect_sh_files "$t"
    done | sort -u
  )

  if [[ "$any_files" -eq 0 ]]; then
    fail "No .sh files discovered in selected targets"
  fi
}

main() {
  resolve_expected_bash
  printf 'Bash 5 consistency check\n'
  printf 'Root: %s\n' "$ROOT_DIR"
  printf 'Expected Bash: %s\n' "$EXPECTED_BASH"
  printf 'Targets: %s\n\n' "${TARGETS[*]}"

  assert_bash_runtime
  assert_bash5_features
  assert_shebang_and_parse

  printf '\nSummary: pass=%d fail=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
  if ((FAIL_COUNT > 0)); then
    exit 1
  fi
}

main "$@"
