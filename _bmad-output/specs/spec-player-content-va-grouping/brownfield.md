# Brownfield Evidence and Focused Proof

## Current cause

`player_content_creator` loads all `album_quality` rows with a source path, so its SQL does not selectively discard `_VA` rows. It then calls `player_artist_directory_label_from_source`, which returns the immediate parent of each album path. For `_VA/2002/<album>`, that parent is `2002`; the supplied screenshot shows this exact false artist heading after the four direct `_VA` albums.

## Change boundary

- Adjust the shared source-layout label rule in `lib/sh/player.sh` and its selector use only as needed so every validated descendant of the top-level `_VA` subtree groups as `_VA`.
- Keep current behavior for ordinary `<artist>/<album>` paths and unavailable or escaping paths.
- Within each display artist, order rows by `year_int`, then `album_norm`, then `id`; this user-approved rule supersedes the original album-first preservation statement.
- Do not rewrite `artist`, `artist_lc`, `artist_norm`, `source_path`, or `player_content_selection` rows.
- Do not change source-relative destination layout; this is a display grouping correction.

If focused fixture evidence contradicts the screenshot-based cause, stop and report the contradiction instead of broadening this task into scanner work.

## Sanity-test stages

1. Red: add one named temporary-fixture test covering direct and nested `_VA` albums plus an ordinary artist; run only that test and prove the current year-heading failure.
2. Green: run that named test after the smallest grouping fix.
3. Regression: run `python3 -m unittest test.test_player_content_creator`, including the year-first assertion.
4. Stop after the focused module passes. The full `make check` gate belongs to the final synchronization-flow task after all four fixes are present.

## Accepted evidence

- Commit `7f348bc` implements and tests `_VA` grouping.
- Commit `84034c7` applies the approved year-first ordering and updates its regression assertion.
- The named `_VA` test passed; the focused module passed all 22 tests.
- Alec verified the behavior manually and approved Prompt 1 closure on 2026-08-31.
- A possible ADR for year-first ordering is deferred; this task does not create one.
