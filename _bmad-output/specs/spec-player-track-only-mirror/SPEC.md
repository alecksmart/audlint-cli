---
id: SPEC-player-track-only-mirror
companions:
  - architecture.md
  - failure-modes.md
  - verification.md
  - ../spec-player-content-filesystem-inventory/SPEC.md
  - ../spec-player-content-filesystem-inventory/brownfield.md
  - ../../../docs/decisions/0007-ADR-player-track-only-destinations.md
  - ../../../docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate.

# Player Track-Only Exact Mirror

## Why

Player transfers currently use a negative filter that retains cover art and permits unknown files, while Player Content builds one rsync argument group per checked album. The observed library contains 22,445 canonical tracks but more than 9,000 hidden-path and image files. Player destinations must instead contain only tracks, use bounded transfer arguments, and remove legacy destination artifacts without changing their source copies.

## Capabilities

- **CAP-1**
  - **intent:** Every player transfer uses one shared positive definition of an eligible track.
  - **success:** Sizing and transfer fixtures select the same regular, non-hidden files through the canonical `lib/sh/audio.sh` extension policy, with no duplicated extension list or media probing.

- **CAP-2**
  - **intent:** The operator can synchronize checked Player Content albums as an exact track-only mirror of the validated player root.
  - **success:** One successful synchronization preserves source-relative paths and leaves only the checked snapshot tracks and their required directories, deleting legacy artifacts, unrelated files, and deselected albums; an empty checked set leaves the validated root empty.

- **CAP-3**
  - **intent:** The operator can transfer browser-selected albums as exact track-only album subtrees without changing other player albums.
  - **success:** Every requested album destination contains exactly its eligible source tracks after success, excluded destination files are removed, unrequested album trees are unchanged, and all requested sources and destinations pass complete preflight before the first transfer.

- **CAP-4**
  - **intent:** The operator receives a trustworthy result and can retry safely after any failure.
  - **success:** Success is reported only after snapshot sizing, ordered-rule generation, rsync, flush, source-stability comparison, and destination postcondition verification all succeed; every failure preserves checked paths, reports its stage, and a later successful retry converges.

## Constraints

- This follow-on replaces only the payload, sizing-membership, rule-generation, and browser excluded-file behavior in `SPEC-player-content-filesystem-inventory`; every other inventory, selection, UI, safety, retry, and free-space clause remains in force.
- `lib/sh/audio.sh` is the only extension authority. Player eligibility adds regular-file, non-symlink, non-hidden-path, and control-safe-path requirements without probing content.
- Extension matching is ASCII case-insensitive. Other path bytes remain literal; normal nested directories are supported, and source symlinks and special files are never followed or copied.
- Build one exact eligible-track snapshot and derive both byte totals and exact ordered rsync rules from it. Stream manifests and rules through secure temporary files; rsync argv must not grow with album or track count.
- Temporary artifacts must have restrictive permissions, checked writes, deterministic cleanup, and locations outside the library, player, repository, and database directory.
- Player Content owns the complete validated player root. Browser transfer owns only requested album subtrees, requires library-relative sources, and uses the same disjoint destructive-destination checks before creating or deleting anything.
- Successful convergence uses deletion of excluded destination content. No install, selector-entry, or cache-migration step may clean the player automatically.
- Never delete, rewrite, rename, or create temporary content in the source library. Preserve the current non-atomic destination failure model: a failed command may leave partial destination changes, and retry must reconverge.
- A payload-policy version in existing `app_meta` atomically refreshes checked cached sizes before old-policy values are trusted. A failed refresh preserves rows and the prior version.
- Preserve zero-selection emptying, checked-state persistence, retry behavior, display-only free-space reporting, and failure on unsafe destinations or unavailable tools.
- Preserve Bash 5 and macOS/Linux portability. Automated verification uses temporary libraries, databases, player destinations, and tool fixtures only.
- Preserve accepted ADR-0007 for the track-only destination contract and accepted ADR-0008 for the compiled file-backed rsync mechanism.

## Non-goals

- Media probing, transcoding, playlists, capacity enforcement, background synchronization, destination inspection outside explicit transfer, atomic destination swaps, or independent byte-integrity verification.
- Changing Player Content inventory shapes, checked-path identity, browser catalog identity, terminal interaction, or the full-library `sync_music.sh` workflow.
- Preserving images, hidden files, documents, caches, databases, archives, or other unmanaged content in an owned destination scope.

## Success signal

Against temporary fixtures containing selected and deselected albums, nested mixed-case tracks, images, hidden caches, documents, special files, and legacy player content, Player Content leaves only selected tracks while browser transfer cleans only requested albums. Source fixtures remain unchanged, argv stays bounded for a large selection, cached sizes match the transfer snapshot, and every injected failure reports failure without losing checked paths.
