---
id: SPEC-player-content-sync-flow
companions:
  - brownfield.md
  - ../spec-player-content-creator/player-content-contract.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete contract for this fix.

# Player Content Creator Direct Clean Synchronization Flow

## Why

Starting synchronization currently requires a second confirmation, and its output plus an `any key Continue` pause is written into the selector canvas. The result is a cluttered screen and extra input for actions the operator has already chosen.

## Capabilities

- **CAP-1**
  - **intent:** The operator can start synchronization with `w` and exit with `q` without confirmation prompts, while seeing a clean running state and concise final result.
  - **success:** After complete preflight, `w` invokes the mirror without `y` or continue input; `q` exits immediately; synchronization output never overlaps album rows; and success or failure automatically returns to a clean selector with one readable outcome while current safety and retry tests pass.

## Constraints

- `w` is the intentional command to mirror the current snapshot, including an empty selection. Do not add a replacement confirmation gesture.
- Preserve every source, destination, containment, writability, manifest, tool, and payload preflight before invoking deleting `rsync`.
- Preserve source immutability, exact selected-mirror deletion, selection persistence on failure, nonzero failure reporting, and retry convergence.
- Give synchronization exclusive ownership of the selector body while it runs; clear and redraw deterministically, then show one concise outcome without an `any key` pause.
- Use temporary fixtures and stub tools only; never access a real library, live database, or mounted player during automated verification.
- Run the staged focused checks in `brownfield.md`, then run `make check` exactly once only after all four child fixes are present.

## Non-goals

- Weakening destructive-path safety, changing mirror scope, adding rollback, or changing payload rules.
- Adding background synchronization, a progress bar, cancellation, or transfer history.
- Changing the separate full-library `sync_music.sh` workflow.

## Success signal

One `w` press against temporary fixtures produces a clean progress/result flow and the expected exact mirror; one `q` exits immediately; unsafe preflight and stubbed failures remain readable and invoke no unsafe deletion; the final repository gate passes once with all four fixes integrated.
