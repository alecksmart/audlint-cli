# ADR Recovery Contract

## Evidence boundary

Inspect only what is needed from:

- current product code;
- tests;
- `docs/architecture/OVERVIEW.md`;
- `AGENTS.md`;
- existing BMAD planning or specification artifacts when relevant;
- Git history when it materially helps establish intentionality.

Start with current architecture documentation and the nearest code or tests that enforce a possible rule. Use focused `rg`, `git log -- <path>`, `git show`, or `git blame` queries only when they can resolve intent, authority, chronology, or a conflict. Cite exact paths and symbols or line locations; cite commit IDs when Git is evidence. Report conflicts between current sources instead of silently choosing one.

Candidate decisions must constrain multiple features or establish a durable boundary. High-value examples include ownership or authority boundaries, persistent-state ownership, database identity rules, destructive-operation safety, source-versus-derived-data authority, portability or runtime constraints, and command or component boundaries.

Exclude ordinary implementation details, temporary feature choices, current R3 minutiae, coding-style conventions, speculative future architecture, and patterns whose architectural significance is not demonstrated.

## Classification

Use exactly one classification for each candidate:

| Classification | Meaning |
| --- | --- |
| Explicit historical decision | Repository evidence directly records the rule as an intentional decision. |
| Recovered decision strongly supported by repository evidence | Multiple current sources establish a durable rule, but no original decision record survives. |
| Architectural pattern only | A pattern exists, but the evidence does not establish it as a durable architectural rule or recover its authority. |

Do not promote confidence into historical fact. If original rationale is unavailable, say so. Pattern-only findings can appear in Phase 1 to expose uncertainty but do not become ADRs in this recovery task.

## Phase 1: candidate review

Write the compact review to `_bmad-output/implementation-artifacts/adr-recovery-candidate-review.md` and present the table to the operator. Prefer a small high-value set over comprehensive enumeration.

The table must contain:

| Field | Required content |
| --- | --- |
| Proposed ADR title | Concise title for the possible durable rule. |
| Proposed current architectural rule | The rule in current language, without unsupported rationale. |
| Classification | One value from the classification table above. |
| Architectural scope | Commands, components, or concerns constrained by the rule. |
| Concrete evidence | Code, tests, docs, BMAD artifacts, or Git evidence with resolvable citations. |
| Recoverable rationale | Only rationale directly supported by evidence; otherwise state that it is unavailable. |
| Important consequences | Material positive and negative effects established by the rule. |
| Confidence | High, medium, or low. |
| Conflicts or uncertainty | Contradictions, missing evidence, unclear authority, or `None found`. |

End the review with a numbered approval list and a clear statement that no ADR has been created. Stop and wait for the operator to name the approved candidates. Do not create `docs/decisions/`, an ADR draft, the index, or integration links during Phase 1.

## Phase 2: approved ADR creation

Treat the operator's explicit approved-candidate list as the complete Phase 2 scope. Create one ADR per approved explicit or recovered candidate and no others. If an approval is ambiguous or would promote a pattern-only finding without new decision evidence, stop and request a decision rather than silently reclassifying it.

Re-check `docs/decisions/` before assigning numbers. Use the next available zero-padded number in the order the approved library is created now. The number does not represent original historical chronology.

Use `docs/decisions/NNNN-ADR-<short-slug>.md` and this exact structure:

```markdown
# ADR-NNNN: Title

## Status
Accepted | Superseded | Deprecated

## Record type
Historical | Recovered

## Context
The architectural problem or pressure supported by evidence.

## Decision
The durable rule in concise current language.

## Evidence
Concrete code, tests, documentation, and/or Git evidence.

## Rationale
Only rationale supported by evidence.
If unavailable, state:
"Original rationale is not recoverable from repository evidence."

## Consequences
Important positive and negative consequences.

## Alternatives
Include only alternatives for which there is actual evidence.

## Related decisions
Links to related, superseded, or superseding ADRs.
```

Map `Explicit historical decision` to record type `Historical` and `Recovered decision strongly supported by repository evidence` to `Recovered`. Use `Accepted` for a current rule. Use `Superseded` or `Deprecated` only when repository evidence establishes that state and the operator approved recording it. When no evidence-backed alternative or related decision exists, state `None recovered from repository evidence` rather than inventing one.

## Reuse and context hygiene

After the approved ADRs exist:

- create `docs/decisions/README.md` if no equivalent index exists;
- keep the index concise: number, title, status, record type, one-line scope, and link;
- update `docs/architecture/OVERVIEW.md` only where an ADR establishes an important current architectural truth;
- add an ADR reference to `AGENTS.md` only for a rule every implementation agent genuinely must know;
- prefer a short current-truth statement plus an ADR link over copied rationale;
- tell future agents to load only ADRs relevant to the current task, never the whole library by default.

Preserve unrelated edits. Before changing the already-modified architecture overview, inspect its current diff and make only narrow, non-overwriting additions.

## Allowed writes

- `_bmad-output/implementation-artifacts/adr-recovery-candidate-review.md` during Phase 1;
- `docs/decisions/README.md` and approved `docs/decisions/NNNN-ADR-<short-slug>.md` files during Phase 2;
- narrow Phase 2 links or current-truth updates in `docs/architecture/OVERVIEW.md` and, only when universally relevant, `AGENTS.md`.

Do not modify product code, tests, other public documentation, BMAD files, the Orchestration Architect skill, or the roadmap. Do not install Graphify. Stay on the current release branch and do not create a branch or PR.

## Verification and handoff

Phase 1 is complete only when the candidate review contains every required column, each evidence citation resolves, exclusions were applied, and `git diff --name-only` shows no ADR or Phase 2 integration file created by this task.

Phase 2 is complete only when:

- every approved candidate maps to exactly one ADR and no unapproved candidate does;
- filenames are unique and sequential in current library creation order;
- every ADR has the required headings, valid status and record type, evidence-backed language, and the exact unrecoverable-rationale statement where needed;
- index and cross-document links resolve;
- `git diff --check` passes;
- a file-scope review confirms this task changed only the allowed paths and preserved pre-existing unrelated edits.

No product test run is required for documentation-only changes. Report the evidence audit, link check, `git diff --check`, and changed-path review. Return to the Orchestration Architect for acceptance review after Phase 2.
