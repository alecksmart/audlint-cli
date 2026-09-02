# SPEC Package Reconciliation

## Verdict

**Changes required before finalization.** The spine has the right paradigm and cleanly assigns durable membership, session state, effects, terminal ownership, projection, synchronization reuse, and test layers. Four binding package rules are missing or too weak, and one machine-boundary rule is internally ambiguous.

## Findings

### 1. High — Checked-set sizing and unavailable-path safety did not fully land

**Source:** `SPEC.md:62`, `SPEC.md:64`; `interaction-contract.md:56–60`; `verification.md` Membership and Synchronization membership rows.

AD-2 introduces a measurement overlay, AD-8 propagates unknown size, and AD-9 names snapshot/size rows, but no rule binds the full lifecycle:

- initial sizing builds the complete checked-set eligible-track snapshot only;
- that same snapshot definition supplies displayed logical bytes and transfer membership;
- a checked path that cannot be measured stays checked, makes its album and artist payload unknown, and blocks `w` until readable or removed;
- unchecking an unavailable checked album requires no measurement and must remain possible;
- human-readable total size is valid only when every checked contributor is known.

Without this invariant, separate sizing, mutation, chrome, and synchronization stories can legitimately choose incompatible measurement scope or allow a partial mirror. Amend an AD (or add one) to bind the shared snapshot/unknown/blocking rule, and make AD-10 inject an unmeasurable checked path to prove both UI state and `w` refusal.

### 2. High — Canonical hierarchy and `_VA` ordering are absent

**Source:** `SPEC.md` CAP-1 and `SPEC.md:59`; `interaction-contract.md:7,13–18`; `verification.md` Hierarchy and scale row; `.memlog.md:26`.

AD-2 freezes an `identity/order inventory`, but it never says which order or grouping is canonical. The binding rule to preserve existing artist/year/album ordering and direct/nested `_VA` grouping was dropped during distillation. That boundary is shared by inventory production, tree construction, focus anchoring, and viewport tests, so code discovery alone does not prevent independent stories from disagreeing.

Bind the existing canonical ordering and `_VA` grouping explicitly, including deterministic placement of unavailable persisted paths in the frozen union inventory. Exact helper names and sort implementation can remain seed/deferred.

### 3. Medium — Destination observation is not separated from synchronization preflight

**Source:** `SPEC.md` CAP-4 and `SPEC.md:62,65`; `interaction-contract.md:64,70`; `verification.md` Help, chrome, and results row.

AD-8 requires a safe destination label, while AD-9 names preflight, but the spine omits that SD-directory presence is refreshed on every redraw and remains informational, that free-space reporting remains informational, and that only accepted `w` performs destination safety/writability preflight. This leaves controller, chrome, and sync stories free to use stale presence or turn informational observations into a selection/sync gate.

Add the observation-versus-authority boundary and retain a seam that changes destination presence between redraws while proving it neither mutates membership nor substitutes for `w` preflight. Preserve the full validated destination in Help when chrome abbreviates it.

### 4. Medium — The record protocol contradicts its own control-character rule

**Source:** The package requires malformed/control-bearing machine data to fail closed and user text never to become shell input (`SPEC.md:68`; `verification.md` Progress handoff row).

AD-5 says fields are separated by ASCII Unit Separator (`0x1f`) and then says to reject “control-bearing records.” Since the separator is itself a control character, two implementations can disagree on whether every valid record is invalid. State that framing delimiters are the only permitted control bytes, field payloads are control-free, and LF/US are rejected inside fields. The protocol seam should cover embedded LF/US, truncated records, size limits, unknown versions, and request-id mismatch.

### 5. Package conflict — Verification still names the wrong planning baseline

**Source:** requested baseline and current HEAD are `77ea99c`; `verification.md:3–15` and `.memlog.md:32–33` still claim `22b6f28` is current HEAD and attach the 42-test result to it.

The later memlog constraint correctly binds the architecture run to `77ea99c`, but the primary verification companion remains contradictory and the spine's Resolved Input Conflicts section does not surface it. Before finalization, update the verification baseline/evidence to `77ea99c` (rerunning or explicitly revalidating the cited proof at that commit) and append a corrective memlog entry; preserve the old append-only entries as historical evidence.

## Confirmed Landed

- Functional Core / Imperative Shell and the ADR-0006 dependency direction.
- SQLite as sole durable membership authority; Python as sole semantic/session-state owner.
- One album/artist intent-to-measure-to-transaction-to-ack mutation path.
- Fixed view/query/expansion/focus/viewport projection pipeline with sync bypass.
- One Bash owner for raw mode, parser state, Help/search dispatch, foreground draining, resize, canvas, and exactly-once restoration.
- Centralized NFC, full casefold, grapheme, and display-cell policy without speculative Python packages.
- Reuse of the accepted file-backed track-only rsync, progress fallback, postcheck, failure-preservation, and retry pipeline.
- Temporary-fixture model, SQLite, player-helper, and PTY test layers under ADR-0004.
