---
id: SPEC-r3-4-cold-warm-serial-benchmark-execution
companions:
  - benchmark-results-schema.md
sources:
  - ../spec-r3-analyzer-corpus-benchmark-baseline/SPEC.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/corpus-manifest.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/benchmark-protocol.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/brownfield.md
  - ../spec-r3-1-corpus-manifest-safe-inventory/SPEC.md
  - ../spec-r3-2-immutable-staging-accuracy-verdict/SPEC.md
  - ../spec-r3-3-analyzer-work-instrumentation/SPEC.md
  - ../../../docs/architecture/OVERVIEW.md
---

> **Canonical contract.** This SPEC and `benchmark-results-schema.md` are the complete, preservation-validated contract for what R3.4 builds, tests, and validates. Source documents are listed only for traceability; this child contract absorbs every requirement needed by a fresh-context implementation.

# R3.4 Cold/Warm Serial Benchmark Execution

## Why

R3.1 defines trustworthy corpus identity, R3.2 defines safe staged execution, and R3.3 defines analyzer work evidence, but Audlint still lacks reproducible raw runtime samples for its supported analysis and safe conversion-planning paths. Maintainers need that baseline before optimization, cache-policy, or parallelism work can be judged without contaminating measurements, warming one tool with another, or risking writes to the approved corpus.

## Capabilities

- **CAP-1 — Validated benchmark plan**
  - **intent:** Maintainers can derive the exact applicable benchmark work from one validated R3.1 manifest without weakening corpus identity, selection, or order.
  - **success:** Full R3.1 validation completes before planning; applicable tool/case records are produced in manifest order with manifest SHA-256 and revision, while invalid manifests, unresolved selections, or missing required analysis dependencies stop before product execution.

- **CAP-2 — Isolated serial cold/warm execution**
  - **intent:** Maintainers can compare application-cold and application-warm behavior without cross-tool, cross-case, cross-iteration, or worker concurrency contamination.
  - **success:** Every applicable tool/case iteration uses a separate fresh R3.2 stage, runs one cold command followed by its identical warm command in that stage, retains only the cold command's generated artifacts between the pair, forces every supported worker control to `1`, and never overlaps measured product commands.

- **CAP-3 — Product-only monotonic timing**
  - **intent:** Maintainers can attribute each elapsed sample to the product command rather than corpus preparation or benchmark bookkeeping.
  - **success:** `elapsed_ms` is derived from a monotonic clock around product subprocess launch through termination and pipe drain only; manifest work, staging, hashing, snapshots, evidence parsing, verification, aggregation, publication, and cleanup are demonstrably outside the interval.

- **CAP-4 — Complete raw benchmark evidence**
  - **intent:** Maintainers can reproduce and interpret every measurement without scraping logs or relying on aggregates alone.
  - **success:** The exact parent-defined `benchmark-results.json` contains every ordered planned sample and all executed raw elapsed values, exact sanitized command identity, exit status, declared and observed cache state, applicable R3.2 verdict evidence, applicable R3.3 counters and decision context, failures or exclusions, deterministic aggregates, and the reproducibility identity defined in the companion.

- **CAP-5 — Safe converter exclusion and failure propagation**
  - **intent:** Maintainers can include converter planning cost only when the measured path is proven non-mutating and can trust failures to remain visible.
  - **success:** `cue2flac`, `any2flac`, and `dff2flac` execute only through an exact fixture-proven read-only, plan-only, or dry-run form; an unproven case is recorded as `excluded` without launch, any mutation after launch is an `error`, and every command, evidence, safety, or cleanup error makes the overall run nonzero.

## Constraints

- R3.4 depends on the completed R3.1 validator, the R3.2 stage/snapshot/cleanup boundary and accuracy evidence, and the exact R3.3 successful `audlint-analyze --json` fields and counting semantics. It may aggregate or retain those contracts but may not add, coerce, infer, rename, or reinterpret them.
- Applicable work is: `audlint-analyze` for every analyzable manifest entry; `audlint-value` for entries supported by the analyzer and DR14 dependencies; `cue2flac` for declared CUE cases; `any2flac` for applicable PCM or lossy cases; and `dff2flac` for declared DFF cases. Missing runtime dependencies for required analysis work are errors, not benchmark exclusions.
- Deterministic execution order is manifest entry, then tool order `audlint-analyze`, `audlint-value`, `cue2flac`, `any2flac`, `dff2flac`, then iteration number, then `cold` followed by `warm`.
- A `cold` sample starts from a newly created, checksum-verified R3.2 stage containing only manifest-declared inputs and no generated Audlint cache, done marker, DR report, converter cache, report, or output relevant to that command.
- A `warm` sample is the immediate identical second product invocation in the same stage. It retains every artifact generated by the cold command, but no other product command or deliberate cache manipulation may run between the pair. Evidence capture between the commands is outside timing and must not modify application state.
- Cold means application-cold only. Operating-system page cache is uncontrolled; R3.4 performs no privileged eviction, records this limitation in every result, and never labels a measurement hardware-cold.
- Iteration count is a required positive integer. Each tool/case/iteration pair receives its own fresh stage outside the corpus root; more than one requested iteration means a new stage and complete cold/warm pair each time, and no stage or temporary output root is reused across tools, cases, or iterations.
- Only one measured product command may run at a time. Set every supported internal worker control to its serial value and record it; current converter controls include `ANY2FLAC_ANALYZE_JOBS=1` and `DFF2FLAC_ANALYZE_JOBS=1`. Do not invent a control for a tool that exposes none.
- Start `time.monotonic_ns()` immediately before subprocess launch and stop immediately after the child terminates and captured pipes are drained. Convert the difference to nonnegative `elapsed_ms`; do not use wall-clock timestamps or shell `time` as the elapsed authority.
- Cold and warm use the same executable, argument vector, working-directory role, temporary-output role, analyzer settings, and environment overrides. Stable `$STAGE` and `$OUTPUT` tokens replace temporary absolute paths in committed command evidence without hiding executable names, flags, relative input identities, or serial settings.
- `audlint-analyze` and `audlint-value` may create application artifacts only inside their disposable stage or temporary output paths. R3.2 source snapshots run before and after every attempted command, including nonzero exit or malformed output, and cleanup is attempted on every path; none of that work is timed.
- A converter command form is eligible only after a focused temporary-fixture test proves that the exact executable, flags, working-directory role, and output routing leave the complete staged input tree unchanged. Dry-run naming or absence of converted FLAC files is not proof.
- Eligible converter commands receive complete pre/post stage snapshots around both cold and warm invocations and use a separate temporary output root where the tool supports one. If no eligible form exists, record ordered `excluded` samples with `executed: false` and a stable reason and do not launch the converter. If an eligible command mutates the stage at runtime, record `error`; do not relabel it as excluded or retain its timing as valid benchmark data.
- Consume R3.3 counters and existing strategy, fallback, confidence, reason, target, fake-upscale, and decision evidence only from structured product output. They are required for successful `audlint-analyze` samples. A tool that does not expose them records `null` plus a stable unavailability reason; the runner never scrapes human-readable logs or infers work from elapsed time.
- Declared cache condition is `cold` or `warm`; observed cache state is `hit`, `miss`, `bypass`, or `unsupported`. Each state cites structured product evidence and/or before/after facts for relevant generated artifacts. Elapsed time alone cannot establish cache state, and `audlint-analyze --json`'s current intentional fresh-analysis behavior must be reported as bypass rather than a fabricated warm hit.
- If a cold command errors, its warm command is not launched because the retained state is not a valid warm baseline; the ordered warm record remains with `executed: false`, `status: error`, and reason `cold_failed`. A warm failure preserves the cold raw sample but makes the pair and overall result erroneous.
- Converter safety exclusions alone do not make the overall result nonzero. Any attempted command failure, malformed required structured output, manifest or staging error, source or stage mutation, timing failure, publication failure, or cleanup failure does.
- Preserve every planned sample and every executed raw measurement in the companion-defined structure. Aggregates include successful executed samples only, declare their method, and remain secondary to raw evidence.
- Publish only `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/benchmark-results.json`. Build it through a temporary candidate and atomically replace the stable file only after all stage verification, source-immutability, and converter-stage checks pass; a safety failure returns nonzero failure evidence but leaves any existing stable artifact untouched. The published file is one UTF-8 JSON object with schema version `1`, two-space indentation, lexicographically sorted object keys, LF endings, one final newline, and arrays in the execution order defined above.
- `bin/audlint-analyze-corpus.sh` remains a thin argument and environment boundary. Planning, subprocess timing, evidence shaping, aggregation, and deterministic JSON publication belong in `lib/py/audlint_analyze_corpus.py` or focused shared Python modules; existing shared staging and instrumentation authorities are reused.
- Automated verification uses repository-owned temporary fixtures and stub product commands only. It must not access `/Volumes/Music/Tests`, a real music library, live SQLite database, mounted sync destination, backup target, or destructive audio, tag, artwork, or conversion workflow.
- Focused tests prove cold stage emptiness, warm artifact retention, fresh stages across tools and iterations, exact cold/warm command equality, no product-command overlap, serial worker enforcement, timing-boundary exclusion, converter exclusion without launch, post-gate converter mutation failure, cache evidence states, deterministic structure and order, raw-sample retention, cold and warm failure propagation, source immutability, and cleanup after success and failure.
- Preserve Bash 5, Python portability across supported macOS/Linux hosts, canonical `SR_HZ/BITS` profiles, and `audlint-analyze` as the sole recode-decision authority.

## Non-goals

- Implementing or changing R3.1 manifest, inventory, coverage, expectation, provenance, trust, or generated-manifest behavior.
- Redesigning R3.2 selection, staging, source snapshots, accuracy verdicts, evidence semantics, or cleanup.
- Adding or changing R3.3 instrumentation fields, counting rules, strategies, fallbacks, confidence, or decision evidence.
- Optimizing performance, reducing work, changing cache reads, writes, invalidation, or policy, or claiming a hardware-cold benchmark.
- Changing analyzer modes, thresholds, decisions, decode reuse, probe order, fallback behavior, or worker models.
- Executing or benchmarking parallel analysis or conversion.
- Reproducing synthetic corpus media or generation recipes.
- Publishing `baseline-summary.md` or any final human-readable baseline.
- Implementing R3A, R4, R5, R6, or later roadmap work.

## Success signal

`python3 -m unittest test.test_audlint_analyze_corpus_smoke test.test_audlint_analyze_corpus_benchmark test.test_audlint_value_smoke test.test_cue2flac_smoke test.test_any2flac_smoke test.test_dff2flac_smoke` proves the complete contract with temporary fixtures, including that an isolated temporary project root receives the exact stable `benchmark-results.json` relative path and no fixture source changes. `make check` then passes. An operator-approved real-corpus invocation can subsequently publish the actual R3.4 artifact with complete cold/warm pairs or explicit converter exclusions; that invocation is not part of unattended automated verification.
