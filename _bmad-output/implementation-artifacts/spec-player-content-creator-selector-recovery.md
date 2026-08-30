---
title: 'Recover Player Content Creator terminal navigation'
type: 'bugfix'
created: '2026-08-30'
status: 'done'
review_loop_iteration: 0
baseline_commit: '8a833b86ad8843e0941c8fec110290f5bda18524'
context:
  - '{project-root}/docs/ai/bmad-lite.md'
  - '{project-root}/AGENTS.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The previous selector change was rolled back because it still flickered, intermittently lost the visible selection, stopped showing new rows at viewport boundaries, and did not accept normal human-paced Escape-plus-letter input. The screen must remain stable and usable while album sizes are measured.

**Approach:** Render the selector as a fixed set of terminal rows inside its virtual window instead of streaming lines through its scroll region. Keep one raw-key session for the selector so Escape becomes a short-lived jump prefix rather than requiring the following letter within 50 milliseconds.

## Boundaries & Constraints

**Always:** Keep the current ordering, selection persistence, background size calculation, arrow, space, sync, and quit behavior. Redraw only individual fixed rows that changed; do not issue a terminal-wide erase, erase-to-display, full-screen home, or scrolling output from Player Content Creator. Count both artist headings and albums when fitting the viewport. Keep exactly one visible selection marker and restore the terminal caret when leaving the selector. Repeated `Esc`, then a letter within one second, advances through matching normalized artist groups and wraps.

**Ask First:** Configuring Warp/Ghostty to forward a physical Command key, changing any behavior outside Player Content Creator, or using a terminal library/dependency.

**Never:** Operate on a real library, live database, or mounted player destination; tests use temporary fixtures only. Do not reintroduce the reverted scroll-region renderer or rewrite unrelated sync/path-safety behavior.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Size progress | Readable library is still being sized | Selector contents remain visually stable; only its status row changes | No display-wide clear sequence is emitted |
| Visible selection | A selected album is moved or screen refreshes | Exactly one `>` marker remains on its current album row; terminal caret stays hidden in selector | Caret is restored on exit |
| Boundary scroll | Down crosses the last visible physical row; up crosses the first | The selected album changes and is rendered in the viewport; the footer remains fixed | Only global first/last rows are no-ops |
| Human-paced jump | Escape, wait 200–500 ms, then `z`; repeat | Advances Zappa, Zebra, then wraps to Zappa | Bare Escape and unmatched letters change nothing |

</frozen-after-approval>

## Code Map

- `bin/audlint-maintain.sh:143-176` -- short-lived raw reads and 50 ms Escape parsing caused the failed jump; replace only selector input handling.
- `bin/audlint-maintain.sh:278-323` -- current streamed selector uses `ESC[2J`, album-count viewport sizing, and automatic full redraws; replace with a fixed physical-row canvas.
- `bin/audlint-maintain.sh:124-132` -- reuse the existing status formatter for the fixed status row.
- `lib/sh/bootstrap.sh:130-267` -- shared TTY FD/raw-mode primitives support one selector-owned input session; do not duplicate platform handling.
- `lib/sh/virtwin.sh:93-101` -- virtual window scroll bounds define the fixed canvas; keep this file read-only.
- `test/test_player_content_creator.py:64-105` -- isolated PTY harness needs window-size and delayed-byte support.
- `test/test_ui_regression.py:200-270` -- existing terminal-screen parser is the reuse point for asserting final physical layout.

## Tasks & Acceptance

**Execution:**

- [x] `bin/audlint-maintain.sh` -- replace selector streaming with a fixed-row renderer within the virtual-window body. Fit artist headings and albums by actual rows, clear/write individual rows only, update size progress without redrawing the list, and hide/restore the terminal caret.
- [x] `bin/audlint-maintain.sh` -- keep one raw TTY session for selector input, decode arrows as CSI sequences, and treat a bare Escape as a one-second jump prefix for the next ASCII letter. Use normalized artist names to cycle distinct matching artist groups.
- [x] `test/test_player_content_creator.py` -- extend the PTY fixture and add compact regression coverage for stable size progress, one visible selection, physical-row boundary scrolling, and delayed repeated Escape-letter jumps. Reuse existing destructive rsync/path-safety tests unchanged.

**Acceptance Criteria:**

- Given a large readable library is sizing, when progress advances, then the selector list does not flicker or emit `ESC[J`/`ESC[2J` and remains responsive.
- Given any selector refresh, when an album is current, then exactly one highlighted `>` row is visible and the terminal caret is hidden until selector exit.
- Given arrows cross either viewport boundary, when another non-boundary album exists, then the selection and visible album rows advance or retreat correctly.
- Given Escape and its letter arrive up to one second apart, when the letter identifies artists, then repeated jumps advance and wrap; bare Escape and no-match input are harmless.

## Spec Change Log

## Design Notes

The reverted approach changed only the erase sequence, but still streamed more physical rows than its album-count viewport allowed. Absolute, per-row writes avoid terminal scrolling and let tests inspect the final rendered screen. Command remains terminal configuration; the application accepts the portable bytes `Escape` followed by a letter.

## Verification

**Commands:**

- `python3 -m unittest test.test_player_content_creator` -- expected: focused selector and existing content-creator safety tests pass.
- `make check` -- expected: full local release gate passes once after implementation.

## Suggested Review Order

**Terminal lifecycle and input**

- Keep raw input and caret state recoverable across normal and signal exits.
  [`audlint-maintain.sh:198`](../../bin/audlint-maintain.sh#L198)

- Decode arrows and human-paced Escape-letter jumps within one selector session.
  [`audlint-maintain.sh:143`](../../bin/audlint-maintain.sh#L143)

**Fixed selector canvas**

- Render only absolute, clipped rows so terminal scrolling cannot hide selection.
  [`audlint-maintain.sh:340`](../../bin/audlint-maintain.sh#L340)

- Preserve physical-row viewport boundaries while headings consume display rows.
  [`audlint-maintain.sh:398`](../../bin/audlint-maintain.sh#L398)

**Regression evidence**

- Exercise sizing, short windows, boundary movement, labels, and delayed jumps through a PTY.
  [`test_player_content_creator.py:344`](../../test/test_player_content_creator.py#L344)
