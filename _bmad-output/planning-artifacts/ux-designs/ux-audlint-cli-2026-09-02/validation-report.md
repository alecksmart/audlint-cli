# Validation Report — audlint-cli Player Content

- **DESIGN.md:** `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md`
- **EXPERIENCE.md:** `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md`
- **Run at:** 2026-09-02T12:06:17+02:00

## Overall verdict

The finalized spine pair is strong and ready for clean source extraction by architecture and implementation consumers. All eight rubric categories pass without findings: source capabilities are covered or explicitly excluded from this UX surface, every reference resolves, load-bearing decisions are committed, and the accessibility claims stay within ADR-0009's baseline terminal boundary.

The additional lenses narrow that readiness. Before implementation, resolve two high-severity ambiguities: operators cannot reveal a clipped Current album's full identity, and cold-load sizing has no input-ownership boundary. Seven medium and one low finding further tighten non-TTY entry, busy-state affordance, repaint behavior, narrow-footer fit, too-small input semantics, search inheritance, unknown-size presentation, and inherited ANSI-color limits. No finding asks for or implies the specialized screen-reader capability excluded by ADR-0009.

## Category verdicts

- Flow coverage — **strong**
- Token completeness — **strong**
- Component coverage — **strong**
- State coverage — **strong**
- Visual reference coverage — **strong**
- Bloat & overspecification — **strong**
- Inheritance discipline — **strong**
- Shape fit — **strong**

## Findings by severity

### Critical (0)

No critical findings.

### High (2)

**[Accessibility] — Full item identity disappears behind clipping** (`DESIGN.md:54,66`; `EXPERIENCE.md:51,140`)

Rows must truncate by display cells, but no keyboard-reachable surface reveals the complete Current artist/year/album identity. Long labels with the same visible prefix can therefore be confused before a membership change.

Fix: Put the full sanitized Current identity in a read-only Help/detail entry that wraps or pages by display cells; keep the tree row clipped and avoid marquee text.

**[Edge cases] — Initial checked-set sizing has no input-ownership boundary** (`EXPERIENCE.md:68-75`; `player-content-contract.md:45-55`)

Cold-load sizing defines progress but not whether Space, `w`, `q`, paste, resize, or partial terminal sequences are honored, ignored, or drained. Queued input can execute immediately after sizing completes.

Fix: Make initial sizing an explicit input-owning phase through its authoritative redraw; define any safe controls, treat resize as layout, discard ordinary bytes, and reset parser state before browser commands resume.

### Medium (7)

**[Accessibility] — Redirected and non-TTY behavior is uncommitted** (`EXPERIENCE.md:19,135`; `ADR-0009:24`; `lib/sh/bootstrap.sh:130,158`)

The contract does not say what happens when stdin or stdout is redirected, leaving room for cursor-control output in files, split `/dev/tty` rendering, or blocked automation.

Fix: Require a usable controlling terminal for input and full-screen output; otherwise emit one plain escape-free stderr diagnostic and return without mutation. Prove redirected-stdin, redirected-stdout, and no-controlling-TTY paths.

**[Accessibility] — Busy surfaces hide the input and cancellation contract** (`DESIGN.md:56,69`; `EXPERIENCE.md:64,91,199`)

Measurement and synchronization drain input, but their visible surfaces do not say ordinary keys, including `q`, are ignored while the normal footer advertises those commands.

Fix: Replace inactive hints with a bounded legend such as `Working — input ignored`; retain abnormal-exit restoration and retry behavior without adding the deferred cancellation feature.

**[Accessibility] — Progress repaint has no reduced-motion or flicker bound** (`DESIGN.md:38,69`; `EXPERIENCE.md:91,100`)

Live progress has no cadence cap or prohibition on blink, spinners, marquees, and full-body flashing.

Fix: Update only the reserved row, coalesce rapid records to a modest fixed rate, and forbid blink, spinner, marquee, and alternating-color animation. Use the stable busy fallback as reduced-motion behavior.

**[Edge cases] — The 40–59-cell footer tier does not fit at 40–42 cells** (`DESIGN.md:54-60`; `EXPERIENCE.md:131-140`)

`Space toggle | v view | ? help | w sync | q` occupies 43 display cells but is assigned to widths beginning at 40, while fixed rows may not wrap.

Fix: Add a fitting 40–42-cell variant, shorten the tier, or start this tier at 43 and reuse the minimal tier below it.

**[Edge cases] — Too-small `q` semantics conflict with preserved search and Help modes** (`EXPERIENCE.md:62-64,74-75,115-121,133-136`)

When the terminal shrinks below 12×20, `q` can mean query text, Help dismissal, or selector exit, but the too-small mode does not say which binding wins.

Fix: Declare too-small as a distinct input mode and give `q` one visible, unambiguous action; suspend underlying mode bindings and prove resize recovery.

**[Edge cases] — Search omits committed year matching and derived expansion restoration** (`.memlog.md:28,30`; `EXPERIENCE.md:37,43-45,62,115-123,169-176`)

The decision log includes year matching and temporary expansion of matching groups, but the finalized spine names only artist/album matching and does not define restoration after clearing a query.

Fix: Match normalized artist, rendered year, and album text; define a derived expansion overlay that exposes results without changing the session-local expansion set.

**[Edge cases] — Global size presentation is ambiguous when checked payload is unknown** (`DESIGN.md:64-66`; `EXPERIENCE.md:59-61,72-73,89-92`)

Artist rows can say `size unknown`, but selector chrome may still present the known-byte subtotal as though it were the complete checked-set size.

Fix: Show global `size unknown` whenever any checked payload is unknown, or label a known subtotal explicitly as partial and keep the unknown count visible.

### Low (1)

**[Accessibility] — Inherited ANSI roles have no contrast boundary** (`DESIGN.md:38,42`; `ADR-0009:20`)

The spine correctly avoids color-only meaning, but does not state what Player Content can and cannot guarantee on user-controlled terminal palettes.

Fix: Set no background color and use no dim, blink, or color-only emphasis for load-bearing text; identify terminal-palette contrast as operator-controlled and `NO_COLOR` as an escape-free presentation, not a conformance claim.

## Closed regression checks

- All seven frontmatter sources resolve, and ADR-0007/ADR-0008/track-only precedence is explicit.
- All six component names match across DESIGN tokens, visual specifications, and EXPERIENCE behavior.
- `{typography.terminal-ui}` resolves; no literal color tokens are required for this inherited terminal delta.
- Every named source capability is covered by a named-protagonist flow or explicitly excluded from Player Content.
- Projection/focus recovery, hidden complete-group scope, unavailable rows, Unicode editor lifecycle, Help, artist/sync ownership, result priority, full-set synchronization, terminal restoration, and ADR-0009's accessibility boundary are explicit.
- No imports, mockups, or wireframes exist, so there are no visual-reference orphans.

## Reviewer files

- `review-rubric.md`
- `review-accessibility.md`
- `review-edge-cases.md`
