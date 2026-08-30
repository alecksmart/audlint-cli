---
title: 'Player Content Creator'
type: 'feature'
created: '2026-08-30'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'e233a6e3448fbedd703264a171a16941ec99e291'
context:
  - 'docs/ai/bmad-lite.md'
  - '_bmad-output/specs/spec-player-content-creator/player-content-contract.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Player content is currently transferred as one-off browser actions, so an operator cannot keep a durable, capacity-visible SD-card selection or safely mirror the card to that exact selection.

**Approach:** Add a Maintenance Content Creator that persists natural album identities, displays their shared player-payload size live, and—only after strict preflight and explicit confirmation—uses one manifest-driven mirror to make the configured player match them.

## Boundaries & Constraints

**Always:** Preserve album identity as `(artist_lc, album_lc, year_int)`; reuse the browser transfer payload rules and source-relative layout; allow browsing and selection without a mounted player; retain current browser transfer behavior; use temporary fixtures only; preserve Bash 5 and macOS/Linux portability; run the release gate once near completion.

**Ask First:** Any change to `sync_music.sh`, `AUDL_SYNC_DEST`, scanning or identity rules, player ownership semantics, or a destructive action against a real library, database, or mounted player.

**Never:** Add capacity enforcement, automatic selection, playlists or track-level selection, multiple profiles, transcoding, or rollback. Do not create a missing player destination, use source cleanup, or delete anything before all preflight checks and `y` confirmation pass.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Selection | Writable database; player absent | `M` → `C` opens, toggles persist natural identities, and right title shows `SD: not mounted`, count, and exact payload bytes | A missing, unreadable, or read-only database keeps `C` unavailable with a clear message |
| Player status | Empty, missing, file, or directory player path | Each redraw reports `not mounted` except for an existing directory, which reports `mounted` | Navigation, sizing, toggling, and quit do no player validation beyond this existence check |
| Mirror | Valid library, writable safe player, and checked snapshot (including empty) | Confirmation states the resolved destination, count, size, and deletion consequence; `y` runs one filtered root mirror then flushes | Any source/destination/overlap/manifest/rsync check failure invokes no `rsync` and deletes nothing; other confirmation keys cancel |
</frozen-after-approval>

## Code Map

- `lib/sh/sqlite.sh:229-419` — sole SQLite initializer and schema-change flag; add the idempotent selection table and flag first creation for normal backup refresh.
- `bin/audlint.sh:3460-3514,3682-3776,4033-4084` — existing player path, payload size, human-size, and rsync filter behavior; extract shared payload/path helpers while preserving the legacy per-album runner and its metadata fallback.
- `lib/sh/bootstrap.sh:3-86` — `path_resolve` and portable byte-size primitive for all source/destination containment and size handling.
- `lib/sh/player.sh` — new focused shared owner of relative-path validation, payload inclusion/size/total/human-label, and reusable rsync payload filters; used by browser and selector only.
- `bin/audlint-maintain.sh:21-35,68-82,616-700` — Maintenance menu and virtual-window title behavior; add the local scrolling selector, direct DB resolution, stale-row cleanup, and confirmed sync workflow. Existing clear-player logic at `353-390` is not sufficient for mirror safety.
- `bin/audlint.sh:5798-5812` — Main-to-Maintenance launch; pass resolved `AUDL_DB_PATH` so `--db` remains authoritative.
- `test/test_library_browser_smoke.py:1389-2254` — existing payload, filters, source-relative transfer, and legacy-fallback regression coverage to preserve, not duplicate.
- `test/test_audlint_maintain_smoke.py:24-315` and `test/test_ui_regression.py:145-180,409-443` — PTY and virtual-window conventions for selector interaction and title redraws.
- `test/test_sqlite_query_plan_smoke.py:12-38` — temporary legacy database harness for one focused schema/backup-refresh test.

## Tasks & Acceptance

**Execution:**

- [x] `lib/sh/player.sh`, `bin/audlint.sh` — extracted the existing player payload and relative-source helpers into the focused shared library; browser fallback and current rsync behavior remain covered by regression tests.
- [x] `lib/sh/sqlite.sh` — created `player_content_selection` with the composite natural key, reports first creation as a schema change, and centralizes stale-row cleanup and single-statement toggles.
- [x] `bin/audlint.sh`, `bin/audlint-maintain.sh` — forwards the resolved database to Maintenance and provides an always-visible, writable-database-gated `c` selector with ordered grouping, bounded scrolling, cached sizes, persisted toggles, and live title status.
- [x] `bin/audlint-maintain.sh` — rebuilds and validates the checked snapshot before confirmation, then runs one filtered root mirror with deletion and `sync`; preflight and failures preserve the selection.
- [x] `test/test_player_content_creator.py` — added compact temporary-fixture coverage for schema/persistence, PTY selection/status/size/payload behavior, real and cancelled mirrors, and grouped no-rsync safety failures; existing browser-transfer tests remain the regression guard.

**Acceptance Criteria:**

- Given a writable legacy database and no player, when an operator enters Main `M`, Maintenance `C`, uses arrows and Space, then albums are artist-grouped in deterministic order, headers are not selectable, the viewport stays bounded, exact natural identities persist across reopening, and title totals update immediately using only transferable payload bytes.
- Given player paths that are empty, absent, files, or directories, when the selector redraws, then only an existing directory reads `SD: mounted`; all non-sync interaction remains available without it and keeps the established virtual-window, color, `NO_COLOR`, and quit behavior.
- Given selected fixtures plus stale player files, when valid preflight and `y` confirmation run, then one source-relative filtered mirror updates checked payloads, removes unchecked and extra player content (including for an empty selection), preserves source files, and flushes writes.
- Given any failed preflight, non-`y` confirmation, missing `rsync`, or nonzero rsync/flush result, when synchronization is attempted, then no unsafe deletion command runs, selection remains unchanged, failures are visible, and a later valid retry can converge the player.

## Spec Change Log

## Design Notes

The new mirror must not reuse the browser's per-album runner: it cannot remove unchecked directories from the player root. The browser retains its metadata destination fallback, but selector synchronization accepts only a verified source-relative path, preventing an invalid source from choosing a destination by metadata.

## Verification

**Commands:**

- `python3 -m unittest test.test_player_content_creator` — expected: temporary fixtures prove persistence, interaction, payload status, mirror, cancellation, and grouped safety failures.
- `python3 -m unittest test.test_library_browser_smoke test.test_audlint_maintain_smoke test.test_sqlite_query_plan_smoke` — expected: extraction and Maintenance integration preserve existing behavior.
- `make check` — expected: repository release gate passes once after targeted checks.

## Suggested Review Order

**Destructive mirror boundary**

- Starts with strict destination and source preflight before confirmation.
  [`audlint-maintain.sh:158`](../../bin/audlint-maintain.sh#L158)

- Builds the exact selected snapshot and runs one filtered root mirror.
  [`audlint-maintain.sh:169`](../../bin/audlint-maintain.sh#L169)

**Persistent selection and selector UI**

- Stores natural identities and removes selections no longer in the inventory.
  [`sqlite.sh:479`](../../lib/sh/sqlite.sh#L479)

- Renders grouped, bounded rows with recoverable unavailable selections.
  [`audlint-maintain.sh:225`](../../bin/audlint-maintain.sh#L225)

- Shares payload sizing and filter policy with the existing browser transfer.
  [`player.sh:53`](../../lib/sh/player.sh#L53)

**Integration and proof**

- Preserves custom database selection while opening Maintenance from Main.
  [`audlint.sh:5661`](../../bin/audlint.sh#L5661)

- Exercises persistence, mirrors, failures, safety, scrolling, and unusual paths.
  [`test_player_content_creator.py:24`](../../test/test_player_content_creator.py#L24)
