# Interaction and Safety Edge-Case Review

## Overall verdict

**Changes required before implementation.** The finalized spines close all ten conditions from the prior edge-case review: payload precedence, projection emptiness and refill, complete-group scope, unavailable rows, Unicode draft lifecycle, Help paging, artist-measurement and synchronization ownership, result priority, too-small preservation, terminal cleanup, and full-set synchronization are now explicit. The rerun found no critical issue, but one high-severity cold-load ownership gap and four medium-severity boundary ambiguities remain.

Finding counts: **critical 0 · high 1 · medium 4 · low 0**.

## Findings

### EC-01 — Initial checked-set sizing has no input-ownership boundary

- **Severity:** high
- **Exact location:** `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:68-75`; `_bmad-output/specs/spec-player-content-creator/player-content-contract.md:45-55`.
- **Trigger:** Player Content opens with a large persisted checked set and sizing takes long enough for the operator to type Space, `w`, `q`, paste input, resize, or leave a partial CSI/SS3 sequence before sizing finishes.
- **Gap:** Initial sizing is defined as a progress state, but unlike artist measurement and synchronization it does not say whether it owns input, which input is honored, when queued bytes are discarded, or whether parser state is reset before the content tree becomes interactive. A sizing failure blocks `w`, but the contract does not prevent a queued `w` from being interpreted immediately after a successful sizing redraw.
- **Consequence:** Reassurance input entered while the selector appears busy can mutate membership, start the destructive exact mirror, or quit as soon as sizing completes. Implementations can also differ on whether resize or `q` is responsive during cold load.
- **Concrete fix:** Define initial sizing as an explicit input-owning phase from selector entry through its authoritative success/failure redraw. State which safe controls, if any, remain active; treat resize only as layout; discard ordinary queued bytes and reset partial key-sequence state before enabling browser commands. If `q` is intentionally supported during sizing, define it as immediate selector exit with the terminal lifecycle invariant preserved.

### EC-02 — The 40–59-cell footer tier does not fit at 40–42 cells

- **Severity:** medium
- **Exact location:** `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:54-60`; `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:131-140`.
- **Trigger:** The supported terminal width is 40, 41, or 42 display cells.
- **Gap:** The exact tier text `Space toggle | v view | ? help | w sync | q` occupies 43 display cells, although it is assigned to the entire 40–59 range. The same contract prohibits wrapping fixed rows.
- **Consequence:** A conforming implementation must overflow, clip a command—most likely the trailing quit hint—or silently invent an undocumented tier. That breaks the stated bounded-canvas and complete-discoverability contract at supported widths.
- **Concrete fix:** Add a fitting 40–42-cell variant, shorten the tier to at most 40 cells, or move the existing 43-cell string's lower bound to 43 and explicitly reuse the 20–39 tier at 40–42.

### EC-03 — Too-small `q` semantics conflict with preserved search and Help modes

- **Severity:** medium
- **Exact location:** `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:62-64,74-75,115-121,133-136`.
- **Trigger:** The terminal drops below 12×20 while the search editor or Help is active, then the operator presses `q` before resizing back.
- **Gap:** The too-small state preserves the active search draft or Help position and says only `q` and resize are accepted. In search, printable `q` normally inserts text; in Help, `q` dismisses Help; in the browser, `q` exits the selector. The too-small state does not say which meaning wins or whether the suspended mode receives the key.
- **Consequence:** The same input can unexpectedly exit, merely dismiss Help, alter a hidden draft, or do nothing depending on implementation. An unexpected exit is especially damaging if the operator believed they were editing a query.
- **Concrete fix:** Declare the too-small surface a distinct input mode and assign `q` one unambiguous action. A safe contract is: suspend all underlying-mode bindings, make `q` exit the selector, preserve the draft/Help position only for resize recovery, and say this explicitly in Help and proof cases. If `q` should instead dismiss the suspended submode, provide a separate, visible exit binding.

### EC-04 — Search omits the committed year field and derived-expansion lifecycle

- **Severity:** medium
- **Exact location:** `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/.memlog.md:28,30`; `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:37,43-45,62,115-123,169-176`.
- **Trigger:** The operator searches by album year, or an album match occurs beneath an artist that was collapsed before the query was applied; the query is later cleared or replaced.
- **Gap:** The canonical decisions say search matches artist, year, and album text and temporarily derives expansion for matching groups before restoring prior expansion when cleared. The spine specifies artist-name and album-only matching but never names year as a candidate or defines query-derived expansion and restoration.
- **Consequence:** Implementations can disagree on year results. An album can satisfy the query yet remain hidden under a collapsed parent, and clearing search can either preserve the temporary expansion or destroy the operator's prior expansion state.
- **Concrete fix:** State that normalized literal matching covers artist, rendered year, and album fields. Define a search-derived expansion overlay that exposes surviving album matches without mutating session-local expansion, and specify when the overlay is recomputed and removed so the prior expansion set returns on clear/cancel as intended.

### EC-05 — Global size presentation is ambiguous when any checked album is unknown

- **Severity:** medium
- **Exact location:** `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:64-66`; `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:59-61,72-73,89-92`; `_bmad-output/specs/spec-player-content-creator/player-content-contract.md:45-55`.
- **Trigger:** One or more persisted checked albums cannot be read or measured while other checked albums have known snapshot sizes.
- **Gap:** Artist payloads explicitly render `size unknown`, and the state table says unknown bytes are excluded from a valid total and block `w`. The global `selector-chrome` contract nevertheless says it reports snapshot-derived size without specifying whether it shows `size unknown`, a labeled partial subtotal, or the sum of known bytes as if exact.
- **Consequence:** A downstream implementation can present a deceptively exact global size even though the source contract requires the current selection size to be trustworthy and unknown checked payload makes it incomplete. The `w` block prevents transfer but does not prevent incorrect capacity decisions during curation.
- **Concrete fix:** Require the global size to become `size unknown` whenever any checked payload is unknown. If a known subtotal is useful, label it explicitly as partial and keep the unknown count visible; never render the known-byte sum as the complete selection size.

## Closed regression checks

- **Payload precedence:** ADR-0007, ADR-0008, and the track-only SPEC are direct sources and explicitly supersede only the older payload paragraph; one eligible-track snapshot owns size and transfer membership (`EXPERIENCE.md:4-11,27-29`).
- **Projection, focus, and hidden scope:** zero-child parents are excluded, empty projections retain an identity/position anchor, and artist Space targets the complete group rather than visible children (`EXPERIENCE.md:43-45,60,81-83,123`).
- **Unavailable rows:** unchecked unavailable albums cannot be checked; checked unavailable albums remain individually and group-removable; unknown checked payload blocks `w` (`EXPERIENCE.md:61,89-92,123`).
- **Unicode editor:** applied and draft buffers, NFC plus full casefold, grapheme Backspace, control rejection, sanitized paste, display-cell clipping, and ASCII fallback are specified (`EXPERIENCE.md:62,115-121`).
- **Help, foreground operations, and results:** Help navigation/resize/restoration, artist measurement ownership, full synchronization ownership, parser reset, and separate persistent context/result priority are explicit (`EXPERIENCE.md:63-64,91,98-102`).
- **Synchronization scope and safety:** `w` always rebuilds from every persisted checked identity regardless of projection, retains full preflight, and owns input through postcheck and authoritative redraw (`EXPERIENCE.md:64,125,178-195`).
- **Terminal lifecycle and ADR-0009:** display-cell safety and exactly-once terminal restoration cover normal, error, signal, EOF, raw-mode re-entry, and unsupported-size exits, without requesting or implying specialized screen-reader support (`EXPERIENCE.md:127-136`; `docs/decisions/0009-ADR-terminal-accessibility-boundary.md:16-30`).
