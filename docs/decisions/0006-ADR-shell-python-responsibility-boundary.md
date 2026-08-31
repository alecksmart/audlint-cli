# ADR-0006: Prefer the Shell Orchestration and Python Computation Boundary

## Status
Accepted

## Record type
Contemporary

## Context
The Phase 1 recovery review found a strong repository-wide pattern: Bash entry commands orchestrate workflows, shared shell libraries hold cross-command policy and mechanics, and Python modules implement substantial computation and rendering. Existing code also contains exceptions, so repository history did not support classifying the pattern as a recovered decision.

On 2026-08-31, Alec explicitly authorized a contract exception to adopt this pattern as a present-day architectural decision. This record does not claim that the rule was historically decided before that authorization.

## Decision
Prefer the dependency direction `bin/*` orchestration → `lib/sh/*` shared policy and mechanics → `lib/py/*` computation.

Bash entry commands own interaction and workflow control. Reusable cross-command parsing, encoding, artwork, SQLite, terminal, and other policy belongs in an existing shared shell or Python helper. Substantial analysis and rendering kernels belong in Python modules.

This is a preferred boundary, not a claim that existing exceptions are invalid or an instruction to refactor them immediately. New exceptions should remain narrow and must not create competing shared contracts in entry scripts.

## Evidence
- `docs/architecture/OVERVIEW.md:5-9,31-53` describes the current architecture and its normal dependency direction.
- `AGENTS.md:29-33` requires reuse of shared shell or Python helpers instead of duplicated policy in entry scripts.
- `bin/audlint.sh:19-43` sources the shared shell libraries used by the TUI.
- `bin/audlint-analyze.sh:43-68,146-159` uses shared shell setup and delegates its analysis kernel to `lib/py/audlint_analyze.py`.
- `docs/architecture/OVERVIEW.md:44,87-89` and `bin/audlint.sh:2589-2615` establish existing exceptions: a command can be sourced as a library, commands retain some format-specific logic, and the TUI embeds Python.
- `_bmad-output/implementation-artifacts/adr-recovery-candidate-review.md` records the prior pattern-only classification and the missing historical authority.

## Rationale
The existing organization gives shared policy a reusable owner and isolates substantial analysis and rendering kernels. The repository's implementation guidance already rejects duplicated cross-command contracts in entry scripts. Adopting the pattern now makes that boundary reviewable without inventing a historical decision or invalidating documented exceptions.

## Consequences
- New work should first extend the appropriate shared helper rather than duplicate policy in an entry command.
- Bash remains the interaction and workflow layer, while substantial computation normally lives in importable Python modules.
- Existing embedded Python, command delegation, and format-specific logic remain valid; this ADR creates no immediate refactoring requirement.
- Reviewers must distinguish a justified local exception from a new competing cross-command contract.

## Alternatives
- Leave the dependency direction descriptive only. This was the Phase 1 classification before the operator's explicit decision to adopt it.
- Enforce a strict three-layer separation with no exceptions. Current code and the architecture overview demonstrate that this would contradict accepted implementation reality, so it was not selected.

## Related decisions
- [ADR-0003: Require Bash 5 with macOS and Linux Portability](0003-ADR-bash5-portability.md)
