---
id: SPEC-player-content-selected-size
companions:
  - brownfield.md
  - ../spec-player-content-creator/player-content-contract.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete contract for this fix.

# Player Content Creator Current Selection Size

## Why

The selector currently emphasizes sizing progress across the complete library, such as `555/1649 albums`, instead of clearly reporting the payload size of the 39 checked albums. Current selection size was a requirement and must remain understandable and useful while choosing content for a finite player.

## Capabilities

- **CAP-1**
  - **intent:** The operator can see the exact transferable size of the current checked selection on entry and after every successful toggle.
  - **success:** The title labels selection size explicitly, any initial progress counts checked albums only, zero selection shows `0b`, and selecting or deselecting an album changes the displayed bytes by exactly its shared transfer payload size in the same redraw.

## Constraints

- Initial sizing is driven by checked albums only. Size an unchecked album on demand when it is selected; do not require a complete-library sizing pass before the selected total settles.
- Use the shared player payload inclusion and human-size contracts so displayed selection size and synchronization size agree.
- Preserve selection count, SD presence, persisted checks, unavailable-row handling, responsive incremental rendering, title clipping, and exact add/subtract behavior.
- Do not alter selection identity, payload filters, or synchronization semantics.
- Follow the focused verification stages in `brownfield.md`; do not run the full release gate in this task.

## Non-goals

- Showing total library size, player capacity, player free space, or filesystem allocation.
- Precomputing and storing album sizes in SQLite.
- Redesigning the selector title beyond making current selection size explicit.

## Success signal

With 39 checked rows in a much larger temporary inventory, the selector reports progress against 39 and then the exact selected payload size; one unselected album can be toggled on and off with an immediate exact size change.

## Assumptions

- “Current selection size” means transferable payload bytes for checked albums, not disk allocation or total library bytes.
