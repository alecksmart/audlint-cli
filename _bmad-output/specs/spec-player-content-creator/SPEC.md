---
id: SPEC-player-content-creator
companions:
  - player-content-contract.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability only.

# Player Content Creator

## Why

The operator needs the music carried on a capacity-limited SD player to be an intentional, persistent subset of the Audlint library rather than a series of one-off transfers. The selected total must stay visible while editing so the operator can fit the collection to the card, and synchronization must remove unchecked content so the card matches that selection. The same top status area must show whether the SD card path configured by `AUDL_MEDIA_PLAYER_PATH` currently exists, so card presence is visible before synchronization is attempted.

## Capabilities

- **CAP-1**
  - **intent:** The operator can maintain a persistent album selection, see its live total transfer size, and synchronize the configured SD player to exactly that selection from Maintenance mode.
  - **success:** From `M` then `C`, the operator can navigate the existing album library, toggle albums without an attached player, see the right-side top status show SD-path presence and update the selected total after each toggle, quit and reopen without losing the selection, and use `w` with an attached player to copy checked albums and delete all unchecked destination content.

## Constraints

- This is one bounded capability. Use the existing Audlint SQLite database, Maintenance virtual window, natural album identity, library and player paths, player payload rules, and `rsync` conventions as specified in `player-content-contract.md`.
- Reuse established shared components and libraries. Extract or create a reusable helper only where this feature introduces a second concrete consumer or an existing shared responsibility; do not generalize for hypothetical future needs.
- Keep the selector UI consistent with existing Audlint Maintenance and virtual-window layout, title status, hints, colors and `NO_COLOR`, terminal sizing, and input behavior.
- Synchronization treats the configured player path as fully managed: after explicit confirmation, content outside the checked snapshot is deleted, including when the snapshot is empty.
- Browsing and toggling must work without the SD card. Synchronization must fail before invoking `rsync` unless every selected source and the existing destination pass the path and access checks in the companion.
- Preserve Bash 5 and macOS/Linux portability. Selection sizing and synchronization must not modify source-library files.
- Automated verification uses temporary library, SQLite, player, and tool fixtures only; it must not access a real music library, live database, mounted destination, or destructive media workflow.

## Non-goals

- Enforcing card capacity, probing free space, or choosing albums automatically.
- Supporting multiple saved selections, multiple player profiles, playlists, tracks below album granularity, transcoding, or format conversion.
- Changing `sync_music.sh`, `AUDL_SYNC_DEST`, the existing browser transfer action, album scanning, or album identity rules.
- Providing a transactional or rollback-capable SD-card update.

## Success signal

A temporary-fixture demonstration shows SD-path presence in the right-side status, selects and deselects albums while the total changes by the exact transfer payload bytes, persists that selection across selector sessions without a player, and then mirrors a temporary player directory so it contains only the checked album payloads.
