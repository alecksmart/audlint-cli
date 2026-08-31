---
id: SPEC-architectural-decision-archaeology-and-adr-recovery
companions:
  - adr-recovery-contract.md
  - ../../../docs/ai/bmad-lite.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for this task. Read only repository evidence relevant to a candidate under review.

# Architectural Decision Archaeology and ADR Recovery

## Why

AUDLINT has durable cross-cutting architectural rules embodied in code, tests, documentation, and history, but no decision ledger under `docs/decisions/`. Recover the small set that materially constrains future work so maintainers and agents can preserve current architecture without inventing historical rationale or loading broad repository context.

## Capabilities

- **CAP-1**
  - **intent:** A maintainer can review a compact, evidence-grounded set of durable architectural decision candidates classified as explicit, recovered, or pattern-only.
  - **success:** Every candidate has the required fields and concrete repository evidence, low-value implementation details are excluded, and Phase 1 creates no ADR files.

- **CAP-2**
  - **intent:** The operator can approve specific candidates before any decision becomes part of the ADR library.
  - **success:** Work stops after presenting the Phase 1 candidate table and resumes only from an explicit list of approved candidates.

- **CAP-3**
  - **intent:** Approved explicit or recovered decisions can be recorded as concise ADRs without fabricating chronology, rationale, alternatives, or authority.
  - **success:** Only approved decisions become correctly named ADRs using the required structure, evidence and record-type rules in `adr-recovery-contract.md`.

- **CAP-4**
  - **intent:** Future maintainers and implementation agents can find and load only the accepted ADRs relevant to their work.
  - **success:** The library has a concise index, important current truths are linked narrowly from the architecture overview, and `AGENTS.md` references only ADR rules every implementation agent must know.

## Constraints

- Treat current code, tests, accepted documentation, and Git as evidence; use Git history only when it materially establishes that a decision was intentional.
- Inspect only the source categories named in `adr-recovery-contract.md` and only as needed for the current candidate.
- Preserve the human approval gate between candidate review and ADR creation.
- Stay on the current release branch and preserve unrelated working-tree changes, including overlapping edits to `docs/architecture/OVERVIEW.md`.
- Limit writes to the documentation and BMAD review artifacts listed in `adr-recovery-contract.md`; do not modify product code, tests, BMAD, or installed skills.
- Keep the recovered library deliberately small and high-signal.

## Non-goals

- Product development, code or test changes, Graphify installation, BMAD customization, roadmap expansion, and unrelated architecture documentation.
- Recording ordinary implementation details, temporary feature choices, current R3 minutiae, coding-style conventions, speculative future architecture, or accidental patterns as decisions.
- Reconstructing historical chronology from ADR numbering or inventing rationale that repository evidence does not preserve.

## Success signal

The operator approves a compact candidate set, and the resulting library contains exactly those evidence-supported decisions with a usable index and minimal current-truth links. A file-scope audit shows no product or unrelated documentation changes, and every historical claim is traceable or explicitly marked unrecoverable.
