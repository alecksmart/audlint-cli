# ADR-0001: Keep the Music Library Authoritative and Preserve Mixed SQLite State

## Status
Accepted

## Record type
Recovered

## Context
Audlint operates on a local music library and maintains a SQLite catalog. Current code and documentation distinguish authority for media content from operational state: files and embedded metadata define the media, while SQLite combines derived scan results with state that a rescan cannot fully reproduce.

## Decision
Audio files, embedded tags, artwork, and album layout are authoritative for media content. SQLite is the operational catalog for derived scan and browser data, persisted work queues, operator-managed state, player selections, and fetched lyrics outcomes.

File mutations change the library directly. Maintenance reconciles derived catalog state afterward, but the database must not be treated as disposable because some of its state is not reconstructible from the library.

## Evidence
- `README.md:18` calls the local library the source of truth.
- `docs/architecture/OVERVIEW.md:9,55-63,72-79` separates media authority from mixed database state and documents reconciliation after file mutation.
- `lib/sh/sqlite.sh:235-282` stores derived quality fields, flags and notes, and an intentionally durable `player_content_selection` table.
- `lib/sh/lyrics.sh:17-40` persists fetched and not-found lyrics outcomes.
- `lib/sh/sqlite.sh:985-1012` integrity-checks and rotates database backup bundles.
- `test/test_player_content_creator.py:119-130,381-397` proves that player selection persists, including across failed synchronization attempts.

## Rationale
The current browser and scanner require an operational catalog, while player selection and fetched or operator-managed state must survive routine rescans. Original rationale is not recoverable from repository evidence.

## Consequences
- Media analysis and maintenance read authority from the library rather than treating catalog rows as media truth.
- Derived rows may be reconciled after direct file mutations.
- Database reset or loss can also lose selections, flags, notes, and cached lyrics; schema migration and database backup remain architectural concerns.
- Callers must distinguish rebuildable scan data from durable database state.

## Alternatives
None recovered from repository evidence.

## Related decisions
- [ADR-0002: Use Normalized Natural Album Identity](0002-ADR-natural-album-identity.md)
