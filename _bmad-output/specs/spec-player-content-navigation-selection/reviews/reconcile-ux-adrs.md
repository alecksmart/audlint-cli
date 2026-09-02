# UX and ADR Reconciliation Review

## Verdict

**Changes required before finalization.** The spine has no direct contradiction with the binding UX documents or ADR-0003/0004/0006/0007/0008/0009. Its central ownership model, one membership mutation path, projection isolation, terminal controller, and reuse of the accepted synchronization pipeline are consistent. Five inherited contracts remain too implicit for independently implemented stories to converge safely.

## Findings

### F1 — High: the adopted terminal accessibility floor is incomplete

**Evidence:** AD-7 binds ADR-0009 and covers single-owner terminal restoration; AD-8 covers bounded rendering; Deferred excludes a specialized screen-reader capability. Neither rule preserves the other accepted baseline requirements: every primary action remains keyboard-operable, `NO_COLOR` and non-color meaning remain intact, Help is reachable and complete at every supported size, and ordinary keyboard/visible-marker behavior is never described as screen-reader support. AD-7 is also not marked `[ADOPTED]` despite principally carrying accepted ADR-0003/0009 constraints. See spine AD-7/AD-8 (lines 82–92), DESIGN.md lines 38–44 and 54–60, EXPERIENCE.md lines 23 and 128–136, and ADR-0009 Decision lines 17–30.

**Why it matters:** Rendering, Help, and documentation stories could each satisfy the current spine while independently dropping a different part of the accepted accessibility boundary.

**Required correction:** Carry the full ADR-0009 floor in an adopted rule (or expand AD-7/AD-8 and mark the inherited portion adopted): keyboard reachability, `NO_COLOR`/non-color semantics, complete Help at supported sizes, display-cell safety, exact restoration, and the prohibition on specialized-mode/conformance claims. Preserve the defined ASCII fallback without changing row meaning.

### F2 — High: destination presence and unknown-size synchronization readiness lack an owner and gate

**Evidence:** AD-8 propagates an unknown checked payload into chrome and prioritizes a safe destination label, but does not say that an unknown checked payload blocks `w`. No AD owns the live SD-directory presence probe or requires it to refresh on every redraw while allowing detached browse, persistence, and sizing. EXPERIENCE.md lines 59 and 72–73 require both behaviors; its synchronization contract also permits full destination preflight only after `w`.

**Why it matters:** Separate chrome, sizing, and synchronization stories could cache destination state at entry, disable detached curation, or allow synchronization from a known-incomplete size state. Those are incompatible experiences and weaken the explicit safety state.

**Required correction:** Assign destination-presence observation to the controller/environment effect boundary and bind each redraw to a fresh directory-existence result without treating it as preflight. State that any checked unavailable/unmeasurable path makes global size unknown and blocks `w` until the path is removed or becomes readable; individual and group uncheck remain available.

### F3 — Medium: Help and result lifecycles are referenced, not settled

**Evidence:** AD-2 assigns Help position and result state to Python, while AD-8 says only that the result slot follows “the contract lifetimes.” The spine does not preserve the cross-mode invariants that Help dismissal restores browser/query/focus/expansion/results unchanged, Help and resize preserve results, errors persist until the next relevant mutation or explicit replacement, and success survives at least one stable repaint and clears when the next action starts. See EXPERIENCE.md lines 63 and 94–97 and DESIGN.md lines 64 and 68–71.

**Why it matters:** Help, resize, mutation, and rendering stories can otherwise clear or replace the same state at different times while all claiming the same owner.

**Required correction:** Put the lifecycle in the owning state/render AD rather than relying on an unnamed external “contract”: modes project or paginate the resident state; they do not reset it. Record the error/success replacement rules and Help dismissal restoration explicitly.

### F4 — Medium: the adopted snapshot/rule identity is ambiguous at the adapter boundary

**Evidence:** AD-9 correctly adopts ADR-0007/0008 and bans duplicated eligibility, sizing, and rule policy, but its sequence says “file-backed eligible-track snapshot and size rows, ordered merge rule.” This does not unambiguously require the ordered merge filter itself to be file-backed or state that displayed logical bytes and transfer membership are derived from the same completed snapshot. ADR-0008 lines 19–33 requires both, along with complete-artifact exposure, fixed-size argv, one deletion-capable root rsync, source stability, destination postcheck, and fresh-artifact retry.

**Why it matters:** A controller adapter could consume size rows from one walk and request a newly generated transfer snapshot, or rebuild per-path rules in argv, reintroducing precisely the divergence ADR-0008 prevents.

**Required correction:** Tighten AD-9 to say that the controller passes one completed file-backed snapshot through the existing shared compiler; that snapshot is the sole source for album/global logical bytes and transfer membership; the compiler produces one file-backed ordered merge filter; the adapter contributes no per-track/per-album rule arrays or alternate walk.

### F5 — Medium: portability and isolated-verification inheritance is only partial

**Evidence:** Deferred mentions the inherited Bash 5 macOS/Linux floor, but AD-4 introduces a libc `wcswidth` backend and AD-5 introduces framed file descriptors and secure temporary artifacts without binding their platform proof to ADR-0003. AD-10 requires temporary fixtures but omits ADR-0004's requirement to stub external tools and does not mention the distro-focused portability checks required for cross-platform behavior.

**Why it matters:** A pure injected width test or temporary directory alone does not prove the selected backend and shell mechanics on supported macOS/Linux environments, and invoking real mount/flush/rsync tooling would violate the accepted verification boundary.

**Required correction:** Mark the portability and resource-safety parts adopted. Require portable shared temporary-file/path helpers, supported-platform probes for the width backend and CSI/SS3 parser, existing Bash 5/distro gates where affected, and stubs for external synchronization/mount/flush tools in all automated proof.

## Confirmed alignments

- Functional Core / Imperative Shell and AD-1 conform to ADR-0006: entry script adapts, shared shell owns policy/effects, and importable Python owns substantial computation.
- AD-2/AD-3 preserve immutable inventory identity, SQLite durability, unavailable checked paths, immediate persistence, and atomic artist mutations.
- AD-6 keeps View, query, expansion, Help, and Current outside membership and synchronization scope.
- AD-7 establishes one TTY owner for raw mode, caret, scroll region, partial sequences, resize, busy input draining, synchronization handoff, and exactly-once restoration.
- AD-9 preserves the accepted track-only owned-root mirror, aggregate-progress fallback, stage-specific outcome, failure preservation, and retry direction without a second synchronization implementation.
- AD-10 correctly keeps SQLite, PTY, player, and Unicode proof on temporary fixtures; F5 is a needed strengthening, not a reversal.

## Conflicts

No spine rule silently overrides an accepted ADR or the UX contract. The two implementation conflicts already surfaced by the spine—purging unavailable checked identities and filename-level progress transcripts—are correctly identified as code/test behavior to replace rather than retained architecture.
