# Verification Contract

## Baseline at `22b6f28`

The planning baseline is current HEAD on `release/v1.4.0`. Claims below were checked against code and tests, not inferred from older BMAD artifacts.

| Baseline claim | Evidence |
| --- | --- |
| Implemented selector is a flat album cursor with visual artist headings and `Esc`+letter jumps; it has no search, views, focusable artist rows, artist mutation, or full Help. | `bin/audlint-maintain.sh`, especially `player_content_read_selector_key`, `player_content_selector_jump`, and `player_content_creator`. |
| Membership is immediately persisted by validated relative path with cached payload bytes. | `lib/sh/sqlite.sh` and Player Content toggle/persistence tests. |
| Direct `w` rebuilds the complete ordered checked set, performs one exact track-only root mirror, and preserves checked paths on failure. | `bin/audlint-maintain.sh:player_content_sync`, `lib/sh/player.sh`, and exact-mirror/failure tests. |
| Optional aggregate rsync progress falls back to the established mirror and the final transfer/postcheck result remains authoritative. | Player Content progress functions and progress/fallback/failure tests. |
| Bounded repaint, one Current marker, `NO_COLOR` structure, minimum terminal size, input draining, raw-mode restoration, and signal cleanup exist as the baseline to preserve. | `bin/audlint-maintain.sh` and selector layout/lifecycle tests. |

`python3 -m unittest test.test_player_content_creator` passed all 42 tests in 96.348 seconds on this baseline using temporary fixtures.

## Required acceptance proof

| Area | Temporary-fixture proof |
| --- | --- |
| Hierarchy and scale | Use at least 1,600 albums across ordinary artists and nested/direct `_VA` paths. Prove deterministic order, focusable parent/child rows, disclosure, one Current marker, row/page/Home/End/Left/Right behavior, bounded rendering, and stable focus through collapse, resize, empty projection, and restored rows. |
| Views and search | Prove All → Checked → Unchecked cycling without writes; filter-then-query ordering; artist-name and album-only matches; NFC equivalence, full Unicode case folding, literal matching, grapheme Backspace, apply/cancel/clear, printable paste, rejected controls, display-cell clipping, and the ASCII fallback. |
| Membership | Prove album persistence before repaint and reopening. Prove `[ ]`, `[-]`, `[x]` against complete groups under reduced projections. Prove atomic artist check/uncheck, unavailable checked removal, blocked unavailable additions, measurement progress, database/measurement rollback, unchanged focus/projection on failure, queued-input draining, and exact global count/size updates. |
| Help, chrome, and results | Prove complete paged Help and local navigation at every supported size; dismissal without state loss; live SD-directory presence; global checked/unknown payload; view/query/position context; persistent exact zero-checked deletion scope; error-over-success priority; and result survival across stable repaint, Help, and resize. |
| Busy and too-small states | During measurement and every synchronization stage, inject ordinary keys, partial CSI/SS3 sequences, paste, and resize. Prove no command replay, no second mutation or `w`, correct clamping, preserved outcome, and fail-closed behavior below 12×20 with only `q` and resize active outside foreground work. |
| Synchronization membership | For every combination of view, query, focus, and collapsed state, prove `w` produces the same manifest from the complete persisted checked set. Prove nonempty and zero-checked exact mirrors, direct action without confirmation, complete preflight, source-stability and destination postchecks, checked-state preservation, stage-specific failure, and successful retry convergence. |
| Progress handoff | With a progress-capable stub, observe sanitized bounded aggregate feedback before completion. With unsupported capability or failed progress setup, observe bounded busy fallback and the same valid mirror. Prove malformed, control-bearing, and oversized records cannot corrupt the canvas and a real nonzero rsync or later-stage failure remains authoritative. |
| Terminal floor | Prove `NO_COLOR`, Unicode and ASCII symbol meaning, display-cell-safe wide/combining labels and caret, footer tiers, preserved Maintenance header, supported resize recovery, common CSI/SS3 variants, and exactly-once TTY/caret/scroll-region restoration on `q`, EOF, error, signal, failed raw-mode re-entry, and too-small exit. Do not claim or test a specialized screen-reader mode. |

## Preservation checks

- Re-run the established Player Content exact-mirror, progress, persistence, failure, retry, and terminal tests; changed expectations are limited to restrictions explicitly superseded by this specification.
- Keep payload eligibility, snapshot/rule identity, source immutability, root ownership, zero-selection deletion, preflight, flush, source-stability comparison, destination postcheck, and retry aligned with ADR-0007, ADR-0008, and the track-only mirror specification.
- Run all automated proof against temporary libraries, SQLite databases, player roots, and tool stubs under ADR-0004. A dry-run label does not permit use of operator resources.
- Treat `make check` as the repository release gate after focused implementation proof; no CI workflow substitutes for it.
