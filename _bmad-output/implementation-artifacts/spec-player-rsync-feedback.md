---
title: 'Player Content Rsync Feedback'
type: 'feature'
created: '2026-09-01'
status: 'done'
baseline_commit: '5b20736'
review_loop_iteration: 0
context:
  - '{project-root}/docs/decisions/0004-ADR-real-resource-verification-safety.md'
  - '{project-root}/docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Player Content displays only “Synchronizing player…” during a long root-level rsync. Its current captured command output hides rsync progress, leaving the operator unable to tell whether a large transfer is advancing.

**Approach:** Show bounded, aggregate rsync progress live in the existing Player Content status area. Keep the one root-level transfer and all exact-mirror safety behavior unchanged.

## Boundaries & Constraints

**Always:** Use rsync aggregate progress only when the installed rsync advertises support. Sanitize and width-bound every displayed update, avoid retaining an output stream or per-file data, preserve rsync’s true exit status, and leave the final result message authoritative. Test exclusively with temporary fixtures and tool stubs.

**Ask First:** Stop before inspecting or writing to any real library, live database, or mounted player.

**Never:** Do not alter rsync membership, deletion, metadata, snapshot, cache, source/destination postcheck, retry, or flush behavior. Do not add per-album transfers, filename-level progress, custom deletion, source-side files, `--ignore-errors`, or a progress dependency that makes an otherwise supported rsync unavailable.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Supported progress | rsync advertises aggregate progress | One clipped, sanitized live status updates during the root transfer | Final success or failure replaces it |
| No progress support | rsync lacks optional progress flags | Existing synchronization proceeds with its normal final outcome | No capability error or raw output |
| Rsync failure | rsync writes progress then exits nonzero | No success claim; checked paths remain preserved | Preserve the actual rsync exit status |
| Narrow terminal | Long or malformed progress record | Status is bounded to the reserved field and does not corrupt the canvas | Discard unsafe/control data |

</frozen-after-approval>

## Code Map

- `bin/audlint-maintain.sh` -- `player_content_sync` owns the single root rsync; selector command substitution currently captures its output.
- `lib/sh/virtwin.sh` -- supplies terminal dimensions and title-row context to long-running commands.
- `bin/audlint.sh` -- browser transfer has portable `--info` / `--outbuf` capability probing to adapt, not copy.
- `test/test_player_content_creator.py` -- existing PTY/blocking-rsync test can prove live bounded output, one rsync invocation, and final outcome.

## Tasks & Acceptance

**Execution:**
- [x] `bin/audlint-maintain.sh` -- add bounded aggregate Player Content progress rendering while retaining the existing root-mirror command and status propagation.
- [x] `test/test_player_content_creator.py` -- add temporary-fixture coverage for supported progress, fallback, narrow output, and rsync failure.
- [x] `docs/architecture/OVERVIEW.md` -- document aggregate live feedback without changing transfer ownership or semantics.

**Acceptance Criteria:**
- Given a progress-capable rsync, when Player Content synchronizes, then aggregate feedback is visible during its one root rsync and the final outcome remains correct.
- Given an rsync without optional progress support, when synchronization runs, then it completes or fails by its existing contract without raw output or a capability error.
- Given progress followed by rsync failure, when the command exits, then no success is reported and the checked selection persists.

## Spec Change Log

## Verification

**Commands:**
- `python3 -m unittest test.test_player_content_creator` -- expected: Player Content feedback and mirror tests pass with temporary fixtures.
- `make check` -- expected: repository release gate passes once after focused verification.

## Suggested Review Order

**Progress ownership and failure behavior**

- Preserves the one root mirror while making feedback strictly optional.
  [`audlint-maintain.sh:450`](../../bin/audlint-maintain.sh#L450)

- Renders only sanitized aggregate records into the reserved selector field.
  [`audlint-maintain.sh:212`](../../bin/audlint-maintain.sh#L212)

**Temporary-artifact safety**

- Creates the FIFO inside a private directory, avoiding name replacement races.
  [`player.sh:147`](../../lib/sh/player.sh#L147)

**Behavioral proof**

- Proves supported feedback, fallback, clipping, and real failure propagation.
  [`test_player_content_creator.py:405`](../../test/test_player_content_creator.py#L405)

- Records the invariant that feedback never changes transfer authority or success conditions.
  [`OVERVIEW.md:91`](../../docs/architecture/OVERVIEW.md#L91)
