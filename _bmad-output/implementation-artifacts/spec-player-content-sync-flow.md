---
title: 'Player Content Creator Direct Clean Synchronization Flow'
type: 'bugfix'
created: '2026-08-31'
status: 'done'
review_loop_iteration: 1
baseline_commit: '80d7adc312933eaec0b0ebc3520480ffe8f76871'
context:
  - '{project-root}/docs/ai/bmad-lite.md'
  - '{project-root}/docs/decisions/0004-ADR-real-resource-verification-safety.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Player Content Creator requires a second confirmation to synchronize and then requires another key to return to the selector. Its unowned terminal output can remain mixed with album rows.

**Approach:** Treat `w` as the explicit mirror command once the full destructive-path preflight passes. Give synchronization an exclusively cleared selector body, then redraw the selector automatically with one concise success or failure outcome. Keep `q` an immediate selector exit.

## Boundaries & Constraints

**Always:** Keep every existing source, destination, containment, writability, manifest, tool, payload, and exact-mirror check before deleting `rsync`; preserve empty-selection mirroring, source immutability, persisted selection on failure, failure visibility, and retry convergence. Use only temporary fixtures and stub tools in automated tests.

**Ask First:** Any change to mirror scope, deletion semantics, payload rules, source cleanup, database selection behavior, or the separate `sync_music.sh` workflow.

**Never:** Add a substitute confirmation, pause, background job, progress bar, cancellation, history, rollback, or real-library/player test.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Valid mirror | `w` with a valid selected snapshot | Complete preflight, clear selector body, run one manifest mirror, redraw selector with one concise result | No confirmation or continue input |
| Empty selection | `w` with no checked rows and safe temporary player | Same complete preflight, exact mirror empties player root | No special cancellation path |
| Unsafe or failed mirror | Invalid preflight, `rsync`, or `sync` failure | Clean redraw with one readable failure; selection remains checked | No deletion/`rsync` on preflight failure; retry converges |

</frozen-after-approval>

## Code Map

- `bin/audlint-maintain.sh:192-195` -- selector-owned row-clearing helper; reuse for deterministic sync canvas clearing.
- `bin/audlint-maintain.sh:338-405` -- `player_content_safe_destination` and `player_content_sync`; preserve its full safety/manifest/mirror mechanics while removing its confirmation branch.
- `bin/audlint-maintain.sh:462-576` -- selector draw loop, owned list region, `w`/`q` dispatch, raw-mode restoration, and redraw cache.
- `test/test_player_content_creator.py:248-530` -- PTY direct-flow, safety, real temporary mirror, zero selection, failure/retry, and literal-path regression coverage.
- `test/test_player_content_creator.py:164,398-441,630` -- previous `_VA`, selected-size, and Cyrillic child tests that must remain present and pass.
- `test/test_library_browser_smoke.py` and `test/test_audlint_maintain_smoke.py` -- focused integration regressions for shared browser and Maintenance behavior; do not alter unless evidence requires it.

## Tasks & Acceptance

**Execution:**
- [x] `bin/audlint-maintain.sh` -- remove the synchronization confirmation and continuation pause; stage running output in a cleared selector-owned region; retain one result across the automatic redraw -- makes the interaction direct without weakening mirror safety.
- [x] `test/test_player_content_creator.py` -- replace confirmation/cancellation PTY expectations with direct-start, clean-region, immediate-`q`, and automatic-result assertions; retain and adapt destructive safety, empty, real mirror, failure, persistence, and retry cases using temporary fixtures -- proves the behavioral contract.

**Acceptance Criteria:**
- Given a valid temporary source/player snapshot, when the operator presses `w`, then the complete preflight finishes before one deleting manifest `rsync` starts, with no `y` or continue prompt.
- Given synchronization is running or has completed, when selector rows are redrawn, then stale album rows do not share the synchronization body and exactly one concise outcome is visible after automatic return.
- Given the operator presses `q` in the selector, when no synchronization is active, then the selector exits immediately with no confirmation.
- Given empty selection, invalid paths/sources, or stubbed `rsync`/`sync` failure, when `w` is pressed, then existing destructive checks, exact mirror scope, error reporting, selection persistence, and later retry convergence remain unchanged.

## Verification

**Commands:**
- `python3 -m unittest test.test_player_content_creator.PlayerContentCreatorTests.test_space_persists_selection_before_direct_root_mirror test.test_player_content_creator.PlayerContentCreatorTests.test_direct_manifest_mirror_clears_canvas_restores_tty_and_drains_repeated_w` -- expected: direct PTY flow, cleared running canvas, no pauses, and no queued repeated mirror.
- `python3 -m unittest test.test_player_content_creator.PlayerContentCreatorTests.test_unsafe_sync_never_calls_rsync test.test_player_content_creator.PlayerContentCreatorTests.test_real_rsync_mirror_copies_only_checked_payload_and_deletes_extra test.test_player_content_creator.PlayerContentCreatorTests.test_empty_selection_directly_empties_player test.test_player_content_creator.PlayerContentCreatorTests.test_rsync_and_sync_failures_preserve_selection_then_retry test.test_player_content_creator.PlayerContentCreatorTests.test_failure_retry_replaces_result_and_narrow_canvas_keeps_outcome_readable` -- expected: destructive safety, exact temporary mirror, empty selection, failure persistence, retry, and readable narrow-canvas outcome.
- `python3 -m unittest test.test_player_content_creator` -- expected: all Player Content Creator cases pass, including `_VA`, Cyrillic, and selected-size tests.
- `python3 -m unittest test.test_library_browser_smoke test.test_audlint_maintain_smoke` -- expected: shared integration suites pass.
- `make check` -- expected: execute exactly once as the final complete release gate after all prior commands pass.

## Acceptance Evidence

- Implementation commit `9784c24` was verified by the operator and accepted on 2026-08-31.
- Eight focused interaction and destructive-safety tests passed; the full Player Content Creator module passed all 28 tests; the two related smoke modules passed 37 tests with one skip.
- The one planned `make check` run completed all 470 tests with one skip. Its final source-audit stage then exposed a malformed Markdown table in the earlier selected-size spec, not a product-code failure.
- Documentation-only repair commit `a4c6fb3` corrected that table. A subsequent authoritative `make source-audit` completed cleanly with zero findings and zero errors; the full test suite was not rerun.
- Prompt 4 is closed. Together with the accepted `_VA`, Cyrillic-jump, and selected-size fixes, this closes the four-task Player Content Creator fix campaign.

## Suggested Review Order

**Direct synchronization flow**

- Preserve guarded manifest mirroring while eliminating the confirmation branch.
  [`audlint-maintain.sh:349`](../../bin/audlint-maintain.sh#L349)

- Clear, hand off terminal mode, drain queued input, and automatically redraw one outcome.
  [`audlint-maintain.sh:570`](../../bin/audlint-maintain.sh#L570)

**Interaction and destructive-safety proof**

- Render the blocked running canvas and prove one direct mirror with no stale rows.
  [`test_player_content_creator.py:293`](../../test/test_player_content_creator.py#L293)

- Keep unsafe paths non-destructive while returning their concise result automatically.
  [`test_player_content_creator.py:343`](../../test/test_player_content_creator.py#L343)

- Prove exact temporary mirroring and narrow-screen retry outcome replacement.
  [`test_player_content_creator.py:374`](../../test/test_player_content_creator.py#L374)
  [`test_player_content_creator.py:543`](../../test/test_player_content_creator.py#L543)
