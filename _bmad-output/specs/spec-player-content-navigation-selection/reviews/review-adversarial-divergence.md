# Adversarial Divergence Review

## Verdict

**Revise before finalizing.** The latest spine closes the code-reconciliation gaps, but seven interfaces still allow independently implemented units to obey every AD literally and remain incompatible. The first two can prevent the selector from functioning at all; the rest produce cross-story behavioral drift.

## Critical findings

### 1. AD-5 defines a wire envelope but not an interoperable protocol

**Compliant unit A:** The Bash controller sends `1 US request-id US inventory US /tmp/artifact US row-count`, uses separate `effect`, `frame`, and `complete` kinds, and expects positional fields.

**Compliant unit B:** The Python model expects `1 US request-id US load US inventory US /tmp/artifact`, uses one `event` kind with a subtype, and encodes optional fields as empty positions.

Both use versioned UTF-8 LF records, request ids, kinds, Unit Separator fields, complete secure artifacts, no executable content, and every rejection rule in AD-5. They still cannot start a session or exchange an effect.

**Hole to close:** Bind a single protocol schema: allowed kinds and direction, field order/cardinality, scalar encoding, artifact record schema, request/reply/completion correlation, and which side chooses inline versus artifact transport. Constants such as byte limits may remain implementation seed only if one shared protocol definition owns them for both sides.

### 2. AD-2, AD-7, AD-8, and AD-9 permit two incompatible render/effect cycles

**Compliant unit A:** Every progress, destination-presence, busy, and effect-result update is sent to the Python state owner; Python returns the next complete semantic frame, and Bash paints it.

**Compliant unit B:** Python owns browser state and persistent results, while Bash directly overlays aggregate progress and fresh destination presence in reserved rows, then sends only one completion event back to Python.

Both keep Python as the owner of session state, keep workers away from the TTY, let Bash paint, supply fresh presence, and let the controller paint progress as the ADs require. They disagree about what state survives resize, Help, an effect failure, and the authoritative redraw.

**Hole to close:** Bind one event loop. State whether every external observation and worker update first becomes a model event and whether every canvas write comes from the resulting complete semantic frame. If progress is the sole exception, define its reserved row, resize behavior, replacement by the final result, and prohibition from mutating model result priority.

## High findings

### 3. AD-3 leaves the replacement scope and transaction precondition ambiguous

**Compliant unit A:** The model emits the complete desired global checked set; the SQLite helper replaces all membership in one transaction.

**Compliant unit B:** The model emits the complete desired set only for the Current album or artist; the helper applies an add/remove delta inside that scope and preserves all rows outside it.

Both implement one “complete target-set replacement intent,” one add/remove manifest, one transaction, measurement before commit, and acknowledgement after commit. A row added outside the current projection or by another writer is deleted by A and preserved by B.

**Hole to close:** Define the mutation manifest as a scoped album/group delta or a global replacement, identify its scope key, reject duplicates and add/remove overlap, and bind the expected-membership precondition. On precondition mismatch, reread or fail; never let separate stories choose overwrite versus merge.

### 4. Sole outer scroll ownership has no resize handoff

**Compliant unit A:** `virtwin.sh` establishes the region once; while it is blocked running the child, the selector recomputes rows from current terminal dimensions but never changes the region.

**Compliant unit B:** The selector treats the originally assigned canvas as fixed through resize because only `virtwin.sh` may set the region, then redraws after return to the parent.

Both preserve `virtwin.sh` as sole scroll-region owner and the controller as resize owner inside its canvas. A can paint against a stale outer region; B cannot satisfy supported live-resize recovery.

**Hole to close:** Define the live geometry contract between outer window and selector: fixed top row, how bottom/width change, who updates the actual terminal region while the child runs, and the acknowledgement/order for resize versus paint. If the selector must never emit a region sequence, the outer owner needs a callable or message seam that can do so synchronously.

### 5. AD-2 does not define “normalized” ordering precisely enough

**Compliant unit A:** Inventory uses the current shell-produced lowercase `artist_norm`/`album_norm` values and locale comparison, with literal relative path as the final tie-break.

**Compliant unit B:** Python derives NFC-plus-full-casefold keys through AD-4 and compares Unicode strings, with the raw path as the final tie-break.

Both freeze the union in normalized artist, numeric year, normalized album, literal-path order. Their artist order, `_VA` placement, focus fallback, and 1,600-row projection differ for non-ASCII and canonically equivalent names.

**Hole to close:** Name the exact order-key transform and comparison domain: for example, original display text retained separately, NFC-plus-casefold keys from the shared kernel, numeric year, then either Unicode scalar or UTF-8 byte comparison for raw relative path. State whether this intentionally replaces or reproduces the existing locale-sensitive Bash order.

### 6. AD-4 leaves width-probe acceptance and “representable” input implementation-defined

**Compliant unit A:** Probes one combining mark, CJK character, and single-code-point emoji; its libc passes, so all printable UTF-8 input is accepted.

**Compliant unit B:** Probes a family ZWJ sequence, flag pair, variation-selector sequence, and the same basic cases; the same libc fails one expected width, so ASCII fallback is selected and non-ASCII search input is rejected.

Both probe combining, wide, emoji, and invalid input, use the declared grapheme tables, and follow the fallback rule. Supported machines can therefore select different glyph sets and accept different queries for reasons unrelated to actual terminal behavior. Runtime `unicodedata` may also differ from the generated grapheme-table version while both are individually declared.

**Hole to close:** Version the exact startup probe vectors and expected widths, define the boolean acceptance rule and the “representable text” predicate, and require compatibility between runtime normalization data and the generated grapheme data. Platform-specific fallback is allowed, but the decision procedure must be shared.

## Medium finding

### 7. Result lifetimes have no shared event taxonomy

**Compliant unit A:** “Next action” includes movement, expansion, Help, resize, and search editing, so success clears immediately on any of them; “relevant mutation” means any Space or `w` attempt.

**Compliant unit B:** “Next action” means the next effectful action only, while an error persists until a successful mutation of the same target or an explicit higher-priority error replaces it.

Both preserve error-over-success priority, Help/resize state, one stable repaint, and the prose in AD-8. Their result rows diverge during ordinary navigation and failed retries.

**Hole to close:** Define event classes for stable repaint, navigation/projection, Help/resize, action start, mutation success/failure, synchronization success/failure, and explicit replacement; bind the result transition for each class.

## Gate summary

The paradigm and ownership split are sound, and the revised spine now addresses unavailable identity reconstruction, grapheme ownership, progress writer isolation, outer scroll ownership, protocol-failure exit, and portable proof seams. Finalization should wait for the shared protocol schema, render/effect cycle, mutation scope, and resize handoff. The ordering, width-probe, and result-transition rules can be tightened in the same pass without adding implementation structure.
