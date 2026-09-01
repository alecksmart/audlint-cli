# ADR-0007: Keep Player Destinations Track-Only

## Status
Accepted

## Record type
Contemporary

## Context
Audlint has two player-transfer paths. Player Content synchronizes checked library-relative albums to the complete configured player root, while the browser transfers requested albums to their individual destination subtrees.

The shared payload policy currently excludes known caches and most images, retains canonical cover art, and otherwise permits files it does not recognize. Read-only library evidence supplied for this decision found 22,445 canonical tracks alongside 6,212 hidden-path files, 2,933 images, and 38 other non-track files. The operator requires player destinations to contain tracks only while every excluded source artifact remains untouched.

The completed Player Content filesystem-inventory contract deliberately preserved the former payload rules. Changing those rules therefore requires a follow-on contract rather than a silent edit.

## Decision
Define a player track through the canonical audio-extension policy in `lib/sh/audio.sh`. A player payload may contain only regular, non-symlink files with a canonical extension. Extension matching is ASCII case-insensitive.

Exclude dot-files and every file beneath a hidden directory even when its extension is canonical. Do not follow or copy source symlinks, devices, sockets, FIFOs, or other special objects. Preserve eligible nested track paths relative to their validated source root.

Player Content owns the complete validated player root. A successful synchronization makes that root an exact mirror of eligible tracks beneath the checked album paths and removes all other destination content, including deselected albums.

Browser transfer owns only the requested album destination subtrees. A successful browser transfer makes each requested subtree an exact eligible-track mirror and leaves unrequested album trees unchanged. Browser success does not certify untouched player areas.

Cleanup begins only from an explicit synchronization or transfer action. Installation, selector entry, inventory, and cached-size migration do not delete destination content.

Never delete, rewrite, rename, or create temporary artifacts in the source library. Preserve the current retryable, non-atomic destination model: a failed operation may leave partial destination changes, but it preserves checked paths and a later successful retry converges.

## Evidence
- `lib/sh/audio.sh:8-95` contains Audlint's canonical extension policy.
- `lib/sh/player.sh:102-173` implements the current negative payload matcher, sizing behavior, and rsync exclusions.
- `bin/audlint-maintain.sh:334-443` performs the root-wide Player Content synchronization and destination safety checks.
- `bin/audlint.sh:3628-3954` sizes and transfers browser-selected albums.
- `_bmad-output/specs/spec-player-content-filesystem-inventory/SPEC.md` freezes the former shared payload exclusions while preserving the live inventory and exact-mirror flow.
- `_bmad-output/specs/spec-player-track-only-mirror/SPEC.md` and `architecture.md` contain the approved follow-on contract, scope split, migration behavior, and acceptance boundaries.
- On 2026-09-01, Alec approved the track-only policy and its separation from the transfer-mechanism decision.

## Rationale
A positive definition prevents newly introduced artwork, caches, documents, playlists, archives, and databases from reaching a player merely because no exclusion knows their names. Keeping extension authority in `audio.sh` prevents sizing and transfer entry points from developing competing meanings of track.

Separate ownership scopes preserve the intent of both workflows. Player Content can remove deselected albums because it owns the root. Browser transfer can make requested albums exact without treating an ad hoc browser selection as authority over every other player album.

Explicit transfer remains the destructive boundary, so adopting the policy cannot silently clean an attached player during browsing, migration, or installation.

## Consequences
- The first successful Player Content synchronization removes previously copied images, hidden files, documents, caches, archives, playlists, unrelated files, and deselected albums.
- The first successful browser transfer removes those artifacts only from requested album destinations.
- An intentionally empty checked set empties the validated player root after the full existing preflight.
- A checked album with no eligible tracks contributes zero bytes and no files.
- A regular file with a canonical extension is a track for this policy even if its contents are mislabeled; media probing is not added.
- Browser sources must resolve to safe library-relative destinations rather than falling back to metadata-derived paths.
- Destination free-space reporting remains informational and does not become a capacity gate.
- Current architecture and public usage documentation must continue describing implemented behavior until the follow-on contract is built.

## Alternatives
- Keep the negative filter and add more exclusions. Rejected because unknown future artifacts remain allowed by default.
- Keep canonical cover art as a player payload exception. Rejected because the operator requires track-only destinations.
- Make every browser transfer own the complete player root. Rejected because a browser request is not the durable Player Content selection.
- Probe file contents before treating a canonical extension as a track. Rejected because it adds media inspection to transfer membership and duplicates the established extension authority.
- Clean the player automatically during installation or cache migration. Rejected because it moves destructive behavior outside an explicit transfer action.

## Related decisions
- [ADR-0001: Keep the Music Library Authoritative and Preserve Mixed SQLite State](0001-ADR-music-library-authority-and-sqlite-state.md)
- [ADR-0003: Require Bash 5 with macOS and Linux Portability](0003-ADR-bash5-portability.md)
- [ADR-0004: Keep Automated Verification Away from Real Operator Resources](0004-ADR-real-resource-verification-safety.md)
- [ADR-0006: Prefer the Shell Orchestration and Python Computation Boundary](0006-ADR-shell-python-responsibility-boundary.md)
- [ADR-0008: Compile Player Snapshots into File-Backed Rsync Rules](0008-ADR-player-file-backed-rsync-snapshots.md)
