#!/usr/bin/env python3
"""
dr_grade.py — DR14 dynamic-range integer → mastering grade (S/A/B/C/F).

The DR14 value produced by dr14meter reflects the crest factor (ratio of
peak to RMS energy) measured over each track.  Higher DR means more dynamic
contrast between quiet and loud passages.

Three genre profiles reflect that loudness is a stylistic convention, not
an absolute defect:

  audiophile  — Classical, Jazz, Blues, Acoustic, Folk, Ambient, New-Age.
                Expects wide dynamic range; masters that would be normal in
                rock are flagged here.

  high_energy — Rock, Metal, Punk, EDM, Hip-Hop, Electronic, Grunge, Trap.
                Intentional loudness / brickwalling is a genre norm; the F
                threshold is set low so only genuinely inaudible masters fail.

  standard    — Everything else, or unknown genre.  Moderate thresholds that
                work well across pop, R&B, country, world music, etc.

Grade meanings:
  S — Excellent dynamics.  Preserves original recording's full dynamic intent.
  A — Good dynamics.  Minor compression; transparent in most listening contexts.
  B — Moderate compression.  Listenable but noticeably loud on some material.
  C — Heavy compression.  Fatiguing on extended listening; borderline for keep.
  F — Severe / defective mastering.  Brickwalled or near-silence floor; trash.

DR14 thresholds (inclusive lower bound):

  Genre        S    A    B    C    F
  audiophile   ≥14  ≥12  ≥9   ≥6   <6
  high_energy  ≥11  ≥9   ≥7   ≥4   <4
  standard     ≥12  ≥9   ≥7   ≥5   <5

Usage (CLI):
    dr_grade.py <dr_value> [genre_profile]
    → prints one of: S | A | B | C | F

Usage (module):
    from dr_grade import grade_from_dr
    grade = grade_from_dr(9, "audiophile")   # → "B"
    grade = grade_from_dr(9, "high_energy")  # → "A"
"""

from __future__ import annotations

import sys

# ---------------------------------------------------------------------------
# Thresholds: (min_dr_inclusive, grade) in descending order of DR.
# ---------------------------------------------------------------------------

_THRESHOLDS: dict[str, list[tuple[int, str]]] = {
    "audiophile": [
        (14, "S"),
        (12, "A"),
        (9,  "B"),
        (6,  "C"),
    ],
    "high_energy": [
        (11, "S"),
        (9,  "A"),
        (7,  "B"),
        (4,  "C"),
    ],
    "standard": [
        (12, "S"),
        (9,  "A"),
        (7,  "B"),
        (5,  "C"),
    ],
}

_VALID_PROFILES = frozenset(_THRESHOLDS)


def grade_from_dr(dr: int | float, genre_profile: str = "standard") -> str:
    """Return a letter grade (S/A/B/C/F) for a DR14 value and genre profile.

    *dr*           — DR14 integer (or float, truncated to int for comparison).
    *genre_profile* — one of 'audiophile', 'high_energy', 'standard'.
                     Unknown values silently fall back to 'standard'.

    Returns one of: 'S', 'A', 'B', 'C', 'F'.
    """
    profile = genre_profile if genre_profile in _VALID_PROFILES else "standard"
    thresholds = _THRESHOLDS[profile]
    dr_int = int(dr)
    for min_dr, letter in thresholds:
        if dr_int >= min_dr:
            return letter
    return "F"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in {"-h", "--help"}:
        print(__doc__)
        sys.exit(0 if len(sys.argv) >= 2 else 2)

    try:
        dr_val = float(sys.argv[1])
    except ValueError:
        print(f"Error: DR value must be a number, got: {sys.argv[1]!r}", file=sys.stderr)
        sys.exit(2)

    profile = sys.argv[2] if len(sys.argv) >= 3 else "standard"
    print(grade_from_dr(dr_val, profile))


if __name__ == "__main__":
    main()
