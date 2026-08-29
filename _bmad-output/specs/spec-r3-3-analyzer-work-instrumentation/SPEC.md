---
id: SPEC-r3-3-analyzer-work-instrumentation
companions: []
sources:
  - ../spec-r3-analyzer-corpus-benchmark-baseline/SPEC.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/corpus-manifest.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/benchmark-protocol.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/brownfield.md
  - ../spec-r3-1-corpus-manifest-safe-inventory/SPEC.md
  - ../spec-r3-2-immutable-staging-accuracy-verdict/SPEC.md
  - ../../../docs/architecture/OVERVIEW.md
---

> **Canonical contract.** This SPEC is the complete, preservation-validated contract for what R3.3 builds, tests, and validates. Source documents are listed only for traceability; this child contract absorbs every requirement needed by a fresh-context implementation.

# R3.3 Analyzer Work Instrumentation

## Why

The analyzer already exposes its decisions, strategies, fallbacks, confidence, and some successful decode evidence, but it does not report the external metadata probes and decoder attempts that produced them or an explicit analyzed-track total. Maintainers need reliable machine-readable work evidence for the parent R3 baseline without scraping logs or changing the analyzer behavior being measured.

## Capabilities

- **CAP-1 — Structured work summary**
  - **intent:** Benchmark consumers can read total analyzed-track, metadata-probe, and decode-operation counts from the existing analyzer JSON boundary.
  - **success:** Every successful `audlint-analyze --json` result contains well-typed additive counters whose totals and breakdowns satisfy the counting invariants in this contract.

- **CAP-2 — External metadata-probe evidence**
  - **intent:** Maintainers can see how many external metadata probes the analyzer actually launches, including repeated `ffprobe` and `soxi` work.
  - **success:** Fixture tool logs exactly match the reported `ffprobe`, `soxi`, and combined metadata-probe invocation counts for normal and multi-track runs, including failed or repeated probes.

- **CAP-3 — Complete decode-work evidence**
  - **intent:** Maintainers can distinguish segment decode work from whole-track decode work while retaining retries and segment-to-full fallback cost.
  - **success:** Fixture decoder logs exactly match the reported segment, full, and combined decode-operation counts; a segment-to-full fallback retains every segment attempt and adds the whole-track attempt, while fast-to-exact reuse adds no decode operation.

- **CAP-4 — Preserved decision context**
  - **intent:** Benchmark consumers can associate work counts with the analyzer's selected strategy, fallback path, confidence, and decision evidence without a second interpretation layer.
  - **success:** Album and per-track strategy, fallback, confidence, reason, target-profile, fake-upscale, and decision fields remain available under their existing names and retain their pre-R3.3 values for the same fixture inputs.

## Constraints

- Successful album JSON adds exactly these top-level work fields:
  - `track_count`: number of objects in `tracks`.
  - `metadata_probe_count`: total external metadata-probe process invocations.
  - `metadata_probe_counts`: object with exact keys `ffprobe` and `soxi`.
  - `decode_operation_count`: total external PCM decoder process invocations.
  - `decode_operation_counts`: object with exact keys `segment` and `full`.
- Every new counter and breakdown value is a nonnegative integer. Zero-valued breakdown keys remain present. `metadata_probe_count` equals `metadata_probe_counts.ffprobe + metadata_probe_counts.soxi`; `decode_operation_count` equals `decode_operation_counts.segment + decode_operation_counts.full`.
- The top-level counters cover all applicable work launched from the start of one `audlint-analyze --json` invocation until its JSON is finalized, including Python analyzer work and shared shell metadata probing. They remain authoritative even when an input is probed but existing analyzer behavior does not emit a track object for it.
- Count one metadata probe immediately before each external `ffprobe` or `soxi` process launch made to obtain analyzer metadata. Count repeated calls for the same file, nonzero exits, and malformed or empty results separately because each launch performed work. Do not count `command -v` or equivalent availability checks, in-process file inspection, source fingerprint reads, or `ffmpeg`/`sox` decoder processes as metadata probes.
- Count one decode operation immediately before each external `ffmpeg` or `sox` process launch that requests PCM for spectral analysis. Count failed launches, nonzero exits, timeouts, and a second backend attempt separately. Do not count FFT windows, channel passes over existing PCM, decision recomputation, temporary-file cleanup, or fast-to-exact analysis that reuses an existing decode.
- Classify a decoder launch as `segment` when it requests a bounded source span for segment analysis and as `full` when it requests the analyzer's whole-track decode path. Segment-to-full fallback therefore preserves all earlier `segment` operations and adds every later `full` backend attempt.
- Existing per-track `decode_operations` and `segment_probe_decode_operations` keep their current successful logical-decode meanings. R3.3 does not rename or reinterpret them; the new process-invocation counters may be larger when a decoder attempt fails before another backend succeeds.
- Existing fields remain the strategy and fallback authority: album `album_analysis_strategies` and per-track `analysis_strategy`, `initial_analysis_strategy`, and `analysis_strategy_reason`; album and per-track `auto_exact_fallback`; and album `album_strategy_fallback_to_full` plus per-track `strategy_fallback_to_full`. R3.3 adds no duplicate strategy or fallback aliases.
- Existing album `album_confidence` and per-track `analysis_confidence`, `statistical_confidence`, `decision_confidence`, `decision_reason`, and `fallback_reason` remain unchanged. When segment-to-full fallback occurs, the applicable existing `segment_probe_analysis_*`, `segment_probe_decision_*`, and `segment_probe_fallback_reason` fields also remain unchanged and machine-readable.
- The same inputs and configuration must produce the same requested and effective analysis modes, strategy selection, fallback triggers, windows and segments, cutoff evidence, target profiles, fake-upscale values, recode decisions, downgrade guards, album aggregation, exit status, text output, and existing JSON values as before R3.3. Thresholds, decode reuse, serial execution, cache reads, cache writes, invalidation, and short-circuit policy do not change.
- Shared counter state, increment rules, and JSON shaping belong in `lib/py/` or `lib/sh/`. `bin/audlint-analyze.sh` may initialize and finalize shared instrumentation at its existing boundary but must remain a thin orchestration script and must not duplicate probe or decode counting policy.
- Automated verification uses repository-owned temporary fixtures and stub `ffprobe`, `soxi`, `ffmpeg`, and `sox` executables only. It must not access `/Volumes/Music/Tests`, a real music library, live SQLite database, mounted sync destination, backup target, or destructive audio, tag, artwork, or converter workflow.
- Focused tests in `test/test_audlint_analyze_cache_smoke.py` and, where computation-only assertions fit, `test/test_audlint_analyze_logic.py` prove:
  - a normal one-track run reports one track and matches every probe/decode stub launch;
  - a failed first decoder backend plus a successful second backend reports two full decode operations while existing `decode_operations` remains one;
  - fast-to-exact fallback over reused PCM sets existing fallback state without increasing the decode-operation count;
  - segment-to-full fallback reports all segment attempts plus all full attempts and preserves its existing segment-probe evidence;
  - a multi-track run reports `track_count == len(tracks)` and command totals matching the complete stub logs; and
  - existing decision and evidence fields retain their prior fixture values apart from the additive fields named above.
- Completion requires `python3 -m unittest test.test_audlint_analyze_logic test.test_audlint_analyze_cache_smoke` and the repository release gate `make check` to pass without external corpus or real-library access.
- Preserve canonical `SR_HZ/BITS` profiles, Bash 5, and macOS/Linux portability.

## Non-goals

- Implementing or changing R3.1 manifest, schema, inventory, provenance, trust, or coverage behavior.
- Implementing or changing R3.2 corpus selection, staging, immutability verification, accuracy verdicts, cleanup, or aggregation-ready case evidence.
- Adding elapsed-time measurement, cold/warm execution, cache-state benchmarking, final benchmark aggregation, `benchmark-results.json`, or `baseline-summary.md`.
- Changing cache policy, cache invalidation, analyzer thresholds, decision policy, strategy selection, fallback policy, decode reuse, probe order, decode order, or execution strategy.
- Optimizing or reducing probes, decodes, fallback work, or runtime.
- Timing or changing `audlint-value`, `cue2flac`, `any2flac`, `dff2flac`, or any converter.
- Reproducing synthetic corpus media or generation checksums and recipes.
- Adding parallelism or implementing R3A, R4, R5, R6, or later roadmap work.

## Success signal

The focused analyzer tests prove from stub process logs that normal, retry, fallback, and multi-track JSON results report the exact work launched while all pre-existing analyzer decisions and evidence stay unchanged; `make check` then passes as the repository-wide release gate.
