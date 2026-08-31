---
title: 'Restore Player Content Creator Selected Size'
type: 'bugfix'
created: '2026-08-31'
status: 'done'
baseline_commit: '7e8656c32364dd7a5367833a36aa45534915c417'
review_loop_iteration: 0
context:
  - 'docs/ai/bmad-lite.md'
  - '_bmad-output/specs/spec-player-content-selected-size/SPEC.md'
  - '_bmad-output/specs/spec-player-content-selected-size/brownfield.md'
  - '_bmad-output/specs/spec-player-content-creator/player-content-contract.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The selector waits to size every available album and labels the result as a total, even though the useful value is the transferable payload size of the checked selection.

**Approach:** Initialize sizing only for available checked rows, make the title explicitly report selected payload size, and size an available unchecked row immediately before its successful selection is persisted.

## Boundaries & Constraints

**Always:** Use `player_payload_size_bytes_for_dir` and `player_human_size_label`; preserve natural-key persistence, selected count, unavailable-row treatment, SD redraw, responsive virtual-window rendering, and exact byte add/subtract behavior. Progress, if shown, is only over checked available albums.

**Ask First:** None; this change must not access real music libraries, databases, player media, or other operator resources.

**Never:** Change selection identity, payload inclusion, synchronization behavior, SQLite schema, or selector layout beyond explicit selected-size wording. Do not precompute all library rows, store byte totals, run `make check`, or use real resources.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Checked subset | 39 checked available rows in a larger temporary inventory | Progress denominator is 39; final title says `Size` and equals the shared payload sum | Unchecked rows are not sized at entry |
| Empty selection | No checked rows | Title reports `Selected: 0 | Size: 0b` without sizing progress | N/A |
| Toggle available row | Unchecked available row is selected then deselected | Selection, checkbox, and title change in one redraw by exactly that row’s payload bytes | Do not persist selection when sizing fails |
| Checked unavailable row | Persisted checked source cannot be read | Row stays checked and unavailable; unknown bytes are excluded | Existing sync block remains intact |

</frozen-after-approval>

## Code Map

- `bin/audlint-maintain.sh:140-148` -- builds the virtual-window right title; replace `Total` with explicit `Size` and retain mounted-directory refresh.
- `bin/audlint-maintain.sh:301-325` -- session-only payload size cache and incremental batch sizing; restrict initial pending work to checked available rows while leaving on-demand sizing available for a toggle.
- `bin/audlint-maintain.sh:401-557` -- selector loading, sort, redraw, and Space handling; preserve selected count, unavailable behavior, and one successful persistence statement per toggle.
- `lib/sh/player.sh:60-103` -- canonical payload filtering, byte calculation, and human-size conversion; reuse unchanged.
- `test/test_player_content_creator.py` -- temporary-file PTY coverage; update legacy title assertions and add selected-subset, zero, and exact toggle-delta proofs.

## Tasks & Acceptance

**Execution:**
- [x] `bin/audlint-maintain.sh` -- initialize and batch-size only checked, available albums; label the completed selected payload total as `Size`; size an unchecked available album on demand before committing its selection.
- [x] `test/test_player_content_creator.py` -- add focused temporary-fixture tests for checked-subset progress, zero selection, and exact select/deselect payload deltas; update affected title expectations.

**Acceptance Criteria:**
- Given 39 selected albums among many available rows, when the selector opens, then any sizing progress is measured against 39 and the settled `Size` equals their canonical payload bytes.
- Given no selected albums, when the selector opens, then it reports `Selected: 0 | Size: 0b` without a library-wide size pass.
- Given an available unchecked album, when Space selects and then deselects it, then the checkbox, count, and `Size` change on each redraw by exactly its canonical payload bytes.
- Given existing unavailable, redraw, persistence, SD-status, and shared-payload tests, when the change runs, then their behavior remains unchanged except for the `Total` to `Size` wording.

## Spec Change Log

- 2026-08-31: Implemented selected-only sizing and focused PTY coverage.

## Verification

**Commands:**
- `python3 -m unittest -k selected_size test.test_player_content_creator` -- expected: selected-size focused tests pass using only temporary fixtures.
- `python3 -m unittest test.test_player_content_creator` -- expected: all Player Content Creator tests pass; do not run `make check`.

## Suggested Review Order

**Selected-size state**

- Distinguishes initially checked work from deferred unchecked sizing.
  [`audlint-maintain.sh:301`](../../bin/audlint-maintain.sh#L301)

- Limits initial pending work and reports progress against the current selection.
  [`audlint-maintain.sh:423`](../../bin/audlint-maintain.sh#L423)

- Keeps selection, pending state, and byte totals synchronized on Space.
  [`audlint-maintain.sh:568`](../../bin/audlint-maintain.sh#L568)

**Status presentation**

- Makes transferable current-selection size explicit without changing SD status.
  [`audlint-maintain.sh:140`](../../bin/audlint-maintain.sh#L140)

**Regression proof**

- Exercises checked-subset progress, zero selection, exact deltas, and disappearing sources.
  [`test_player_content_creator.py:398`](../../test/test_player_content_creator.py#L398)
