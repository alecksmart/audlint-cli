---
id: SPEC-r3-1-corpus-manifest-safe-inventory
companions: []
sources:
  - ../spec-r3-analyzer-corpus-benchmark-baseline/SPEC.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/corpus-manifest.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/benchmark-protocol.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/brownfield.md
  - ../../../docs/architecture/OVERVIEW.md
---

> **Canonical contract.** This SPEC is the complete, preservation-validated contract for what R3.1 builds, tests, and validates. Source documents are listed only for traceability; this child contract absorbs every requirement needed by a fresh-context implementation.

# R3.1 Corpus Manifest Schema and Safe Inventory

## Why

Audlint's current corpus runner accepts permissive manifests with direct machine paths and silently treats malformed trust values as weak. Before any approved corpus can be analyzed or benchmarked, maintainers need a versioned inventory whose identities, paths, objective media facts, checksums, expectations, provenance, and trust are valid without allowing inventory automation to alter the corpus or manufacture ground truth.

## Capabilities

- **CAP-1 — Strict manifest contract**
  - **intent:** Maintainers can validate one versioned `corpus-manifest.json` contract containing stable corpus and case identity, ordered file inventory, expected values, provenance, and trust.
  - **success:** Validation accepts a complete schema-version-1 manifest and rejects unsupported versions, missing or ill-typed required fields, duplicate stable IDs, invalid profiles, incomplete file facts, checksum errors, invalid provenance, and unknown trust values with actionable errors.

- **CAP-2 — Safe root-relative identity**
  - **intent:** Maintainers can describe corpus cases independently of machine-specific roots without allowing a declared case or file to escape the explicitly supplied corpus root.
  - **success:** Absolute, empty, non-normalized, dot-segment, parent-traversal, missing, and symlink-mediated escaping paths are rejected; accepted POSIX-style paths resolve within the supplied root and remain root-relative in the manifest.

- **CAP-3 — Read-only objective inventory**
  - **intent:** Maintainers can inventory objective facts for declared corpus inputs without running Audlint analysis or changing the source corpus.
  - **success:** Against temporary fixtures, inventory deterministically records declared files, roles, SHA-256 values, byte sizes, and applicable media probe facts while succeeding against a read-only corpus tree and producing no added, removed, rewritten, retagged, renamed, permission-changed, or deliberately timestamp-changed corpus entry.

- **CAP-4 — Human-owned expectations and lineage**
  - **intent:** Maintainers retain explicit ownership of expected analyzer truth, trust decisions, provenance, and synthetic lineage while automation supplies only objective inventory facts.
  - **success:** Inventory preserves human-supplied expected values, provenance, and literal `trusted` or `weak` status; incomplete trusted entries and incomplete synthetic recipes fail validation, and no value is populated, changed, validated by agreement with, or promoted from current Audlint output.

## Constraints

- The top-level JSON object requires integer `schema_version` equal to `1`, stable `corpus_id`, immutable `corpus_revision`, RFC 3339 `generated_at_utc`, and an ordered `entries` array.
- Every entry requires a unique stable `id`; safe `album_path`; `category` equal to `real`, `fake`, or `edge_case`; stable `case_class`; non-empty ordered `files`; `expected_source_profile`; `expected_target_profile`; `expected_decision`; boolean `expected_fake_upscale`; literal `trust`; and `provenance`. `expected_analysis_mode` is optional. A path change must not silently change entry identity.
- PCM expected profiles use canonical `SR_HZ/BITS`. DSD-family sources use an explicit family label for `expected_source_profile`, retain native probe facts in their file items, and still use canonical `SR_HZ/BITS` for the expected analyzer target.
- Every `files` item requires a safe root-relative `path`, `role`, lowercase SHA-256 digest, and nonnegative `bytes`. Audio items also require objective container, codec, sample rate, applicable bit depth, channels, and duration facts. Duplicate or conflicting file identities are invalid.
- Stored paths use POSIX separators, are relative to the runtime-supplied corpus root, contain no empty, `.` or `..` segments, and resolve inside the root. Absolute paths and escapes through traversal or symlinks are invalid.
- `trust` accepts only `trusted` or `weak`; missing or malformed values are errors, not parser fallbacks. `provenance` records its basis, source reference or recipe lineage, rationale, named reviewer, and UTC review date.
- A `trusted` entry is valid only when independent source or synthetic lineage, named human review of every expected field, and checksum-pinned declared inputs are present. Missing trusted truth stops validation; automation neither invents it nor silently downgrades the case.
- A synthetic derivative requires `generation_recipe` metadata containing the trusted source checksum, exact `audlint-dataset.sh` invocation parameters, and relevant encoder or tool versions. Independently sourced media omit `generation_recipe`.
- Coverage validation reports, without fabricating cases or labels, missing genuine PCM classes `44100/16`, `44100/24`, `48000/24`, `96000/24`, and `192000/24`; MP3, AAC, and Opus fake-upscale lineage at multiple source bitrates and 48, 96, and 192 kHz fake targets; sparse genuine high-resolution content; low-pass mastering, noisy live, and vinyl-rip edge cases; DSD-family sources; large CUE/WavPack inputs; and misleading spectrogram evidence.
- Inventory may enumerate declared inputs, compute checksums and sizes, and collect objective container, codec, sample-rate, bit-depth, channel, and duration facts. It must not invoke `audlint-analyze`, infer expected values from Audlint or library/database results, or treat agreement with current output as validation of truth.
- The supplied corpus root is immutable input. R3.1 writes only the generated manifest at `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest.json`; it never writes a manifest, cache, sidecar, log, probe artifact, or other output under the corpus root.
- Generated JSON is one UTF-8 object using two-space indentation, lexicographically sorted object keys, LF line endings, one final newline, and deterministic array order. The SHA-256 of those exact bytes is its stable corpus-contract identity.
- CLI parsing and orchestration remain thin. Manifest validation and inventory live in `lib/py/audlint_analyze_corpus.py` or a focused shared Python module and reuse existing shared probing policy rather than duplicating media rules in `bin/`.
- Preserve Bash 5, macOS/Linux portability, and canonical profile normalization.
- Automated verification uses repository-owned temporary fixtures only. It must not access `/Volumes/Music/Tests`, any real music library, live SQLite database, mounted sync destination, backup target, or destructive media workflow.
- Focused tests cover valid schema and canonical output, schema-version rejection, stable-ID uniqueness, absolute and traversal paths, symlink-mediated escape, malformed trust, incomplete trusted provenance or expected values, file inventory and checksum validation, synthetic lineage requirements, missing coverage reporting, and read-only inventory behavior.

## Non-goals

- Running `audlint-analyze` or any other analyzer against the corpus.
- Copying or staging corpus media for analyzer, converter, or benchmark execution.
- Executing trusted or weak accuracy verdicts.
- Producing cold or warm runtime measurements.
- Adding work, decode, metadata-probe, cache, fallback, or timing instrumentation.
- Tuning analyzer behavior, thresholds, decisions, cache policy, parallelism, or performance.
- Implementing R3A, R4, R5, or R6 work.
- Reproducing synthetic derivatives; R3.1 validates already-required lineage metadata only.

## Success signal

A focused temporary-fixture test run proves that one explicit corpus-root invocation either emits the exact deterministic schema-version-1 manifest at the declared BMAD output path or fails with a precise validation error, while the entire fixture corpus remains unchanged and no analyzer or benchmark command runs.
