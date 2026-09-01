---
id: SPEC-player-rsync-feedback
companions:
  - ../../../docs/decisions/0003-ADR-bash5-portability.md
  - ../../../docs/decisions/0004-ADR-real-resource-verification-safety.md
  - ../../../docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate.

# Player Content Live Rsync Progress

## Why

Player Content shows only `Synchronizing player...` during the potentially long `[m]` → `[c]` → `[w]` write. Because rsync output is hidden, the operator cannot tell whether a large transfer is advancing.

## Capabilities

- **CAP-1**
  - **intent:** The operator can see live aggregate rsync progress while Player Content synchronizes the player.
  - **success:** A progress-capable rsync produces bounded live transfer updates before the authoritative final result; a rsync without optional progress support still follows the existing completion and failure contract.

## Constraints

- Preserve the one root-level exact track-only mirror and every existing snapshot, rule, deletion, flush, source-stability, destination-postcheck, exit-status, checked-selection, and retry behavior.
- Probe optional rsync progress support instead of requiring one version or flavor; preserve Bash 5 and macOS/Linux portability under ADR-0003.
- Render only sanitized, terminal-width-bounded aggregate updates in selector-owned space. Raw filenames, control data, verbose output, and unbounded buffering must not enter or corrupt the canvas.
- Progress setup failure or unavailable progress flags must fall back to the existing synchronization path and must not make an otherwise valid transfer unavailable.
- Automated proof must use temporary libraries, databases, destinations, and tool stubs under ADR-0004. Real operator resources require explicit approval.
- Preserve the file-backed snapshot and root-rsync mechanism established by ADR-0008.

## Non-goals

- Filename-level transcripts, per-file progress UI, cancellation, background transfer, or transfer history.
- Progress changes to browser transfer or `sync_music.sh`.
- Any change to transfer membership, deletion authority, metadata policy, or success conditions.

## Success signal

A temporary-fixture PTY test blocks rsync after emitting aggregate progress and observes a bounded update before release, then observes the correct final result. Focused tests also prove a real nonzero rsync status remains authoritative with checked selection preserved, unsafe or oversized records cannot corrupt the canvas, and rsync without optional progress support still synchronizes normally.

## Assumptions

- Aggregate transfer state in the existing Player Content status area satisfies the request for rsync progress; raw per-file output is not required.
