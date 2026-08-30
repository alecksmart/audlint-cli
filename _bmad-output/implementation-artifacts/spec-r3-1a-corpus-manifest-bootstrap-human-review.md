---
title: 'R3.1A Corpus Manifest Bootstrap and Human Review'
type: 'feature'
created: '2026-08-30'
status: 'done'
review_loop_iteration: 0
baseline_commit: '28bd61760b6988e3abb00d14a68140a58cd84fc9'
context:
  - '{project-root}/docs/architecture/OVERVIEW.md'
  - '{project-root}/_bmad-output/specs/spec-r3-1a-corpus-manifest-bootstrap-human-review/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-r3-1a-corpus-manifest-bootstrap-human-review/draft-manifest-contract.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** R3.1 safely inventories a fully reviewed strict manifest, but maintainers have no read-only way to prepare the initial candidate inventory. Mechanical discovery must not turn into automated ground truth or alter an approved corpus.

**Approach:** Add `--bootstrap CORPUS_ROOT` to produce one atomic, deterministic schema-v1 review draft. It discovers only objective facts and clearly leaves all identities, expectations, lineage, provenance, reviewer data, and trust for human review before the unchanged R3.1 inventory route accepts the result.

## Boundaries & Constraints

**Always:** Operate only on an explicit root, with an `lstat`-based non-following walk and full pre/post source evidence. Emit only `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest-review-draft.json`, atomically and only if absent. Use root-relative POSIX paths, deterministic ordering and JSON bytes, shared objective probe/profile policy, repository-owned temporary fixtures, and a thin Bash wrapper. Leave human-owned required fields as JSON `null`; do not add draft-only fields.

**Ask First:** Accessing `/Volumes/Music/Tests` or another real library; changing R3.1 schema/inventory behavior; changing any R3.2–R3.5 contract or implementation; replacing, deleting, or otherwise handling an existing review draft.

**Never:** Run an analyzer, value command, converter, dataset generator, staging/evaluation/benchmark/finalization operation, database command, or any mutating corpus workflow. Do not write below the supplied root, follow symlinks, accept unsupported filesystem entries, invent human values, overwrite a draft, create a branch/PR, modify `main`, or inspect or alter `.agents/skills/audlint-orchestration-architect/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Bootstrap draft | Safe temporary root containing supported audio/CUE and supporting regular files | Ordered review draft with candidate groups, objective facts, role/category suggestions, and human `null` fields | Source snapshot remains exactly unchanged (except access time) |
| Existing draft | Stable review draft already present | Nothing is changed | Fail nonzero without replacing the existing file |
| Unsafe discovery | Symlink, special file, escape, probe failure, or detected source change | No new draft is published | Fail nonzero with a precise diagnostic |
| Human handoff | Draft still has placeholders, then reviewer completes it using existing schema | Unchanged R3.1 rejects placeholders; reviewed copy succeeds through `--inventory` | Bootstrap never writes canonical `corpus-manifest.json` |

</frozen-after-approval>

## Code Map

- `bin/audlint-analyze-corpus.sh` -- thin Python dispatcher; preserve its existing inventory and legacy routes while exposing bootstrap.
- `lib/py/audlint_analyze_corpus.py` -- owns strict R3.1 manifest handling, objective inventory, deterministic JSON, existing snapshot utility, and the new safe discovery/draft boundary.
- `lib/py/audlint_analyze.py` -- reuse `ffprobe_audio_json` through existing objective-fact shaping; do not enter analyzer execution.
- `lib/py/profile_norm.py` -- existing canonical profile policy retained for reviewed R3.1 inventory only.
- `lib/sh/audio.sh` -- authoritative recognized-media extension policy; keep Python discovery aligned with this set and CUE support.
- `test/test_audlint_analyze_corpus_smoke.py` -- temporary-fixture R3.1/R3.2 command and source-immutability patterns; add dedicated R3.1A tests here.
- `README.md` -- public R3.1 command documentation; add bootstrap lifecycle, output, and required human review.

## Tasks & Acceptance

**Execution:**

- [x] `lib/py/audlint_analyze_corpus.py` -- add bootstrap discovery, non-following containment and immutable-source snapshots, objective file/media shaping, deterministic candidate grouping/diagnostics, and atomic create-if-absent publication while leaving R3.1–R3.5 routes intact.
- [x] `bin/audlint-analyze-corpus.sh` -- expose the `--bootstrap CORPUS_ROOT` invocation without adding orchestration logic.
- [x] `test/test_audlint_analyze_corpus_smoke.py` -- cover draft facts/order/format, category and role suggestions, unassigned diagnostics, root immutability, non-invocation of analysis, placeholder rejection and reviewed-inventory compatibility, and all unsafe/no-overwrite failures using temporary fixtures only.
- [x] `README.md` -- document bootstrap as a review-draft producer and the unchanged R3.1 review-to-inventory handoff.

**Acceptance Criteria:**

- Given a safe repository-owned fixture, when bootstrap runs, then it atomically creates only the declared review-draft path, with schema-v1 structure, stable byte formatting/order, accurate objective facts, and no source-tree change other than possible access times.
- Given nested candidates, ordinary support files, and `real`, `fake`, or `edge_cases` path families, when discovery runs, then direct recognized media/CUE directories become separately ordered suggestions, files receive only allowed mechanical fields, and unassigned regular files are diagnosed outside JSON.
- Given an unsafe entry, source mutation, failed probe, or pre-existing draft, when bootstrap runs, then it exits nonzero without a partial/new/replaced draft and without invoking prohibited workflows.
- Given an unchanged draft and then a fully human-reviewed copy, when existing R3.1 inventory validates each, then the draft is rejected for remaining placeholders and the reviewed copy follows the existing canonical inventory path without R3.2–R3.5 changes.

## Design Notes

Bootstrap is intentionally not an alternate manifest schema. The `null` placeholders make the review boundary mechanically visible and let existing strict R3.1 validation remain the only acceptance gate. Publication must use create-if-absent semantics: existing atomic replacement is unsuitable because it could erase partial review.

## Verification

**Commands:**

- `python3 -m unittest test.test_audlint_analyze_corpus_smoke` -- expected: R3.1/R3.1A temporary-fixture safety and compatibility tests pass without real-library access.
- `make check` -- expected: the repository release gate passes with R3.1–R3.5 behavior preserved.

## Suggested Review Order

**Bootstrap boundary**

- Routes the new mode before every existing corpus workflow.
  [`audlint_analyze_corpus.py:2146`](../../lib/py/audlint_analyze_corpus.py#L2146)

- Rejects unsafe roots and keeps the review artifact outside source input.
  [`audlint_analyze_corpus.py:575`](../../lib/py/audlint_analyze_corpus.py#L575)

- Performs a non-following walk and shapes only mechanical review facts.
  [`audlint_analyze_corpus.py:609`](../../lib/py/audlint_analyze_corpus.py#L609)

- Publishes create-if-absent bytes after immutable-source evidence.
  [`audlint_analyze_corpus.py:706`](../../lib/py/audlint_analyze_corpus.py#L706)

**Evidence and handoff**

- Covers draft content, rejected placeholders, reviewed inventory, and unsafe fixtures.
  [`test_audlint_analyze_corpus_smoke.py:691`](../../test/test_audlint_analyze_corpus_smoke.py#L691)

- Covers source-root output isolation, concurrent publication, and format classification.
  [`test_audlint_analyze_corpus_smoke.py:804`](../../test/test_audlint_analyze_corpus_smoke.py#L804)

- Explains the operator lifecycle and strict R3.1 review handoff.
  [`README.md:193`](../../README.md#L193)
