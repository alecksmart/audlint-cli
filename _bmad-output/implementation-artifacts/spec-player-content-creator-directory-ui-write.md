---
title: 'Correct Player Content Creator directory names and actions'
type: 'bugfix'
created: '2026-08-30'
status: 'done'
baseline_commit: '7d3168fb50e789831de1d8e1941d75d8529b075a'
review_loop_iteration: 0
context:
  - '{project-root}/docs/ai/bmad-lite.md'
  - '{project-root}/AGENTS.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The stable selector now places a plain status line in its content area and lost the creator title and colored controls. It also shows database artist names such as `Mark Knopfler` instead of the source-library artist folder `Knopfler, Mark`; its order and Escape-letter jumps follow the wrong name. The user also reports that writing does not work.

**Approach:** Restore the virtual-window title/status presentation with fixed, cursor-safe writes, color the creator controls, and make the source-path artist directory the selector’s display, sort, and jump key. Verify both selection persistence and the guarded `w` root mirror as the two possible writing actions.

## Boundaries & Constraints

**Always:** Preserve the fixed-row renderer, no-flicker guarantees, terminal cleanup, physical-row navigation, payload filters, and destructive rsync/path safety. For every source path valid under the library root, derive the artist label from its immediate parent directory. `Knopfler, Mark` must be displayed, ordered under K, and reached by repeated `Esc` then `K`; database identity keys remain unchanged for persistence. Put the green status at the virtual-window title’s right side, the colored creator title in its reserved body row, and colored controls in the fixed footer.

**Ask First:** Changing folder naming, rebuilding/altering the library database, using metadata instead of source folders, or operating the real library/player destination.

**Never:** Reintroduce streamed output, terminal-wide clears, or cursor save/restore in the sizing loop. Do not change sync selection semantics, transfer payload, or path-safety rules.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Directory artist | DB artist `Mark Knopfler`; source path under `Knopfler, Mark` | Heading shows `Knopfler, Mark`; it sorts with K folders | Invalid/outside source keeps its existing unavailable-row treatment |
| Directory jump | Several source artist folders, including `Knopfler, Mark` | `Esc`, then `k` moves to that folder and repeats through K folders | Bare/unmatched input remains harmless |
| Fixed presentation | Creator opens or size progress changes | Colored title/body controls stay fixed; green status updates only in title right side | No body status row or full display erase |
| Write actions | Space toggles, then `w` confirms mirror | Selection is committed; sync reaches confirmation and executes only after `y` | Existing unsafe/missing-destination guards still prevent rsync |

</frozen-after-approval>

## Code Map

- `lib/sh/player.sh:21-36` -- validated source-relative path helper is the correct shared foundation for extracting the artist directory.
- `bin/audlint-maintain.sh:76-91` -- old right-title helper uses cursor save/restore; replace its effect with fixed title-row writing.
- `bin/audlint-maintain.sh:181-237` -- selector label, jump, and terminal helpers; directory label must become the sort/jump key.
- `bin/audlint-maintain.sh:340-475` -- loads selector rows, owns fixed title/body/footer rendering, Space persistence, and `w` sync entry.
- `bin/audlint-maintain.sh:284-338` -- guarded root-mirror transaction remains the write behavior to preserve and prove.
- `bin/audlint-maintain.sh:458-475` -- footer leaves the cursor outside virtwin's scroll region; move the confirmed `w` flow back into that region before output.
- `test/test_player_content_creator.py:52-105` -- temporary library/PTY harness for separate DB metadata and artist-directory fixtures.
- `test/test_player_content_creator.py:146-234` -- existing persistence, destructive rsync, and path-safety coverage must be reused, not duplicated.

## Tasks & Acceptance

**Execution:**

- [x] `lib/sh/player.sh` -- add one reusable helper that returns a validated source path’s immediate artist-directory label under `LIBRARY_ROOT`.
- [x] `bin/audlint-maintain.sh` -- load and order selector rows by directory-derived artist data, use it for headings and Escape cycling, while retaining `artist_lc`/album/year for database selection writes.
- [x] `bin/audlint-maintain.sh` -- restore a clipped green right-title status via direct row writes; render the creator title and colorized controls in their reserved fixed rows, and start `w` output inside virtwin's scroll region without invalidating the canvas.
- [x] `test/test_player_content_creator.py` -- add focused directory-name/order/jump and colored-layout assertions, plus one combined Space-persistence/`w`-confirmation regression. Retain current destructive safety tests.

**Acceptance Criteria:**

- Given `source_path` is `.../Knopfler, Mark/1988 - ...` and DB artist differs, when the selector opens, then it displays and sorts `Knopfler, Mark` under K.
- Given the source directory artist is `Knopfler, Mark`, when `Esc` then `k` is sent, then it selects that artist group and repeated input cycles K groups.
- Given the creator is active, when it renders or updates sizing, then the body has a colored creator title and controls while only the clipped green right-title status changes.
- Given Space toggles an available album and `w` is confirmed, when the write flow completes, then the database selection persists and exactly one safe root mirror is invoked; unsafe destinations still invoke none.

## Spec Change Log

## Design Notes

The source directory is the user’s canonical artist presentation. The database artist fields still identify the selected record; they must not rewrite or rename library folders. The title hint is rendered by absolute positioning so it cannot disturb the fixed selector canvas.

## Verification

**Commands:**

- `python3 -m unittest test.test_player_content_creator` -- expected: directory-driven selector, writing, and existing safety tests pass.
- `make check` -- expected: full local release gate passes once near completion.

## Suggested Review Order

**Selector presentation and interaction**

- Restores fixed status, title, controls, and visible sync output without cursor save/restore.
  [`audlint-maintain.sh:76`](../../bin/audlint-maintain.sh#L76)

- Derives safe directory labels, preserves database identity, and maintains physical-row navigation.
  [`audlint-maintain.sh:401`](../../bin/audlint-maintain.sh#L401)

- Uses a stable in-memory sort for responsive directory-based navigation at library scale.
  [`audlint-maintain.sh:257`](../../bin/audlint-maintain.sh#L257)

**Source-path safety**

- Extracts only a control-safe immediate artist directory from a validated library path.
  [`player.sh:41`](../../lib/sh/player.sh#L41)

**Regression proof**

- Exercises directory labels, identity persistence, resize placement, and prompt-gated mirroring in PTYs.
  [`test_player_content_creator.py:132`](../../test/test_player_content_creator.py#L132)
