# Brownfield Boundary and Verification

## Current failure

`player_content_creator` selects every `album_quality` row with a source path. It derives a directory heading only when that stored path is currently readable; otherwise it keeps database artist text and marks the row unavailable. A renamed artist directory therefore leaves stale albums in the list and can split headings by metadata spelling.

## Target data boundary

- Maintenance `C` performs one ordered flow: complete the live directory-name inventory, reconcile and overlay checked table rows, obtain `COUNT(*)` and `SUM(size_bytes)`, then render the selector with selected totals and SD free space.
- The inventory walk recognizes only `<library>/<index>/<artist>/<album>` and `<library>/_VA/<album>`. It resolves each album-position directory beneath the library root and carries its relative path, source path, path-derived artist heading, directory-derived year/title, and stable sort values without opening or classifying files; deeper directories are content and `_VA/<year>/<album>` is out of scope.
- If traversal reports any error, or returns zero albums while checked rows exist, preserve the table, warn, and return to Maintenance without rendering or cleanup.
- When the legacy natural-key selection table is detected, prompt before deleting it. Explicit yes replaces it once with an empty table containing checked relative paths and cached directory byte sizes; any other input leaves it intact and returns to Maintenance. There is no conversion or dual-write path.
- Checking measures that source directory at that moment and inserts its relative path and size. Unchecking deletes it. Rechecking after source files change therefore stores a new size without any selector-entry refresh pass.
- Complete measurement before any database write. A disappeared path, unreadable content, or sizing error leaves the table unchanged, reports the path and reason, and returns to Maintenance.
- Reconciliation deletes checked paths absent from the completed inventory in one guarded transaction. If the tree is unavailable or cannot be read completely, keep every database row, report the error, and return to Maintenance without showing a partial selector.
- Synchronization joins checked state to the fresh inventory by relative path, remeasures every checked directory and updates cached sizes, then repeats source containment, readability, destination containment, tool availability, and exact-mirror checks before deletion-capable `rsync`.
- Selector redraws query only available bytes on the filesystem containing the configured destination path. The path may be the SD volume root or any existing descendant; redraws do not walk or compare destination files, and `rsync` alone converges destination contents after `w` passes preflight.
- Any synchronization failure retains checked rows, reports the most concrete available preflight or command reason, and exits Player Content to Maintenance rather than redrawing the selector.
- A checked path missing at synchronization is a failure, not an implicit selection change; preserve the table and let the next successful selector entry perform dropped-row cleanup.
- Free space is informational only. Do not perform a capacity gate; an intentionally empty checked table plus `w` still empties the managed destination after full preflight.
- Inventory, table replacement, selector, and synchronization switch together. No compatibility mode, feature flag, or staged rollout is required for the current single-machine use.

## Change map

- `lib/sh/seek.sh` and `lib/sh/player.sh`: reuse or minimally extend directory walking, relative-path validation, display grouping, directory sizing, and mirror filtering without media probing during inventory.
- `lib/sh/sqlite.sh`: replace the legacy table, own the path-keyed Player Content schema, checked-state writes, cached-size updates, SQL aggregates, and completed-inventory purge transaction.
- `bin/audlint-maintain.sh`: load the selector from live inventory, merge checked/cache state by relative path, preserve responsive rendering, report SD free space, and synchronize from fresh inventory rather than `album_quality`.
- `test/test_player_content_creator.py`: replace database-only unavailable inventory assumptions with filesystem authority, intentional legacy-table replacement, cache, purge-fail-closed, free-space, and live-manifest regressions while retaining terminal and destructive-safety coverage.
- Accepted architecture and Player Content contract documentation: record that Player Content path identity is a deliberate exception to catalog natural identity while browser/catalog behavior remains unchanged.

## Focused proof

1. Inventory fixtures prove the two supported shapes, exclusion of nested `_VA` and directories below albums, unusual directory names, control characters, symlink escape rejection, deterministic ordering, and no catalog or media probing. Traversal failure and suspicious zero inventory preserve checked rows and return to Maintenance.
2. State fixtures prove the legacy-table yes/no prompt, intentional legacy-row loss only after yes, exact path-key persistence, fresh complete measurement on every check, no write on sizing failure, delete on uncheck, SQL aggregate totals on entry, and rename-as-drop cleanup only after successful inventory.
3. Sync fixtures prove checked relative paths create the same filtered exact mirror, refreshed source sizes are stored, zero selection still empties only a validated temporary player, and every unsafe destination, disappeared checked path, disk-space, `rsync`, and flush failure reports a reason, preserves rows, and returns to Maintenance without unsafe operation.
4. Free-space fixtures prove volume-root, deeper-directory, missing, non-directory, and query-failure states without enumerating destination contents or coupling the value to selected size.
5. Run the focused Player Content module while iterating, related Maintenance/browser integration once after cutover, and `make check` once at the end.
