---
id: SPEC-r3-2-immutable-staging-accuracy-verdict
companions: []
sources:
  - ../spec-r3-analyzer-corpus-benchmark-baseline/SPEC.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/corpus-manifest.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/benchmark-protocol.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/brownfield.md
  - ../spec-r3-1-corpus-manifest-safe-inventory/SPEC.md
  - ../../../docs/architecture/OVERVIEW.md
---

> **Canonical contract.** This SPEC is the complete, preservation-validated contract for what R3.2 builds, tests, and validates. Source documents are listed only for traceability; this child contract absorbs every requirement needed by a fresh-context implementation.

# R3.2 Immutable Staging and Accuracy Verdict

## Why

Audlint's current corpus runner passes manifest paths directly to `audlint-analyze`, which can write cache and result sidecars beside the media. Maintainers need to evaluate R3.1 cases without exposing the approved external corpus to product writes, while distinguishing trusted regressions from weak-label disagreement and retaining evidence that later R3 benchmark work can aggregate.

## Capabilities

- **CAP-1 — Validated case selection**
  - **intent:** Maintainers can resolve requested R3.1 manifest cases from one explicitly supplied corpus root without accepting an alternate or weakened manifest contract.
  - **success:** Full R3.1 validation completes before selection or copying; accepted cases resolve inside the supplied root in manifest order, while missing, escaping, unresolved, or inconsistent cases stop before analyzer execution with an error.

- **CAP-2 — Verified isolated staging**
  - **intent:** Maintainers can prepare selected cases for execution without linking the analyzer's working tree to the external corpus.
  - **success:** Each case gets a unique temporary stage outside the corpus root containing fresh byte copies of its manifest-declared inputs in the required relative layout; source and stage checksums and sizes match the manifest, and traversal, missing inputs, symlink use, hard-link shortcuts, or failed stage verification stop execution with an error.

- **CAP-3 — Stage-only analyzer execution**
  - **intent:** Maintainers can run the current analyzer against an isolated case while keeping every analyzer-created artifact away from the corpus.
  - **success:** `audlint-analyze --json` receives only the staged case path and temporary output locations, never the external corpus path, and its exit status, structured stdout, and stderr are captured for the case result.

- **CAP-4 — Trust-aware accuracy verdict**
  - **intent:** Maintainers can tell a trusted analyzer regression from disagreement with an uncertain label without treating Audlint output as ground truth.
  - **success:** Exact comparison of actual target profile, decision, fake-upscale value, and any declared analysis mode yields `pass` on a match, `fail` plus nonzero overall status for a trusted mismatch, `warn` without failure for a weak mismatch, and `error` plus nonzero overall status for any contract or execution failure.

- **CAP-5 — Source immutability and cleanup**
  - **intent:** Maintainers can prove that evaluating a selected case did not add, remove, or change anything in its source subtree and did not leave a normal temporary stage behind.
  - **success:** Complete before-and-after snapshots of each selected case subtree compare equal after every attempted execution; any difference or cleanup failure is an `error`, and cleanup is attempted after success, mismatch, analyzer failure, malformed output, or safety failure.

- **CAP-6 — Aggregation-ready accuracy evidence**
  - **intent:** Later R3 benchmark work can consume each R3.2 result without rerunning the analyzer or scraping human-readable logs.
  - **success:** Deterministic machine-readable output retains manifest identity and order plus each case ID, trust, expected and actual comparison values, status, mismatch or error reasons, analyzer evidence, source-immutability verdict, stage-verification verdict, and cleanup outcome.

## Constraints

- R3.2 depends on the R3.1 schema and validator. It consumes schema-version-1 `corpus-manifest.json` without adding, coercing, inferring, or redefining manifest fields, expectations, provenance, or trust. Unsupported schema, invalid trust or provenance, missing trusted truth, malformed entries, duplicate IDs, and every other R3.1 validation failure are `error`, never weak fallbacks.
- The caller supplies both the manifest and corpus root explicitly. `album_path` and declared file paths remain POSIX-style root-relative identities; evidence does not store the machine-specific corpus root.
- Selection uses stable manifest case IDs and preserves manifest order. Unknown, duplicate, or otherwise unresolved requested IDs are errors; selecting no valid case must not report a successful evaluation.
- For each selected case, canonical path resolution must prove that the case directory and every declared input remain inside the supplied root. Absolute paths, traversal, missing paths, escapes, and paths through symlinks are rejected before product execution.
- The source immutability boundary is the complete selected case directory subtree, not only manifest-declared files. It includes the case root as `.` and every descendant found without following symlinks; unrelated corpus cases are not traversed or hashed.
- Before copying, record each source entry with `lstat`: normalized relative path, file type, byte size, permission bits, nanosecond modification time, and nanosecond status-change time. Record SHA-256 for every regular file and the link target for every symlink. Access time is excluded.
- Every declared input must be the required regular-file input and match the manifest byte size and SHA-256 before copying. A declared symlink, a path reached through a symlink, a missing file, type mismatch, size mismatch, or checksum mismatch is an `error`.
- Create each stage with a portable unique temporary-directory pattern outside the corpus root. Copy only declared inputs, preserving the relative album, CUE, and media layout needed by `audlint-analyze`; never use or follow symlinks and never substitute hard links for byte copies.
- Before execution, verify every staged input against the manifest again. Reject a missing or extra staged-input identity, unexpected file type, symlink, hard-link shortcut, layout mismatch, byte-size mismatch, checksum mismatch, or any inability to prove that the stage is an independent copy.
- The product command is exactly the staged `audlint-analyze --json` evaluation boundary. No product command receives the external corpus path as an album, input, cache, report, or output path. Staging, hashing, evidence capture, source verification, and cleanup are outside analyzer execution; R3.2 records no benchmark timing.
- Analyzer JSON must be one well-formed object with the well-typed fields needed to derive actual target profile, decision, fake-upscale value, and any compared analysis mode. The target profile is normalized to canonical `SR_HZ/BITS`; a missing, malformed, or ill-typed required value is `error`, not a mismatch.
- Compare `expected_target_profile`, `expected_decision`, `expected_fake_upscale`, and `expected_analysis_mode` when present. A match is `pass`; a trusted mismatch is `fail`; a weak mismatch is `warn`. A passing or matching run never changes provenance, expected values, or trust.
- Analyzer nonzero exit, malformed or incomplete output, R3.1 manifest inconsistency, selection failure, missing or mismatched source input, staging or stage-verification failure, source mutation, or cleanup failure is `error` and makes the overall result nonzero regardless of trust. The overall result is zero only when every case is `pass` or `warn` and cleanup succeeds.
- Repeat the complete source snapshot after every attempted product execution, including analyzer failure and invalid JSON, and compare it field-for-field with the pre-run snapshot. Any added or removed path, type change, size change, permission change, timestamp change, regular-file checksum change, or symlink-target change invalidates the run.
- Capture case evidence before cleanup, then attempt cleanup on every exit path. Successful cleanup leaves no stage; failed cleanup remains visible in machine output and makes the case `error`.
- Machine output preserves manifest and execution order and includes manifest SHA-256, corpus revision, case ID, root-relative case identity, trust, expected and actual values, mismatch reasons, status, analyzer exit and safe diagnostic evidence, source-snapshot verdict, stage-verification verdict, and cleanup verdict. Corpus and temporary absolute paths are sanitized to root-relative identities or omitted.
- R3.2 emits aggregation-ready accuracy results but does not publish `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/benchmark-results.json`, `baseline-summary.md`, or any new stable runtime artifact. Those final artifacts and their aggregation remain later R3 work.
- `bin/audlint-analyze-corpus.sh` remains a thin argument and environment boundary. R3.1 validation, selection, staging, snapshot comparison, verdict calculation, and evidence shaping belong in `lib/py/audlint_analyze_corpus.py` or focused shared Python modules; the runner must not reconstruct `audlint-analyze` decision policy.
- Automated verification uses repository-owned temporary fixtures only. It must not access `/Volumes/Music/Tests`, a real music library, live SQLite database, mounted sync destination, backup target, or destructive audio, tag, artwork, or converter workflow.
- Focused tests cover stage isolation and byte verification, rejection of traversal, missing inputs, source or stage checksum mismatch, symlink and hard-link shortcuts, analyzer receipt of only the stage path, complete-subtree source mutation detection, trusted mismatch, weak mismatch, analyzer failure, invalid JSON, R3.1 manifest inconsistency, and cleanup after both success and failure.
- Preserve Bash 5, macOS/Linux portability, canonical profile normalization, and `audlint-analyze` as the sole recode-decision authority.

## Non-goals

- Implementing or changing the R3.1 inventory, schema, expectation, provenance, trust, coverage, or canonical-manifest generation contract.
- Adding metadata-probe, decode, track, cache, fallback, confidence, elapsed-time, or other benchmark counters.
- Running cold/warm iterations or producing runtime summaries, deterministic aggregates, `benchmark-results.json`, or `baseline-summary.md`.
- Running or benchmarking `audlint-value`, `cue2flac`, `any2flac`, `dff2flac`, or any other converter.
- Regenerating synthetic corpus media or reproducing generation checksums and recipes.
- Changing analyzer thresholds, decisions, structured-output policy, cache semantics, worker models, parallelism, or performance.
- Implementing R3A, R4, R5, R6, or later roadmap work.

## Success signal

`python3 -m unittest test.test_audlint_analyze_corpus_smoke` (and any focused staging test module added by the implementation) proves with temporary fixtures that only verified independent stages reach the analyzer, the complete source subtree remains identical, trusted/weak and all required error paths yield the specified machine evidence and exit status, and stages are removed after success and failure. `make check` then passes as the repository-wide release gate without accessing an external corpus or real music library.
