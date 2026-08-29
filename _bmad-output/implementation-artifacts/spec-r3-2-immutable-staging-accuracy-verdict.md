---
title: 'R3.2 Immutable Staging and Accuracy Verdict'
type: 'feature'
created: '2026-08-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: '9286f1205ff70ae594584aff89a65085df2ca33c'
context:
  - '{project-root}/docs/architecture/OVERVIEW.md'
  - '{project-root}/_bmad-output/specs/spec-r3-2-immutable-staging-accuracy-verdict/SPEC.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** R3.1 validates and inventories an external corpus, but the existing evaluator sends manifest paths directly to `audlint-analyze`, which writes sidecars beside media. Maintainers need a trustworthy R3.2 verdict that isolates product execution and distinguishes trusted regressions from weak-label disagreement.

**Approach:** Add a strict R3.2 evaluation route that validates the complete schema-v1 manifest, selects manifest IDs in manifest order, stages verified byte copies outside the corpus, runs `audlint-analyze --json` only on the stage, and emits sanitized machine-readable evidence with an accuracy verdict.

## Boundaries & Constraints

**Always:** Reuse R3.1 validation before selection; preserve its schema, trust, provenance, expected values, and manifest order. Require explicit corpus root and manifest; use POSIX root-relative identities. Reject unsafe paths, missing files, symlinks, hard-link stage shortcuts, mismatched hashes/sizes, malformed analyzer JSON, source mutation, and failed cleanup. Snapshot each complete selected case subtree with `lstat` before and after every attempt. Normalize actual profiles with shared `normalize_profile`; compare target, decision, fake-upscale, and optional analysis mode exactly. Emit only deterministic sanitized result evidence; success is only all `pass`/`warn` cases with cleanup successful.

**Ask First:** Any change to R3.1 manifest semantics, analyzer decision policy/output, the approved corpus, a real library/database, or an R3.3+ benchmark artifact.

**Never:** Pass an external-corpus path to the analyzer; write beneath the corpus; create benchmark results/summary artifacts; record timing; use real-media fixtures; alter analyzer thresholds, cache policy, worker behavior, or R3.1 inventory output.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Verified evaluation | Valid v1 root, manifest, and requested IDs | Independent stage retains declared relative layout; analyzer sees only staged album; ordered evidence reports `pass` | Stage removed and source snapshot unchanged |
| Label disagreement | Complete analyzer JSON differs from expected values | `fail` for trusted, `warn` for weak, including comparison reasons | Trusted mismatch makes overall status nonzero |
| Unsafe or inconsistent input | Unknown/duplicate/no IDs, invalid R3.1 entry, traversal, symlink, missing/checksum-mismatched input | Stop before analyzer execution | Ordered `error` evidence and nonzero status |
| Execution or cleanup failure | Analyzer nonzero/malformed JSON, source mutation, stage verification or cleanup failure | Preserve safe diagnostics and verification outcomes | `error`, nonzero status, cleanup attempted |

</frozen-after-approval>

## Code Map

- `bin/audlint-analyze-corpus.sh:28-37` -- existing thin Bash environment/dispatch boundary; forward the strict route without analyzer policy.
- `lib/py/audlint_analyze_corpus.py:121-147,316-430` -- R3.1 root-relative validation and strict schema-v1 inventory model; validate before selection but do not call artifact-writing inventory.
- `lib/py/audlint_analyze_corpus.py:433-611` -- legacy permissive evaluator sends source paths and coerces values; keep it isolated from the new strict route or replace it deliberately.
- `lib/py/profile_norm.py` -- shared canonical `SR_HZ/BITS` normalization for typed analyzer target values.
- `lib/py/audlint_analyze.py:2010-2012,2044-2063` -- analyzer JSON can have exit-zero error payloads; successful payload defines the required verdict fields.
- `bin/audlint-analyze.sh:160-169,317-328` -- analyzer accepts a directory and writes `.sox_album_*` sidecars, proving stage-only execution is required.
- `test/test_audlint_analyze_corpus_smoke.py:21-23,26-117,119-363` -- portable executable analyzer stubs and temporary strict-manifest fixtures to extend for R3.2 safety coverage.

## Tasks & Acceptance

**Execution:**

- [x] `lib/py/audlint_analyze_corpus.py` -- add a strict `--evaluate CORPUS_ROOT MANIFEST [CASE_ID ...]` route (no IDs evaluates all entries), manifest-byte identity, ordered case selection, lstat snapshots, independent verified staging, typed analyzer-result parsing, verdict calculation, path-sanitized evidence, and unconditional cleanup.
- [x] `bin/audlint-analyze-corpus.sh` -- retain its thin portable bootstrap while forwarding the R3.2 evaluate arguments and injected analyzer path.
- [x] `test/test_audlint_analyze_corpus_smoke.py` -- extend repository-owned temporary fixtures for byte-copy and stage isolation, selection/path/source/stage safety failures, source-subtree mutation, trusted/weak verdicts, analyzer failure/invalid JSON, safe evidence, and cleanup after every outcome.
- [x] `README.md` -- document the explicit R3.2 evaluate invocation, all-case/default and manifest-ID selection behavior, stage-only guarantee, output/exit meaning, and no stable benchmark publication.

**Acceptance Criteria:**

- Given a complete R3.1 manifest and temporary fixture corpus, when R3.2 evaluates selected cases, then full validation precedes selection, selected IDs retain manifest order, and only a verified unique byte-copy stage reaches `audlint-analyze --json`.
- Given analyzer-created files, mismatch, malformed JSON, nonzero exit, or any safety failure, when the attempt completes, then its source case subtree is field-for-field unchanged, cleanup is attempted, and machine evidence records verification and cleanup outcomes without absolute corpus or stage paths.
- Given equal values or a label disagreement, when actual typed JSON is compared to declared expectations, then matching cases pass, trusted mismatches fail, weak mismatches warn, and only pass/warn-only complete runs exit zero.
- Given an invalid schema-v1 manifest, unsafe selection/path, symlink, hard-link stage, or source/stage checksum discrepancy, when evaluation is requested, then the analyzer is never invoked and the command exits nonzero with a contract error.

## Design Notes

The user-facing route is `--evaluate CORPUS_ROOT MANIFEST [CASE_ID ...]`: absence of IDs selects all validated entries, while supplied IDs are checked for duplicates and resolved in manifest order. This fills the SPEC's CLI-shape gap without weakening any contract. The result remains stdout evidence only; it intentionally does not publish R3.4's stable aggregate artifacts.

## Verification

**Commands:**

- `python3 -m unittest test.test_audlint_analyze_corpus_smoke` -- expected: strict staging, verdict, immutability, cleanup, and existing R3.1 fixture coverage pass without external-media access.
- `make check` -- expected: complete local release gate passes.
