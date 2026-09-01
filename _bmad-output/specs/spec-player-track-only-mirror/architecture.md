# Architecture and Brownfield Change

## Current state and precedence

`lib/sh/audio.sh` owns the canonical audio extensions. `lib/sh/player.sh` currently sizes a negative payload that includes ordinary non-image files and canonical cover art. `bin/audlint-maintain.sh` appends parent and album rules to rsync argv, while `bin/audlint.sh` runs an album-scoped negative filter that preserves excluded destination files.

This contract follows `SPEC-player-content-filesystem-inventory`. It replaces that spec's payload exclusions, cached-size meaning where membership changes, and browser preservation of excluded files. Filesystem inventory, path-keyed checked state, terminal behavior, source and destination safety, zero-selection flow, retry behavior, and display-only free-space reporting remain unchanged.

## Eligible-track invariant

For a checked album directory `A`, a source path `p` is eligible when all conditions hold:

1. `p` is strictly beneath `A` and remains beneath the resolved library root.
2. `p` is a regular file and not a symlink.
3. No library-relative path component of `p` begins with `.`.
4. Its basename does not begin with `.`.
5. Its final extension matches the canonical `audio.sh` registry under ASCII case folding.
6. The relative path contains no ASCII control character.

Normal nested directories are allowed. A directory named `disc.flac` is not a track. A zero-byte regular track is eligible. Hard-linked paths are independent payload paths and each contributes its logical size. Nested source symlinks and special files are neither followed nor copied. A mounted directory beneath a checked album is a real descendant and is traversed without source mutation.

After successful Player Content synchronization, destination regular-file paths and logical sizes equal the eligible snapshot beneath the checked album paths. No other regular file, symlink, or special object remains. Only required directories remain. Browser success establishes the same invariant inside each requested album destination and makes no claim about untouched player areas.

## Canonical extension API

Refactor `lib/sh/audio.sh` so one registry drives existing and new consumers:

- `audio_track_extensions ARRAY_NAME` fills a caller array with the canonical lowercase extensions.
- `audio_name_has_track_extension BASENAME` performs ASCII-case-insensitive membership testing.
- `audio_collect_files` and `audio_find_iname_args` derive their behavior from the registry rather than retaining parallel lists.

`lib/sh/player.sh` sources this policy and must not copy the extensions into matchers or rsync patterns.

## Snapshot and rule API

Keep reusable mechanics in `lib/sh/player.sh`:

- `player_secure_temp_create LABEL OUT_VAR` creates a mode-restricted artifact outside protected trees.
- `player_track_snapshot_build LIBRARY_ROOT SELECTION_FILE SNAPSHOT_FILE SIZES_FILE` completes a non-following walk, validates every eligible path, records path/type/logical-size rows, detects overlap, duplicates, and ASCII-case collisions, and fails on traversal, readability, `stat`, write, sort, or arithmetic errors.
- `player_track_snapshot_total_bytes SNAPSHOT_FILE` sums the already validated snapshot without walking again.
- `player_rsync_filter_escape_literal PATH` makes one validated relative path literal in rsync filter syntax.
- `player_track_filter_compile SNAPSHOT_FILE RULES_FILE` streams unique parent-directory includes followed by exact regular-file includes and one final exclusion.
- `player_track_snapshot_compare EXPECTED ACTUAL` compares source snapshots without interpreting path text.
- `player_destination_snapshot_build ROOT OWNED_SCOPE OUT_FILE` inventories path, object type, and logical size during explicit transfer verification.
- `player_destination_snapshot_matches SOURCE_SNAPSHOT DEST_SNAPSHOT` proves the owned destination scope contains the intended objects only.

All builders write staging files and expose only complete artifacts. Shell arrays may hold fixed command options but not per-album or per-track rules.

## Ordered rule file

For an eligible snapshot containing two tracks, the generated merge file is equivalent to:

```text
+ /A/
+ /A/Artist/
+ /A/Artist/2001 - Album/
+ /A/Artist/2001 - Album/Disc 1/
+ /A/Artist/2001 - Album/01 Track.FLAC
+ /A/Artist/2001 - Album/Disc 1/02 Track.m4a
- *
```

The real compiler escapes literal rsync metacharacters and preserves deterministic byte ordering under `LC_ALL=C`. It embeds only validated control-safe paths, so the portable line-oriented merge format remains unambiguous.

The Player Content invocation is structurally:

```bash
"$RSYNC_BIN" \
  -r --prune-empty-dirs \
  --delete --delete-excluded \
  --itemize-changes \
  -f ". $rules_file" \
  "$library_real/" "$player_real/"
```

`-r` copies the selected regular-file content and required directory structure without preserving source permissions, timestamps, group, or owner metadata. This deliberately avoids AppleDouble `._*` sidecars on removable filesystems that cannot represent those metadata writes. `--delete-excluded` makes the final exclusion eligible for destination deletion rather than protection. Do not add `--ignore-errors`.

Browser transfer uses the same options and an album-rooted exact rule file for each requested source and destination pair.

## Player Content flow

1. Preserve the existing complete live inventory and checked-state read.
2. Resolve library, player, database directory, repository, and safe temporary locations.
3. Validate the destination and all checked source roots; reject overlapping checked roots.
4. Refresh old-policy cached sizes atomically when the payload policy version differs.
5. Build the ordered checked-path snapshot, eligible-track snapshot, per-album sizes, and exact rule file.
6. Re-read and compare the complete ordered checked-path set; a same-count replacement is a failure.
7. Update cached sizes only from the completed sizes artifact.
8. Revalidate the resolved destination immediately before the destructive call.
9. Run one library-root rsync, then the existing flush command.
10. Rebuild the source snapshot and require equality with the transfer snapshot.
11. Build the destination snapshot and require path/type/logical-size equality.
12. Clean temporary artifacts and report success. Any earlier exit reports its stage, preserves checked paths, and never claims success.

Zero selection follows the same flow. Its valid rule file contains only the final exclusion and empties the validated player root.

## Browser flow

1. Snapshot all requested browser rows before transfer.
2. Require every resolved source to be a readable, non-symlink album strictly beneath the library root.
3. Derive every destination from the validated library-relative path; do not use the metadata-derived fallback.
4. Apply Player Content's full broad-root, overlap, repository, database-directory, existence, and writability checks.
5. Reject exact or ASCII-case-fold destination collisions before the first rsync.
6. Build and size every album snapshot and rule file before the first rsync.
7. Run the album-scoped rsync calls. A failure stops the sequence; earlier albums may already have changed.
8. Run the existing flush once after all rsync calls succeed.
9. Recheck every source snapshot and owned album destination before reporting success.

## Cached-size migration

Use existing `app_meta` with a new `player_payload_policy_version`. On mismatch after trustworthy inventory reconciliation, measure every checked path under the new policy. Update all checked sizes and the version in one transaction only after every measurement succeeds. With no checked rows, record the version without walking albums. Failure preserves prior rows and version and performs no transfer.

No migration step touches player contents. Cleanup begins only from explicit `w` synchronization or browser transfer.

## Alternatives

| Alternative | Decision |
| --- | --- |
| One ordered merge-filter file | Selected. It preserves exact rule order, bounded argv, one global deletion boundary, and explicit browser album scopes. |
| Separate `--include-from` and `--exclude-from` files | Rejected. Parent traversal, exact files, and the terminal exclusion require one ordered stream; using explicit `+` and `-` rows in an include file only disguises a merge filter. |
| `--files-from` alone | Rejected. It represents exact transfer membership but does not reliably delete omitted root content and deselected album trees outside synchronized directories. |
| Album-plus-extension rules | Rejected. They can select a different file set from the completed size snapshot when source files change and make exact membership harder to verify. |
| One global extension allowlist | Rejected because it includes tracks from unchecked albums. |
| Repeated per-album Player Content rsync | Rejected because it cannot remove deselected albums and unrelated root content in one owned mirror. |
| Custom destination deletion | Rejected because it duplicates rsync deletion safety with a second destructive implementation. |
| Source-side `.rsync-filter` files | Rejected because creating them modifies the protected source library. |
| Temporary symlink staging | Rejected because dereferencing can race source replacement, consumes one temporary inode per path, and leaves a larger interrupted-cleanup surface. |

## Code change map

- `lib/sh/audio.sh`: establish the single registry and derive collection, find, and basename matching from it.
- `lib/sh/player.sh`: replace the negative payload policy with snapshot, sizing, literal-filter, temporary-file, rsync-option, and postcondition helpers.
- `lib/sh/sqlite.sh`: own the payload-policy version and atomic checked-size refresh.
- `bin/audlint-maintain.sh`: replace per-album argv arrays with the snapshot compiler and one global rule file while retaining selector and safety flow.
- `bin/audlint.sh`: fail closed on sizing, require library-relative sources, preflight all destinations, use album rule files with excluded deletion, and verify requested scopes.
- `test/test_player_content_creator.py`: replace cover-art payload expectations and extend global mirror, migration, failure, retry, source-stability, and destination-postcondition coverage.
- `test/test_library_browser_smoke.py`: replace exclusion-preservation expectations and cover scoped cleanup, full preflight, source-relative enforcement, collision, and failure behavior.
- Focused helper tests: prove registry derivation, eligibility, sizing-rule parity, literal escaping, bounded generation, and GNU/openrsync semantics.
- `docs/architecture/OVERVIEW.md` and public player-transfer documentation: describe track-only scope after implementation.
- `docs/decisions/0007-ADR-player-track-only-destinations.md`: record the durable payload and ownership policy.
- `docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md`: record the replaceable transfer mechanism.

## Accepted ADR boundaries

[ADR-0007](../../../docs/decisions/0007-ADR-player-track-only-destinations.md) records canonical regular-track eligibility, global versus browser ownership, source immutability, explicit cleanup, and retryable non-atomic destination updates. [ADR-0008](../../../docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md) records exact snapshots, file-backed ordered rules, bounded argv, delete-excluded convergence, and postcondition verification. Exact helper names, test cases, and cache migration remain in this spec rather than the ADR ledger.
