# Accessibility Review — Audlint Player Content

## Overall verdict

**Adequate, with one high-impact ambiguity to resolve before implementation.** The finalized spines now cover the baseline terminal guarantees that ADR-0009 keeps binding: complete keyboard operation, non-color meaning, Unicode/display-cell safety, bounded Help, stable focus through projection and resize, exclusive input ownership, explicit destructive scope, authoritative outcomes, and terminal restoration. They also correctly avoid claiming a specialized screen-reader mode or accessibility conformance. The remaining weaknesses concern access to clipped identity, non-TTY output, busy-state affordance, repaint cadence, and the limits of inherited terminal colors.

Finding counts: **critical 0 · high 1 · medium 3 · low 1**.

## Findings

### Full item identity disappears behind clipping

- **[high]** Rows, status, and query text must truncate by display cells, but the contract gives no keyboard-reachable way to inspect the complete Current artist/album identity. Search does not solve collisions between long labels with the same visible prefix, and Help guarantees the full destination only—not the full Current item. An operator can therefore check the wrong album while every visible cue remains valid. (`_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:54`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:66`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:51`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:140`). *Fix:* Put the full sanitized Current artist/year/album identity in a keyboard-reachable, read-only Help/detail entry that wraps or pages by display cells; keep the tree row clipped and do not use a marquee.

### Redirected and non-TTY output behavior is uncommitted

- **[medium]** Foundation scopes the experience to a terminal and the lifecycle contract assumes saved TTY state, but neither spine says what happens when stdin, stdout, or both are redirected. A downstream implementation can legitimately emit cursor-control bytes into a file, split rendering between stdout and `/dev/tty`, or wait for terminal input during automation. That is a baseline correctness boundary, not a request for the line-oriented screen-reader mode rejected by ADR-0009. (`_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:19`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:135`, `docs/decisions/0009-ADR-terminal-accessibility-boundary.md:24`, `lib/sh/bootstrap.sh:130`, `lib/sh/bootstrap.sh:158`). *Fix:* State one fail-closed rule: require a usable controlling terminal for both input and full-screen output before entering the selector; otherwise print one plain, escape-free diagnostic to stderr and return without mutation. Add redirected-stdin, redirected-stdout, and no-controlling-TTY proof.

### Busy surfaces hide the input and cancellation contract

- **[medium]** Measurement and synchronization correctly own and drain input, and controlled synchronization cancellation is explicitly deferred. The visible contracts, however, promise only progress/busy copy; they do not require the surface to say that ordinary keys—including `q`—are ignored or that the operator must wait. The normal footer advertises `q`, so preserving or blanking it without replacement creates a false affordance. (`_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:56`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:69`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:64`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:91`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:199`). *Fix:* Give both busy surfaces a bounded mode legend such as `Working — input ignored`; remove inactive command hints while busy. Keep signal/abnormal-exit restoration and retry behavior explicit without introducing the deferred cancellation feature.

### Progress repaint has no reduced-motion or flicker bound

- **[medium]** The fixed canvas prevents scrolling corruption, but live rsync and measurement progress have no maximum repaint rate or prohibition on blinking, spinners, marquee text, or full-body flashing. A progress producer can therefore make the reserved region visually unstable even while every record is sanitized and width-bounded. (`_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:38`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:69`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:91`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:100`). *Fix:* Require progress to update only its reserved row, coalesce rapid records to a modest fixed rate, and forbid blink, spinner, marquee, and alternating-color animation. The existing stable `Synchronizing player…` fallback is the reduced-motion behavior; no accessibility-mode setting is needed.

### Inherited ANSI roles have no contrast boundary

- **[low]** The design sensibly avoids literal colors and never relies on color alone, but “reuse existing roles” does not state the limits of those roles on user-controlled light, dark, or custom terminal palettes. Numeric contrast cannot be guaranteed for ANSI colors, yet the contract can still prevent avoidable degradation. (`_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:38`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/DESIGN.md:42`, `docs/decisions/0009-ADR-terminal-accessibility-boundary.md:20`). *Fix:* State that Player Content sets no background color and uses no dim, blink, or color-only emphasis for load-bearing text; terminal-palette contrast remains operator-controlled, with `NO_COLOR` as the supported escape-free presentation—not a conformance claim.

## Validated coverage

- **TTY/enhanced UI:** fixed rows, bounded repaint, display-cell measurement, Unicode/ASCII fallbacks, and minimum-size recovery are explicit.
- **Plain baseline:** `NO_COLOR` plus fixed-column ASCII symbols preserves Current, expansion, membership, availability, warning, and result meaning. It is correctly not named an “accessible mode.”
- **Screen readers:** ADR-0009 is honored. The spines explicitly disclose that incremental repaint may remain unsuitable and make no support or conformance claim (`_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:129`, `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/EXPERIENCE.md:136`, `docs/decisions/0009-ADR-terminal-accessibility-boundary.md:26`).
- **Keyboard, focus, and resize:** every primary function is reachable; Current and Checked are distinct; focus anchors survive empty projections; Help and body offsets clamp on resize; too-small operation fails closed.
- **Color and non-color meaning:** every load-bearing state has a word, count, checkbox, marker, or disclosure symbol under `NO_COLOR`; no meaning depends on hue.
- **Status, errors, and safety:** persistent context and authoritative results have separate rows; errors outrank success; failures name their stage; zero-checked root deletion names the destination; reduced projections never narrow sync membership.
- **Preview/data safety:** live selection size, checked count, measurement scope, unavailable/unknown states, and the full validated destination in Help prevent inferred destructive scope. The high finding above is limited to full Current item identity after clipping.
- **Fallback boundaries:** unavailable sources, missing progress capability, undersize recovery, queued input, failed raw-mode re-entry, EOF, errors, and signals all have fail-closed or restoration behavior. Verification is fixture-only.

## Mechanical notes

- Both finalized spines cite ADR-0009 and use its terminology consistently.
- The earlier request for a dedicated screen-reader mode is intentionally superseded by ADR-0009 and is not repeated as a finding.
- No mockups, wireframes, imports, or preview artifacts are present; validation therefore rests on the two authoritative spines and their cited sources.
