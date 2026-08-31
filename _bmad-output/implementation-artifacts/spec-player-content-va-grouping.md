---
title: 'Player Content Creator `_VA` Display Grouping'
type: 'bugfix'
created: '2026-08-31'
status: 'done'
baseline_commit: 'fb2c4ebe189f500f7f0568eaedd423affdef02d4'
review_loop_iteration: 0
context:
  - 'docs/decisions/0001-ADR-catalog-identity.md'
  - 'docs/decisions/0003-ADR-bash5-portability.md'
  - 'docs/decisions/0004-ADR-real-resource-verification-safety.md'
  - 'docs/decisions/0006-ADR-shell-python-responsibility-boundary.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Albums in `_VA/<year>/<album>` are cataloged but the selector labels them with the intermediate year directory. This fragments one Various Artists inventory and makes it look incomplete.

**Approach:** Change only the validated source-layout display-label rule: every album below the library root’s top-level `_VA` directory displays under `_VA`. Retain immediate-parent grouping for ordinary artist layouts and leave catalog and synchronization data untouched.

## Boundaries & Constraints

**Always:** Preserve selection identity `(artist_lc, album_lc, year_int)`, stored catalog fields, deterministic selector ordering, ordinary artist-directory labels, and source-relative synchronization destinations. Derive labels only from source paths proven to be below `AUDLINT_LIBRARY_ROOT`. Use temporary fixtures and the existing PTY unittest helper.

**Ask First:** Stop if fixture evidence shows the selector does not obtain the incorrect heading through `player_artist_directory_label_from_source`, because fixing scanner or database behavior is outside this task.

**Never:** Do not alter scanner discovery, database schema, source paths, album metadata or identities, selector navigation/layout, synchronization behavior/layout, or real library/player/database resources. Do not run `make check`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Nested VA album | Valid `_VA/2002/Album` source directory | Selector shows artist header `_VA`, never `2002` | Existing valid-path behavior |
| Direct VA album | Valid `_VA/Album` source directory | Selector shows artist header `_VA` | Existing valid-path behavior |
| Ordinary album | Valid `Artist/Album` source directory | Selector retains `Artist` directory header | Existing valid-path behavior |
| Invalid or escaping source | Missing, unavailable, or outside library root | Existing unavailable/no-label behavior is unchanged | No new fallback label |

</frozen-after-approval>

## Code Map

- `lib/sh/player.sh:26-37` — `player_relative_album_path_from_source` is the shared, symlink-safe library-relative source validator; reuse its result rather than re-resolving paths.
- `lib/sh/player.sh:38-49` — `player_artist_directory_label_from_source` currently returns the immediate parent of a validated album path, producing a year heading for nested `_VA` albums. This is the narrow change point.
- `bin/audlint-maintain.sh:401-425` — `player_content_creator` obtains the display directory label, replaces only transient `artist`/`artist_norm` arrays, and then sorts selector rows. It does not persist these labels.
- `test/test_player_content_creator.py:28-91` — temporary database, library fixture, and PTY harness used for selector regression coverage; no real resources are touched.
- `test/test_player_content_creator.py:111-140` — directory-label and selection-persistence test pattern to preserve ordinary grouping and natural-key identity while adding `_VA` proof.
- `_bmad-output/specs/spec-player-content-va-grouping/SPEC.md` and companions `brownfield.md`, `../spec-player-content-creator/player-content-contract.md` — canonical contract and required focused verification sequence.

## Tasks & Acceptance

**Execution:**
- [x] `test/test_player_content_creator.py` — added a named, temporary-fixture PTY regression test with direct and nested `_VA` albums plus an ordinary artist; it proved the prior `2002` heading, then the corrected single `_VA` heading, selection natural key, ordered display, source-relative destination, and invalid-source behavior.
- [x] `lib/sh/player.sh` — updated the validated source-directory display-label helper so a library-relative path whose first component is exactly `_VA` returns `_VA`; ordinary immediate-parent results and invalid-path rejections remain intact.

**Acceptance Criteria:**
- Given cataloged, readable sources at `_VA/Album`, `_VA/2002/Album`, and `Artist/Album`, when the selector renders in its PTY fixture, then one `_VA` header contains both compilation albums, no `2002` artist header appears, and `Artist` remains an ordinary header.
- Given a toggled nested `_VA` row, when the selector exits, then `player_content_selection` contains its existing `(artist_lc, album_lc, year_int)` tuple and no catalog identity or source path is modified.
- Given a nested `_VA` source, when its synchronization destination is derived, then it remains source-relative (`_VA/2002/Album`) rather than using the display label.
- Given a source outside the library root or with no artist-directory component, when the helper is used, then it remains unlabeled/unavailable as before.

## Spec Change Log

## Design Notes

The selector already treats the helper result as a transient display override, then retains the database natural key and source path in parallel arrays. Therefore the helper is the smallest safe boundary: it can recognize the namespace after existing safe path validation without changing storage, ordering tie-breakers, or transfer path derivation.

## Verification

**Commands:**
- `python3 -m unittest test.test_player_content_creator.PlayerContentCreatorTests.test_nested_va_grouping_uses_one_va_heading` — expected: fails before the helper change because `2002` appears as an artist header, then passes after it.
- `python3 -m unittest test.test_player_content_creator` — expected: all focused Player Content Creator tests pass; do not run the repository-wide release gate.

## Suggested Review Order

**Display grouping boundary**

- Reuses existing validated relative paths to group the reserved namespace safely.
  [`player.sh:42`](../../lib/sh/player.sh#L42)

**PTY regression proof**

- Exercises direct and nested compilations, ordinary artists, selection persistence, and destination preservation.
  [`test_player_content_creator.py:159`](../../test/test_player_content_creator.py#L159)
