# Player Content Creator Contract

## Existing contracts to reuse

- `lib/sh/sqlite.sh` remains the only schema lifecycle owner. `bin/audlint-maintain.sh` owns the selector because entry is Main `M` to Maintenance `C`.
- Direct Maintenance runs resolve `AUDL_DB_PATH`, falling back to `$AUDL_PATH/library.sqlite`; `bin/audlint.sh` passes its resolved `DB_PATH` as `AUDL_DB_PATH` when launching Maintenance so `--db` overrides remain exact.
- Album identity remains `(artist_lc, album_lc, year_int)`. `id` and `source_path` are not selection identities.
- Extract the current player relative-path, payload-inclusion, byte-total, and human-size behavior from `bin/audlint.sh` into a focused shared `lib/sh/player.sh` used by both the existing transfer action and this selector. Preserve current transfer behavior while moving it.
- The payload includes normal album files and canonical `cover.jpg` or `cover.jpeg`; it excludes Audlint cache sidecars and noncanonical image files exactly as the existing player transfer does. The displayed total is the byte sum of this payload, not raw directory allocation.
- Reuse the existing virtual-window title row, Maintenance menu buttons, terminal input, color and `NO_COLOR`, sizing, and redraw conventions. Extend a shared UI helper when both the existing interface and this selector need the same behavior; keep selector-only rendering local.

## Minimal database change

Add this table through the existing idempotent database initializer:

```sql
CREATE TABLE IF NOT EXISTS player_content_selection (
  artist_lc TEXT NOT NULL,
  album_lc TEXT NOT NULL,
  year_int INTEGER NOT NULL,
  PRIMARY KEY (artist_lc, album_lc, year_int)
);
```

Row presence means checked; row absence means unchecked. Do not add copied artist or album labels, paths, byte totals, timestamps, player identifiers, or synchronization state. The primary key supplies the only required index.

Creating the table counts as a schema change for the existing database-backup refresh. When a writable selector opens, delete selection rows that no longer match an `album_quality` natural identity; an identity change represents a different album and is not guessed from `source_path`.

A Space toggle is one SQLite statement: insert the natural key with conflict ignored when checking, or delete the exact natural key when unchecking. Redraw only after the statement succeeds. A missing or non-writable database makes `C` unavailable with a clear message; it does not produce an in-memory selection that would be lost.

## Selector behavior

Maintenance always shows `[c Player Content Creator]` when its database path can be resolved; player attachment does not control this entry.

The selector loads current `album_quality` rows with nonempty `source_path`, ordered by `artist_norm`, `album_norm`, `year_int`, then `id`. Render a terminal-height scrolling viewport with artist headers and album rows in this form:

```text
Artist
  [ ] 1999 - Album
  [x] 2004 - Another Album
```

Artist headers are visual grouping only and are skipped by the cursor. The footer shows `Up/Down move | Space toggle | w synchronize | q quit` plus the current album position. Up and Down move one album and scroll the viewport; movement stops at the first and last album. No search, filtering, paging mode, artist-level toggle, or second selection hierarchy is added.

On entry, calculate each album payload once from its current source directory and cache the bytes only for that selector session. Show a sizing state until the first complete total is available. The preserved right side of the virtual-window title row then shows:

```text
SD: <mounted|not mounted> | Selected: <album-count> | Total: <human-size>
```

`SD: mounted` means the expanded `AUDL_MEDIA_PLAYER_PATH` exists as a directory; an empty, missing, or non-directory path shows `SD: not mounted`. Refresh this presence check on every selector redraw so insertion or removal is visible without reopening. It is informational only and does not imply that the path is writable, safe, or a distinct filesystem.

After a successful Space toggle, add or subtract the cached album bytes and update the checkbox, count, and right-side status in the same redraw. Deselection therefore reduces the total immediately. Restore the Maintenance title area when `q` returns to its menu.

Other than the path-presence check used by the status indicator, the SD card is not read or validated during entry, navigation, sizing, toggle, or quit. Missing or unreadable library album paths are visibly unavailable for selection. If a previously checked source becomes unavailable, retain its checked row in the screen with an error marker, count no unknown bytes as valid capacity, and block `w` until it is unchecked or becomes readable.

## Synchronization and safety

`w` refreshes the checked payload sizes and builds a fresh manifest by joining `player_content_selection` to `album_quality`. Before any deleting command, it must verify all of the following:

- `AUDLINT_LIBRARY_ROOT` and `AUDL_MEDIA_PLAYER_PATH` resolve to existing directories; the library is readable and the player is writable.
- The resolved player path is not empty, `/`, the user home, a broad system or mount root, the repository, the database directory, or the library root; source and destination trees do not contain one another.
- Every checked identity resolves to exactly one current album row, every selected `source_path` resolves to a readable directory strictly below the library root, and every generated destination-relative path stays below the player root.
- `rsync` exists. A missing player path is never created, because absence is treated as an unmounted card.

Any failed check reports the reason and invokes no `rsync` or deletion. Quote paths and escape generated rsync selection rules so normal album names containing spaces or filter metacharacters remain literal.

After preflight, show a confirmation containing the resolved destination, selected album count, refreshed total size, and the statement `All player content not in this selection will be deleted.` Only `y` proceeds; any other key cancels without changing source, destination, or selection. A zero-album selection uses the same confirmation and, when accepted, empties the managed player root.

Run one manifest-driven `rsync` mirror rooted at the resolved library root and player root. Preserve source-relative album directories. Reuse the current player permission normalization and payload exclusions, enable destination deletion including excluded and unselected paths, show rsync progress in the Maintenance window, and flush completed writes with the existing `sync` command. Do not run the source-cleanup behavior from `sync_music.sh`.

All destination content is owned by this mirror operation; there is no unmanaged-content exception. A nonzero `rsync` or flush status is reported as synchronization failure, leaves the database selection unchanged, and may leave a partial destination update. Retrying `w` converges the destination to the same checked snapshot.

## Focused acceptance tests

1. Initialize a temporary legacy database and verify `player_content_selection` is created once, its composite key rejects duplicates, creation requests the normal backup refresh, and checked rows survive closing and reopening the selector.
2. From a PTY, press Main `m`, Maintenance `c`, navigate with both arrow sequences, toggle with Space, and quit with `q`. Verify artist grouping, cursor scrolling over more rows than the viewport, no selectable header, persistence of the exact natural identities, and compliance with existing Maintenance layout, hint, color and `NO_COLOR`, sizing, and redraw conventions.
3. Load a synthetic inventory of at least 1,600 albums across many artists and verify deterministic artist/album/year ordering, bounded viewport rendering, correct first and last boundaries, and no attempt to render all rows as one terminal page.
4. With empty, missing, existing-directory, and non-directory `AUDL_MEDIA_PLAYER_PATH` fixtures, verify the right-side status changes between `SD: not mounted` and `SD: mounted` on redraw using directory existence only. Verify `C`, Up/Down, Space, live totals, persistence, and `q` work without a player; verify only `w` performs writability and safety preflight.
5. Use album fixtures containing audio, canonical cover art, extra artwork, Audlint sidecars, spaces, and metacharacters. Verify the initial total equals the exact shared transfer payload and each select/deselect changes the right-side `Selected` count and `Total` immediately by that album byte count.
6. Mirror checked fixtures into a temporary player containing a previously selected but now unchecked album and unrelated extra files. After the explicit `y` confirmation, verify checked payloads are updated, unchecked and extra destination content is deleted, source-relative layout is preserved, and source files are unchanged.
7. Confirm a zero selection empties only the validated temporary player root after `y`; cancellation leaves it unchanged. Verify missing, unwritable, broad, overlapping, or escaping destinations and missing, duplicate, unreadable, or escaping selected sources invoke no rsync and delete nothing.
8. Stub `rsync` and `sync` failures and verify nonzero status is visible, selection rows remain unchanged, no success message is shown, and a later successful retry converges the temporary destination.

Run the focused SQLite and Maintenance PTY tests first. Near completion, run the repository release gate once as required by BMAD Lite.
