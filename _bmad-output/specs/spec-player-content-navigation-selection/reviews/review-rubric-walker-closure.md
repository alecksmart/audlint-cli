# Good-Spine Rubric Closure Review

## Verdict

**Not yet closed.** Deterministic lint still passes with zero findings. Four of five prior rubric findings are closed, but the ordering repair conflicts with the driving package, and one new width-policy rule cannot guarantee terminal-cell correctness. Two medium lifecycle/boundary gaps remain.

## Prior Findings

| Prior finding | Closure |
| --- | --- |
| H1 — synchronization sequence omitted preflight | **Closed:** AD-9 now places complete shared safety/writability preflight before transfer, revalidates before rsync, and forbids transfer after any pre-rsync failure. |
| H2 — result separation and priority missing | **Closed:** AD-8 now separates chrome/result state, fixes `error > success > information`, and defines replacement/preservation transitions. |
| M1 — ordering normalization/comparison undefined | **Not closed:** comparison is now precise, but it deliberately changes the binding existing order. See H1 below. |
| M2 — Unicode data version unpinned | **Closed:** AD-4 pins checked-in Unicode 14.0.0 grapheme data and a runtime floor; AD-10 pins its fixtures. |
| M3 — projection-independent sync seam missing | **Closed:** AD-10 now varies view/query/focus/expansion/collapse and covers zero and unknown checked states. |

## Critical

None.

## High

### H1 — AD-2 silently introduces a new sort order

- **Driving contract:** `SPEC.md` says the redesign does not supersede stable ordering and lists new sort orders as a non-goal; `interaction-contract.md` requires preserving existing artist/year/album order.
- **Current rule:** AD-2 changes sorting to NFC + full casefold, Python Unicode-scalar comparison, and literal UTF-8 path tie-breaking, explicitly replacing the brownfield locale-dependent comparison.
- **Why it remains load-bearing:** This is precise but not inherited. Full casefold can reorder labels differently from the current lowercase keys, and a new path tie-breaker can reorder equal artist/year/album rows. Focus fallback, page movement, reopening, and 1,600-row fixtures all consume this order. The change is neither marked as a resolved input conflict nor authorized by the package.
- **Required disposition:** **Autofix if code evidence supplies an exact preservation rule; otherwise discuss.** Treat current inventory sort keys/order as opaque canonical input or reproduce their semantics without adding a new sort. If deterministic cross-locale replacement is truly required, surface it as a SPEC conflict and obtain authority instead of calling it preservation.

### H2 — AD-4's conservative width policy is not terminal display-cell measurement

- **Driving contract:** Search, labels, truncation, and caret placement must use terminal display cells; unreliable measurement must enter the defined fallback.
- **Current rule:** Every cluster containing an East Asian Ambiguous scalar is always counted as two cells, while all other printable-base clusters not covered by Wide/Fullwidth, regional-indicator, or Extended-Pictographic checks are counted as one.
- **Why it remains load-bearing:** East Asian Ambiguous characters are normally one cell in common Western macOS/Linux terminals and may be two in CJK-width environments. Always counting them as two can place the search caret in the wrong cell even if early clipping prevents wraps. A fixed conservative count is therefore not an accurate terminal-cell oracle, and the rule does not route ambiguous-width clusters through its unreliable-measurement fallback. Other terminal-dependent emoji sequences can create the same mismatch.
- **Required disposition:** **Discuss, then fix the invariant.** Bind one supported terminal-width profile with evidence, or classify width-variable clusters as unreliable and apply replacement/entry fallback. Keep the cell oracle and PTY tests independent enough to detect policy-versus-terminal disagreement rather than sharing the same incorrect function.

## Medium

### M1 — Availability/measurement overlay has no refresh transition

- **Where:** AD-2, AD-8, AD-9
- **Problem:** The model owns a mutable availability/measurement overlay; initial sizing can mark a checked path unknown and AD-8 blocks `w` “until readable or removed.” No rule says what event rechecks readability during the session. If unknown state prevents the model from emitting a sync intent, AD-9's fresh snapshot is unreachable even after the source becomes readable.
- **Required disposition:** **Autofix from the contract's foreground model.** Define the refresh point—for example, accepted `w` first remeasures unknown checked paths during preflight and proceeds only if the new complete snapshot succeeds, while identity/order remain frozen. Add the transition to the adapter seam.

### M2 — Protocol artifacts lack a security and completion lifecycle

- **Where:** AD-5, Protocol v1
- **Problem:** Inventory, frame, event/effect, and mutation data can travel by artifact path, but the revised rule no longer fixes artifact creation permissions, owner, location, publish-after-close behavior, or cleanup. AD-9 protects synchronization artifacts only. Rejecting truncated input is fail-closed, but it does not prevent partial artifacts from being exposed, sensitive library paths from receiving broad permissions, or controller/model cleanup ownership from diverging.
- **Required disposition:** **Autofix.** Require protocol artifacts to use the repository's portable secure-temp policy, restrictive permissions, checked complete writes exposed only after close, locations outside protected roots, single-owner cleanup, and cleanup on normal/fatal/trappable exits. Keep exact filenames and buffering mechanics deferred.
