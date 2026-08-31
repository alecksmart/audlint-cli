---
id: SPEC-player-content-filesystem-inventory
companions:
  - brownfield.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate.

# Player Content Filesystem-Authoritative Inventory

## Why

Player Content currently treats `album_quality` as its inventory, so renamed or removed library paths remain visible as unavailable rows and stored artist variants split one filesystem artist into several headings. On entry, the selector must instead represent what is readable in the library now, overlay the operator's checked paths from SQLite, show their total size, and report SD filesystem free space without inspecting destination contents.

## Capabilities

- **CAP-1**
  - **intent:** The operator can browse a Player Content list built from current readable album directories, grouped and labeled by their validated library-relative paths.
  - **success:** A fixture whose database catalog contains stale or conflicting rows but whose filesystem contains current `<index>/<artist>/<album>` and `_VA/<album>` directories renders only those album-position directory names under path-derived headings; no file, tag, codec, or media metadata is opened to decide membership or labels, and ordering plus jump behavior remains deterministic.

- **CAP-2**
  - **intent:** The operator's checked directories and their latest measured directory sizes persist by validated library-relative path without making the quality catalog part of Player Content identity.
  - **success:** Every check completely measures the directory before inserting its path and size, every uncheck deletes that row, and reopening obtains the selected count and total through SQL aggregates without remeasuring; any measurement failure writes nothing and returns to Maintenance with the path and reason, while dropped rows are purged only after a complete trustworthy inventory.

- **CAP-3**
  - **intent:** The operator can mirror the checked live filesystem paths to the player without resolving selection through `album_quality`.
  - **success:** One `w` validates and remeasures every checked directory, updates cached sizes, and produces the same source-relative mirror and deletion behavior without querying `album_quality`; a disappeared checked path, preflight failure, `rsync` failure, or flush failure preserves checked state, reports its available concrete reason, invokes no further operation, and returns to Maintenance.

- **CAP-5**
  - **intent:** The operator can see available space on the configured SD filesystem independently of the current Player Content selection.
  - **success:** Each selector redraw reports current free space for the filesystem containing the configured player path, whether that path is the volume root or an existing descendant, and reports it as unavailable otherwise, without walking, comparing, or inferring anything from destination contents.

## Constraints

- Use a completed filesystem directory inventory as Player Content membership authority. The only selectable shapes are `<library>/<index>/<artist>/<album>` and `<library>/_VA/<album>`; directories below the album position are content, not separate entries, and `_VA/<year>/<album>` is unsupported.
- Derive membership and display only from relative directory positions and names; do not parse formatted `tree` output, query the quality catalog, inspect file types, or open media during inventory.
- Key Player Content state by a control-safe, validated path relative to the resolved library root. A rename is a dropped old item plus a new unchecked item; do not guess continuity from metadata.
- Purge dropped checked entries only after the library root is verified readable and the complete traversal succeeds. Any traversal error preserves all checked rows, warns, and returns to Maintenance without rendering a partial selector.
- If traversal yields zero albums while checked rows exist, treat the result as suspicious: preserve the table, warn, skip cleanup, and return to Maintenance.
- When a legacy natural-key Player Content table is detected, ask whether to delete it. An explicit yes replaces it once with an empty path-keyed table and continues; any other answer changes nothing and returns to Maintenance. Do not migrate or guess old checks; normal database backup-refresh behavior still applies.
- A check always measures the directory before inserting its path and cached byte size; an uncheck deletes it. Selector entry uses SQL `COUNT` and `SUM` only, while synchronization remeasures all checked directories and updates the cache before copying.
- Complete size measurement before opening a database transaction. Any disappeared path, unreadable content, or measurement error writes nothing, reports the checked directory and concrete reason, and returns to Maintenance.
- Treat cached directory bytes as a source-directory snapshot for the selected total, not as a prediction of bytes written by `rsync`.
- Preserve the shared payload exclusions, source-relative destination layout, fixed-row terminal behavior, `_VA` grouping, ASCII and Cyrillic jumps, live selected count and size, direct `w`/`q` flow, retry behavior, and all destructive destination checks.
- Outside explicit synchronization, player-path access is limited to a filesystem free-space query. Do not enumerate, compare, or infer selection from destination contents.
- SD free space is display-only; do not accept or reject synchronization by comparing it with selected size.
- If a checked directory disappears after selector entry, synchronization preserves the table, reports the missing path, and returns to Maintenance. A later successful selector entry performs normal dropped-row cleanup.
- An intentionally empty checked table followed by `w` remains an explicit request to empty the managed player destination after the complete existing safety preflight.
- Apply inventory, legacy-table replacement, selector overlay, total sizing, and synchronization identity as one atomic change; there is no staged deployment or supported mixed-identity runtime.
- Keep the browser and quality catalog database-backed; this change does not repair or otherwise alter catalog reconciliation.
- Automated verification uses temporary libraries, databases, and player destinations only.

## Non-goals

- Rebuilding the browser from the filesystem or making the rest of SQLite disposable.
- Preserving selection automatically across directory renames, metadata changes, duplicate releases, or guessed path matches.
- Preserving or migrating rows from the legacy natural-key Player Content table.
- Supporting `_VA/<year>/<album>` or inferring additional library layouts.
- Adding search, paging, artist-level selection, background sync, transfer history, or new payload rules.
- Inventorying, comparing, cleaning, or otherwise reporting current SD contents outside explicit synchronization.
- Repairing existing live catalog rows or operating on a real library as part of implementation or automated verification.

## Success signal

With stale Jarre-like catalog fixtures and one renamed live artist directory, Player Content shows only the two supported live directory shapes, overlays path-keyed checks, obtains the selected total from cached table rows, reports independent free space for either an SD root or descendant path, and mirrors exactly the checked directories safely. Legacy-table refusal, incomplete or suspiciously empty inventory, sizing failure, disappeared checked paths, and synchronization failure preserve state, explain the problem, and return to Maintenance; focused and repository gates pass without touching real operator resources.
