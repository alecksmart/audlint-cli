---
title: 'R3.5 Synthetic Verification and Final Baseline Publication'
type: 'feature'
created: '2026-08-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'b351edbfbf0a3e86d26ff9eb015b9a934a01da3c'
context:
  - '{project-root}/docs/architecture/OVERVIEW.md'
  - '{project-root}/_bmad-output/specs/spec-r3-5-synthetic-verification-final-baseline-publication/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-r3-4-cold-warm-serial-benchmark-execution/benchmark-results-schema.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** R3.1–R3.4 produce a manifest and raw serial benchmark evidence but do not independently reproduce declared synthetic lineage or publish one checked, readable baseline. A final artifact must expose valid failures and limitations without modifying corpus evidence or treating analyzer agreement as ground truth.

**Approach:** Add an R3.5 finalization route that strictly consumes the existing manifest and benchmark result, reproduces each declared synthetic recipe only in verified temporary paths, validates every output and cross-artifact identity, then atomically writes the one parent-defined Markdown summary.

## Boundaries & Constraints

**Always:** Reuse R3.1 manifest/objective-fact validation, R3.2 snapshots and independent byte staging, and R3.4 evidence unchanged. Require a precise, unambiguous R3.5 recipe shape; reject opaque or insufficient legacy recipe facts rather than infer inputs, commands, outputs, or tool versions. Run generators serially with `AUDLINT_DATASET_JOBS=1`, avoid corpus/repository paths for generated media, preserve valid upstream `warn`/`fail`/`error` meanings, emit machine-readable diagnostics, and atomically publish only `baseline-summary.md` with UTF-8/LF/final newline.

**Ask First:** Any real-corpus invocation, access to `/Volumes/Music/Tests`, modification of generated manifest/result artifacts, a change to `main`, branch/PR creation, or work outside R3.5.

**Never:** Rewrite expectations, provenance, trust, recipe truth, R3.2 verdicts, R3.3 counters, R3.4 timing/cache semantics, or dataset generation policy; run Audlint to establish lineage; generate media in the repository/corpus; publish a summary after a safety, consistency, cleanup, or publication failure; commit, merge, or open a PR.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Valid all-pass fixture | Strict manifest/result and declared stub recipe | Verifies staged source and exact generated output, then atomically publishes linked summary | Zero only if upstream verdict is also zero |
| Valid recorded benchmark failure | Trusted `fail` or execution `error` with consistent evidence | Publishes faithful summary with separate finding sections | Returns preserved nonzero upstream verdict |
| Recipe or output mismatch | Ambiguous recipe, wrong tool/version, checksum/metadata mismatch, missing/extra output | No new summary; trust and source remain unchanged | Nonzero diagnostic and cleanup attempt |
| Safety/publication failure | Source mutation, path escape, symlink, cleanup or replace failure | Existing summary and both JSON files stay byte-identical | Nonzero machine evidence |

</frozen-after-approval>

## Code Map

- `bin/audlint-analyze-corpus.sh:28-39` — retain thin environment/dispatch boundary; expose one explicit finalization mode only.
- `lib/py/audlint_analyze_corpus.py:155-249,350-474` — reuse safe root-relative handling, checksums, probes, full manifest validation, and exact-byte digest; add strict R3.5 recipe/result readers beside these contracts.
- `lib/py/audlint_analyze_corpus.py:476-620` — reuse lstat snapshots and independent byte-copy staging; add repository-safe temporary source/output roots and declared-output-tree verification without weakening R3.2 behavior.
- `lib/py/audlint_analyze_corpus.py:805-847,942-1081` — reuse atomic-candidate and sanitization patterns plus unchanged R3.4 identity, accuracy, analyzer evidence, aggregates, and summary fields; add Markdown-specific atomic publication and deterministic renderer.
- `lib/py/audlint_analyze_corpus.py:1083-1231` — consume, never rerun or reinterpret, the R3.4 result model; add standalone structural, reference, aggregate, and identity validation that permits a valid failing baseline.
- `bin/audlint-dataset.sh:51-91,92-126,385-484` — remains the declared generator; its fixed input/output shape and `AUDLINT_DATASET_JOBS` control define the permitted R3.5 invocation boundary.
- `test/test_audlint_analyze_corpus_baseline.py` — add isolated temporary corpus/project roots, generator/tool stubs, injected facts, and finalizer-focused safety/publication coverage.
- `test/test_audlint_analyze_corpus_benchmark.py:19-73,258-324` — retain its temporary stub and atomic-failure conventions; adjust only shared test helpers if necessary.

## Tasks & Acceptance

**Execution:**
- [x] `lib/py/audlint_analyze_corpus.py` — add an R3.5 finalizer that validates exact manifest/result bytes and a versioned, explicit recipe representation; rejects missing or ambiguous source, executable, argv/environment, version, and output facts; verifies every declared synthetic entry in manifest order while allowing equivalent normalized invocations to be shared only after validating every linked entry.
- [x] `lib/py/audlint_analyze_corpus.py` — create non-symlink temporary source and output roots outside both supplied corpus and repository; snapshot each referenced source boundary before/after byte staging; require declared-only generated regular files, objective media facts, checksums, sizes, and cleanup before publication.
- [x] `lib/py/audlint_analyze_corpus.py` — strictly validate R3.4 samples, exclusions, aggregates, manifest/result/repository identities, then render the required distinct Markdown sections with stable evidence links and atomically replace only the sibling summary. Keep finalization-gate failure separate from the upstream benchmark verdict.
- [x] `bin/audlint-analyze-corpus.sh` — pass the new explicit finalization command through without owning policy or changing existing modes.
- [x] `test/test_audlint_analyze_corpus_baseline.py` — use temporary byte/media fixtures and executable stubs to prove reproduction, safety, deterministic rendering, faithful failing-baseline publication, atomic non-overwrite, and all recipe/output/cleanup error paths; never access external media.

**Acceptance Criteria:**
- Given complete matching temporary fixture evidence, when finalization runs, then every synthetic entry is independently reproduced from a byte-copied trusted source in serial temporary paths, every source/output fact matches, and a deterministic identity-linked summary is the sole changed stable artifact.
- Given a recipe, source, generator, version, destination, output set, checksum, or media fact inconsistency, when finalization validates it, then it returns nonzero with sanitized diagnostics, attempts cleanup, leaves source evidence unchanged, and cannot replace a prior summary.
- Given a schema-valid R3.4 result containing trusted failures, weak warnings, errors, or exclusions, when all finalization gates pass, then the summary separates those populations and returns the unchanged nonzero verdict where R3.4 requires it.
- Given fixed injected clock/repository/tool facts and the same temporary inputs, when finalization is repeated, then Markdown bytes, references, order, empty-population statements, and machine-evidence links are identical.

## Design Notes

Treat synthetic reproduction as a separate safety gate: R3.4 result validation proves that recorded benchmark evidence is internally consistent; it does not make old opaque recipe strings executable. The new recipe reader must demand executable identity, normalized declared parameters, source mapping, complete output identities, and tool-version facts, so a legacy manifest lacking those facts fails closed instead of being “repaired” from the local installation.

## Verification

**Commands:**
- `python3 -m unittest test.test_audlint_dataset_smoke test.test_audlint_analyze_corpus_smoke test.test_audlint_analyze_corpus_benchmark test.test_audlint_analyze_corpus_baseline test.test_audlint_value_smoke test.test_cue2flac_smoke test.test_any2flac_smoke test.test_dff2flac_smoke` — expected: temporary-fixture R3.5 and related checks pass without external media access.
- `make check` — expected: complete local release gate passes.

## Suggested Review Order

**Finalization entry and artifact gate**

- The single route validates before any synthetic work or atomic publication.
  [`audlint_analyze_corpus.py:1735`](../../lib/py/audlint_analyze_corpus.py#L1735)

- Public dispatch keeps the Bash operator boundary thin.
  [`audlint_analyze_corpus.py:1896`](../../lib/py/audlint_analyze_corpus.py#L1896)

**Lineage and temporary-path safety**

- Recipe normalization rejects ambiguous inputs before generator launch.
  [`audlint_analyze_corpus.py:1336`](../../lib/py/audlint_analyze_corpus.py#L1336)

- Independent roots, snapshots, cleanup, and exact outputs contain generated media.
  [`audlint_analyze_corpus.py:1437`](../../lib/py/audlint_analyze_corpus.py#L1437)

**Evidence validation and publication**

- R3.4 evidence is checked structurally without changing upstream verdicts.
  [`audlint_analyze_corpus.py:1517`](../../lib/py/audlint_analyze_corpus.py#L1517)

- Summary sections derive only from validated machine evidence.
  [`audlint_analyze_corpus.py:1666`](../../lib/py/audlint_analyze_corpus.py#L1666)

- Candidate publication rejects escapes and replaces the summary atomically.
  [`audlint_analyze_corpus.py:1702`](../../lib/py/audlint_analyze_corpus.py#L1702)

**Fixture proof**

- Temporary fixtures cover successful, failing, safety, identity, and CLI paths.
  [`test_audlint_analyze_corpus_baseline.py:101`](../../test/test_audlint_analyze_corpus_baseline.py#L101)
