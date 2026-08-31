---
title: 'Filesystem-Authoritative Player Content Inventory'
type: 'feature'
created: '2026-08-31'
status: 'done'
review_loop_iteration: 0
baseline_commit: '5e9e30c88d7a46717fde613bbce579c369f9ca91'
context:
  - '{project-root}/docs/ai/bmad-lite.md'
  - '{project-root}/docs/decisions/0001-ADR-music-library-authority-and-sqlite-state.md'
  - '{project-root}/docs/decisions/0003-ADR-bash5-portability.md'
  - '{project-root}/docs/decisions/0004-ADR-real-resource-verification-safety.md'
  - '{project-root}/docs/decisions/0006-ADR-shell-python-responsibility-boundary.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Player Content currently uses `album_quality` as its inventory. Stale catalog rows and metadata spelling can therefore display unavailable or split entries even when the live library has a different readable layout.

**Approach:** Make one completed filesystem directory inventory authoritative for Player Content membership and labels. Overlay checked state from SQLite by validated library-relative path, cache measured payload bytes, and make synchronization use the same path identity while leaving browser/catalog behavior unchanged.

## Boundaries & Constraints

**Always:** Recognize only `<library>/<index>/<artist>/<album>` and `<library>/_VA/<album>`; treat deeper directories as album content. Derive labels and ordering from validated relative directory names without querying `album_quality`, opening media, or inspecting file types. Replace legacy natural-key selection only after an explicit yes. Complete inventory and directory sizing before writes; purge dropped rows only after a successful nonempty-or-valid inventory. Preserve existing selector navigation, payload exclusions, source-relative mirror layout, `rsync --delete` safety preflight, retry behavior, and display-only SD free-space reporting.

**Ask First:** Stop for any request to touch real libraries, live databases, mounted player destinations, or to add compatibility/staged rollout behavior beyond this contract.

**Never:** Do not migrate or guess old selections, support `_VA/<year>/<album>`, reconcile scanner source paths, rebuild the browser from files, add new payload rules, walk destination contents outside synchronization, or gate synchronization on free space. Do not create `stories.yaml` or run sprint planning.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|-----------------------------|----------------|
| HAPPY_PATH | Readable supported library tree and path-keyed checks | Selector shows current albums, grouped by path-derived headings; SQL count/sum supplies totals; `w` mirrors checked paths | N/A |
| LEGACY_TABLE | Existing natural-key `player_content_selection` | Prompt; yes replaces it once with an empty path/size table; other input leaves it unchanged | Return to Maintenance |
| INVENTORY_ERROR | Traversal error or zero albums with checked rows | Do not render partial inventory or purge rows | Preserve all rows and report reason |
| SIZE_ERROR | Check or synchronization measurement fails | No partial selection/cache update; checked rows remain on sync failure | Report path and concrete reason; return to Maintenance |
| MISSING_CHECKED_PATH | Checked path disappears after entry | Synchronization does not silently uncheck it | Preserve table and report missing path |
| FREE_SPACE | Player root, descendant, missing, or invalid path | Redraw reports filesystem free bytes or unavailable | Never inspect destination contents or reject sync |

</frozen-after-approval>

## Code Map

- `lib/sh/seek.sh:3-47` -- existing NUL-safe directory traversal; extend with a callback inventory that records only the two supported album shapes and propagates traversal errors.
- `lib/sh/player.sh:24-108` -- validated relative paths, payload filtering, payload byte measurement, and human-size labels; reuse these contracts and add any path-key inventory helpers here.
- `lib/sh/sqlite.sh:229-283,479-500` -- schema initialization and natural-key selection writes; replace the selection table atomically, own path/size writes, SQL aggregates, and guarded completed-inventory cleanup.
- `bin/audlint-maintain.sh:135-148,301-400,403-597` -- selector state, status rendering, synchronization safety boundary, and current catalog-backed load; cut over entry, overlay, toggle, free-space query, and `w` flow without weakening preflight.
- `test/test_player_content_creator.py:30-718` -- temporary-fixture PTY coverage for selector, database state, sizing, grouping, mirror, failure preservation, and terminal behavior; update catalog-authority assumptions and add inventory/legacy/free-space regressions.
- `docs/architecture/OVERVIEW.md` and `docs/decisions/0002-ADR-natural-album-identity.md` -- document Player Content’s deliberate path-identity exception while retaining natural catalog identity and browser behavior.

## Tasks & Acceptance

**Execution:**
- [x] `lib/sh/seek.sh`, `lib/sh/player.sh` -- implement complete supported-shape inventory, validation, path-derived display fields, safe sizing, and free-space query helpers -- keep filesystem policy shared and media-free.
- [x] `lib/sh/sqlite.sh` -- replace legacy selection schema and add atomic path-keyed cache writes, aggregates, and fail-closed purge -- keep backup/schema ownership centralized.
- [x] `bin/audlint-maintain.sh` -- load inventory, handle legacy prompt and overlay, render live totals/free space, and synchronize by relative path -- preserve all destructive destination checks.
- [x] `test/test_player_content_creator.py` -- prove filesystem authority, path persistence, legacy refusal/replacement, failure preservation, free space, rename/drop cleanup, and mirror behavior with temporary fixtures.
- [x] `docs/architecture/OVERVIEW.md`, `docs/decisions/0002-ADR-natural-album-identity.md` -- record the cross-component contract and identity exception.

**Acceptance Criteria:**
- Given stale or conflicting catalog rows, when Player Content opens, then only supported readable filesystem album directories appear with deterministic path-derived headings and no media/catalog probing.
- Given a complete inventory, when dropped checked paths are reconciled, then only absent path rows are removed; any traversal error or suspicious empty result preserves every row and returns to Maintenance.
- Given a toggle, when a directory is checked or unchecked, then a complete measurement precedes insertion and the path/size row is inserted or deleted atomically; failures write nothing.
- Given checked path rows, when the selector opens or `w` runs, then count/sum and fresh measurements use path identity only; a failed synchronization preserves checked state and reports its concrete cause.
- Given a configured player root or existing descendant, when the selector redraws, then filesystem free space is informational only and destination contents are never enumerated outside `w`.
- Given an intentional empty checked table, when `w` passes existing safety preflight, then only the validated temporary player mirror is emptied.

## Design Notes

Path identity is a deliberate exception to the catalog’s natural album identity: a directory rename is a dropped checked item plus a new unchecked item. The selector must therefore join the completed live manifest to SQLite by exact validated relative path, not by metadata or `source_path` catalog lookup. Directory byte caches describe the selected source snapshot; they are not a capacity gate or an `rsync` prediction.

## Verification

**Commands:**
- `python3 -m unittest test.test_player_content_creator` -- focused Player Content tests pass using temporary library, database, player, and tool fixtures.
- `python3 -m unittest test.test_audlint_maintain_smoke test.test_library_browser_smoke` -- related Maintenance/browser integration passes after cutover.
- `make check` -- full local release gate passes once near completion.

**Manual checks (if no CLI):**
- Inspect the diff to confirm no real operator paths are accessed, no destination walk occurs outside synchronization, and no `rsync` safety boundary was removed.

## Suggested Review Order

**Entry point and synchronization**

- Start with the live selector and synchronization orchestration.
  [`audlint-maintain.sh:334`](../../bin/audlint-maintain.sh#L334)

- Review completed inventory loading, legacy handling, and path-keyed overlay.
  [`audlint-maintain.sh:443`](../../bin/audlint-maintain.sh#L443)

**Filesystem identity and safety**

- Verify supported directory shapes, labels, control rejection, and root containment.
  [`player.sh:44`](../../lib/sh/player.sh#L44)

- Verify payload measurement and informational free-space behavior.
  [`player.sh:111`](../../lib/sh/player.sh#L111)

- Verify bounded traversal propagates failures without partial inventories.
  [`seek.sh:55`](../../lib/sh/seek.sh#L55)

**SQLite contract**

- Check schema detection and explicit legacy replacement boundaries.
  [`sqlite.sh:229`](../../lib/sh/sqlite.sh#L229)

- Check atomic cached-size updates and completed-inventory stale-row cleanup.
  [`sqlite.sh:546`](../../lib/sh/sqlite.sh#L546)

**Documentation and evidence**

- Confirm the path-identity exception is explicit while catalog identity remains unchanged.
  [`OVERVIEW.md:81`](../../docs/architecture/OVERVIEW.md#L81)

- Review regression coverage for temporary fixtures, mirror safety, rename, and cache refresh.
  [`test_player_content_creator.py:1`](../../test/test_player_content_creator.py#L1)
