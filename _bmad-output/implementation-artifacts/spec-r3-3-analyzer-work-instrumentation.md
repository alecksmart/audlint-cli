---
title: 'R3.3 Analyzer Work Instrumentation'
type: 'feature'
created: '2026-08-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'e23caf4c8bf02fa4fd5074a6adedc600bd4565ee'
context:
  - '{project-root}/docs/architecture/OVERVIEW.md'
  - '{project-root}/_bmad-output/specs/spec-r3-3-analyzer-work-instrumentation/SPEC.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `audlint-analyze --json` reports analysis decisions and successful logical decode evidence, but not the metadata probes and decoder process attempts that performed the work. R3 needs additive, exact work counts without changing analysis results, cache behavior, or execution order.

**Approach:** Add invocation-scoped instrumentation across the Python analyzer and the shared shell metadata probe boundary. Final JSON will report typed track, metadata-probe, and decoder-process totals while preserving every existing decision, fallback, confidence, and logical-decode field.

## Boundaries & Constraints

**Always:** Successful JSON adds exactly `track_count`, `metadata_probe_count`, `metadata_probe_counts` (`ffprobe`, `soxi`), `decode_operation_count`, and `decode_operation_counts` (`segment`, `full`). Every value is a nonnegative integer; both totals equal the sum of their exact-key breakdowns. Count immediately before every relevant external launch, including repeat calls, failures, timeouts, malformed results, and decoder backend retries. Count shell and Python metadata work from the start of the invocation until JSON finalization, even if a probed input does not become a track. A bounded PCM request is `segment`; a whole-track PCM request is `full`. Preserve pre-existing JSON names and values, target profile normalization, analyzer decisions, execution order, cache reads/writes, reuse, and serial operation. Use only repository-owned temporary fixtures and stub tools.

**Ask First:** Changing analyzer policy, thresholds, cache or invalidation behavior, JSON decision/fallback/confidence field names or meanings, the R3.1/R3.2 corpus contracts, or testing against a real library, database, mounted corpus, or destructive media workflow.

**Never:** Count tool-availability checks, in-process inspection, source fingerprints, FFT/channel work, cleanup, reuse without a decoder launch, or non-PCM encoder work as an instrumented operation. Do not add timing, benchmark artifacts, parallelism, R3.4+ behavior, duplicate decision/fallback aliases, or non-serial execution.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Normal analysis | One fixture track; successful metadata and PCM tools | One emitted track and JSON counts exactly equal all probe/decoder stub-log entries | Zero-valued breakdown keys still exist |
| Decoder retry | First whole-track backend fails; second succeeds | `full` count records both launches while existing logical `decode_operations` remains one | Preserve existing result and failure behavior |
| PCM reuse | Fast analysis falls back to exact using existing PCM | Existing fallback evidence is present; no additional decoder operation is counted | Do not alter reuse policy |
| Segment fallback | Segment work leads to whole-track fallback | Counts retain every segment attempt and add every full attempt; existing segment evidence remains | Failed backend attempts are retained |
| Multi-track or omitted track | Several inputs, including any already-probed input not emitted | `track_count == len(tracks)`; process totals cover all invocation work | No path or source behavior changes |

</frozen-after-approval>

## Code Map

- `lib/py/audlint_analyze.py:184-322` -- `soxi` and all `ffprobe` launch helpers; increment the shared metadata counter immediately before `subprocess.run`.
- `lib/py/audlint_analyze.py:404-433` -- `audio_meta()` orchestrates Python probe calls and must retain its current fallback/order behavior.
- `lib/py/audlint_analyze.py:461-584` -- one decoder launch boundary plus segment/full request construction; count each backend attempt before launch and classify from bounded-span arguments.
- `lib/py/audlint_analyze.py:1344-1641` -- existing logical decode, PCM reuse, and segment-to-full fallback semantics; do not redefine their per-track counters.
- `lib/py/audlint_analyze.py:1885-2063` -- per-track and album JSON shaping; add only the five top-level fields after all work is known.
- `lib/sh/audio.sh:155-174` -- shared shell `ffprobe` metadata path used after Python analysis; include it in the same invocation count without changing cache semantics.
- `bin/audlint-analyze.sh:219-230,270-328` -- thin orchestration boundary that initializes/finalizes shared state and emits finalized JSON; keep count policy outside the entry script.
- `test/test_audlint_analyze_cache_smoke.py:44-163,229-493,714-749` -- portable stub tools and existing retry/reuse/segment tests to extend with exact command logs and additive JSON assertions.
- `test/test_audlint_analyze_logic.py` -- use only if a small computation-only invariant/helper can be isolated without process fixtures.

## Tasks & Acceptance

**Execution:**

- [x] `lib/py/audlint_analyze.py` -- introduce an invocation-safe shared event/count interface, instrument every Python metadata and PCM decoder process launch, and shape additive counters without changing existing logical counters or decisions.
- [x] `lib/sh/` shared analyzer instrumentation helper and `lib/sh/audio.sh` -- own portable invocation state plus final counter aggregation; instrument the shared shell `ffprobe` launch while preserving its cache and probe behavior.
- [x] `bin/audlint-analyze.sh` -- initialize, pass through, and finalize shared instrumentation at its existing JSON boundary only; retain thin orchestration.
- [x] `test/test_audlint_analyze_cache_smoke.py` -- log stub `ffprobe`, `soxi`, `ffmpeg`, and `sox` launches and prove normal, retry, reuse, segment-fallback, multi-track, typing, totals, and pre-existing evidence behavior using temporary fixtures.
- [x] `test/test_audlint_analyze_logic.py` -- add computation-only counter/invariant assertions only if the implementation exposes a pure helper worth testing independently.

**Acceptance Criteria:**

- Given any successful analyzer JSON result, when its work summary is read, then it has exactly the specified typed fields and invariant-preserving totals, with `track_count` equal to the emitted track array length.
- Given repeated, failed, or retried metadata and decoder launches, when fixture logs are compared with JSON, then each individual process launch is counted once in the correct category.
- Given fast-to-exact reuse or segment-to-full fallback, when analysis completes, then process counts distinguish reuse from all attempts and existing fallback, confidence, strategy, decision, and logical-decode evidence retains its prior values.
- Given normal and multi-track fixture inputs, when all shell and Python work finishes, then the top-level totals include the complete invocation and no analyzer policy or externally visible text/exit behavior changes.

## Design Notes

One invocation-scoped event stream avoids losing the shell metadata probes that occur after Python writes its temporary JSON. The finalization boundary aggregates that stream into exact-key counters; Python may also finalize consistently for direct analysis callers. This preserves the existing layering: Python owns analysis, shared shell owns shell probing, and `bin/` only orchestrates.

## Verification

**Commands:**

- `python3 -m unittest test.test_audlint_analyze_logic test.test_audlint_analyze_cache_smoke` -- expected: all focused instrumentation and existing analyzer assertions pass using only temporary fixtures and stubs.
- `make check` -- expected: the complete local release gate passes.

## Verification Result

- `python3 -m unittest test.test_audlint_analyze_logic test.test_audlint_analyze_cache_smoke` -- passed (45 tests).
- `python3 -m unittest test.test_lyrics_smoke.LyricsSmokeTests.test_lyrics_album_returns_nonzero_when_embed_fails` -- passed after the fixture creates an empty album-local `.env`.
- `make check` -- passed: 305 core tests (1 expected skip) and 78 legacy tests.

## Suggested Review Order

**JSON work boundary**

- Initializes instrumentation only for JSON analysis and finalizes the emitted payload.
  [`audlint-analyze.sh:319`](../../bin/audlint-analyze.sh#L319)

- Records process launches and shapes the additive analyzer JSON work fields.
  [`audlint_analyze.py:99`](../../lib/py/audlint_analyze.py#L99)

**Shared shell metadata work**

- Maintains invocation-scoped shell event state and final JSON aggregation.
  [`analyze_work.sh:1`](../../lib/sh/analyze_work.sh#L1)

- Records the post-analysis shell metadata probe without coupling other consumers.
  [`audio.sh:171`](../../lib/sh/audio.sh#L171)

**Verification**

- Exercises probe/decode totals, retries, reuse, fallbacks, and omitted tracks.
  [`test_audlint_analyze_cache_smoke.py:289`](../../test/test_audlint_analyze_cache_smoke.py#L289)

- Keeps the lyrics failure fixture isolated from repository-level environment state.
  [`test_lyrics_smoke.py:118`](../../test/test_lyrics_smoke.py#L118)
