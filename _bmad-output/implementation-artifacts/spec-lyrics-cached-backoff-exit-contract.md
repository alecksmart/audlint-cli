---
title: 'Lyrics Cached-Backoff Exit Contract'
type: 'bugfix'
created: '2026-08-28'
status: 'done'
review_loop_iteration: 2
baseline_commit: 'f49c649456c0bd515c2543a52a423bb3c752127e'
context:
  - '{project-root}/_bmad-output/specs/spec-lyrics-cached-backoff-exit-contract/SPEC.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `lyrics_album.sh` exits nonzero whenever an album finishes with zero tracks containing lyrics, even when every eligible track was intentionally deferred by an unexpired cached-not-found retry window. That false failure propagates through `lyrics_seek.sh` despite there being no actionable processing error.

**Approach:** Track eligible and cached-deferred outcomes separately from successful lyrics and processing failures. Treat only the all-eligible-tracks-deferred outcome as a successful no-op while preserving every existing real-failure path.

## Boundaries & Constraints

**Always:** Preserve failure precedence, the cached revisit message, retry-window/cache lookup behavior, and the absence of remote requests for deferred tracks. Keep the implementation portable across Bash 5 on macOS and Linux, reuse existing helpers, and verify only with temporary fixtures.

**Ask First:** Any solution that changes shared cache helpers/schema, retry duration, lookup matching, operator-facing messages, `lyrics_seek.sh`, or exit semantics beyond the all-eligible-tracks-deferred case.

**Never:** Operate on a real music library or live SQLite database; make fresh not-found, missing-tag, unsupported-codec, no-audio, or embed-failure outcomes successful; rework fetching, embedding, batch traversal, or unrelated database maintenance.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| All deferred | Every eligible track has an unexpired cached `not_found` row | Print each cached revisit message, make no remote request, exit 0 | Successful no-op |
| Mixed deferred and fresh miss | At least one eligible track is deferred and another remote lookup returns no lyrics | Defer the cached track, process the other normally, exit nonzero when no lyrics result | Preserve fresh-not-found failure |
| Deferred plus embed failure | One eligible track is deferred and another cannot embed fetched/cached lyrics | Print both outcomes and exit nonzero | Processing failure takes precedence |
| Existing lyrics | A supported, tagged track already contains lyrics | Skip it as before; it is not a deferred candidate | Preserve current album outcome |
| Ineligible input | Track is unsupported or lacks artist/title | Skip as before; do not count it toward all-deferred success | Preserve current non-success outcome |

</frozen-after-approval>

## Code Map

- `bin/lyrics_album.sh:177-180` -- initializes album outcome counters; add eligibility, deferment, and disqualifying pre-cache skip state here.
- `bin/lyrics_album.sh:185-209` -- unsupported-codec and missing-tag branches must disqualify the new all-deferred success path without changing their behavior in albums that already succeed for other reasons.
- `bin/lyrics_album.sh:217-236` -- existing-lyrics tracks retain their current success contribution and remain outside cache eligibility.
- `bin/lyrics_album.sh:238-253` -- performs shared cache lookup; the unexpired `not_found` branch is the only deferred outcome.
- `bin/lyrics_album.sh:260-310` -- preserves fresh lookup, cache upsert, embed success, and `TRACKS_FAILED` behavior.
- `bin/lyrics_album.sh:317-325` -- final failure precedence and broad zero-lyrics rule that causes the regression.
- `lib/sh/lyrics.sh:7-122` -- read-only shared retry-window, cache lookup, and upsert policy; no helper/schema change is required.
- `bin/lyrics_seek.sh:83-132` -- read-only batch caller whose existing nonzero propagation must remain intact.
- `test/legacy/test_legacy_tags_scripts.py:396-438` -- temporary SQLite regression fixture already asserts cached revisit, exit 0, and no `curl` call.
- `test/test_lyrics_smoke.py:119-204` -- temporary-fixture guards for embed failure and batch failure propagation.

## Tasks & Acceptance

**Execution:**
- [x] `bin/lyrics_album.sh` -- count cache-eligible tracks, unexpired cached deferrals, and unsupported/missing-tag pre-cache skips; allow zero only when eligibility is positive, every eligible track was deferred, no disqualifying skip occurred, and the existing failure-first check has passed -- distinguish intentional no-op without making mixed ineligible albums newly successful or making pre-cache skips globally fatal.
- [x] `test/legacy/test_legacy_tags_scripts.py` -- retain the cached-backoff regression and add multi-track all-deferred, mixed fresh-miss, deferred-plus-embed-failure, deferred-plus-unsupported, deferred-plus-missing-tag, existing-lyrics, standalone ineligible, existing-lyrics-plus-unsupported, and newly-embedded-lyrics-plus-missing-tag coverage using temporary fixtures -- prove aggregation, every matrix boundary, and preservation of previously successful mixed albums.
- [x] `test/test_lyrics_smoke.py` -- preserve focused embed-failure and `lyrics_seek.sh` propagation guards -- demonstrate downstream failure contracts remain nonzero.

**Acceptance Criteria:**
- Given the targeted temporary-fixture lyrics tests, when the cached-backoff fix is exercised alongside embed and batch failures, then every expected status, message, and network-call assertion passes.
- Given the complete local suite, when it runs after targeted tests, then the former cached-backoff legacy failure is resolved with no new failures.
- Given the changed shell script, when lint, formatting, and Bash 5 checks run, then it remains portable and compliant.

## Spec Change Log

- Review loop 1 -- Trigger: the first derivation excluded unsupported and missing-tag tracks from eligibility without separately disqualifying the all-deferred success branch, so a deferred track mixed with either outcome could return zero; the plural aggregation also lacked a multi-track positive test. Amended the Code Map, execution tasks, Design Notes, and Verification to require disqualifying-skip accounting plus mixed-ineligible and multi-track all-deferred fixtures. This avoids masking preserved non-success outcomes and shipping counter logic proven only for one track. KEEP: album-local counters, the existing `TRACKS_FAILED`-first ordering, unchanged shared cache and seeker code, focused mixed fresh-miss/embed-failure tests, temporary fixtures, message/network assertions, and the previously passing quality/full-suite gates.
- Review loop 2 -- Trigger: the second derivation correctly scoped disqualifying skips to the new zero-lyrics exception, but verification did not prove that an existing or newly embedded lyrics success still wins when another track is unsupported or missing tags. Amended the execution task and targeted verification to require two cross-paired mixed-success fixtures. This avoids a future/global `disqualifying skips > 0` check making previously successful albums and `lyrics_seek.sh` runs fail while all prior tests remain green. KEEP: the loop-1 counter design and placement, positive multi-track aggregation, all deferred/mixed failure/ineligible fixtures, opt-in test-stub controls, unchanged frozen intent/shared helpers/seeker, and all passing targeted, quality, and full-suite gates.

## Design Notes

An eligible track is supported, has artist/title metadata, lacks an existing lyrics tag, and therefore reaches cache lookup. Increment the deferred count only in the unexpired cached-`not_found` branch. Separately count unsupported-codec and missing-tag skips that would have kept a zero-lyrics album nonzero before this change; require that count to be zero only inside the new all-deferred exception. Evaluate `TRACKS_FAILED` first, then grant the exception only when eligibility is positive, every eligible track was deferred, and no disqualifying skip occurred. Do not make pre-cache skips globally fatal: albums with existing or newly embedded lyrics must retain their prior outcome.

## Verification

**Commands:**
- `python3 test/legacy/test_legacy_tags_scripts.py TagsScriptsTests.test_lyrics_album_respects_cached_not_found_backoff -v` -- expected: cached-backoff fixture exits 0, prints revisit text, and performs no network fetch.
- `python3 test/legacy/test_legacy_tags_scripts.py TagsScriptsTests.test_lyrics_album_all_cached_not_found_backoff_multiple_tracks TagsScriptsTests.test_lyrics_album_mixed_cached_backoff_and_fresh_miss_fails TagsScriptsTests.test_lyrics_album_deferred_track_does_not_mask_embed_failure TagsScriptsTests.test_lyrics_album_deferred_track_does_not_mask_unsupported_track TagsScriptsTests.test_lyrics_album_deferred_track_does_not_mask_missing_tags TagsScriptsTests.test_lyrics_album_unsupported_track_remains_nonzero TagsScriptsTests.test_lyrics_album_missing_tags_remains_nonzero TagsScriptsTests.test_lyrics_album_skips_when_tag_already_exists TagsScriptsTests.test_lyrics_album_existing_lyrics_with_unsupported_track_stays_successful TagsScriptsTests.test_lyrics_album_embedded_lyrics_with_missing_tags_stays_successful -v` -- expected: counter aggregation, all mixed/standalone matrix boundaries, and both prior-success preservation cases produce their specified statuses, messages, and network behavior.
- `python3 test/test_lyrics_smoke.py LyricsSmokeTests.test_lyrics_album_returns_nonzero_when_embed_fails LyricsSmokeTests.test_lyrics_seek_returns_nonzero_after_any_album_failure -v` -- expected: both failure guards exit nonzero as asserted.
- `make lint fmt-check bash5-check` -- expected: shell quality and Bash 5 portability checks pass.
- `make test` -- expected: core and legacy suites pass with the known cached-backoff regression eliminated.

## Suggested Review Order

**Exit contract**

- The final predicate grants success only to fully deferred, otherwise clean zero-lyrics albums.
  [`lyrics_album.sh:329`](../../bin/lyrics_album.sh#L329)

- Pre-cache skips disqualify only the new deferred-only success exception.
  [`lyrics_album.sh:195`](../../bin/lyrics_album.sh#L195)

- Eligibility and deferment are counted at their exact semantic transition points.
  [`lyrics_album.sh:243`](../../bin/lyrics_album.sh#L243)

**Canonical intent**

- CAP-1 defines the operator-visible no-op and preserved failure contract.
  [`SPEC.md:18`](../specs/spec-lyrics-cached-backoff-exit-contract/SPEC.md#L18)

**Regression coverage**

- Per-track temporary fixtures isolate codec, metadata, lyrics, and embed outcomes.
  [`test_legacy_tags_scripts.py:280`](../../test/legacy/test_legacy_tags_scripts.py#L280)

- Expired cache misses prove retry attempts remain actionable failures.
  [`test_legacy_tags_scripts.py:526`](../../test/legacy/test_legacy_tags_scripts.py#L526)

- Multi-track deferrals prove aggregate cached-backoff success without network access.
  [`test_legacy_tags_scripts.py:558`](../../test/legacy/test_legacy_tags_scripts.py#L558)

- Mixed failure cases prove deferred tracks cannot mask processing or eligibility problems.
  [`test_legacy_tags_scripts.py:584`](../../test/legacy/test_legacy_tags_scripts.py#L584)

- Mixed success cases prove pre-existing successful album outcomes remain unchanged.
  [`test_legacy_tags_scripts.py:719`](../../test/legacy/test_legacy_tags_scripts.py#L719)
