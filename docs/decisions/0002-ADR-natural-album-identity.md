# ADR-0002: Use Normalized Natural Album Identity

## Status
Accepted

## Record type
Recovered

## Context
Discovery, scan queues, catalog upserts, browser rows, and durable player selections need one shared album identity. The implemented identity is metadata-derived and is separate from the album's current filesystem location.

## Decision
Identify an album by `(artist_lc, album_lc, year_int)`. Derive the values from the first recognized track, prefer `album_artist` to track artist, fall back to directory names when tags are absent, and store `0` when no valid year is available.

Keep `source_path` indexed but non-unique. When metadata changes the identity associated with one path, remove stale catalog keys for that path before recording the current identity.

## Evidence
- `docs/architecture/OVERVIEW.md:83-87` states the current identity contract.
- `lib/sh/ffprobe.sh:3-65` extracts the first-track identity, prefers album artist, and implements directory fallbacks.
- `lib/sh/sqlite.sh:235-268,277-282,350-358,779-817` defines the natural keys, unique index, selection key, non-unique path index, and conflict upsert.
- `bin/audlint-task.sh:1039-1065,1097-1127,1252-1267` queues by normalized identity and prunes stale keys for a source path.
- `test/legacy/test_legacy_audlint_task_db.py:650-732` proves that a changed year rekeys one source path and drains duplicate queued work.

## Rationale
The comment at `lib/sh/ffprobe.sh:32-34` states that preferring album artist prevents compilations from being keyed under the first track's artist. The comments at `bin/audlint-task.sh:1054-1062` state that stale-key pruning keeps one canonical identity per path and prevents duplicate scans. Original rationale is not recoverable from repository evidence.

## Consequences
- Album identity is shared across discovery, catalog rows, and durable player selection.
- Moving an album does not inherently require a new identity.
- A metadata identity change replaces the stale key for that path.
- Distinct physical releases with the same normalized artist, album, and year cannot coexist as separate natural-key catalog rows.

## Alternatives
None recovered from repository evidence.

## Related decisions
- [ADR-0001: Keep the Music Library Authoritative and Preserve Mixed SQLite State](0001-ADR-music-library-authority-and-sqlite-state.md)
