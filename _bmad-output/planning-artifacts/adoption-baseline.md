# BMAD Adoption Baseline

Date: 2026-08-28
Repository baseline: `5f1c907` on `main`, synchronized with `origin/main`
Latest release tag observed: `v1.3.0`

## Product baseline

Audlint is a shipped Bash 5/Python CLI and TUI. The BMAD transition changes the
AI development harness only; it does not authorize a product runtime rewrite.
Destructive recoding, metadata, artwork, deletion, synchronization, backup, and
database workflows continue to require explicit operator care.

The retired private Go/React service draft was not adopted as current product
direction. Reintroducing it requires a new BMAD product brief, PRD, architecture
decision, and approved epics.

## Verification baseline

- `make lint fmt-check bash5-check`: passed.
- Core unittest discovery: 282 passed, 1 skipped.
- Legacy unittest discovery: 67 passed, 1 failed.

Known failure: `lyrics_album.sh` returns status 1 when all tracks are skipped by
the cached-not-found retry window, while
`test_legacy_tags_scripts.TagsScriptsTests.test_lyrics_album_respects_cached_not_found_backoff`
expects status 0. Commit `003a950` introduced the broad
`TRACKS_WITH_LYRICS == 0` failure rule without updating this older contract.

## First BMAD work

Create a bounded `bmad-spec` for the lyrics cached-backoff exit contract. Decide
whether a deferred retry is a successful no-op or an album failure, update the
implementation and conflicting tests together, and run the targeted lyrics
tests before the complete suite.

## Recovery

The removed local harness and private planning workspace were archived before
cleanup at `/tmp/audlint-pre-bmad-harness-2026-08-28.tgz`.
SHA-256: `d132c785fccb5b197a0cdb73a8b4127ae469540d5ba20800964f8866523df9ec`.
