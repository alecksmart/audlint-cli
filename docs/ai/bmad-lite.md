# BMAD Lite Rules

Use the smallest process and implementation that safely satisfies the requested capability.

## Scope

- Treat the capability requested by the user as the complete default scope.
- Do not add adjacent capabilities, speculative improvements, future extensibility, or roadmap items unless explicitly requested.
- One requested capability should normally remain one bounded work item.
- Decompose only when independent implementation or verification genuinely requires it.
- If decomposition appears necessary, explain why before creating child work.

## Design

- Prefer modifying existing code over creating new abstractions.
- Prefer the simplest implementation that satisfies the acceptance criteria.
- Create reusable infrastructure only when there are already multiple concrete consumers.
- Do not generalize for hypothetical future requirements.
- Preserve established architecture and applicable ADRs.

## Planning

- Keep specifications short, concrete, and implementation-oriented.
- Describe what changes, what remains unchanged, and how success is verified.
- Avoid methodology jargon and unnecessary explanatory prose.
- Do not expand the product roadmap while specifying a bounded capability.
- Do not turn implementation observations into new requirements.

## Context

- Read only project context relevant to the current capability.
- Load only ADRs that constrain the current work.
- Do not preload old specs, archived plans, unrelated implementation artifacts, or future ideas.
- Current code, tests, accepted ADRs, and Git state take precedence over stale planning artifacts.

## Verification

- Reduced process must not mean reduced correctness.
- Implement the minimum focused automated test set that convincingly proves the changed behavior.
- Combine related acceptance cases where practical.
- Avoid exhaustive permutation matrices and duplicated coverage already provided by existing tests.
- Give extra test coverage to destructive, safety-critical, and regression-prone behavior.
- Run targeted verification during implementation.
- Run the project's full required verification once near completion unless an intermediate full run is specifically justified.
- Avoid repeatedly running expensive whole-project verification after trivial edits.

## Escalation

Use heavier BMAD planning only when the work is genuinely:
- cross-cutting,
- architecturally consequential,
- safety-sensitive,
- ambiguous in scope,
- or large enough that decomposition materially reduces implementation risk.

Otherwise prefer the shortest safe BMAD path.
