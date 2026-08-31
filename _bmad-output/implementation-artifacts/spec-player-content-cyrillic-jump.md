---
title: 'Player Content Cyrillic Escape Jump'
type: 'bugfix'
created: '2026-08-31'
status: 'done'
review_loop_iteration: 0
baseline_commit: '290125a8ae4c260d5eb1a54643111cb7309cb5db'
context:
  - '{project-root}/docs/ai/bmad-lite.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Player Content Creator displays Cyrillic, including Ukrainian, artist headings, but its raw-terminal Escape-letter parser recognizes ASCII only. `Esc` followed by a Cyrillic letter therefore cannot reach the existing group jump behavior.

**Approach:** Accept one complete alphabetic character after Escape under a UTF-8 locale, then retain the existing normalized first-character comparison and group-cycle logic. Add one focused PTY regression that proves Cyrillic first match, repeat, wrap, and unmatched input while the present ASCII case remains a guard.

## Boundaries & Constraints

**Always:** Keep one terminal character per jump token; preserve CSI/SS3 arrows, bare Escape, delayed human-paced Escape input, unmatched-key no-op behavior, raw-TTY cursor restoration, bounded redraw, fixed footer wording/layout, Bash 5, and macOS/Linux portability. Use temporary PTY/library/database fixtures only. Run the new named test first, then the existing focused ASCII/arrow regressions as appropriate, then `python3 -m unittest test.test_player_content_creator`.

**Ask First:** Stop for direction before changing any artist grouping or sort behavior, shared terminal policy, terminal layout/footer text, synchronization logic, or test scope beyond Player Content Creator.

**Never:** Do not transliterate, search, map keyboard layouts, add symbol/digit jumps, switch locales, access real operator libraries/databases/player media, run `make check`, or modify unrelated artifacts.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Cyrillic first match | UTF-8 PTY; `Esc` then a Cyrillic initial with two matching groups | Cursor selects the first matching artist group | N/A |
| Repeat and wrap | Repeat the same `Esc`+initial twice | Cursor advances to the next matching group, then wraps to the first | N/A |
| Unmatched Cyrillic | `Esc` then a Cyrillic initial absent from headings | Current cursor and screen state are unchanged | No-op |
| Existing navigation | ASCII jump, arrows, bare Escape, and delayed Escape input | Existing behavior, cursor visibility, and footer/layout guards remain unchanged | Existing parser behavior applies |

</frozen-after-approval>

## Code Map

- `bin/audlint-maintain.sh:159-190` — `player_content_read_selector_key` owns raw-TTY Escape parsing. Its two ASCII-only predicates occur after the initial 50ms probe and after the delayed bare-Escape probe; change only the recognition boundary.
- `bin/audlint-maintain.sh:239-255` — `player_content_selector_jump` already lowercases normalized display labels, compares their first character, and cycles/wraps matching groups; preserve it.
- `bin/audlint-maintain.sh:440-563` — selector canvas, fixed footer, cursor/redraw rules, and input dispatch. These provide preservation boundaries, not change targets.
- `test/test_player_content_creator.py:29-118` — temporary fixture and PTY harness, including delayed key injection; no operator resource is involved.
- `test/test_player_content_creator.py:533-558` — existing named ASCII delayed Escape-jump/cycle/wrap regression to retain and run as a guard.
- `test/test_player_content_creator.py:393-415, 474-506, 508-531` — existing arrow, boundary, visible-marker, bounded-render, and fixed-layout coverage to retain through the focused module run.
- `lib/sh/bootstrap.sh:130-156, 236-290` — existing shared fd/TTY utilities; selector-specific raw input means no shared-helper change is needed for this bounded fix.

## Tasks & Acceptance

**Execution:**
- [x] `test/test_player_content_creator.py` — add one named UTF-8 PTY test with at least two Cyrillic artist groups sharing an initial and one different group. Drive delayed `Esc`+letter input and assert first match, repeated cycle, wrap, and unmatched no-op without weakening the current ASCII test.
- [x] `bin/audlint-maintain.sh` — make both Escape-letter recognition paths accept one complete UTF-8 alphabetic character, retaining all read counts, delays, CSI/SS3 handling, and dispatch values. Reuse the existing jump function for normalization and cycling.
- [x] `test/test_player_content_creator.py` — run the named Cyrillic test first, then retain focused ASCII/arrow behavior through the requested module command; correct only failures caused by this change.

**Acceptance Criteria:**
- Given a UTF-8 PTY fixture with two Ukrainian/Cyrillic headings sharing an initial, when the operator sends delayed `Esc` plus that letter, then the first press selects the first matching group, the second selects the next group, and the third wraps to the first.
- Given the same fixture, when the operator sends `Esc` plus an unmatched Cyrillic letter, then the selected row and rendered selector state do not change.
- Given existing ASCII jump, arrow, bare Escape, delayed-input, cursor, and layout coverage, when the focused module runs, then all tests remain green without a footer or redraw regression.

## Spec Change Log

## Design Notes

The parser must retain character-level reads: under the supported UTF-8 locale, Bash character operations let the existing single-character jump logic receive the complete Cyrillic letter. The minimal repair is confined to the two recognition checks, so the current arrow and delayed-Escape state machine stays intact.

## Verification

**Commands:**
- `python3 -m unittest test.test_player_content_creator.PlayerContentCreatorTests.test_selector_escape_cyrillic_letter_jumps_groups_cycles_wraps_and_ignores_unmatched` — expected: the new UTF-8 PTY case passes before the implementation is accepted.
- `python3 -m unittest test.test_player_content_creator.PlayerContentCreatorTests.test_selector_escape_letter_jumps_groups_after_human_delays_and_wraps` — expected: existing ASCII delayed-input/cycle/wrap behavior passes.
- `python3 -m unittest test.test_player_content_creator.PlayerContentCreatorTests.test_large_selector_is_ordered_bounded_and_reaches_both_boundaries test.test_player_content_creator.PlayerContentCreatorTests.test_small_inventory_final_down_is_a_noop` — expected: arrow/boundary behavior passes.
- `python3 -m unittest test.test_player_content_creator` — expected: focused Player Content Creator module passes; do not run `make check`.

## Suggested Review Order

**Escape input recognition**

- Extends both existing Escape probes without changing their timing or arrow handling.
  [`audlint-maintain.sh:174`](../../bin/audlint-maintain.sh#L174)

**UTF-8 PTY regression**

- Pins UTF-8 and proves immediate/delayed Cyrillic jump, wrap, and unmatched no-op.
  [`test_player_content_creator.py:560`](../../test/test_player_content_creator.py#L560)
