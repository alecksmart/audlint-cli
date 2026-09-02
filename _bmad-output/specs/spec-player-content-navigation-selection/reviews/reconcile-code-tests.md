# Code and Test Reconciliation

## Verdict

**Revise before finalizing.** The spine correctly identifies the main brownfield policy owners and both explicit baseline conflicts, but four runtime seams are not yet reconciled with the implementation and one test seam will fail solely because of the proposed relocation. The baseline itself is healthy: `python3 -m unittest test.test_player_content_creator test.test_ui_regression` ran 52 tests successfully at `77ea99c`.

## Findings

### 1. AD-7 assigns exclusive scroll-region ownership without accounting for the outer virtual window

`bin/audlint.sh` launches Maintenance through `virtwin_run_command`; `lib/sh/virtwin.sh:93-112` sets and later resets the scroll region around the entire child command. The current selector normally relies on that region and only sets/resets one itself under `VIRTWIN_COMPACT_TOP` (`bin/audlint-maintain.sh:699-702`, `282-299`). The diagram and AD-7 start at `bin/audlint-maintain.sh`, so they omit the existing outer owner while promising no nested owner and exactly-once restoration.

**Required correction:** Bind the `audlint.sh`/`virtwin.sh` handoff. Either the outer window remains the sole scroll-region owner and passes a fixed canvas to the selector, or it explicitly transfers ownership and supplies the parent region to restore. Define which component restores which state on selector exit versus whole-browser exit; include this boundary in the structural seed or diagram.

### 2. “Only TTY writer” conflicts with the current aggregate-progress implementation

The accepted transfer path starts `player_content_progress_consume` in a background subshell and gives it a duplicated terminal output FD (`bin/audlint-maintain.sh:519-547`, `666-674`). That child writes cursor movement and progress directly while the foreground shell blocks in rsync. AD-7 says the controller remains the only TTY writer, while AD-9 says to consume the established progress pipeline without stating which part is preserved.

**Required correction:** Preserve the accepted capability probe, transfer fallback, and authoritative result, but bind progress presentation to the terminal owner. The progress reader should emit bounded semantic updates for the controller to paint, or AD-7 must explicitly permit one serialized controller-owned writer. Do not leave both literal readings valid. The transcript conflict at lines 141-142 is accurate; current transcript functions and tests at `test/test_player_content_creator.py:485-542` must be removed or replaced while aggregate/fallback tests remain.

### 3. The unavailable-row union lacks a deterministic metadata and ordering rule

`player_content_selection` stores only `relative_path` and `size_bytes` (`lib/sh/sqlite.sh:251-258`). Artist, year, album label, normalized sort keys, and source path currently come only from live inventory rows produced by `player_content_inventory_row_from_dir` (`lib/sh/player.sh:51-89`). Therefore a checked path missing from the live walk has no stored display metadata. AD-2 requires a frozen union and unavailable rows, but does not say how those fields are recovered, how malformed-but-persisted paths fail, or where missing rows sort. The current sort is artist normalized key, numeric year, album normalized key, then source order (`bin/audlint-maintain.sh:329-370`).

**Required correction:** Bind one path parser for unavailable persisted identities, its validation/failure behavior, `_VA` reconstruction, and the canonical sort/tie-break used for the entire union. Otherwise inventory, tree, and focus stories can all obey AD-2 while producing incompatible identities and order. The resolved purge conflict also covers `test_completed_inventory_purges_dropped_checked_paths` and `test_renamed_album_is_new_unchecked_path` (`test/test_player_content_creator.py:799-825`), not just one obsolete expectation.

### 4. AD-4 overstates what is already supported for graphemes and display cells

The repository has no shared grapheme or display-cell implementation. Current Player Content sanitizes and clips with Bash character counts and locale character classes (`bin/audlint-maintain.sh:193-209`); the reused test renderer advances one Python code point per cell (`test/test_ui_regression.py:200-273`). Python `unicodedata` supports NFC and `str.casefold` is suitable for search, and the local C runtime exposes `wcswidth`, but Python's standard library does not expose the full extended-grapheme-break properties/algorithm needed by the contract. The spine therefore names ingredients without fixing the repository-owned grapheme definition or proving the width backend across the accepted macOS/Linux floor.

**Required correction:** Treat NFC/casefold as confirmed, then bind the repository-owned grapheme algorithm/data source and its Unicode-version policy. Probe `wcswidth` with representative combining, wide, emoji, and invalid cases before selecting it; define the fallback trigger. Keep pure kernel tests authoritative because the current PTY screen emulator cannot prove wide/combining cell placement.

### 5. The persistent Python protocol is a new runtime, not a ratified brownfield seam

Current Python use is one-shot or embedded; there is no persistent bidirectional model process, `coproc`, or framed request/reply helper in `bin/` or `lib/sh/`. AD-5 gives a useful envelope, but AD-7/Deferred leave unexpected EOF, model crash, protocol rejection, and commit-ack loss unresolved. In particular, SQLite may commit successfully and the model may die before receiving the acknowledgement; retrying the mutation and continuing with stale state are materially different behaviors.

**Required correction:** Bind fail-closed lifecycle semantics: on model/protocol loss, stop dispatching effects, restore the terminal, do not retry an ambiguous mutation, and rebuild from SQLite only on a fresh selector session (or state another single recovery rule). Add protocol tests for EOF/crash/malformed reply and commit-with-lost-ack. Startup command and buffer constants may remain deferred.

### 6. Existing white-box tests are tied to the entry-script layout that AD-1 replaces

`test_selector_sizes_without_repainting_its_fixed_rows` slices `player_content_creator()` out of `bin/audlint-maintain.sh` and inspects its source (`test/test_player_content_creator.py:943-946`). `test_progress_capable_rsync_renders_aggregate_feedback_during_one_root_mirror` also requires a specific terminal-FD line in that entry script (`458-460`). Moving the controller to `lib/sh/` as AD-1 requires will fail these tests even when behavior is correct.

**Required correction:** State that these source-location assertions move to the shared controller or become behavioral PTY assertions. AD-10's proposed pure-model, SQLite, player-fixture, and PTY split is otherwise consistent with the current fixture strategy and ADR-0004.

## Confirmed Brownfield Claims

- The selection table is path-keyed durable authority with cached nonnegative bytes; the current per-album mutation helper is the seed to replace with one manifest transaction (`lib/sh/sqlite.sh:529-591`).
- Inventory, snapshot eligibility, secure artifacts, ordered merge rules, one root rsync, flush, source-stability check, destination postcheck, selection preservation, and fresh retry are present in `seek.sh`, `player.sh`, and `player_content_sync`.
- Synchronization rereads the complete ordered SQLite checked set and does not use the visible selector rows (`bin/audlint-maintain.sh:406-504`).
- The proposed functional-core/imperative-shell direction fits ADR-0006, but the persistent model and IPC mechanism are new architecture, not current code structure.
