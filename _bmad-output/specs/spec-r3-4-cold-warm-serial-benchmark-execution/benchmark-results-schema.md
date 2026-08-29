# Benchmark Results Schema

## Stable artifact

R3.4 writes one artifact:

`_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/benchmark-results.json`

It is schema version `1`. JSON serialization uses UTF-8, two-space indentation, lexicographically sorted object keys, LF line endings, and one final newline. Object-key sorting does not reorder arrays.

The result must contain no corpus-root or temporary absolute path. Command and evidence paths use manifest-relative identities or the stable tokens `$STAGE` and `$OUTPUT`.

## Benchmark plan and pair lifecycle

The runner validates the complete R3.1 manifest before selection and requires a positive iteration count, then plans records in this order:

1. manifest entry order;
2. `audlint-analyze`, `audlint-value`, `cue2flac`, `any2flac`, `dff2flac`;
3. iteration `1..N`;
4. `cold`, then `warm`.

Only applicable tool/case combinations enter the plan. A converter combination that is otherwise applicable but lacks a proven safe command form remains in the plan as two `excluded` records. The stable `sample_id` is `<case-id>:<tool>:<iteration>:<cache-condition>`.

For each planned pair:

1. Take the R3.2 source snapshot, create and verify a fresh stage, and create any separate empty temporary output root.
2. Confirm the stage has none of the product's generated cache, done-marker, DR, report, converter-cache, or output artifacts.
3. Record cold cache-artifact facts, time only the cold product subprocess, then capture structured output and post-command artifact facts.
4. Recheck the source subtree. For converters, also compare the complete stage with its pre-command snapshot. Abort the pair on any safety failure.
5. Without running another product command or changing application artifacts, record warm pre-command facts and time the identical command.
6. Capture warm evidence and repeat required source and converter-stage checks.
7. Capture evidence before cleanup, clean the stage and temporary output root on every path, and retain the cleanup verdict.

Every additional iteration repeats this lifecycle from a new stage. The runner never executes two product commands concurrently. Subprocesses spawned internally by a product are forced to one worker wherever the product exposes a supported control.

## Converter eligibility

Eligibility is attached to the exact command form, not to a tool name or a `--dry-run` label. A fixture proof must compare the complete staged input tree before and after the command, including path set, type, size, permission bits, nanosecond modification and status-change times, regular-file SHA-256, and symlink targets without following symlinks.

The safe form may be read-only, plan-only, or dry-run. It must route outputs to a separate temporary root where supported and must not create analyzer sidecars, cache files, report files, artwork state, or output directories in the staged input tree. A missing proof produces `excluded` records without launch. A difference observed after an eligible invocation is `converter_stage_mutated`, makes the run erroneous, and disqualifies that timing sample.

## Top-level object

| Field | Contract |
| --- | --- |
| `schema_version` | Integer `1`. |
| `generated_at_utc` | RFC 3339 UTC publication timestamp. |
| `identity` | Reproducibility identity defined below. |
| `samples` | Every planned sample record in deterministic execution order; raw records are never replaced by aggregates. |
| `exclusions` | Ordered references to samples whose status is `excluded`, carrying case ID, tool, iteration, cache condition, and the same reason object. |
| `aggregates` | Deterministic summaries over successful executed samples only. |
| `summary` | Counts by status and executed state plus `overall_status`. |

`overall_status` is `pass` only when there is no `fail` or `error` sample and no global manifest, stage, timing, publication, source-mutation, or cleanup error. `warn`, `fail`, and `error` retain the R3.2 meaning for analyzer accuracy evidence; any `fail` or `error` makes the overall run nonzero. `excluded` converter samples are visible but do not alone make it nonzero.

The runner builds this object as a temporary candidate. It atomically replaces the stable artifact only after every stage-verification, source-immutability, and converter-stage check passes. On one of those safety failures, the command returns nonzero machine failure evidence to the caller but does not publish the candidate or overwrite a previous valid stable artifact.

## Reproducibility identity

`identity` records:

| Area | Required values |
| --- | --- |
| Manifest | `corpus_id`, `corpus_revision`, and SHA-256 of the exact validated manifest bytes. |
| Repository | Full `HEAD` commit and boolean dirty state captured before product execution. |
| Host | OS name and version, architecture, CPU identity, logical-core count, and memory where discoverable. |
| Toolchain | Version strings for Bash, Python, NumPy, SoX, `soxi`, FFmpeg, `ffprobe`, DR14, and each invoked Audlint tool where discoverable. Missing optional version facts are `null` with an unavailability reason; they are not invented. |
| Analyzer | Requested/effective analyzer mode and every relevant `AUDLINT_ANALYZE_*` setting that can affect work or output. |
| Execution | Iteration count and recorded serial worker overrides, including `ANY2FLAC_ANALYZE_JOBS=1` and `DFF2FLAC_ANALYZE_JOBS=1` when those tools are planned. |
| Cache limitation | A fixed statement that application-cold stages are controlled but operating-system page cache is uncontrolled and no hardware-cold claim is made. |

Environment discovery and version probes occur before or after measured subprocesses, never inside their timed interval.

## Sample record

Each `samples` item contains:

| Field | Contract |
| --- | --- |
| `ordinal` | One-based position in deterministic plan order. |
| `sample_id` | Stable `<case-id>:<tool>:<iteration>:<cache-condition>` identity. |
| `case` | Manifest `id`, root-relative `album_path`, `trust`, `category`, and `case_class`. |
| `tool` | One of the five ordered product tool names. |
| `iteration` | One-based integer. |
| `cache_condition` | Declared `cold` or `warm`. |
| `applicable` | Boolean from manifest facts and the command matrix. |
| `executed` | Whether the product command was launched. |
| `status` | `pass`, `warn`, `fail`, `error`, or `excluded`. |
| `command` | Exact executable and argv with `$STAGE`/`$OUTPUT` tokens, working-directory role, relevant environment overrides, and serial worker settings. It may be `null` only when no safe converter command can be formed, in which case the exclusion reason says so. |
| `exit_status` | Integer child exit status, or `null` when not executed. |
| `elapsed_ms` | Nonnegative monotonic duration in milliseconds, or `null` when not executed or when a safety/timing failure invalidates the sample. |
| `cache_observation` | Declared condition, observed `hit`, `miss`, `bypass`, or `unsupported`, evidence basis, and ordered before/after relevant artifact facts. |
| `accuracy_evidence` | The unchanged R3.2 expected/actual comparison, trust, mismatch reasons, and verdict for applicable analyzer samples; otherwise `null` with a reason. |
| `analyzer_evidence` | The R3.3 work and existing decision context defined below, or `null` with a stable unavailability reason. |
| `safety` | Stage verification, source snapshot comparison, converter-stage comparison when applicable, and cleanup outcome. |
| `diagnostics` | Source-control-safe stdout/stderr digests and bounded sanitized excerpts or references, including truncation flags. |
| `reason` | `null` for an unqualified pass; otherwise a stable code and concise detail for warn, fail, error, or exclusion. |

Cold and warm `command` objects must compare equal. `cache_condition`, cache evidence, exit status, elapsed time, product evidence, safety outcome, diagnostics, and reason may differ.

If cold fails, the warm record has `executed: false`, `status: error`, `elapsed_ms: null`, and reason code `cold_failed`. If warm fails, cold remains a raw sample but the pair and overall result fail. Cleanup failure updates the affected record to `error` even when the product command returned zero.

## Cache observation

Observed state is evidence, not an expectation:

- `miss`: the product's supported cache lookup reports a miss or equivalent structured evidence proves the lookup performed work with no valid prior artifact.
- `hit`: structured product evidence proves a valid retained artifact was used to avoid the corresponding work.
- `bypass`: the command's supported semantics or structured evidence proves that it deliberately did not use the relevant application cache. Current `audlint-analyze --json` samples use this state even when the cold command writes profile sidecars.
- `unsupported`: the product exposes no relevant application cache or no structured evidence can distinguish hit, miss, and bypass.

Before/after artifact facts name only stage-relative paths and record existence, type, byte size, and SHA-256 for regular files. Cache state is never inferred from elapsed time or unstructured log wording.

## R3.3 analyzer evidence

Every successful `audlint-analyze` sample retains these exact R3.3 fields and validates their invariants:

- `track_count`;
- `metadata_probe_count` and `metadata_probe_counts` with exact keys `ffprobe` and `soxi`;
- `decode_operation_count` and `decode_operation_counts` with exact keys `segment` and `full`.

It also retains the existing structured authorities needed to interpret the work: album and per-track strategy, initial strategy and strategy reason; fast-to-exact and segment-to-full fallback state; statistical, analysis, decision, and album confidence; decision and fallback reasons; target profile, fake-upscale, decision, window/segment, and applicable segment-probe evidence.

R3.4 neither recomputes nor aliases these values. A successful analyzer exit with missing, ill-typed, or invariant-breaking required R3.3 evidence is an `error`. Other tools retain such evidence only if their existing structured product boundary exposes it; otherwise `analyzer_evidence` is `null` with `not_exposed_by_tool` and no log scraping or extra untimed analyzer invocation is substituted.

## Deterministic aggregates

`aggregates` declares that only records with `executed: true`, non-null valid `elapsed_ms`, and status `pass` or `warn` are included. It contains groups for the parent-required dimensions: trust, category, case class, tool, cache condition, selected strategy, fast-to-exact fallback, and segment-to-full fallback.

Within each dimension, groups sort lexicographically by normalized key, with an explicit `unavailable` key when structured evidence does not expose that dimension. Each group records sample count and elapsed minimum, median, arithmetic mean, and maximum using the raw millisecond values and a declared fixed rounding precision. Failure, exclusion, and unavailable-evidence counts remain in `summary`; they are never folded into elapsed statistics.

## Required verification evidence

Focused temporary-fixture tests must demonstrate:

1. cold stages contain only declared inputs and warm runs retain cold-created application artifacts;
2. tools, cases, and iterations receive distinct stages, while cold/warm commands within a pair are identical;
3. subprocess intervals never overlap and supported worker settings arrive as `1`;
4. injected delays in staging, hashing, evidence parsing, source checks, aggregation, publication, and cleanup do not change the measured product interval, while an injected child delay does;
5. a converter without an exact safety proof is excluded and its launch log remains empty;
6. an eligible converter whose stub mutates the stage becomes an error, has its elapsed value invalidated, returns nonzero, and cannot create or replace the stable artifact;
7. result serialization, array order, sample IDs, nullability, status counts, exclusion references, and aggregates are deterministic for fixed fixture inputs and clock values;
8. all raw iterations remain present;
9. cache miss, hit, bypass, and unsupported evidence paths are represented without timing inference;
10. cold failure suppresses warm launch, warm failure preserves cold evidence, every failure propagates to a nonzero exit, and source checks plus cleanup still run.

The focused command is:

`python3 -m unittest test.test_audlint_analyze_corpus_smoke test.test_audlint_analyze_corpus_benchmark test.test_audlint_value_smoke test.test_cue2flac_smoke test.test_any2flac_smoke test.test_dff2flac_smoke`

The repository completion gate is `make check`. Tests mirror the production output path under a temporary project root; they do not write fixture results into the repository's real benchmark directory or access the approved external corpus.
