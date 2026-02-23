#!/opt/homebrew/bin/bash
# quality_gate.sh — shared mastering-gate logic used by qty_seek, spectre, and
# qty_compare.  Source this file; do not execute it directly.

apply_mastering_guard() {
  # Usage: apply_mastering_guard <spec_rec> <mastering_grade> <mastering_rec>
  #
  # MX3 — Mastering guard.
  # If the album requires replacement (grade C/F, or mastering rec is Trash/Replace)
  # AND the spectral recommendation is only a profile downgrade ("Store as …"),
  # the recode changes container size but cannot fix mastering defects.
  # Returns the (possibly overridden) recommendation on stdout.
  local spec_rec="$1"
  local mastering_grade="$2"
  local mastering_rec="$3"

  # Pass through unchanged unless spec_rec is a profile-downgrade recommendation.
  if [[ -z "$spec_rec" || "$spec_rec" != *"Store as "* ]]; then
    printf '%s\n' "$spec_rec"
    return 0
  fi

  # Grade C or F → replacement required; recode won't fix mastering.
  case "$mastering_grade" in
    C | F)
      printf '%s\n' "Mastering issue — recode won't help"
      return 0
      ;;
  esac

  # Mastering recommendation explicitly says Trash or Replace.
  case "$mastering_rec" in
    "Trash" | *"Replace"*)
      printf '%s\n' "Mastering issue — recode won't help"
      return 0
      ;;
  esac

  printf '%s\n' "$spec_rec"
}
