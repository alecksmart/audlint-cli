# Brownfield Baseline

These facts describe the implementation at spec creation. They define the change boundary, not completed R3 behavior.

Scope is derived from the `R3 — Build the analyzer evidence base` section of `_bmad-output/planning-artifacts/product-roadmap.md`; unrelated roadmap capabilities are intentionally outside this bounded contract.

## Existing behavior

| Area | Current fact |
| --- | --- |
| Corpus entry point | `bin/audlint-analyze-corpus.sh` delegates to `lib/py/audlint_analyze_corpus.py`. |
| Manifest input | The runner accepts either a list or an object with `entries`; entries contain a path, trust, label, target-profile expectation, decision expectation, fake-upscale expectation, and optional analysis-mode expectation. |
| Verdict | Trusted mismatches fail; weak mismatches warn; execution errors fail. Existing fixture tests cover trusted failure and weak warning. |
| Path handling | Entries currently carry direct paths, and the runner passes each path directly to `audlint-analyze --json`; there is no corpus-root abstraction or staging boundary. |
| Trust parsing | Any value other than literal `trusted` is normalized to `weak`, so malformed trust values are not rejected. |
| Dataset builder | `bin/audlint-dataset.sh` builds genuine lower-profile and MP3/AAC/Opus fake derivatives with bounded jobs, but it does not own a versioned inventory or provenance record. |

## Safety gap

`bin/audlint-analyze.sh --json` performs fresh analysis and then writes `.sox_album_profile`; it may also create or remove `.sox_album_done`. Direct execution against `/Volumes/Music/Tests` therefore violates the immutable-input requirement even though the media payload is only decoded.

`bin/audlint-value.sh` invokes the analyzer and `dr14meter`, reads analyzer sidecars, and may discover or create DR report evidence. It also requires an isolated copied stage.

Converter help advertises dry-run behavior, but R3 accepts timing only after a pre/post fixture test proves that the selected invocation leaves staged inputs unchanged.

## Observability gap

The analyzer JSON already exposes album and per-track strategy, fast-to-exact escalation, segment-to-full escalation, confidence, decision and fallback reasons, windows/segments, and decode-operation data. The corpus runner currently retains only a small album-level subset.

R3 must add or surface:

- Monotonic command timing.
- Track-count aggregation.
- Explicit external metadata-probe invocation counters.
- Complete decode-work aggregation, including segment-probe work.
- Cache-condition and observed cache behavior.
- Per-tool command failure and exclusion reasons.
- Reproducibility identity for the manifest, repository, host, toolchain, and analyzer configuration.

## Ownership boundary

| Responsibility | Owner |
| --- | --- |
| CLI argument parsing and orchestration | `bin/audlint-analyze-corpus.sh` remains thin. |
| Manifest validation, staging, verdict aggregation, benchmark records | `lib/py/audlint_analyze_corpus.py` or focused shared Python modules. |
| Analyzer work counters and structured decision evidence | `lib/py/audlint_analyze.py` and its shell boundary. |
| Shared media probing policy | Existing `lib/sh/` or `lib/py/` probing authority; do not duplicate it in the entry script. |
| Synthetic generation | `bin/audlint-dataset.sh` plus versioned recipe and provenance metadata. |
| Safety and regression verification | Temporary-fixture tests, especially `test/test_audlint_analyze_corpus_smoke.py` and `test/test_audlint_dataset_smoke.py`. |

R3 measures and exposes the present implementation. Cache-policy changes belong to R3A, analyzer contract convergence to R4, decision tuning to R5, and parallel execution to R6/R7.
