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

The selector loads current `album_quality` rows with nonempty `source_path`, ordered by display artist, `year_int`, `album_norm`, then `id`. Use the validated library-relative source layout for display grouping: albums anywhere under the top-level `_VA` subtree group as `_VA`, while ordinary artist directories retain their current directory-derived labels. Do not change catalog membership, natural identity, stored metadata, source paths, or source-relative synchronization layout. Render a terminal-height scrolling viewport with artist headers and album rows in this form:

```text
Artist
  [ ] 1999 - Album
  [x] 2004 - Another Album
```

Artist headers are visual grouping only and are skipped by the cursor. The footer shows `Up/Down move | Space toggle | Esc+letter jump | w synchronize | q quit` plus the current album position. Up and Down move one album and scroll the viewport; movement stops at the first and last album. Escape followed by an ASCII or Cyrillic letter jumps to the next artist group beginning with that normalized display letter and wraps through repeated matches. Preserve arrow sequences, bare Escape, delayed human input, and unmatched-key no-op behavior. No search, filtering, paging mode, artist-level toggle, transliteration, or second selection hierarchy is added.

On entry, calculate checked album payloads from their current source directories and cache those bytes only for that selector session. Show a sizing state only for the checked set until the current selection size is complete. Size an unchecked available album on demand when it is selected. The preserved right side of the virtual-window title row then shows:

```text
SD: <mounted|not mounted> | Selected: <album-count> | Size: <human-size>
```

`SD: mounted` means the expanded `AUDL_MEDIA_PLAYER_PATH` exists as a directory; an empty, missing, or non-directory path shows `SD: not mounted`. Refresh this presence check on every selector redraw so insertion or removal is visible without reopening. It is informational only and does not imply that the path is writable, safe, or a distinct filesystem.

Any sizing-progress denominator refers to checked albums, never the whole library. After a successful Space toggle, add or subtract the album payload bytes and update the checkbox, count, and right-side status in the same redraw. Deselection therefore reduces the current selection size immediately. Restore the Maintenance title area when `q` returns to its menu; `q` requires no confirmation.

Other than the path-presence check used by the status indicator, the SD card is not read or validated during entry, navigation, sizing, toggle, or quit. Missing or unreadable library album paths are visibly unavailable for selection. If a previously checked source becomes unavailable, retain its checked row in the screen with an error marker, count no unknown bytes as valid capacity, and block `w` until it is unchecked or becomes readable.

## Synchronization and safety

`w` refreshes the checked payload sizes and builds a fresh manifest by joining `player_content_selection` to `album_quality`. Before any deleting command, it must verify all of the following:

- `AUDLINT_LIBRARY_ROOT` and `AUDL_MEDIA_PLAYER_PATH` resolve to existing directories; the library is readable and the player is writable.
- The resolved player path is not empty, `/`, the user home, a broad system or mount root, the repository, the database directory, or the library root; source and destination trees do not contain one another.
- Every checked identity resolves to exactly one current album row, every selected `source_path` resolves to a readable directory strictly below the library root, and every generated destination-relative path stays below the player root.
- `rsync` exists. A missing player path is never created, because absence is treated as an unmounted card.

Any failed check reports the reason and invokes no `rsync` or deletion. Quote paths and escape generated rsync selection rules so normal album names containing spaces or filter metacharacters remain literal.

After preflight, `w` starts synchronization immediately; it is the operator's explicit mirror command and no second confirmation is shown. A zero-album selection is valid and empties the managed player root after the same complete preflight.

Run one manifest-driven `rsync` mirror rooted at the resolved library root and player root. Preserve source-relative album directories. Reuse the current player permission normalization and payload exclusions, enable destination deletion including excluded and unselected paths, show rsync progress in a clean selector-owned region, and flush completed writes with the existing `sync` command. Do not run the source-cleanup behavior from `sync_music.sh`.

Synchronization output must not overlap stale album rows. After success or failure, redraw the selector automatically and show one concise outcome without an `any key Continue` pause.

All destination content is owned by this mirror operation; there is no unmanaged-content exception. A nonzero `rsync` or flush status is reported as synchronization failure, leaves the database selection unchanged, and may leave a partial destination update. Retrying `w` converges the destination to the same checked snapshot.

## Focused acceptance tests

1. Initialize a temporary legacy database and verify `player_content_selection` is created once, its composite key rejects duplicates, creation requests the normal backup refresh, and checked rows survive closing and reopening the selector.
2. From a PTY, press Main `m`, Maintenance `c`, navigate with both arrow sequences and ASCII/Cyrillic Escape-letter jumps, toggle with Space, and quit directly with `q`. Verify nested `_VA` grouping, ordinary artist grouping, jump cycling and wrap, cursor scrolling over more rows than the viewport, no selectable header, persistence of exact natural identities, and compliance with existing Maintenance layout, color, `NO_COLOR`, sizing, and redraw conventions.
3. Load a synthetic inventory of at least 1,600 albums across many artists and verify deterministic artist/album/year ordering, bounded viewport rendering, correct first and last boundaries, and no attempt to render all rows as one terminal page.
4. With empty, missing, existing-directory, and non-directory `AUDL_MEDIA_PLAYER_PATH` fixtures, verify the right-side status changes between `SD: not mounted` and `SD: mounted` on redraw using directory existence only. Verify `C`, Up/Down, Space, live totals, persistence, and `q` work without a player; verify only `w` performs writability and safety preflight.
5. Use album fixtures containing audio, canonical cover art, extra artwork, Audlint sidecars, spaces, and metacharacters. With a small checked subset inside a large inventory, verify initial progress counts checked albums only, final `Size` equals the exact shared transfer payload, and each select/deselect changes count and size immediately by that album byte count.
6. Mirror checked fixtures into a temporary player containing a previously selected but now unchecked album and unrelated extra files. Verify one `w` press updates checked payloads, deletes unchecked and extra destination content, preserves source-relative layout and source files, shows no confirmation or continue prompt, and returns to a clean selector result without mixed album rows.
7. Confirm one `w` press with a zero selection empties only the validated temporary player root. Verify missing, unwritable, broad, overlapping, or escaping destinations and missing, duplicate, unreadable, or escaping selected sources invoke no rsync and delete nothing.
8. Stub `rsync` and `sync` failures and verify nonzero status is visible, selection rows remain unchanged, no success message is shown, and a later successful retry converges the temporary destination.

Run named focused PTY tests and then `python3 -m unittest test.test_player_content_creator` for each child task. Do not run the whole suite between fixes. After all four child fixes are present, run related focused integration modules and then the repository `make check` release gate exactly once from the final synchronization-flow task.
