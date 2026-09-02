# Player Content Interaction Contract

## State and terms

- Rename the Maintenance entry and screen from **Player Content Creator** to **Player Content**. Existing SQLite and code identifiers may retain `player_content_selection` naming.
- **Current** is the one keyboard-focused visible row. **Checked** is persisted player membership. **View** is the non-mutating All, Checked, or Unchecked projection. Do not use “selected” for both focus and membership.
- Preserve existing artist/year/album order and `_VA` grouping. Search, views, expansion, Help, and resize change only the visible projection.
- Artist rows are focusable and show disclosure plus `[ ]`, `[-]`, or `[x]` for none, some, or all complete-group albums checked. Album rows are focusable only when their parent is expanded and they survive projection.
- Reuse `C_TITLE`, `C_LABEL`, `C_VALUE`, `C_ACTION`, `C_RESULT`, and `C_SELECT`; add no literal colors. Use terse operational copy, avoid celebratory language and generic failures, and name the action, scope, or failed stage.

## Projection and focus

Build the visible tree in this order:

1. Filter album children by All, Checked, or Unchecked view.
2. Apply the current query.
3. Retain an artist only when at least one child survives.

An artist-name match admits every child allowed by the active view; an album-only match admits only matching children. A parent with no surviving children is neither rendered nor toggleable. Artist checkbox, count, and payload always describe the complete group, including hidden children.

A truly empty inventory shows that no albums are available and makes movement and toggles no-ops. An empty projection keeps view and query visible, shows `No matching albums`, retains the focus anchor, and leaves search and view controls active.

Keep a session-local focus anchor as stable row identity plus sorted position. If a projection hides Current, move Current to its visible parent or nearest visible row, preferring forward on a tie. An empty projection has no Current but retains the anchor; when rows return, restore the anchor if visible, otherwise use the same fallback. A truly empty inventory starts without Current or an anchor.

`▸` and `▾` mean collapsed and expanded; fixed-column `+` and `-` are the ASCII fallback. Collapse hides children without changing membership. Exactly one visible row has `>` when a projection is nonempty.

## Browser commands

| Input | Browser behavior |
| --- | --- |
| Up / Down | Move to the previous or next visible tree row. |
| Left | Album to parent; expanded artist collapses; otherwise no-op. |
| Right | Collapsed artist expands; expanded artist moves to first projected child; album no-op. |
| Page Up / Down | Move one physical body height and clamp at bounds. |
| Home / End | Move to first or last visible row. |
| Enter | Toggle Current artist expansion; album no-op. |
| Space | Toggle the Current album or the complete Current artist group. |
| `/` | Open the bounded search editor with the applied query copied to a draft. |
| `Esc` | In search, discard the draft; in the browser, clear an applied query; otherwise no-op. |
| `v` | Cycle All → Checked → Unchecked → All without mutation. |
| `?` | Open Help. |
| `w` / `q` | Start direct exact synchronization / quit Player Content. |

Support common CSI and SS3 variants for arrows, Page, Home, and End on Bash 5 macOS and Linux.

## Search editor

- Normalize query and candidates to NFC, apply full Unicode case folding, and perform literal substring matching. Do not transliterate or interpret regular expressions. Preserve original text for display.
- Printable command letters insert text while the editor owns input. Enter applies; empty Enter clears. `Esc` discards the draft. Backspace removes one grapheme cluster.
- Arrow keys, Delete, Home, End, Tab, malformed input, and non-printable controls do not edit the query and produce bounded feedback. Accept bracketed or multi-character paste only as sanitized printable text.
- Keep the caret inside one bounded `Search:` row with apply/cancel hints and a visible overflow cue. Query text never wraps the canvas or becomes executable shell text.
- When Unicode rendering or display-cell measurement is unreliable, use the defined ASCII glyphs, restrict entry to representable text, and explain the restriction in bounded feedback.

## Membership mutations

An album Space action commits its one path-keyed change before repaint. Checking requires a complete eligible-track measurement; checking an unavailable album is blocked. Unchecking a checked unavailable album deletes its path without requiring measurement or inventing a byte delta. Database failure rolls back and preserves membership, Current, projection, and an error result.

Artist Space always targets the complete group, including hidden children. For `[ ]` or `[-]`, name the artist and affected count before measuring every newly checked album. Measurement owns input, retains Current, and shows bounded `Measuring <artist>… n of m`. Commit all additions in one transaction only after every target is measurable; otherwise change nothing. For `[x]`, remove every group path in one transaction, including checked unavailable albums. Any database failure leaves the complete group unchanged. After either busy path, drain queued bytes and reset partial key-sequence state before repaint.

Initial sizing builds the complete checked-set track snapshot only. Until complete, show checked-set progress. If a checked path cannot be measured, mark its album and artist payload unknown, retain membership, and block `w`. Human sizes are valid only when every contributing checked path is known.

## Chrome, rows, and results

The bounded selector chrome shows active view and query, visible position, refreshed SD-directory presence, global checked count, and complete checked-set payload. SD presence is refreshed on every redraw and remains informational; only `w` performs destination safety and writability preflight.

At narrow supported widths, retain view, query, zero-checked scope, and a safe destination label before optional detail. Examples of the intended operational voice are `Checked 8 of 12 for Bowie, David.`, `Measuring Bowie, David… 3 of 8`, and `Artist unchanged: 1 album could not be measured.`

Keep persistent context separate from the latest result. An active error outranks success or informational text. Errors remain until the next relevant mutation or explicit replacement. Success survives at least one stable repaint and clears when a new action starts. Help and resize preserve both context and result.

Zero membership always shows `0 checked — w deletes all content from player: <safe destination label>`. At narrow widths, chrome may use a stable abbreviated label, while Help exposes the full validated destination. This warning coexists with authoritative success or failure and is not a second confirmation.

Use these row meanings without relying on color:

- Artist: `> ▾ [-] Artist name (checked/total · checked payload)`.
- Album: `>   [x] YEAR - Album [unavailable]`.
- Payload and availability: use written `unavailable` or `size unknown` state where applicable; render a human size when complete and `sizing…` while pending.

The fixed non-wrapping footer tiers are:

- 20–39 cells: `? help | w sync | q`
- 40–59 cells: `Space toggle | v view | ? help | w sync | q`
- 60+ cells: add navigation and visible-position hints as room permits.

## Help

`?` opens read-only, selector-owned Help. Up/Down move one logical entry; Page Up/Down move one body; Home/End reach bounds. Show `Help · page n of m` and a local key legend at every supported size. Boundary movement is a no-op. Resize repaginates and keeps the nearest logical entry. All browser commands are consumed while Help is open. `?` or `q` dismisses Help and restores browser/query/focus/expansion/results unchanged.

Help includes the full command map, search and view semantics, complete-group artist scope, persistent checked membership, zero-checked deletion meaning, busy input ownership, synchronization stages, progress fallback, retry, the full safe destination, Unicode/ASCII behavior, and the baseline accessibility boundary.

## Foreground work and synchronization handoff

Measurement and synchronization own input. Ordinary bytes are discarded, resize changes layout only, partial key sequences are cleared, and queued bytes are never replayed as commands.

On accepted `w`, snapshot every persisted checked identity, not the projection. The synchronization surface owns the body through snapshot creation, full preflight, rsync, flush, source-stability comparison, destination postcheck, and authoritative redraw. It retains view/query and safety context for the return state.

When optional aggregate rsync progress is available, render only sanitized width-bounded aggregate updates in selector-owned space. If capability probing or progress-channel setup fails, retain a bounded `Synchronizing player…` state and run the established valid root-mirror path. Progress never changes transfer membership, exit status, success conditions, or retry.

Any failure names preflight, transfer, flush, source stability, or destination postcheck as applicable; it preserves checked paths and makes retry direct `w`. A failed non-atomic destination may be partial, and a later successful retry rebuilds artifacts from current checked state and converges.

## Terminal lifecycle and accessibility floor

Preserve the Maintenance header, fixed canvas, bounded title/status/result rows, incremental repaint, inherited terminal typography and color roles, and `NO_COLOR`. Measure and truncate by terminal display cells, never bytes or code points. Do not split a grapheme or let any label, query, caret, status, result, or progress record wrap or scroll the preserved header.

At fewer than 12 rows or 20 columns, show a bounded too-small state and preserve browser, search draft/applied query, Help position, focus anchor, expansion, and results. Outside an in-flight operation, only `q` and resize act. In-flight measurement or synchronization remains foreground, drains input, and retains its outcome until supported size returns.

Save the original TTY, caret, and scroll-region state once. Preserve or re-enter the browser raw-mode and caret state across search, Help, measurement, synchronization, failure, and resize. Restore the original state exactly once on `q`, EOF, error, signal, failed raw-mode re-entry, or exit from the too-small state.

Every primary function is keyboard reachable; meaning survives `NO_COLOR` and ASCII fallback; Help is complete at every supported size. These are baseline terminal guarantees under ADR-0009, not a specialized screen-reader mode or accessibility-conformance claim.
