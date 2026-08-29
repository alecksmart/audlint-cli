---
id: SPEC-product-roadmap
companions:
  - ../../planning-artifacts/product-roadmap.md
  - ../../../docs/architecture/OVERVIEW.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Audlint Product Roadmap

## Why

Audlint is a shipped local CLI/TUI whose safety, analyzer evidence, correctness, performance, and operator clarity must mature before new product surfaces can safely expose its behavior. This roadmap orders that maturation while preserving the option to reject, defer, or deliberately approve a remote service after the CLI contracts are stable.

## Capabilities

- **CAP-1 — Reproducible baseline (R0)**
  - **intent:** Maintainers can establish a current, reproducible quality and release baseline before declaring a release candidate.
  - **success:** A dated verification artifact describes current `main`; the local quality gate passes, and every supported distro harness passes or has an explicitly accepted blocker.

- **CAP-2 — Truthful mutation safety (R1)**
  - **intent:** Operators can predict and recover from every mutating workflow through truthful dry-run, backup, atomicity, cleanup, and recovery contracts.
  - **success:** A checked-in mutation matrix covers every destructive command, and temporary-fixture tests enforce the highest-risk contracts without touching real libraries or destinations.

- **CAP-3 — Portable continuous verification (R2)**
  - **intent:** Maintainers can receive an automated portable release-gate verdict without displacing the authoritative local gate.
  - **success:** A clean change receives the same essential verdict locally and in automation, with documented exceptions for environment-specific checks.

- **CAP-4 — Analyzer evidence base (R3)**
  - **intent:** Maintainers can evaluate analyzer accuracy and runtime against a versioned corpus whose labels and provenance have explicit trust levels.
  - **success:** The corpus runner fails on trusted mismatches, reports weak mismatches separately, writes nothing into the approved corpus, and produces reproducible accuracy/runtime evidence that exposes cache hits, repeated work, and expensive fallbacks.

- **CAP-5 — Proportionate analyzer execution (R3A)**
  - **intent:** Analyzer consumers can reuse valid analysis and DR evidence under an explicit invalidation contract without repeating avoidable probes or decodes.
  - **success:** Trusted corpus decisions remain unchanged, normal probe and fallback costs are measured, and repeated analyzer use across value, scan, comparison, browser, and conversion paths meets the bounded spec's performance envelope.

- **CAP-6 — Analyzer contract convergence (R4)**
  - **intent:** Every downstream caller can consume one structured analyzer decision contract without reconstructing recode policy from presentation output.
  - **success:** Contract tests cover every decision class and fallback reason, while callers retain only workflow-specific presentation, safety, and execution behavior.

- **CAP-7 — Evidence-driven analyzer refinement (R5)**
  - **intent:** Maintainers can change analyzer thresholds or voting logic only in response to named corpus evidence and measured regressions.
  - **success:** Every decision change improves or preserves the trusted corpus, has explicit regression coverage, and remains within an agreed runtime envelope.

- **CAP-8 — Deterministic analysis parallelism (R6)**
  - **intent:** Operators can run bounded per-track analysis concurrently without changing decisions, ordering, caches, or failure semantics.
  - **success:** Representative workloads improve measurably while serial and parallel modes remain decision-equivalent, resource-bounded, deterministically ordered, and cleanly cancellable.

- **CAP-9 — Safe conversion worker pools (R7)**
  - **intent:** Conversion workflows can share bounded preparation and encoding workers without partial replacement or unrecoverable album state.
  - **success:** Conversion results are serial-equivalent, worker counts are bounded, failures leave no partial replacement, reruns are idempotent, and every supported workflow has focused fixture coverage.

- **CAP-10 — Accessible terminal themes (R8)**
  - **intent:** Operators can use a readable shared terminal palette in dark, light, and no-color environments.
  - **success:** Theme selection or detection is documented, contrast-critical states are covered by PTY or snapshot assertions, and all three modes remain behaviorally identical.

- **CAP-11 — Operator clarity and recovery guidance (R9)**
  - **intent:** Operators can determine workflow readiness, state ownership, failure cause, and supported recovery without private planning material.
  - **success:** A new operator can identify whether a workflow is safe to run, why it failed, and which next or recovery action is supported.

- **CAP-12 — Remote service decision gate (G0)**
  - **intent:** Product owners can decide whether a self-hosted service should exist and what authority it may have before implementation begins.
  - **success:** An approved product brief and PRD establish user value and scope, and an architecture decision demonstrates preservation of CLI safety and data contracts.

- **CAP-13 — Conditional service delivery (G1–G8)**
  - **intent:** If CAP-12 approves a service, the team can deliver it through the roadmap's gated dependency sequence without treating archived hypotheses as requirements.
  - **success:** Each service milestone enters only after its documented gate is satisfied and preserves the approved permission, safety, data, migration, deployment, and recovery contracts.

## Constraints

- Development remains ad hoc and pull-based: priorities express logical urgency, not dates, sprints, velocity, or time-box commitments.
- Roadmap item IDs and states remain stable; completed items move to the evidence-backed ledger, and only one bounded item becomes a build spec at a time unless the user explicitly authorizes parallel work.
- Audio files and embedded tags remain authoritative for media content; SQLite contains derived analysis and operator-managed state and is not assumed fully reconstructible.
- Destructive audio, tag, artwork, deletion, sync, backup, and database workflows require explicit operator control, truthful simulation semantics, failure cleanup, and recoverability.
- Automated verification uses temporary fixtures. Only `/Volumes/Music/Tests` may serve as an approved external analyzer corpus, read-only through staging that prevents generated files from entering it.
- `audlint-analyze` remains the sole recode-decision authority; callers may add safety and presentation but may not recreate analyzer policy.
- Shared policy belongs in `lib/sh/` or `lib/py/`, `bin/` scripts remain orchestration, and normalized profiles remain `SR_HZ/BITS`.
- Bash 5 and macOS/Linux portability remain mandatory.
- Performance work may not weaken deterministic output, failure atomicity, no-upscale behavior, lossy-source guardrails, or trusted-corpus decisions.
- The Go/React service direction remains parked until CAP-12 succeeds; archived technology, database, cloud, monetization, and market choices remain hypotheses.

## Non-goals

- Publishing a release automatically from baseline evidence.
- Introducing sprint planning, velocity, or date commitments.
- Treating roadmap status or planning artifacts as proof of implemented behavior.
- Reopening verified completed work without contrary code, test, or decision evidence.
- Implementing any remote service milestone before CAP-12 approves the product and architecture.
- Building a music player, downloader, general-purpose tag manager, mobile app, multi-user system, or hosted SaaS without a later approved product decision.

## Success signal

Each roadmap item is promoted through a bounded spec only when its dependencies and entry conditions are satisfied, then reaches its source-defined exit gate with code, test, or decision evidence. The CLI foundation becomes demonstrably safe, evidence-backed, deterministic, portable, performant, and understandable before any remote surface can advance from `parked`.

## Open Questions

- What numeric performance envelopes should the bounded specs for CAP-5, CAP-7, CAP-8, and CAP-9 enforce?
- Which mutation classes must require paranoia backup, and what transaction-consistency guarantee must SQLite backups provide under CAP-2?
- Should CAP-12 ever be promoted from `parked`, and if so must the service be read-only, write-capable, or permission-tiered?
