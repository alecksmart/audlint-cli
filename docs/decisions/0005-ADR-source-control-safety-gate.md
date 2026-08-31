# ADR-0005: Fail Closed on Prohibited Source-Control Content

## Status
Accepted

## Record type
Historical

## Context
Private media-library metadata and prohibited artifacts can enter Git through committed, staged, modified, untracked, or force-added content. The R10 work established a local audit whose authority and diagnostics cannot be weakened by a repaired index, permissive runtime state, or unreviewed broad exclusions.

The R10 implementation artifact still reports `status: in-progress`, although the gate is committed and wired into the release check. This decision accepts the implemented current rule without claiming that the earlier artifact's lifecycle was formally closed.

## Decision
Keep the source-control audit local, deterministic, developer-only, and fail-closed. The authoritative release audit examines current `HEAD`, the index, tracked worktree state, and eligible untracked worktree state under a strictly indexed policy and byte-identical visible copy.

Keep `--prospective` index-only and non-authoritative. Permit only exact reviewed exception tuples, keep boundary findings non-exemptible, redact content and host paths from diagnostics, revalidate authority and candidate state before success, and run the authoritative audit after the complete test suite in `make check`.

## Evidence
- `_bmad-output/implementation-artifacts/spec-r10-source-control-safety-gate.md:13-38,73-84` is the human-frozen intent and directly records the problem, authority model, constraints, and rationale.
- Commit `a88dc1955ef512cc6766f90db857aed31f459e97` adds the source-control safety gate.
- `bin/audlint-source-audit.sh:1-19` is the thin developer-only entry point.
- `lib/py/audlint_source_audit.py:158-184,214-239,534-580` enforces stage-0 authority, independent HEAD scanning, full versus prospective source sets, revalidation, deterministic output, and fail-closed errors.
- `test/test_audlint_source_audit_smoke.py:39-87,188-198` verifies deterministic results, blocking HEAD, protected paths, exact exceptions, and error exits.
- `Makefile:131-144` runs the complete test suite before the source audit.

## Rationale
The approved R10 intent states that prior release checks did not independently inspect every commit candidate or provide a safe redacted disposition workflow. Its design notes state that stage-0 bytes establish authority, a byte-identical worktree copy proves the operator sees that policy, state revalidation detects a moving target, and relative redacted diagnostics avoid leaking content or host paths.

## Consequences
- Unsafe historical content remains blocking even after a clean index repair.
- Prospective remediation can validate the index without weakening the release authority.
- Malformed policy, hostile Git state, unsupported entries, or concurrent mutation stop the audit rather than producing a partial success.
- The audit is not installed as a product command.
- Exceptions require exact, reviewed tuples; boundary rules cannot be exempted.

## Alternatives
- An index-only release audit exists as `--prospective`, but the approved intent explicitly makes it non-authoritative because it cannot expose unsafe current `HEAD` or worktree state.
- Broad path or directory exclusions and automatic allowlist baselines were explicitly prohibited by the approved R10 intent.

## Related decisions
None recovered from repository evidence.
