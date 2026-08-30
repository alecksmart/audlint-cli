---
title: 'R10 Source-Control Safety Gate'
type: 'feature'
created: '2026-08-30'
status: 'in-progress'
review_loop_iteration: 0
baseline_commit: '9a797ffe87692d9bfb3c444e45546aafdba57097'
context:
  - '{project-root}/_bmad-output/specs/spec-r10-source-control-safety-gate/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-r10-source-control-safety-gate/source-control-safety-policy.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Private media-library metadata and prohibited artifacts can still reach Git through committed, staged, modified, or force-added content. Existing release checks do not independently examine every commit candidate or provide a safe, redacted disposition workflow.

**Approach:** Add one local, deterministic source-control audit with a strictly indexed policy, exact reviewed exceptions, four independent authoritative sources, and a prospective index-only mode. Wire it into the release gate only after the unchanged test target, without turning it into an installed product command or altering R3 and product behavior.

## Boundaries & Constraints

**Always:** Follow the canonical SPEC and companion exactly; use Bash 5, Git, Python 3 standard library, and supported macOS/Linux behavior. Keep the entry point thin and the audit logic reusable in `lib/py/`. Treat current `HEAD` as independently blocking; make `--prospective` index-only and non-authoritative. Obtain policy and optional allowlist only from matching stage-0 `100644` blobs and contained byte-identical regular worktree copies. Use raw-byte-safe, repository-relative diagnostics and fixed redacted JSONL/error records; never output matches, raw tool errors, machine paths, absolute repository paths, or ignored candidate paths. Test exclusively with temporary Git repositories and runtime-assembled synthetic values. Keep protected and repository-ignored tracked candidates content-free. Preserve `make test`, product/install behavior, R3.1–R3.5, staging, benchmark, analyzer, and instrumentation behavior.

**Ask First:** If the staged authoritative audit finds any real-repository occurrence, preserve only its redacted record and stop for a human disposition before adding or changing an allowlist entry. Boundary rules are never exemptible. Do not resolve a contradiction by reading `.memlog.md` unless the rendered canonical contract itself is contradictory.

**Never:** Do not create a branch, commit, PR, push, ADR, architecture document, hook, broad/file/directory exclusion, automatic allowlist baseline, network dependency, or third-party runtime dependency. Never enumerate, open, hash, parse, restore, or display ignored benchmark artifacts, or touch a real music library, live SQLite database, or mounted sync content.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Authoritative clean audit | Valid staged policy and matching worktree copy; clean HEAD/index/worktree | Zero-argument entry and `make source-audit` emit deterministic clean JSONL summary and exit 0 | stderr empty |
| Unsafe historical source | Unsafe candidate remains in HEAD after an index repair | Emits redacted HEAD finding and exits 1 | No matched bytes or raw errors exposed |
| Prospective remediation | Unsafe HEAD but clean complete stage-0 index | `--prospective` scans only index and can exit 0 | It is never used by `make check` |
| Protected/ignored tracked path | Candidate is under protected prefix or same-source `.gitignore` | Emits only the applicable path boundary finding, without reading content | Boundary rules cannot be allowlisted |
| Invalid authority or state | Missing/mismatched/staged-wrong policy or allowlist, hostile Git environment, mutation, or unsupported state | Discards findings, emits fixed redacted error JSONL and exits 2 | Earliest prescribed phase wins |
| Exact exception | Valid exact exemptible tuple matches unchanged rule/path/fingerprint across source movement | Suppresses only that occurrence | Any path, mode, content, record, or ordinal change revokes suppression |

</frozen-after-approval>

## Code Map

- `bin/audlint-analyze-corpus.sh:4-41` -- closest thin Bash-to-Python entry pattern; new audit entry must resolve its physical location and exec Python without sourcing `.env` or permissive bootstrap helpers.
- `lib/py/audlint_analyze_corpus.py:2145-2192` -- established `main(argv) -> int` and deterministic JSON output convention; its Git identity helpers are informational only and unsuitable for a fail-closed audit.
- `lib/sh/bootstrap.sh:109-124` -- explicitly read-only contrast: permissive fallback path resolution must not be reused for R10 authority decisions.
- `Makefile:7-90` -- current all-`bin/*.sh` installer list and `check` prerequisites; preserve `test: test-core test-legacy`, exclude the developer command, and serialize audit after tests.
- `test/test_audlint_analyze_corpus_smoke.py:1-25` and `test/test_install_sh_smoke.py:1-20` -- unittest, temporary-directory, subprocess, and local-helper style for a new temporary-Git audit suite and Make/install assertions.
- `test/sh/bash5_consistency.sh:92` -- automatically validates all `bin/*.sh`; Python filesystem byte APIs avoid BSD/GNU `stat` divergence.
- `docs/architecture/OVERVIEW.md:114-118` and `README.md:150-154` -- focused maintainer-facing verification/install guidance.

## Tasks & Acceptance

**Execution:**
- [ ] `lib/py/audlint_source_audit.py` -- implement the complete fixed v1 policy floor, strict indexed authority/bootstrap/phase model, raw-byte Git and worktree snapshots, collision/containment/limit enforcement, candidate scanners, deterministic fingerprinting, exact exception lifecycle, and redacted JSONL diagnostics -- centralizes all security decisions in standard-library Python.
- [ ] `bin/audlint-source-audit.sh` -- add the Bash 5 developer-only resolver and exact `[--prospective|--help]` interface that runs the Python engine from the physical repository root -- keeps runtime orchestration minimal and portable.
- [ ] `.audlint-source-audit-policy.json` -- stage the complete strict version-1 declarative policy, containing mandatory floor values without executable patterns -- establishes the first authoritative policy; create no allowlist unless a human later approves an exact occurrence.
- [ ] `Makefile`, `README.md`, `docs/architecture/OVERVIEW.md` -- add `source-audit`, strict `check` sequencing, installation/relink exclusion, and concise invocation guidance -- keeps release and operator behavior clear without changing `make test`.
- [ ] `test/test_audlint_source_audit_smoke.py` -- build all repos/positive values at runtime and cover every companion primitive, source, authority state, short circuit, phase/limit/error/redaction/order/fingerprint/exception/portability boundary, plus Make ordering and installation exclusion -- proves the gate without tracked sensitive fixtures or real data.

**Acceptance Criteria:**
- Given a valid staged policy and immutable snapshots, when the audit runs from any caller directory, then it audits the physical entry repository and returns byte-identical ordered output for identical inputs.
- Given every authoritative source and an unborn-HEAD repository, when synthetic unsafe content is introduced independently, then the correct source finding blocks exit 1; a clean prospective index cannot mask unsafe HEAD.
- Given policy/allowlist weakening, malformed JSON, duplicate keys, invalid modes/stages/symlinks, environment routing, snapshot mutation, collisions, unsupported entries, parse/read/resource failures, when encountered in prescribed phases, then the first fixed exit-2 error is emitted with no findings or raw evidence.
- Given protected or repository-ignored tracked content and an effectively ignored untracked candidate, when enumerating, then protected/ignored tracked paths stop before any content access and ignored untracked content is neither named nor opened.
- Given every required rule primitive and near miss in temporary repositories, when files, blobs, links, structured records, and limits are scanned, then exact redacted findings, span-derived line/ordinal fingerprints, ordering, and non-exemptible boundaries follow the companion.
- Given a reviewed exact allowlist tuple, when the unchanged exemptible occurrence appears in any source, then only it is suppressed; all tuple/content/mode/record/ordinal changes remain visible.
- Given `make check` (including `-j`), when earlier checks pass, then the unchanged `make test` completes before `make source-audit`; a preceding failure prevents audit, and `make install`/`make relink` never link the developer command.

## Spec Change Log

## Design Notes

The audit is intentionally a dedicated Python subsystem rather than a wrapper around existing permissive Git helpers. Stage-0 bytes are authority, while worktree copies prove an operator is auditing the same policy they can see; phase-7 revalidation prevents a correct scan of a moving target. The scanner must preserve raw path bytes internally and serialize only the prescribed percent-encoded relative path, so safety checks and diagnostics cannot leak host paths or content.

## Verification

**Commands:**

- `python3 -m unittest test.test_audlint_source_audit_smoke` -- expected: focused temporary-repository R10 suite passes.
- `make lint fmt-check bash5-check` -- expected: shell and formatting checks pass.
- `make test` -- expected: existing core and legacy suites run unchanged.
- `make source-audit` -- expected: staged authoritative redacted result; if findings occur, stop for human disposition.
- `make check` -- expected: tests complete before the authoritative audit and all release checks pass after approved dispositions.
- `make install PREFIX=<temporary directory>` and `make relink PREFIX=<temporary directory>` -- expected: neither creates `audlint-source-audit.sh` symlink.
