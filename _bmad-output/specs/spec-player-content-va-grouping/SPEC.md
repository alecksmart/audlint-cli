---
id: SPEC-player-content-va-grouping
companions:
  - brownfield.md
  - ../spec-player-content-creator/player-content-contract.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete contract for this fix.

# Player Content Creator Various Artists Grouping

## Why

Albums stored in nested `_VA` folders are present in the catalog but appear under intermediate directory headings such as `2002`, making the Various Artists inventory look incomplete. The operator needs the selector to reflect the library's `_VA` grouping without disturbing normal artist grouping or durable selections.

## Capabilities

- **CAP-1**
  - **intent:** The operator can see every cataloged album stored anywhere below the `_VA` subtree under one `_VA` artist heading.
  - **success:** Temporary fixtures for `_VA/<year>/<album>` and direct `_VA/<album>` paths all render under `_VA` in year-first order, while ordinary artist paths, selection identity, and source-relative synchronization paths remain unchanged.

## Constraints

- Change display grouping only; preserve catalog membership and the `(artist_lc, album_lc, year_int)` selection identity defined by ADR-0001 and ADR-0002.
- Derive grouping only from a source path already validated below the configured library root. Preserve ordinary artist-directory grouping and order rows within each display artist by `year_int`, then `album_norm`, then `id`.
- Preserve Bash 5 and macOS/Linux portability per ADR-0003 and the shell/shared-helper boundary in ADR-0006.
- Automated verification uses temporary fixtures only per ADR-0004.
- Follow the focused verification stages in `brownfield.md`; do not run the full release gate in this task.

## Non-goals

- Changing scanner discovery, metadata, album identity, source paths, synchronization layout, or the `_VA` directory convention.
- Adding uncataloged filesystem folders directly to the selector.
- Redesigning selector navigation, sizing, synchronization, or ordering beyond the approved year-first rule.

## Success signal

A focused PTY fixture that previously produced `_VA` plus year-number headings now shows one `_VA` group containing every nested compilation album in year-first order, with existing ordinary-artist and selection tests still passing.

## Assumptions

- “Sanity testing” means the existing focused unittest and PTY fixture workflow, not a new test framework.
