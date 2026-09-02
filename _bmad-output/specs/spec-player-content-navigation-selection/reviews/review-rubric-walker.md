# Good-Spine Rubric Review

## Gate Verdict

**Not ready to finalize:** deterministic lint passes and the architecture is disciplined, brownfield-aware, and broadly capability-complete, but two high-severity rules are not yet enforceable as written; three medium convergence gaps remain.

Deterministic lint: **PASS** — 0 findings using `lint_spine.py` with an isolated writable `uv` cache.

## High

### H1 — The authoritative synchronization sequence omits preflight

- **Where:** AD-8, AD-9
- **Rubric failure:** A Rule must be enforceable and actually prevent its stated divergence; the spine must cover the driving synchronization contract.
- **Problem:** AD-8 says only accepted `w` performs destination safety/writability preflight. AD-9 then declares the established sequence as checked-set snapshot → eligible-track snapshot → filter → rsync → flush → postchecks, but never places or invokes complete preflight in that sequence. Saying the adapter “never duplicates … preflight” establishes ownership but not execution. A builder following AD-9 literally can reach the destructive root rsync without the required complete preflight.
- **Disposition:** **Autofix.** Put complete preflight explicitly before the first destructive transfer in AD-9, owned by the existing shared player pipeline. Keep temporary snapshot/rule construction fail-closed and preserve direct `w` with no second confirmation.

### H2 — Result-slot separation and precedence were dropped

- **Where:** AD-8
- **Rubric failure:** CAP-4 is not fully covered, and independently built chrome, Help/resize, busy, and effect-result stories can diverge.
- **Problem:** AD-8 now defines error and success lifetimes, but no longer requires a separate latest-result slot or states that an active error outranks success and informational feedback. The driving contract requires persistent context to remain separate from the result row and makes error precedence load-bearing. Persistence alone does not stop a lower-priority completion, destination observation, or informational event from replacing an active error.
- **Disposition:** **Autofix.** Restore the separate result slot and the explicit priority `error > success/information`, while retaining the existing lifetime and Help/resize preservation rules.

## Medium

### M1 — Inventory ordering uses undefined normalization and comparison

- **Where:** AD-2
- **Rubric failure:** The canonical hierarchy/order rule is not fully enforceable and can diverge across Python, Bash fixtures, and platforms.
- **Problem:** “normalized artist … normalized album … literal relative-path order” does not define the normalization function or comparison domain. Search normalization in AD-4 is NFC plus full casefold, while the brownfield selector currently emits lowercase sort keys; locale-sensitive and bytewise comparisons can also differ. The 1,600-row hierarchy proof requires deterministic preserved order, including unavailable union rows.
- **Disposition:** **Autofix after code confirmation.** Name the shared emitted sort keys and comparison rule explicitly—preferably one repository-owned normalization function and deterministic comparison locale/order used by both model and fixtures. Do not silently turn search casefold semantics into sort semantics unless that is the confirmed brownfield order.

### M2 — The generated Unicode data version is required but not pinned

- **Where:** AD-4, AD-10
- **Rubric failure:** A named/version-sensitive technology is not fixed sufficiently for independently implemented kernel, generator, and conformance-test units to converge.
- **Problem:** AD-4 requires a “declared Unicode data version” but leaves the declaration to implementation. Separate stories can check in different Grapheme Break/Extended Pictographic tables or fixtures and still claim compliance. The memlog records the repository baseline runtime at Unicode data 16.0.0, but the spine does not bind a version or an authoritative checked-in version marker.
- **Disposition:** **Autofix.** Bind the initial generated-table/conformance-fixture version to one exact repository-supported Unicode version (or one checked-in authoritative version file) and require NFC/casefold compatibility evidence. Future upgrades can remain the coordinated table-plus-fixture change already described.

### M3 — CAP-7’s projection-independence lacks an explicit adapter-level seam

- **Where:** AD-10
- **Rubric failure:** The proof seam does not explicitly exercise one of the feature’s central cross-boundary invariants.
- **Problem:** AD-6 correctly requires synchronization to bypass projection and reread SQLite, and AD-10 names generic synchronization-handoff PTY coverage. It does not require the verification contract’s decisive test: the same durable checked set must yield the same manifest across All/Checked/Unchecked, query, focus, expansion, and collapse combinations, including zero checked. Pure model tests plus player-helper tests can both pass while the controller adapter accidentally exports visible rows.
- **Disposition:** **Autofix.** Add an adapter-level temporary-fixture seam that varies every projection input and compares the emitted manifest/snapshot identity; include zero-checked deletion scope and an unknown checked path that must stop before transfer.

## Rubric Summary

| Checklist dimension | Result | Note |
| --- | --- | --- |
| Real divergence points fixed | **Needs fixes** | H1, H2, M1 remain cross-story forks. |
| AD Rules enforceable and preventive | **Needs fixes** | H1 and H2 are incomplete as written. |
| Deferred cannot cause unit divergence | **Pass** | Deferred items are implementation mechanics or separately scoped product work. |
| Named/version-sensitive technology verified | **Needs fix** | M2 leaves the Unicode table version unbound. |
| Brownfield ratification | **Pass** | Existing helpers and `virtwin.sh` ownership are seed; intentional inventory/progress conflicts are surfaced rather than hidden. |
| Driving capabilities covered | **Needs fixes** | CAP-4 result precedence and CAP-7 preflight/proof need tightening; all other capabilities land. |
| Inherited spine integrity | **N/A** | No parent architecture spine is declared. Accepted ADRs are adopted without weakening. |
| Feature-owned dimensions addressed | **Pass** | State, data/mutation, boundaries, terminal lifecycle, rendering, sync, verification, portability, safety, and operational envelope are decided or deferred. |

## What Is Already Strong

- The Functional Core / Imperative Shell paradigm compresses the design effectively.
- Durable SQLite membership, immutable session inventory, Python semantic state, and Bash effects have one owner each.
- Album and complete-artist mutation share one measure/transaction/ack path, including lost-ack fail-closed handling.
- Projection order and complete-group truth are explicit and synchronization bypasses projection.
- Unicode/grapheme/display policy has one kernel and no speculative package dependency.
- The framed Bash/Python protocol is non-executable and has clear crash/ambiguity behavior.
- `virtwin.sh`, selector raw mode, parser state, foreground input draining, worker output, and exactly-once restoration have non-overlapping owners.
- Track-only file-backed rsync, bounded progress fallback, postchecks, failure preservation, and retry are consumed rather than duplicated.
- Operational, deployment, package-management, and specialized screen-reader scope is explicitly bounded.
