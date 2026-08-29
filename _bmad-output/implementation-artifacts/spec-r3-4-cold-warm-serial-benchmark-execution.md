---
title: 'R3.4 Cold/Warm Serial Benchmark Execution'
type: 'feature'
created: '2026-08-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: '6754a5bcf3f00fc3001a6c8a4ac48b67f477e940'
context:
  - '{project-root}/docs/architecture/OVERVIEW.md'
  - '{project-root}/_bmad-output/specs/spec-r3-4-cold-warm-serial-benchmark-execution/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-r3-4-cold-warm-serial-benchmark-execution/benchmark-results-schema.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** R3.1–R3.3 establish a trusted manifest, safe staging, and analyzer work evidence, but Audlint has no reproducible raw cold/warm serial runtime samples for supported analysis and safe converter-planning paths.

**Approach:** Add R3.4 only: a benchmark route that validates the entire manifest, runs isolated ordered cold/warm pairs serially, preserves raw evidence in the specified atomically published JSON artifact, and excludes converter forms that cannot be fixture-proven non-mutating.

## Boundaries & Constraints

**Always:** Reuse the R3.1 validator and R3.2 staging/snapshot boundary without changing their semantics. Time only product subprocess launch through exit and pipe drain with `time.monotonic_ns()`. Plan manifest entry/tool/iteration/cold-warm order; give each pair a new verified stage and retain only cold artifacts for its immediate identical warm command. Force every existing worker control to `1`, preserve source immutability and cleanup evidence, and write deterministic schema-v1 JSON through a candidate plus atomic replacement. Use structured analyzer output only; require the exact R3.3 work counters for successful `audlint-analyze` samples.

**Ask First:** A real-corpus run, a command form that may mutate staged input, publishing anything other than the defined JSON artifact, changing `main`, creating a branch or PR, or extending work to R3.5/R3A/later work.

**Never:** Modify R3.1–R3.3 contracts, analyzer decisions/cache policy/worker model, real music or live services, source manifests or corpus content, or run benchmark product commands concurrently. Do not infer cache states or analyzer evidence from logs/timing; do not treat DFF dry-run as safe without proof.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Valid analysis pair | Valid fixture manifest and analyzer stub | Fresh declared-only stage; identical cold/warm commands; ordered raw records and atomic artifact | Source/stage snapshots and cleanup pass |
| Unsafe converter | Applicable case with no fixture-proven exact safe form | Ordered cold/warm records are `excluded`, not launched | Stable exclusion reason; overall may still pass |
| Product or evidence failure | Cold/warm nonzero exit, malformed JSON, R3.3 invariant failure, or source change | Preserve planned/raw evidence; relevant pair is error/fail | Nonzero result; cold failure suppresses warm; cleanup still runs |
| Post-gate mutation | Eligible converter stub changes staged tree | Timing invalidated and candidate not published | `converter_stage_mutated`, nonzero, prior stable artifact remains |

</frozen-after-approval>

## Code Map

- `bin/audlint-analyze-corpus.sh:28-37` — retain as the thin Python dispatch and environment boundary.
- `lib/py/audlint_analyze_corpus.py:320-419,437-588` — reuse strict full-manifest validation, exact manifest digest, source snapshots, path-safe staging, and safe diagnostics; add a separate R3.4 planner/runner, monotonic subprocess wrapper, evidence shaping, aggregates, and atomic publication rather than altering R3.2 evaluation semantics.
- `lib/py/audlint_analyze_corpus.py:421-434,887-960` — extend deterministic JSON publication to candidate-plus-replace and add an explicit benchmark CLI route with an injectable temporary project root/output boundary for tests.
- `lib/py/audlint_analyze_corpus.py:591-622` and `lib/py/audlint_analyze.py:100-155,2112-2129` — retain the existing R3.2 verdict parser; add R3.4-only validation/retention of structured R3.3 counters and decision context.
- `bin/audlint-analyze.sh:249-343` — `--json` intentionally performs fresh analysis, so benchmark cache observation is structured `bypass`, not a fabricated warm hit.
- `bin/cue2flac.sh:79-93,793-816` — gate the exact `--profile … --out $OUTPUT --dry-run` form with a complete fixture stage-snapshot proof.
- `bin/any2flac.sh:403-421,455-573` — gate `--profile … --dir $STAGE --plan-only`; do not use `--with-boost`, which creates a cache.
- `bin/dff2flac.sh:169,234-265,345-346` — current dry-run creates output/cache in its working tree; represent applicable DFF samples as unlaunched exclusions.
- `test/test_audlint_analyze_corpus_smoke.py:119-382` — keep existing temporary fixture/staging patterns and R3.2 behavior unchanged.
- `test/test_audlint_analyze_corpus_benchmark.py` — add R3.4 stubs and assertions for ordering, isolation, timing boundaries, safety gates, cache evidence, failures, deterministic artifact, and cleanup.

## Tasks & Acceptance

**Execution:**

- [x] `lib/py/audlint_analyze_corpus.py` — add a benchmark-only CLI and execution model that fully validates before planning, builds the five-tool applicability matrix, executes isolated serial cold/warm pairs, captures monotonic raw timings and structured evidence, enforces serial environment overrides, and atomically publishes only a complete safe candidate.
- [x] `lib/py/audlint_analyze_corpus.py` — add exact converter eligibility proof and post-run complete staged-tree checking; use the safe CUE/any2flac forms only after proof and retain dff2flac as an unlaunched exclusion.
- [x] `test/test_audlint_analyze_corpus_benchmark.py` — provide repository-owned temporary fixtures and stubs proving the benchmark schema/lifecycle, non-overlap and timing isolation, cache observations, failure propagation, source immutability, cleanup, and no replacement after a converter safety failure.
- [x] `test/test_audlint_analyze_corpus_smoke.py` — adjust only shared fixture helpers or focused assertions needed to preserve R3.1/R3.2 compatibility with the new route.

**Acceptance Criteria:**

- Given a valid fixture manifest and positive iterations, when the benchmark runs, then every applicable record is ordered exactly by manifest, tool, iteration, cold, warm; each pair has a distinct verified stage, equal sanitized commands, serial worker settings, raw monotonic elapsed values, and no product-command overlap.
- Given successful `audlint-analyze --json` samples, when their evidence is written, then the unchanged R3.2 verdict and all required typed R3.3 counters/context are retained and cache state is `bypass`; tools without structured cache/evidence state the fixed unavailability reason.
- Given a missing converter proof, cold failure, warm failure, malformed output, mutation, timing, source, cleanup, or publication error, when the runner completes, then all planned samples and appropriate raw evidence remain visible, the command exits nonzero where required, cleanup is attempted, and unsafe candidates cannot replace an existing stable artifact.
- Given fixed fixture inputs and clock values, when a safe run publishes, then the sole output is the exact schema-v1 `benchmark-results.json` at the fixture project root, with sorted two-space UTF-8 LF JSON, ordered arrays, exclusion references, and deterministic aggregates over successful raw samples only.

## Design Notes

Keep R3.4 beside, not inside, `evaluate_strict_manifest`: R3.2 is an accuracy verdict runner with one analyzer stage per case, while the benchmark owns an ordered product-command plan and two-command lifecycle. Its safety primitives remain shared. Converter eligibility is attached to a command descriptor plus a fixture proof, so a future tool change cannot silently promote a dry-run label into a safe benchmark form.

## Verification

**Commands:**

- `python3 -m unittest test.test_audlint_analyze_corpus_smoke test.test_audlint_analyze_corpus_benchmark test.test_audlint_value_smoke test.test_cue2flac_smoke test.test_any2flac_smoke test.test_dff2flac_smoke` — expected: all temporary-fixture R3.4 and related product tests pass with no real-media access.
- `make check` — expected: complete local release gate passes.

## Suggested Review Order

**Benchmark boundary and safety lifecycle**

- The public wrapper supplies the product command identities without owning benchmark policy.
  [`audlint-analyze-corpus.sh:31`](../../bin/audlint-analyze-corpus.sh#L31)

- The benchmark planner owns ordered isolated pairs, safety checks, and conditional publication.
  [`audlint_analyze_corpus.py:1083`](../../lib/py/audlint_analyze_corpus.py#L1083)

- Command descriptors pin serial overrides and exclude unsafe DFF execution.
  [`audlint_analyze_corpus.py:897`](../../lib/py/audlint_analyze_corpus.py#L897)

- Timing measures only child launch through pipe drain with monotonic precision.
  [`audlint_analyze_corpus.py:929`](../../lib/py/audlint_analyze_corpus.py#L929)

**Evidence and publication**

- Candidate-plus-replace prevents partial or unsafe artifact publication.
  [`audlint_analyze_corpus.py:805`](../../lib/py/audlint_analyze_corpus.py#L805)

- Aggregates remain deterministic secondary views over successful raw samples.
  [`audlint_analyze_corpus.py:1004`](../../lib/py/audlint_analyze_corpus.py#L1004)

**Fixture verification**

- Temporary stubs cover pair ordering, converter safety, evidence, failure paths, and serialization.
  [`test_audlint_analyze_corpus_benchmark.py:1`](../../test/test_audlint_analyze_corpus_benchmark.py#L1)
