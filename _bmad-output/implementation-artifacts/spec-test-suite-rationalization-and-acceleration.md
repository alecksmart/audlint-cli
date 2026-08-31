---
title: 'Test Suite Rationalization and Acceleration'
type: 'maintenance'
created: '2026-08-30'
status: 'in-review'
review_loop_iteration: 0
baseline_commit: '7c30559c4fa7026267fc3bf272ab79e457a64adb'
context:
  - '{project-root}/docs/ai/bmad-lite.md'
  - '{project-root}/Makefile'
  - '{project-root}/docs/architecture/OVERVIEW.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `make test` currently runs every top-level and `test/legacy/` Python suite and takes about 330 seconds on the development machine. That is too slow for the normal edit-and-test loop, even though the full suite remains valuable for releases.

**Approach:** Classify every Python test file by current evidence, make the fast and deep suites disjoint Make targets, retain all meaningful coverage in the release gate, and remove only measured avoidable test-harness cost. Publish the classification, evidence, and before/after timings for maintainers.

## Boundaries & Constraints

**Always:** Follow BMAD Lite. Work only in `test/`, test helpers, `Makefile`, `README.md`, `docs/architecture/OVERVIEW.md`, and a focused maintainer test-suite report. Use temporary, deterministic fixtures. Keep conversion, analyzer, database, filesystem-safety, destructive-operation, PTY, and regression contracts convincing. Keep the current release branch; do not create a branch or PR. `make check` must run lint, formatting, Bash 5 validation, the complete supported Python suite exactly once, then the source audit.

**Ask First:** A production-code change, a real music library/live SQLite database/mounted destination, a change to a destructive-operation safety contract, or a test removal/consolidation whose evidence does not prove where equivalent current coverage lives.

**Never:** Do not classify a file REDUNDANT or OBSOLETE because of age, size, timing, name, or location under `test/legacy/`. Do not make the full/release target omit a meaningful test. Do not change Player Content Creator behavior or refactor production code merely to improve test timing.

## Baseline and Classification

Before modifying test code or targets, record one representative baseline on this machine. Preserve the supplied approximately 330-second full-suite result and its environment/command in the report; where practical, time the existing `make test` once plus the named costly files with the same Python/dependency state. Do not repeatedly run the full suite just to chase timing noise.

The report must inventory every discovered `test/test_*.py` and `test/legacy/test_*.py` file in a table with: file, test count, measured or grouped timing, classification, release-gate target, and reason. Permitted classifications are:

| Classification | Meaning |
| --- | --- |
| FAST | Suitable for frequent local development runs. |
| INTEGRATION / DEEP REGRESSION | Meaningful but comparatively expensive, environment-shaped, or broad; runs through the complete gate. |
| REDUNDANT | Substantively duplicates a current test that proves the same supported contract. |
| OBSOLETE | Exercises behavior no longer in the supported product. |

For every REDUNDANT or OBSOLETE proposal, cite the exact test methods and current product behavior or replacement tests that prove the conclusion. State the replacement location for every deleted or merged test. If that proof is absent, retain and tier the test; finding no removable tests is acceptable.

Known initial measurements to validate and use as prioritization, not classification proof:

| File | Baseline |
| --- | ---: |
| `test/legacy/test_legacy_audlint_task_db.py` | 104.01s |
| `test/test_library_browser_smoke.py` | 47.42s |
| `test/test_cue2flac_smoke.py` | 33.09s |
| `test/test_audlint_analyze_cache_smoke.py` | 28.03s |
| `test/test_any2flac_smoke.py` | 23.41s |
| `test/legacy/test_legacy_tags_scripts.py` | 14.75s |
| `test/test_cover_smoke.py` | 13.51s |
| `test/test_dff2flac_smoke.py` | 10.72s |
| `test/test_ui_regression.py` | 7.46s |
| `test/legacy/test_legacy_boost_audio_cli_smoke.py` | 6.43s |

## Target Contract

- `make test` runs only the final FAST file set and is materially faster than the recorded baseline.
- `make test-integration` runs only the final INTEGRATION / DEEP REGRESSION file set.
- `make test-all` runs the exact union of the two sets once. The two file sets must be explicit and disjoint; no test can run twice through prerequisite overlap.
- `make check` runs `lint`, `fmt-check`, `bash5-check`, `test-all`, and `source-audit` in that order. It must not call `test` plus `test-all`, or otherwise duplicate test execution.
- Keep useful focused targets, such as the spectre target, when their semantics remain clear. Rename, remove, or document misleading aggregate targets rather than leaving a target whose name hides a different tier. Update `Makefile` help, `README.md`, and the architecture overview with the normal and release commands.

## Tasks & Acceptance

**Execution:**
- [ ] `docs/testing.md` -- add the complete classification/timing report, exact baseline and post-change commands, hardware/runtime notes, every file moved between tiers, and evidence/replacement links for any REDUNDANT/OBSOLETE or removed/merged coverage -- makes tiering reviewable instead of encoding it only in Make variables.
- [ ] `Makefile` -- define one disjoint FAST suite and one disjoint integration/deep-regression suite; implement `test`, `test-integration`, `test-all`, and a non-overlapping `check` that preserves the complete meaningful gate -- separates iteration speed from release coverage without changing product behavior.
- [ ] `test/`, shared test helpers, and only the measured expensive suites -- profile the five primary offenders before editing and remove demonstrated setup overhead while keeping per-test mutation isolation. Investigate repeated isolated runtime assembly in `test/legacy/test_legacy_audlint_task_db.py`, repeated PTY polling and copied `lib/` trees in `test/test_library_browser_smoke.py`, repeated shell-library setup in `test/test_cue2flac_smoke.py`, timeout/fixture cost in `test/test_audlint_analyze_cache_smoke.py`, and repeated stub setup in `test/test_any2flac_smoke.py`. Share only immutable inputs or fixture construction that cannot leak writes between tests; replace sleeps/polling only with event- or process-state synchronization that preserves timeout behavior.
- [ ] `README.md` and `docs/architecture/OVERVIEW.md` -- document `make test` as the fast loop, `make test-integration` for deep regression, `make test-all` for all Python tests, and `make check` as the full release gate -- keeps maintainer instructions aligned with actual target behavior.
- [ ] Any deletion or merge -- perform only after the report records substantive duplicate/obsolete evidence and the destination test coverage; otherwise leave the file in FAST or INTEGRATION / DEEP REGRESSION.

**Acceptance Criteria:**
- Given the pre-change tree, when every Python test file is examined, then the maintainer report classifies every file and includes the stated evidence for each proposed REDUNDANT or OBSOLETE result; a `legacy` path alone is never used as evidence.
- Given the resulting Make targets, when `make test`, `make test-integration`, and `make test-all` run, then FAST and deep file lists are disjoint and `test-all` executes their complete union exactly once.
- Given `make check`, when preceding quality steps pass, then it executes the complete supported regression suite through `test-all` before `source-audit`; no meaningful current test silently disappears from the release gate.
- Given the five primary offenders and any changed harness, when focused tests exercise successful, failure, timeout, PTY, conversion, cache, database, and destructive-safety paths, then their pre-existing assertions still pass and no test depends on another test's mutable state.
- Given the completed work, the report records `make test`, `make test-integration`, `make test-all`, and `make check` results, explains moved files, lists any consolidated/removed tests with evidence, and demonstrates that the normal `make test` loop is substantially faster than its approximately 330-second baseline.

## Code Map

- `Makefile:1-89` -- current target authority: `test` is `test-core test-legacy` and `check` invokes it before the source audit; this is the required wiring point.
- `test/legacy/test_legacy_audlint_task_db.py:31-349` -- 43 database/task regression tests build a temporary runtime, copy command files and every `lib/sh` helper for each test; its real coverage must survive even if setup is accelerated.
- `test/test_library_browser_smoke.py:82-137,1439-2490` -- PTY helpers poll at 100 ms and several tests copy an isolated browser plus the full shell library; preserve isolation, prompting, timeout, and signal semantics while measuring cost.
- `test/test_cue2flac_smoke.py:46-242` -- temporary conversion environment and shell helper copying are repeated per test.
- `test/test_audlint_analyze_cache_smoke.py:24-187,250-278` -- analyzer stubs and fixtures are per-test; the one-second hanging-SoX stub deliberately proves a 0.2-second decode timeout and cannot be shortened by simply removing the timeout condition.
- `test/test_any2flac_smoke.py:20-227` -- conversion stubs are recreated per temporary album; share only immutable fixture assets if profiling proves it worthwhile.
- `README.md:157-169` and `docs/architecture/OVERVIEW.md:114-119` -- current maintainer instructions say `make test` is the entire core-plus-legacy suite and must be updated with the target split.

## Verification

Run focused files or named tests while changing their harnesses. Near completion, run each final target once for timing and run the release gate once:

- `make test` -- records the normal-loop runtime and passes the FAST suite.
- `make test-integration` -- records deep-regression runtime and passes the integration suite.
- `make test-all` -- records complete Python-suite runtime and passes the exact union without duplicate file execution.
- `make check` -- passes lint, formatting, Bash 5, `test-all`, and source audit in release order.
- For each changed expensive suite, run its direct `python3 -m unittest ...` invocation before the final gate; include the suite-specific command and result in the report.

</frozen-after-approval>

## Suggested Review Order

**Suite contract and release gate**

- Explicit, disjoint manifests make the developer and release tiers inspectable.
  [`Makefile:21`](../../Makefile#L21)

- The gate calls the complete union once before the authoritative audit.
  [`Makefile:125`](../../Makefile#L125)

- A focused test prevents future omissions, overlap, or ordering regressions.
  [`test_makefile_contract.py:32`](../../test/test_makefile_contract.py#L32)

**Harness acceleration and isolation**

- Shared runtime inputs retain isolated mutable database and stub fixtures.
  [`test_legacy_audlint_task_db.py:25`](../../test/legacy/test_legacy_audlint_task_db.py#L25)

- Immutable stubs hard-link when possible and copy safely when not.
  [`test_any2flac_smoke.py:20`](../../test/test_any2flac_smoke.py#L20)

- Analyzer fixtures detach replacement stubs from their shared source.
  [`test_audlint_analyze_cache_smoke.py:19`](../../test/test_audlint_analyze_cache_smoke.py#L19)

- Read-only library symlinks avoid repeated fixture-tree copies.
  [`test_cue2flac_smoke.py:52`](../../test/test_cue2flac_smoke.py#L52)

**Maintainer documentation**

- Classification, timing, runtime context, and final evidence make tiering reviewable.
  [`testing.md:1`](../../docs/testing.md#L1)

- Everyday and release commands are explained at the primary contributor entry point.
  [`README.md:157`](../../README.md#L157)
