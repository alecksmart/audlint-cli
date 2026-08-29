---
id: SPEC-r3-analyzer-corpus-benchmark-baseline
companions:
  - corpus-manifest.md
  - benchmark-protocol.md
  - brownfield.md
  - ../../../docs/architecture/OVERVIEW.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# R3 Analyzer Corpus and Benchmark Baseline

## Why

Audlint has a corpus runner and synthetic dataset builder but no durable representative inventory or current accuracy/runtime record. Without evidence whose provenance and execution safety are explicit, analyzer tuning, cache work, and parallelism could preserve historical output while worsening truth, repeat work, or write derived files into the approved external corpus.

## Capabilities

- **CAP-1 — Versioned corpus inventory**
  - **intent:** Maintainers can identify every approved corpus case, its media facts, expected outcomes, provenance, and trust level without depending on machine-specific paths.
  - **success:** A schema-valid manifest records stable relative paths, checksums, objective codec/container metadata, human-supplied expected source and target profiles, expected decisions, label provenance, and `trusted` or `weak` status for every inventoried case; automation never creates or promotes expected analyzer truth.

- **CAP-2 — Immutable staged execution**
  - **intent:** Maintainers can evaluate external corpus cases without exposing the corpus to analyzer, DR, report, cache, or converter writes.
  - **success:** Every command runs only against a verified byte-for-byte temporary copy, no executable receives a corpus path as its writable album or output path, and complete pre/post snapshots detect any added, removed, or changed entry in each selected case directory without hashing unrelated cases.

- **CAP-3 — Trust-aware accuracy verdict**
  - **intent:** Maintainers can distinguish decision regressions from uncertain labels while retaining the evidence needed to review either outcome.
  - **success:** Trusted mismatches and execution errors produce a nonzero verdict; weak mismatches remain explicit warnings; only explicit human review can promote provenance and expected profile, decision, or fake-upscale values to `trusted`; missing trusted truth stops the run instead of being inferred from Audlint output.

- **CAP-4 — Reproducible serial runtime baseline**
  - **intent:** Maintainers can measure current analyzer work and elapsed time under declared cold and warm application-cache conditions before optimization begins.
  - **success:** Stable generated artifacts contain applicable cold/warm serial measurements for `audlint-analyze`, `audlint-value`, `cue2flac`, `any2flac`, and `dff2flac`, including environment identity, track and work counters, strategy, cache state, fallbacks, confidence, and failures or exclusions.

- **CAP-5 — Reproducible synthetic lineage**
  - **intent:** Maintainers can reproduce declared genuine and fake derivatives independently of Audlint's current verdict.
  - **success:** Each synthetic case records its trusted source checksum and generation recipe, and `audlint-dataset.sh` can recreate it in temporary output with matching declared metadata and checksum without committing audio.

## Constraints

- `/Volumes/Music/Tests` is immutable input: the implementation may read it only to inventory or copy declared inputs into temporary staging and must never create, remove, rename, rewrite, retag, chmod, or timestamp anything inside it.
- Stages contain byte-for-byte copies, never symlinks or hard links, and live outside the corpus root; staging and verification time is excluded from command timing.
- Source immutability covers the complete subtree of each selected case directory, not only manifest-declared files. Unrelated corpus cases are outside that run's snapshot and hashing boundary.
- The generated runtime artifacts are `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest.json`, `benchmark-results.json`, and `baseline-summary.md`; the sibling Markdown companions of this SPEC define their contract and are not generated runtime evidence.
- Automated tests use repository-owned temporary fixtures. No real music library, live SQLite database, mounted sync destination, backup target, or destructive conversion flow may be used.
- `audlint-analyze` remains the sole recode-decision authority; the runner evaluates structured output without reconstructing analyzer policy.
- The baseline is serial and deterministic. It exposes repeated work and fallback cost without changing analyzer thresholds, decision rules, cache semantics, or worker models.
- Audio stays outside Git. Committed R3 artifacts contain only manifests, checksums, reviewed labels, generation recipes, source-control-safe logs or summaries, and benchmark results under BMAD output.
- Shared instrumentation belongs in `lib/sh/` or `lib/py/`; `bin/` scripts remain orchestration layers.
- Preserve canonical `SR_HZ/BITS` PCM profiles, Bash 5, and macOS/Linux portability.

## Non-goals

- Tuning spectral thresholds, voting, confidence, or fallback policy.
- Optimizing cache reuse, metadata probing, decode count, or runtime.
- Converging all analyzer consumers on a revised decision contract.
- Introducing or benchmarking parallel analysis or conversion.
- Making converter behavior writable merely because it runs inside a disposable stage.
- Adding CI/release automation, redistributing corpus audio, or using library database results as ground truth.

## Success signal

One explicit corpus-root invocation inventories and evaluates the approved cases through temporary copies, leaves the external tree byte-for-byte unchanged, fails on any trusted mismatch, warns on weak mismatches, and emits a reproducible accuracy/runtime baseline that makes cache hits, repeated probes/decodes, and expensive fallback classes visible for R3A, R4, R5, and R6.
