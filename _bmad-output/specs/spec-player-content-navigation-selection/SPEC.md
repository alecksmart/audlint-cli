---
id: SPEC-player-content-navigation-selection
companions:
  - ARCHITECTURE-SPINE.md
  - interaction-contract.md
  - verification.md
  - ../spec-player-track-only-mirror/SPEC.md
  - ../spec-player-rsync-feedback/SPEC.md
  - ../../../docs/decisions/0004-ADR-real-resource-verification-safety.md
  - ../../../docs/decisions/0007-ADR-player-track-only-destinations.md
  - ../../../docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md
  - ../../../docs/decisions/0009-ADR-terminal-accessibility-boundary.md
sources:
  - ../../planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md
  - ../../planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md
  - ../spec-player-content-creator/SPEC.md
  - ../spec-player-content-creator/player-content-contract.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if narrative rationale is needed.

# Player Content Navigation and Selection

## Why

The existing flat Player Content album list does not scale to large libraries and cannot search, filter, navigate artist hierarchy, or change a complete artist safely. The operator needs a searchable tree that improves curation without weakening durable path-based membership, exact destructive synchronization, retry safety, terminal correctness, or the accepted player payload contract.

## Capabilities

- **CAP-1**
  - **intent:** The operator can navigate Player Content as a focusable artist-and-album tree at large-library scale.
  - **success:** Deterministic artist hierarchy, disclosure, row and page navigation, bounds, `_VA` grouping, stable focus anchoring, and empty-state behavior satisfy `interaction-contract.md` with at least 1,600 temporary-fixture albums.

- **CAP-2**
  - **intent:** The operator can find albums with Unicode search and non-mutating All, Checked, and Unchecked views.
  - **success:** NFC-normalized, full-case-folded literal matching, the defined view/query projection order, search editing and cancellation, empty projections, and projection-independent membership pass the cases in `verification.md`.

- **CAP-3**
  - **intent:** The operator can change one album or one complete artist group while retaining path-keyed durable membership.
  - **success:** Album changes persist before repaint; artist check and uncheck each commit atomically over the complete group; any measurement, availability, or database failure leaves the group unchanged and preserves focus, projection, and a useful result.

- **CAP-4**
  - **intent:** The operator can understand selection scope, projection, destination presence, payload size, busy work, and authoritative outcomes without leaving the selector.
  - **success:** Bounded persistent chrome and a separate result row keep global checked scope, unknown size, view/query context, destination state, and zero-checked deletion meaning visible while busy and result states follow the priority and lifetime rules in `interaction-contract.md`.

- **CAP-5**
  - **intent:** The operator can open complete context-sensitive Help without losing browser state.
  - **success:** Paged Help remains usable at every supported size, consumes browser commands while open, clamps after resize, and dismisses with `?` or `q` while restoring query, focus, expansion, and results unchanged.

- **CAP-6**
  - **intent:** The operator can use Player Content safely across supported, narrow, resized, and temporarily too-small terminals.
  - **success:** Keyboard-only operation, non-color meaning, display-cell-safe rendering, ASCII fallback, foreground input ownership, and exactly-once restoration of the original TTY, caret, and scroll-region state hold across normal, error, signal, EOF, resize, and raw-mode failure paths.

- **CAP-7**
  - **intent:** The operator can hand the complete durable checked set to direct foreground synchronization from any browser projection.
  - **success:** `w` snapshots every persisted checked path regardless of view, query, Current focus, expansion, collapsed state, Help history, or visible rows, then preserves the authoritative exact-mirror, progress-fallback, final-status, failure-preservation, and retry contracts.

## Constraints

- This specification explicitly supersedes the old flat list, visual-only artist headings, `Esc`+letter jumping, and the prohibitions on search, filtering, paging, and artist-level selection. It does not supersede stable ordering, `_VA` grouping, validated path identity, immediate persistence, preflight, or synchronization safety.
- `player_content_selection` remains keyed by validated library-relative path. Search draft, applied query, view, Current focus, focus anchor, expansion, Help position, and visible projection remain session-local and never redefine membership.
- ADR-0007, ADR-0008, and the complete track-only mirror specification govern payload eligibility, sizing membership, snapshot and rule generation, deletion, source stability, and destination postcheck over the older Player Content payload paragraph.
- One complete eligible-track snapshot supplies displayed logical bytes and transfer membership. Existing free-space reporting remains informational and cannot become a selection or synchronization gate.
- Album and artist rows report complete-group checked truth, not projected truth. Artist Space checks all when the group is none or partly checked and unchecks all only when the group is fully checked.
- Checking an unavailable album is blocked. A checked unavailable album remains visible and removable, contributes unknown rather than valid bytes, and blocks `w` until removed or readable.
- `w` remains direct after complete preflight with no second confirmation. Zero checked is valid and empties the validated player root; persistent chrome must state that exact scope and show a safe destination label.
- Search, view, focus, expansion, collapsed state, Help, and visible rows never limit synchronization membership. `w` always rebuilds from the complete persisted checked set.
- Preserve the active Player Content rsync-progress contract: optional capability probing, sanitized bounded aggregate feedback when supported, bounded busy fallback when unsupported or setup fails, the unchanged valid transfer path, and authoritative final postchecked status.
- Meaning must not depend on color, indentation, or optional Unicode glyphs alone. All user-controlled text, query editing, carets, status, results, and progress are sanitized and bounded by terminal display cells and cannot become shell input.
- ADR-0009 is authoritative. Preserve baseline keyboard, `NO_COLOR`, Unicode/fallback, Help, destructive-scope, and terminal-restoration guarantees without adding or claiming a specialized screen-reader mode, assistive-technology protocol, conformance, or detection.
- Preserve Bash 5 and macOS/Linux portability and the existing Maintenance virtual-window boundary.
- Automated verification uses temporary library, SQLite, player, and external-tool fixtures only under ADR-0004. It must not access a real library, live database, mounted destination, or destructive media workflow without explicit approval.

## Non-goals

- Global or visible-set clear actions, new sort orders, saved searches, track-level selection, multiple player profiles, or capacity automation.
- Synchronization cancellation, background synchronization, history, atomic destination swaps, or changes to browser transfer and `sync_music.sh`.
- Changes to the accepted track-only payload, file-backed rsync mechanism, source immutability, destination ownership, or postchecked success definition.
- A specialized screen-reader mode, announcement model, accessibility setting, assistive-technology test target, or accessibility-conformance claim.
- A roadmap, PRD, architecture replacement, implementation decomposition, or product-code change.

## Success signal

Using temporary fixtures, an operator can curate a 1,600-album library through the tree, Unicode search, views, album toggles, and atomic artist toggles; reopen to the same path-keyed checked set; and press direct `w` from a reduced projection to mirror the complete checked snapshot. Live aggregate progress or its bounded fallback precedes the authoritative result, injected failures preserve membership and retry, and every terminal exit restores the original session state.
