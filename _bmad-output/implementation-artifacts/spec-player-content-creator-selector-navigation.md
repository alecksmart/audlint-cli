---
title: 'Stabilize Player Content Creator redraws and add artist jumps'
type: 'bugfix'
created: '2026-08-30'
status: 'done'
review_loop_iteration: 0
baseline_commit: '9e1141d7f08d84fc88f338909852dc3ae41399be'
context:
  - '{project-root}/docs/ai/bmad-lite.md'
  - '{project-root}/AGENTS.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Player Content Creator clears and redraws the entire terminal for every update. Warp and Ghostty visibly flicker, especially while the selector incrementally measures album sizes. Reaching late-alphabet artists with arrow keys is also impractical in a large library.

**Approach:** Render the selector in place without the terminal-wide erase sequence, and add a repeatable letter jump that selects the next artist whose normalized name starts with that letter. The command uses the terminal sequence that Command/Option key mappings can deliver: Escape followed by a letter.

## Boundaries & Constraints

**Always:** Preserve the existing selector ordering, selection persistence, incremental sizing, virtual-window header, arrow and space controls, and Bash 5/macOS/Linux behavior. A letter jump begins at the next artist group, skips later albums by the current artist, wraps around, and can be repeated to cycle matching artists. The UI must clearly show the shortcut and avoid a full-display clear while the selector is active.

**Ask First:** Changing terminal-emulator keybindings, accepting a non-Escape encoding for a physical Command key, or altering behavior outside Player Content Creator.

**Never:** Read or modify a real music library, live database, or mounted player destination; use only temporary test fixtures. Do not replace the bounded selector with a full inventory or add an external terminal dependency.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Stable sizing | Selector is calculating sizes | Redraw stays within the active view and does not emit a full-display clear; sizing stays interactive | Existing unavailable-size handling remains intact |
| First jump | Escape then `z`; several Z artists | Cursor moves to the first matching artist after the current artist | If none match, cursor and selection stay unchanged |
| Repeat jump | Escape then the same letter again | Cursor advances to the next distinct matching artist, wrapping after the last | One matching artist remains selected after wrap |
| Existing keys | Arrow, space, `w`, `q`, or escape alone | Existing action still works; escape alone is harmless | Incomplete escape sequences do not invoke a destructive action |

</frozen-after-approval>

## Code Map

- `bin/audlint-maintain.sh:76` -- `virtwin_set_right_hint` updates the frozen title row; selector redraw changes must leave this contract intact.
- `bin/audlint-maintain.sh:143-176` -- Player-specific blocking and polling key decoders already normalize arrow sequences and are the correct place to recognize Escape-plus-letter input.
- `bin/audlint-maintain.sh:278-323` -- `player_content_creator` owns ordered metadata arrays, viewport offsets, sizing batches, rendering, and control dispatch. Its `\033[2J` redraw causes the flicker.
- `lib/sh/bootstrap.sh:130-267` -- shared TTY FD and raw-key primitives; reuse them rather than introducing terminal-specific input code.
- `lib/sh/virtwin.sh:15-155` -- outer virtual window establishes the preserved header and scroll region; it is read-only for this focused change.
- `test/test_player_content_creator.py:34-75` -- PTY harness delivers arrow/Escape byte sequences through isolated temporary fixtures.
- `test/test_player_content_creator.py:237-264` -- large selector test is the natural place for bounded-rendering and alphabetical jump coverage.

## Tasks & Acceptance

**Execution:**

- [x] `bin/audlint-maintain.sh` -- replace the selector-wide clear-and-home redraw with an in-place, bounded clear suitable for the existing virtual window; throttle no user input and keep sizing progress visible without terminal-wide flicker.
- [x] `bin/audlint-maintain.sh` -- decode Escape-plus-ASCII-letter as a selector jump while preserving arrows and plain controls; use the existing sorted artist metadata to advance among distinct artist groups by initial letter and update the viewport.
- [x] `bin/audlint-maintain.sh` -- disclose the shortcut in the selector footer as `Esc+letter` so it works with terminal Option/Command mappings that emit Escape-prefixed input.
- [x] `test/test_player_content_creator.py` -- add one focused PTY test that proves repeated late-letter jumps advance through distinct artists, wrap, preserve bounded output, and confirms the selector source no longer has its full-display clear. Keep current selection/sync safety tests unchanged.

**Acceptance Criteria:**

- Given a large selector that is still sizing albums, when it refreshes, then it remains responsive and does not issue `ESC[2J` from Player Content Creator.
- Given artists ordered through Z, when the user sends Escape followed by `z`, then the selector moves to the next Z artist group and shows it in the viewport.
- Given the cursor is on a Z artist, when the user sends the same jump again, then it advances to the next distinct Z artist and wraps after the final match.
- Given no artist starts with a requested letter or an Escape sequence is incomplete, when that input arrives, then no selection is changed and no destructive command runs.

## Spec Change Log

## Design Notes

Terminal applications usually intercept the physical Command key and do not report it to TUI programs. `Esc` followed by a letter is the portable byte sequence commonly emitted by Option/Meta or a configurable Command mapping, so it makes this interaction available in both Warp and Ghostty without coupling the CLI to either emulator.

## Verification

**Commands:**

- `python3 -m unittest test.test_player_content_creator` -- expected: selector PTY tests pass, including repeatable alphabetical jumps and current rsync/path-safety coverage.
- `make check` -- expected: full local release gate passes once after the targeted tests.

## Suggested Review Order

**Selector responsiveness and controls**

- Decode safe, portable Escape-prefixed input without blocking on bare Escape.
  [`audlint-maintain.sh:152`](../../bin/audlint-maintain.sh#L152)

- Redraw only the selector view and batch size-progress updates.
  [`audlint-maintain.sh:282`](../../bin/audlint-maintain.sh#L282)

- Cycle distinct normalized artist groups by repeated letter input.
  [`audlint-maintain.sh:328`](../../bin/audlint-maintain.sh#L328)

**Focused regression coverage**

- Drive delayed Escape sequences through the real selector PTY.
  [`test_player_content_creator.py:249`](../../test/test_player_content_creator.py#L249)
