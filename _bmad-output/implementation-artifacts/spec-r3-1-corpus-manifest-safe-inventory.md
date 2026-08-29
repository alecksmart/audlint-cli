---
title: 'R3.1 Corpus Manifest Safe Inventory'
type: 'feature'
created: '2026-08-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'c7dc81dfd7b393dc794c8341af7369836b38a100'
context:
  - '{project-root}/docs/architecture/OVERVIEW.md'
  - '{project-root}/_bmad-output/specs/spec-r3-1-corpus-manifest-safe-inventory/SPEC.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The current corpus command evaluates loose manifests with absolute paths and silently weakens bad trust values. Maintainers need a versioned, portable inventory that collects objective facts without changing corpus media or inventing analyzer truth.

**Approach:** Add a strict schema-v1 validation and read-only inventory command for a supplied corpus root. It preserves human-owned expectations, provenance, trust, and synthetic lineage while refreshing only declared-file checksums, sizes, and objective media facts into the deterministic R3 manifest artifact.

## Boundaries & Constraints

**Always:** Keep paths root-relative POSIX values and reject missing, absolute, non-normalized, traversal, and symlink-escape paths. Require literal `trusted` or `weak`, canonical PCM profiles, complete trusted provenance and synthetic lineage, deterministic JSON, and repository-owned temporary-fixture tests. Keep CLI orchestration thin and use shared Python probe/profile policy.

**Ask First:** Any change to analyzer decisions, analyzer invocation, corpus staging/benchmark execution, the approved corpus, or existing non-R3 corpus-evaluation semantics.

**Never:** Run `audlint-analyze`, use real music/database/sync data, create any output under the corpus root, infer or promote expected truth, reproduce derivatives, or begin R3.2+ work.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Valid inventory | Complete v1 human-authored manifest and read-only fixture root | Deterministic artifact at the R3 output path with ordered entries/files and refreshed objective facts | No corpus writes or analyzer run |
| Unsafe path | Absolute, traversal, missing, or escaping symlink album/file path | No artifact is emitted | Precise validation failure identifies the field |
| Invalid human truth | Bad trust, incomplete trusted expectations/provenance, or invalid synthetic recipe | No artifact is emitted and supplied human values stay untouched | Precise validation failure |
| Coverage gap | Valid manifest missing required coverage classes | Inventory remains valid but reports the missing classes | Never fabricates cases or labels |

</frozen-after-approval>

## Code Map

- `bin/audlint-analyze-corpus.sh` -- existing thin Bash bootstrap and Python dispatch; extend its CLI surface only as needed for inventory.
- `lib/py/audlint_analyze_corpus.py` -- current permissive analyzer evaluator; add or route a strict inventory/validation boundary that cannot invoke the analyzer.
- `lib/py/audlint_analyze.py` -- reuse objective `ffprobe_audio_json` and metadata normalization helpers without entering analyzer execution.
- `lib/py/profile_norm.py` -- reuse canonical profile validation; schema values must already equal canonical output.
- `test/test_audlint_analyze_corpus_smoke.py` -- existing temporary-fixture command coverage; evolve/add focused R3.1 validation and inventory tests.
- `test/test_audio_probe_smoke.py` -- reference pattern for PATH-injected `ffprobe` fixture stubs and DSD facts.
- `_bmad-output/specs/spec-r3-1-corpus-manifest-safe-inventory/SPEC.md` -- authoritative R3.1 contract and focused verification scope.

## Tasks & Acceptance

**Execution:**

- [x] `lib/py/audlint_analyze_corpus.py` -- implement strict schema-v1 parsing, safe root-relative resolution, human-owned expectation/provenance/trust/lineage validation, coverage reporting, deterministic JSON output, and declared-file objective inventory; no analyzer or corpus-root writes.
- [x] `bin/audlint-analyze-corpus.sh` -- expose the explicit root-and-manifest inventory/validation invocation while retaining a thin portable wrapper.
- [x] `test/test_audlint_analyze_corpus_smoke.py` -- cover valid canonical inventory, schema/type/ID/profile failures, unsafe and symlink paths, trust/provenance/lineage failures, checksums/facts, coverage reporting, and immutable read-only fixtures.
- [x] `README.md` -- document the R3.1 inventory invocation, generated artifact location, and the rule that expectations and trust are human-authored.

**Acceptance Criteria:**

- Given a complete manifest and temporary read-only corpus fixture, when R3.1 inventories its declared inputs, then it writes only the exact deterministic schema-v1 JSON under `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/` and preserves the full corpus snapshot.
- Given invalid schema, canonical profile, stable identity, path, checksum, trust, trusted-truth, provenance, or synthetic-lineage input, when validation runs, then it exits nonzero with an actionable error and does not silently normalize, downgrade, or infer human-owned truth.
- Given a valid but incomplete corpus classification, when validation runs, then it reports missing required coverage without creating media, labels, or manifest entries.
- Given any R3.1 command, when it inventories or validates, then no analyzer, database, dataset builder, staging, benchmark, or conversion command is invoked.

## Design Notes

The former evaluator's default-to-weak parsing cannot be shared with R3.1. Keep the new manifest model strict and read-only; preserve ordered arrays while sorting JSON object keys so the emitted byte sequence is a stable contract identifier.

## Verification

**Commands:**

- `python3 -m unittest test.test_audlint_analyze_corpus_smoke` -- expected: all R3.1 fixture and safety tests pass without real-media access.
- `make check` -- expected: project release gate passes.

## Suggested Review Order

**Inventory boundary**

- Strict schema, trust, containment, and objective-fact rules stay in one Python boundary.
  [`audlint_analyze_corpus.py:316`](../../lib/py/audlint_analyze_corpus.py#L316)

- Path resolution rejects traversal, dot segments, and symlink-mediated escapes.
  [`audlint_analyze_corpus.py:121`](../../lib/py/audlint_analyze_corpus.py#L121)

- Synthetic lineage and coverage reporting preserve human-owned truth without fabrication.
  [`audlint_analyze_corpus.py:229`](../../lib/py/audlint_analyze_corpus.py#L229)

**Shared media probing**

- The shared probe now exposes container identity for objective inventory facts.
  [`audlint_analyze.py:194`](../../lib/py/audlint_analyze.py#L194)

**Evidence and operator use**

- Fixture tests cover deterministic inventory, isolation, failures, and refreshed facts.
  [`test_audlint_analyze_corpus_smoke.py:119`](../../test/test_audlint_analyze_corpus_smoke.py#L119)

- The public command documents the fixed artifact destination and human ownership.
  [`README.md:193`](../../README.md#L193)
