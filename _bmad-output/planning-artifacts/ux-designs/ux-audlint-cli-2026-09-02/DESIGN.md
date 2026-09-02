---
name: Audlint Player Content
description: Visual delta for a hierarchical terminal browser within the existing Audlint Maintenance system.
status: final
sources:
  - ../../../specs/spec-player-content-creator/SPEC.md
  - ../../../specs/spec-player-content-creator/player-content-contract.md
  - ../../../specs/spec-player-rsync-feedback/SPEC.md
  - ../../../specs/spec-player-track-only-mirror/SPEC.md
  - ../../../../docs/decisions/0007-ADR-player-track-only-destinations.md
  - ../../../../docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md
  - ../../../../docs/decisions/0009-ADR-terminal-accessibility-boundary.md
updated: 2026-09-02
typography:
  terminal-ui:
    note: 'Inherit the terminal emulator monospace face and existing Audlint Maintenance hierarchy.'
components:
  selector-chrome:
    visual-role: 'Existing Maintenance title, status, result, and action roles; persistent context and authoritative outcomes use separate bounded rows.'
  artist-row:
    anatomy: '> ▾ [-] Artist name (checked/total · checked payload)'
  album-row:
    anatomy: '>   [x] YEAR - Album [unavailable]'
  search-editor:
    anatomy: 'Search: query · Enter apply · Esc cancel'
  help-surface:
    visual-role: 'Existing Maintenance title, label, value, action, and bounded page-position roles.'
  sync-feedback-surface:
    visual-role: 'Existing selector-owned bounded progress canvas.'
---

# Audlint Player Content — Design Spine

Contract scope: ADR-0009 governs baseline terminal accessibility. ADR-0007, ADR-0008, and the track-only mirror specification replace only the older companion's payload paragraph; all other inherited requirements remain. These spines govern the redesigned tree, search, view, Help, and visual treatment.

## Brand & Style

Player Content remains an Audlint Maintenance instrument: keyboard-first, information-dense, and explicit about consequences. Rename the menu entry and screen from **Player Content Creator** to **Player Content**; the screen curates and synchronizes a persisted set rather than creating content. This is a structural upgrade, not a rebrand. It inherits the fixed terminal canvas, incremental row repaint, terminal typography, color roles, and `NO_COLOR` behavior.

## Colors

Add no literal colors. Reuse existing `C_TITLE`, `C_LABEL`, `C_VALUE`, `C_ACTION`, `C_RESULT`, and `C_SELECT` roles. Meaning must survive without color: `>` marks Current; `▸`/`▾` mark collapsed/expanded; `[ ]`/`[-]`/`[x]` mark none/some/all Checked; `[unavailable]`, `[size unknown]`, and words state availability and sizing.

When Unicode glyph rendering or display-width measurement is unreliable, use fixed-column ASCII fallbacks: `+`/`-` for collapsed/expanded, straight quotes, and hard clipping or `...` for truncation. The Current and disclosure columns remain distinct. Never let a fallback change row width or meaning.

## Typography

Use `{typography.terminal-ui}`. **Current** means keyboard focus; **Checked** means persisted player membership; **View** means the non-mutating All, Checked, or Unchecked projection. Avoid using “selected” for both focus and membership.

## Layout & Spacing

Preserve the virtual-window header, bounded title/status/result rows, one selector body, and one non-wrapping footer. The body is a tree: artist rows at the base indent, album rows one level deeper. Search, view, expansion, Help, and resize change the visible projection without changing stored sort order.

Measure and truncate labels, query text, caret position, status, and feedback by terminal display cells, never bytes or code points. At supported narrow widths, title/status rows retain view, query, zero-checked state, and a safe destination label; the footer uses these exact tiers:

- 20–39 cells: `? help | w sync | q`
- 40–59 cells: `Space toggle | v view | ? help | w sync | q`
- 60+ cells: add navigation and visible-position hints as space permits

The search editor temporarily owns one bounded input row with `Search:` and apply/cancel hints; overflow is clipped with a visible continuation cue while the caret remains within the row. Help owns the body and keeps a page/position marker plus its local navigation legend visible. Never clear, wrap, or scroll the preserved Maintenance header.

## Components

- **selector-chrome** — Body title and status name the active view/query, visible position, SD-path presence, global checked count/size, and compact zero-checked state. A separate result row holds the latest authoritative outcome, so an error or success never erases destructive-scope context.
- **artist-row** — Base indent with disclosure marker, tri-state checkbox, name, and bounded checked/total plus checked-payload field. Payload renders a human size when complete, `sizing…` while pending, and `size unknown` when any checked child cannot be measured.
- **album-row** — One-level indent with checkbox, year, name, and written-out availability/sizing state. An unavailable unchecked row remains visibly blocked; a checked unavailable row remains removable.
- **search-editor** — One bounded row labeled `Search:` with distinct query text, overflow cue, visible caret, and `Enter apply · Esc cancel`. It cannot be mistaken for list-command mode.
- **help-surface** — Read-only, selector-owned pages using existing title, label, value, and action hierarchy. Page/position and Help-local navigation remain visible at every supported size.
- **sync-feedback-surface** — Visually unchanged bounded progress canvas. Show sanitized aggregate progress only; progress-capability fallback retains a bounded busy state and authoritative outcome.

`EXPERIENCE.md` owns focus, persistence, input modes, Help dismissal, synchronization, and result lifetimes.

## Do's and Don'ts

| Do | Don't |
|---|---|
| Use symbols plus words/counts for state, with ASCII fallbacks | Depend on color, indentation, or optional glyphs alone |
| Show complete artist scope and measurement progress before a bulk change | Accept queued mutations while measuring |
| Keep view/query and zero-checked destination scope visibly active | Let a reduced view look like the complete library |
| Preserve one visible Current marker and a stable logical focus anchor | Focus hidden children or two rows at once |
| Say `0 checked — w deletes all content from player: <safe label>` | Describe root-wide deletion only as “empty the managed player” |
| Keep authoritative outcomes beside persistent safety context | Let a warning overwrite a failure or success |
| Keep `w` direct after complete preflight | Add an unguarded global clear or a second sync confirmation |
