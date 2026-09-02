---
name: Audlint Player Content
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
---

# Audlint Player Content — Experience Spine

## Foundation

The experience is keyboard-only and runs in a desktop or laptop terminal, inside the existing Audlint Maintenance virtual window. `DESIGN.md` owns visual identity; this document owns behavior. The working scale is hundreds or thousands of albums.

Replace the flat album selector with a searchable tree of focusable artist groups and album children, tri-state artist selection, fast tree/page navigation, All/Checked/Unchecked views, contextual Help, and explicit zero-checked feedback. Rename the Maintenance entry and screen **Player Content**. Persisted SQLite and code identifiers may retain `player_content_selection`.

ADR-0009 defines the accessibility boundary. This experience preserves baseline keyboard operation, non-color meaning, bounded Unicode rendering, complete Help, and terminal-state restoration. It does not add or claim a specialized screen-reader mode, announcement protocol, assistive-technology detection, or accessibility conformance; such a surface requires separate intent, design, proof, and a superseding decision.

## Baseline and Boundaries

Current code and PTY tests establish a flat album cursor, visual artist headings, immediate Space persistence, a fixed sanitized viewport, resize handling, one `>` marker, and direct `w` synchronization. This update replaces `Esc`+letter jumping with Unicode search and adds hierarchy, paging, views, scoped bulk action, and full Help.

ADR-0007, ADR-0008, and `../../../specs/spec-player-track-only-mirror/SPEC.md` replace only the older `player-content-contract.md` payload paragraph. One complete snapshot of eligible regular, non-symlink, non-hidden canonical tracks drives displayed logical bytes and transfer membership. The older contract remains authoritative for identity, persistence, preflight, owned-root deletion, failure preservation, and retry. This UX consumes the track-only source's shared payload contract (CAP-1), Player Content exact mirror (CAP-2), and trustworthy result/retry contract (CAP-4); its browser-transfer capability (CAP-3) has no Player Content surface and remains unchanged. These spines govern tree, search, view, and Help behavior where the original contract prohibited them.

## Information Architecture

| Surface | Purpose |
|---|---|
| Content tree | Browse focusable artist groups and album children |
| All / Checked / Unchecked views | Project persisted membership without mutation |
| Search editor/results | Edit and apply a Unicode query within the active view |
| Help | Read the complete context-sensitive key map |
| Artist measurement | Show bounded progress while preparing one atomic group check |
| Sync feedback | Own the body during the foreground exact mirror |
| Too-small state | Fail closed until the terminal returns to at least 12×20 |

Build the visible tree in this order: filter album children by All/Checked/Unchecked; apply the query; retain an artist only when at least one child survives. An artist-name match admits all of that artist's children allowed by the view; an album-only match admits the matching children. A zero-child parent is never rendered or toggleable. Views, search, expansion, and Help never write membership.

Preserve existing artist/year/album order and `_VA` grouping. Keep a session-local focus anchor—stable identity plus sorted position—independently of Current. When a projection hides Current, move Current to its visible parent or the nearest visible row, preferring forward on ties. While a projection is empty, show no Current but retain the anchor. When rows return, restore Current to the anchored identity if it is visible; otherwise, apply the same fallback. A truly empty inventory starts without an anchor.

## Voice and Tone

Use terse operational language: `Checked 8 of 12 for Bowie, David.`; `Checked view · "live" · 14 albums`; `Measuring Bowie, David… 3 of 8`; `Artist unchanged: 1 album could not be measured.` Avoid celebratory copy, ambiguous “selected,” and generic failures.

Destructive scope must be exact: `0 checked — w deletes all content from player: <safe destination label>`. At narrow widths, show a stable abbreviated label in chrome and the full validated destination in Help. This is persistent comprehension, not a second confirmation.

## Component Patterns

Visual rules live in `DESIGN.md.Components`.

| Component | Behavioral rules |
|---|---|
| selector-chrome | Names active view/query and visible position; refreshes SD directory presence on every redraw; reports global checked count and snapshot-derived size; keeps safety context separate from results. |
| artist-row | Focusable. `Enter` toggles expansion. Space targets the complete group, including hidden children. `[ ]`/`[-]`/`[x]` and checked count/payload describe the full group, not its projection. |
| album-row | Focusable only when its parent is expanded and it survives projection. Space persists one album before repaint. Checking an unavailable album is blocked; unchecking a checked but unavailable album deletes its natural key without measurement or an invented byte delta. |
| search-editor | `/` opens with the applied query copied to a draft. Printable command letters insert text. Enter applies; empty Enter clears. Esc discards the draft. Backspace removes one grapheme cluster. Unsupported controls are rejected with bounded feedback. |
| help-surface | `?` opens. Up/Down move one logical entry; Page Up/Down move one body; Home/End reach bounds. Show `Help · page n of m`; boundary inputs no-op. Clamp after resize, consume browser commands, and dismiss with `?` or `q`, restoring browser/query/focus/expansion/results unchanged. |
| sync-feedback-surface | After `w` is accepted, this surface owns input and the body through snapshot creation, rsync, flush, the source-stability check, the destination postcheck, and the authoritative redraw. Discard ordinary input, treat resize only as layout, clear partial key-sequence state, and never replay bytes. |

## State Patterns

### Environment and startup

| State | Owner and treatment |
|---|---|
| Initial sizing | `selector-chrome`: size only the complete checked-set track snapshot; show checked-set progress, then exact bytes. A failure marks affected album/artist payload unknown and blocks `w`. |
| SD mounted / not mounted | `selector-chrome`: refresh directory-existence status on every redraw. Browsing, persistence, and sizing remain available while detached; only `w` runs full destination preflight. |
| Resize at supported size | Recompute display-cell layout and pages, keep Current visible, and clamp Help/search/body offsets without wrapping fixed rows. |
| Below 12×20 | Show bounded too-small state; preserve browser, draft/applied query, Help position, focus anchor, and results. Outside an in-flight operation, accept only `q` and resize; Space, new `w`, and every other command no-op. An in-flight measurement or sync remains foreground, drains input, and retains its outcome until supported size returns. |

### Browsing and projection

| State | Owner and treatment |
|---|---|
| Artist collapsed / expanded / mixed | `artist-row`: `▸` hides children, `▾` exposes projected children, `[-]` means some complete-group members are checked. Collapse never changes membership. |
| Empty inventory | Content tree has no Current or anchor; movement/toggles no-op and explain that no albums are available. |
| Empty projection | Keep view/query visible, show `No matching albums`, retain the focus anchor, and leave search/view controls active. |

### Membership changes

| State | Owner and treatment |
|---|---|
| Checked unavailable / unknown size | Keep membership and written state visible, exclude unknown bytes from a valid total, and block `w` until removed or readable. Individual uncheck remains available. |
| Album mutation | Commit one natural key before repaint. Database failure rolls back and preserves membership, focus, projection, and an error result. |
| Artist check measurement | Show `Measuring artist… n of m`, name complete scope, own input, and keep Current. Measure every newly checked album, then commit once; any unavailable/unmeasurable target changes nothing. Drain queued input and reset parser state before the result redraw. |
| Artist uncheck | Remove the complete group in one transaction, including checked unavailable rows; failure leaves the group unchanged. |

### Synchronization and results

| State | Owner and treatment |
|---|---|
| Result priority | Persistent context always remains in chrome. In the result row, an active error outranks the latest success or informational message. Errors persist until the next relevant mutation or explicit replacement; success survives at least one stable repaint and clears when a new action starts. Help and resize preserve both. |
| Zero checked | Chrome always shows `0 checked` plus root-wide deletion and safe destination context. It coexists with, and never overwrites, authoritative results. |
| Progress active | `sync-feedback-surface` shows sanitized, bounded aggregate updates before the final result. |
| Progress unsupported/setup failed | Keep a bounded `Synchronizing player…` state and use the existing valid transfer path; progress capability alone never blocks synchronization. |
| Sync/preflight failure | Preserve selection and context. Name the failing stage: preflight, transfer, flush, source stability, or destination postcheck. Retry remains `w`. |

## Interaction Primitives

| Input | List behavior |
|---|---|
| Up / Down | Previous / next visible tree row |
| Left | Album → parent; expanded artist → collapse; otherwise no-op |
| Right | Collapsed artist → expand; expanded artist → first projected child; album → no-op |
| Page Up / Down | One physical body height; clamp at bounds |
| Home / End | First / last visible row |
| Enter | Expand/collapse Current artist; no-op on album |
| Space | Toggle Current album or complete Current artist scope |
| `/` | Enter `Search:` mode with a draft of the applied query |
| `Esc` | In search, discard draft; in list, clear an applied query; otherwise no-op |
| `v` | Cycle All → Checked → Unchecked → All |
| `?` | Open Help |
| `w` / `q` | Direct exact mirror / quit |

Search matching normalizes candidates and the query to NFC, then applies full Unicode case folding. It uses literal substring matching, not transliteration or regular expressions. Preserve original text for display. The editor supports only append and Backspace: arrow keys, Delete, Home, End, Tab, malformed input, and non-printable controls do not edit the query and produce bounded feedback. Bracketed or multi-character paste is accepted only as sanitized printable text. The field scrolls or clips by display cells with a visible overflow cue. When Unicode rendering or display-width measurement is unreliable, use the DESIGN ASCII glyph set and restrict entry to representable text with an explanation; query text never becomes executable shell input.

Artist Space always targets the complete group, even under search or a filtered view. Before measurement starts, name the artist and affected count in a bounded row. Unavailable unchecked albums block a group check; checked unavailable albums may be removed by group uncheck.

`w` always rebuilds one track snapshot from every persisted checked identity. View, query, Current, expansion, and visible rows never limit mirror membership. It retains the existing complete preflight and direct-action contract; no second confirmation is added.

## Accessibility Floor

This is the baseline terminal guarantee defined by ADR-0009, not a screen-reader-support or conformance claim.

- Every primary function is keyboard reachable; no mouse, hover, or color is required.
- Current, expansion, membership, availability, sizing, warnings, outcomes, and destructive scope retain text/symbol meaning under `NO_COLOR` and the ASCII fallback.
- Measure every row and caret position in terminal display cells; never split a grapheme or allow input to wrap/corrupt the canvas.
- Help is complete and reachable at every supported size. The minimum footer remains `? help | w sync | q`; view/query/safety context lives in bounded chrome.
- Save the original TTY, caret, and scroll-region states once. Restore the browser's raw-mode and caret state across search, Help, measurement, synchronization, failure, and resize. Restore the original terminal state exactly once on `q`, EOF, error, signal, failed raw-mode re-entry, or unsupported-size exit.
- The full-screen incremental-repaint interface may remain unsuitable for some screen-reader users; do not describe keyboard access, `NO_COLOR`, or visible markers as screen-reader support.

## Responsive & Platform

Taller terminals expose more tree rows and increase the distance moved by Page Up and Page Down. Footer tiers and persistent chrome follow `DESIGN.md.Layout & Spacing`. Help repaginates by logical entry and retains the nearest entry after resize. Search input, labels, results, progress, and destination scope truncate by display cells.

Common CSI/SS3 variants for arrows, Page, Home, and End must work on the Bash 5 macOS/Linux portability floor. Prefer Unicode disclosure, quotes, and truncation only when locale and width support are reliable; otherwise use the defined ASCII fallbacks.

## Inspiration & Anti-patterns

- **Lifted restriction:** hierarchy, paging, views, Unicode search, artist controls, and full Help replace the older flat-list limits because the operator explicitly approved a better large-library interaction.
- **Retained boundary:** stable sort order, natural identity, immediate persistence, direct `w`, full preflight, exact track-only snapshot, owned-root deletion, failure preservation, and retry are safety contracts, not UX clutter.
- **Rejected:** a global or visible-set one-keystroke clear and projection-relative `w`. Reduced projections conceal scope; synchronization reflects durable membership, and any future whole-library action needs a separately guarded design that states the affected count.
- **Out of scope under ADR-0009:** a specialized screen-reader mode or conformance claim. It must not be approximated by repaint tweaks or unsupported announcements.

## Key Flows

| Flow | Contract coverage |
|---|---|
| 1 | `spec-player-content-creator/SPEC.md` CAP-1; `spec-player-track-only-mirror/SPEC.md` CAP-1 |
| 2 | Approved tree/search UX extension |
| 3 | `spec-player-content-creator/SPEC.md` CAP-1; `spec-player-rsync-feedback/SPEC.md` CAP-1; `spec-player-track-only-mirror/SPEC.md` CAP-1, CAP-2, CAP-4 |
| 4 | `spec-player-content-creator/SPEC.md` CAP-1; `spec-player-track-only-mirror/SPEC.md` CAP-2, CAP-4 |

### Flow 1 — Detached curation and persistence

1. Marta opens Player Content with no SD path present; chrome says `SD: not mounted` while initial checked-set sizing completes.
2. She pages through 1,600 albums, opens the `_VA` group, and checks an album; its row, artist payload, global count, and exact track-snapshot bytes update together.
3. She quits without synchronizing, reopens later, and the natural-key membership and size return while the refreshed chrome now reports the inserted SD path.
4. **Climax:** detached work is visibly durable and the live destination-presence signal changes without altering selection.

Failure: an already checked source is now unavailable; it remains checked with unknown size, can be removed, and blocks `w` until resolved.

### Flow 2 — Unicode search and atomic artist check

1. Olek presses `/`; `Search:` opens with the current applied query and explicit apply/cancel hints.
2. He enters a canonically equivalent Cyrillic query and applies it; matching parents provide context only when a child survives the active view.
3. On a mixed artist, he presses Space; bounded measurement progress owns input and names the complete group.
4. **Climax:** one commit changes the artist to `[x]`; count and checked payload update, Current stays anchored, and queued keys do nothing.

Failure: one target is unavailable; the whole artist remains unchanged and the persistent result names the cause.

### Flow 3 — Non-empty exact mirror with live or fallback feedback

1. Nina activates Checked view and a query, leaving some persisted checked albums hidden, then presses `w`.
2. The complete persisted checked set—not the projection—produces the one eligible-track snapshot used for both bytes and transfer rules.
3. When rsync provides aggregate progress, she sees a bounded update before completion. When aggregate progress is unavailable, she sees bounded `Synchronizing player…`, and the same transfer continues.
4. The synchronization surface owns and drains input while preflight, rsync, flush, source-stability, and destination-postcheck complete.
5. **Climax:** the validated player root contains exactly the checked snapshot tracks; unchecked albums and unrelated root content are gone, and the authoritative result appears beside unchanged view/query context.

Failure: the result names the failed stage, checked membership remains unchanged, and `w` remains available to reconverge.

### Flow 4 — Intentionally empty the player

1. Iga removes the final checked album.
2. Chrome persists `0 checked — w deletes all content from player: <safe destination label>` across view, search, Help, and resize.
3. She presses `w`; complete preflight runs without a second confirmation and sync owns input through postcheck.
4. **Climax:** the validated player root is empty and success remains visible without hiding the zero-state scope for a future `w`.

Failure: preflight or sync failure names its stage beside the persistent zero-state context; membership remains empty and retry is `w`.

## Delivery and Proof

The first increment implements this spine. Defer global or visible-set bulk actions, new sorting, saved searches, capacity automation, track-level selection, synchronization cancellation, background synchronization, synchronization history, and any specialized screen-reader mode or conformance claim. Preserve snapshot, preflight, deletion, source-stability, destination-postcheck, and retry semantics under the stated source precedence.

Use temporary fixtures only. PTY proof covers 1,600+ albums; detached browsing, live SD-path refresh, persistence, and `_VA`; initial and failed sizing; exact non-empty and empty mirrors; identical sync manifests under every projection; live aggregate progress and no-progress fallback; Unicode NFC/casefold, grapheme deletion, display-cell width, controls, paste, and ASCII fallback; search mode lifecycle; stable focus through empty projections; tri-state truth; individual unavailable toggles; blocked artist measurement and queued input; paged Help; result priority; narrow/too-small recovery; terminal lifecycle exits; `NO_COLOR`; and unchanged direct-`w`, progress ownership, failure preservation, and retry behavior.
