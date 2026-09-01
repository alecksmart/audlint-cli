---
id: SPEC-player-adr-corrections
companions:
  - corrections.md
  - ../../../docs/decisions/0007-ADR-player-track-only-destinations.md
  - ../../../docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md
  - ../../../docs/decisions/README.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate.

# Player ADR Corrections

## Why

The newest player ADRs preserve approved decisions but mix durable policy, mechanism, transitional wording, and claims broader than current proof. Maintainers need a lean, current decision ledger that describes the implemented guarantees without changing player behavior.

## Capabilities

- **CAP-1**
  - **intent:** Maintainers can rely on ADR-0007 and ADR-0008 as lean, current, internally consistent records of approved player payload and transfer decisions.
  - **success:** The corrected records define their scopes and guarantees precisely, pin decision inputs separately from implementation proof, remove stale or unrelated commitments, preserve every approved behavior, and introduce no code or runtime change.

## Constraints

- Modify only ADR-0007, ADR-0008, and `docs/decisions/README.md` if an ADR title or scope label changes.
- Preserve accepted track-only payload, ownership, explicit destructive action, source immutability, one-root Player Content mirroring, browser subtree ownership, file-backed rules, `--size-only`, metadata policy, postchecks, and retry behavior.
- Use exactness and stability terms only for the path, object-type, and logical-size guarantees current snapshots and postchecks prove.
- Preserve accepted status and decision history while distinguishing decision-baseline evidence from current implementation evidence.
- Use current Git, code, focused tests, and accepted specs as evidence. Do not access real operator resources.
- Apply every correction in `corrections.md` without creating new product behavior.

## Non-goals

- Rsync progress, feedback, UI, cancellation, or transfer changes.
- Changes to code, tests, architecture docs, public usage docs, specs, or implementation artifacts.
- Reconsidering approved `--size-only`, track-only payload, ownership, deletion, metadata, or postcheck behavior.
- Creating new player capabilities or release operations.

## Success signal

A documentation-only diff shows ADR-0007/0008 aligned with current code, tests, accepted specs, and Git history; all ADR links resolve; `git diff --check` passes; and no file outside the allowed decision-ledger scope changes.

## Assumptions

- Correct ADR-0007 and ADR-0008 in place rather than create ADR-0009; retitle or rescope ADR-0008 and update the decision index only if needed for an honest boundary.
