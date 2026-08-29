---
id: SPEC-r3-1a-corpus-manifest-bootstrap-human-review
companions:
  - draft-manifest-contract.md
sources:
  - ../spec-r3-1-corpus-manifest-safe-inventory/SPEC.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/SPEC.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/corpus-manifest.md
  - ../../../docs/architecture/OVERVIEW.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability only.

# R3.1A Corpus Manifest Bootstrap and Human Review

## Why

R3.1 can safely validate and inventory a substantially complete strict manifest, but the approved corpus has no safe starting workflow for creating that input. Maintainers need read-only discovery that removes mechanical inventory work while keeping analyzer expectations, provenance, reviewer identity, synthetic lineage, and trust under human control.

## Capabilities

- **CAP-1 — Read-only corpus discovery**
  - **intent:** Maintainers can discover candidate corpus cases and objective file and media facts beneath an explicitly supplied root without analyzing or changing the corpus.
  - **success:** A temporary-fixture run deterministically enumerates safe root-relative candidates, hashes regular files, probes supported media, rejects unsafe filesystem entries, and launches no analyzer or mutating workflow.

- **CAP-2 — Review-safe draft**
  - **intent:** Maintainers can receive one draft that clearly separates objective automation output from decisions requiring human review.
  - **success:** The draft follows the existing schema-version-1 shape, populates only permitted objective or mechanical fields, leaves every human-owned required field as `null`, and therefore cannot pass unchanged through strict R3.1 validation.

- **CAP-3 — Human review handoff**
  - **intent:** A reviewer can turn the draft into valid input for the existing R3.1 inventory without another conversion format or a second source of manifest rules.
  - **success:** After the reviewer completes and confirms every field listed in the companion contract, the unchanged R3.1 `--inventory CORPUS_ROOT REVIEWED_DRAFT` path either emits canonical `corpus-manifest.json` or rejects the input under its existing strict rules.

- **CAP-4 — Immutable-source evidence**
  - **intent:** Maintainers can prove that bootstrap discovery treats the supplied corpus as read-only input.
  - **success:** Pre/post fixture evidence shows no path, type, content, size, mode, modification-time, or status-change-time difference beneath the supplied root; only the repository draft artifact may be created or replaced atomically, and read access-time changes are excluded.

## Constraints

- The bootstrap route requires an explicit corpus root and writes its sole stable output to `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest-review-draft.json`.
- Draft publication is atomic and does not overwrite an existing draft by default, preserving partial human review.
- The draft uses the existing schema-version-1 manifest structure and contains no draft-only fields. Required human values use JSON `null`, which the existing strict validator rejects until review is complete.
- Automation may populate only the fields listed as automated in `draft-manifest-contract.md`. It may suggest deterministic case boundaries, categories, and file roles, but the human review must confirm or correct those suggestions.
- Human review owns stable corpus and entry identity, case grouping and classification, expected source and target profiles, expected decision, expected fake-upscale value, optional expected analysis mode, provenance, reviewer identity and date, trust, and synthetic generation recipes.
- Discovery stores normalized POSIX paths relative to the supplied root, does not follow symlinks, and fails safely on path escape or unsupported filesystem entry types.
- `/Volumes/Music/Tests` remains immutable input. Bootstrap creates no file, directory, cache, sidecar, temporary path, tag, permission change, rename, generated media, or timestamp write beneath it.
- Bootstrap does not run `audlint-analyze`, `audlint-value`, converters, dataset generation, staging, evaluation, benchmarking, finalization, database commands, or any current R3.2–R3.5 operation.
- Draft JSON uses UTF-8, two-space indentation, lexicographically sorted object keys, LF endings, one final newline, and deterministic array order.
- CLI orchestration remains thin; discovery, containment, hashing, probing, and draft shaping reuse shared Python policy where it already exists.
- Preserve Bash 5, macOS/Linux portability, canonical `SR_HZ/BITS` normalization, and all existing R3.1–R3.5 public behavior.
- Automated verification uses repository-owned temporary fixtures only. It covers deterministic discovery, objective fact accuracy, candidate ordering, unsafe paths, symlinks and special files, probe failure, no-overwrite behavior, remaining-placeholder rejection by R3.1, analyzer non-invocation, and complete source immutability.

## Non-goals

- Changing the strict R3.1 manifest schema, validation rules, canonical output, or coverage policy.
- Inventing, deriving from Audlint, or defaulting any expected result, provenance statement, reviewer decision, synthetic lineage, or trust value.
- Evaluating corpus accuracy or changing R3.2 staging and verdict behavior.
- Changing R3.3 instrumentation, R3.4 benchmark execution, R3.5 synthetic verification or finalization, or any analyzer decision and performance behavior.
- Running R3.1A automated tests against `/Volumes/Music/Tests` or another real library.

## Success signal

Against a repository-owned read-only fixture, one bootstrap invocation creates the exact review draft at the declared path and changes nothing beneath the fixture root. The unchanged draft fails strict R3.1 validation on human-owned `null` fields; after those fields are reviewed and completed, the existing `--inventory` route accepts it and emits the canonical manifest without any R3.2–R3.5 change.
