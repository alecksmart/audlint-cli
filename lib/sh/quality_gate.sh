#!/opt/homebrew/bin/bash
# quality_gate.sh — shared mastering-gate logic used by qty_seek, spectre, and
# qty_compare.  Source this file; do not execute it directly.

apply_mastering_guard() {
  # Usage: apply_mastering_guard <spec_rec> <mastering_grade> <mastering_rec> <current_quality>
  #
  # MX3 — Mastering guard.
  # Fires ONLY when the spectral recommendation is a genuine profile DOWNGRADE
  # (target profile != current storage format) AND the album already requires
  # replacement (grade C/F or mastering rec is Trash/Replace).
  # The no-op case ("Store as 192/24" when already at 192/24) is passed through
  # unchanged so the existing no-op check in the caller can handle it normally.
  local spec_rec="$1"
  local mastering_grade="$2"
  local mastering_rec="$3"
  local current_quality="${4:-}"   # e.g. "192/24", "96/24" — may be empty

  # Pass through if not a profile-downgrade recommendation.
  if [[ -z "$spec_rec" || "$spec_rec" != *"Store as "* ]]; then
    printf '%s\n' "$spec_rec"
    return 0
  fi

  # Extract the recommended target profile from "… Store as <profile>".
  local recode_target
  recode_target="${spec_rec##*Store as }"
  recode_target="${recode_target%%[[:space:]]*}"

  # If the target matches the current quality (no-op), pass through unchanged.
  # Normalise 32f → 24 the same way the caller's no-op check does.
  if [[ -n "$current_quality" ]]; then
    local current_norm="${current_quality//\/32f/\/24}"
    if [[ "$recode_target" == "$current_norm" ]]; then
      printf '%s\n' "$spec_rec"
      return 0
    fi
  fi

  # Guard: grade C or F → replacement required; recode won't fix mastering.
  case "$mastering_grade" in
    C | F)
      printf '%s\n' "Mastering issue — recode won't help"
      return 0
      ;;
  esac

  # Guard: mastering recommendation explicitly says Trash or Replace.
  case "$mastering_rec" in
    "Trash" | *"Replace"*)
      printf '%s\n' "Mastering issue — recode won't help"
      return 0
      ;;
  esac

  printf '%s\n' "$spec_rec"
}
