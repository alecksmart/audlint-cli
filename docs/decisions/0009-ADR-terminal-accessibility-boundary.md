# ADR-0009: Preserve Baseline Terminal Accessibility Without a Specialized Screen-Reader Mode

## Status
Accepted

## Record type
Contemporary

## Context
Audlint is a keyboard-driven Bash and Python CLI/TUI. Its interactive terminal surfaces already avoid mouse-only operation, support `NO_COLOR`, express important state in text or symbols, bound terminal output, and restore terminal state after full-screen interaction.

Formal review of the proposed Player Content redesign recommended a separate accessible terminal mode for screen-reader users. Such a mode would require a different rendering and announcement model, focus semantics, terminal-emulator compatibility work, and dedicated assistive-technology verification. It is a distinct product capability rather than an incidental refinement of the existing full-screen selector.

The project needs a clear boundary so ordinary terminal usability and safety are not confused with a claim of specialized assistive-technology support.

## Decision
Preserve baseline accessibility across Audlint terminal interfaces:

- Every primary action remains keyboard-operable.
- Meaning does not depend on color alone, and `NO_COLOR` remains supported.
- Focus, checked state, availability, warnings, results, and destructive scope have textual or symbolic representations.
- Help remains reachable and complete at every supported terminal size.
- User-controlled text is sanitized and bounded by terminal display width; new Unicode input must not corrupt the canvas or become executable shell text.
- Raw mode, echo, the scroll region, and caret visibility are restored on every normal, error, signal, EOF, and unsupported-size exit path.

Do not add or claim a specialized screen-reader mode as part of ordinary terminal UI work. This excludes a parallel line-oriented interface, screen-reader announcement protocol, terminal-assistive-technology detection, accessibility-mode setting, and screen-reader conformance claim.

`NO_COLOR`, keyboard operation, and visible text markers must not be described as screen-reader support. They are baseline terminal behavior only.

Any future screen-reader-specific capability requires separate product intent, interaction design, implementation, and verification, plus an explicit decision that supersedes this boundary.

## Evidence
- `bin/audlint-maintain.sh:45-75` implements the shared `NO_COLOR` behavior and terminal color roles.
- `bin/audlint-maintain.sh:188-209` sanitizes and bounds Player Content rows.
- `bin/audlint-maintain.sh:282-309,640-690` owns raw-mode entry, caret visibility, cleanup, signals, and minimum terminal size.
- `test/test_player_content_creator.py:255-277,933-985` verifies fixed colored rows, `NO_COLOR`-compatible structure, bounded repainting, one visible focus marker, resize handling, and clipped labels.
- `_bmad-output/planning-artifacts/ux-designs/ux-audlint-cli-2026-09-02/review-accessibility.md` separates the proposed screen-reader mode from the review's ordinary terminal usability and safety findings.
- On 2026-09-02, Alec approved preserving baseline terminal accessibility without building or claiming a specialized screen-reader mode.

## Rationale
A dedicated screen-reader experience cannot be made reliable by adding labels to an absolute-position, incrementally repainted terminal canvas. Treating it as a separate capability prevents unsupported claims and avoids forcing unrelated Player Content work to invent an unverified assistive interaction model.

The retained baseline is still load-bearing. Keyboard access, non-color meaning, complete Help, safe display width, explicit destructive copy, and terminal restoration protect every operator and prevent data-loss or shell-session failures. This ADR narrows specialized accessibility scope; it does not waive general usability, portability, or safety.

## Consequences
- The Player Content validation finding requesting a dedicated screen-reader mode is out of scope for the redesign.
- The remaining accessibility-review findings continue to apply where they concern terminal correctness, usability, discoverability, Unicode safety, constrained layouts, input ownership, warning clarity, or terminal cleanup.
- Automated tests are not required to drive a screen reader or certify assistive-technology compatibility.
- Public documentation must not claim screen-reader support or accessibility conformance for the full-screen TUI.
- Full-screen interactive surfaces may remain unsuitable for some screen-reader users until a separately approved capability supplies another interaction model.
- New terminal UI work must not regress the baseline behaviors listed in this decision.

## Alternatives
- Build a dedicated accessible terminal mode as part of the Player Content redesign. Rejected because it is an independent interaction surface without approved product requirements or a verified compatibility target.
- Treat all accessibility concerns as non-binding. Rejected because keyboard access, non-color meaning, bounded output, clear destructive scope, and terminal restoration are ordinary correctness and safety requirements.
- Claim that keyboard control and `NO_COLOR` make the current full-screen interface screen-reader accessible. Rejected because absolute cursor movement and incremental repainting are not reliably announced by terminal screen readers.

## Related decisions
- [ADR-0003: Require Bash 5 with macOS and Linux Portability](0003-ADR-bash5-portability.md)
- [ADR-0006: Prefer the Shell Orchestration and Python Computation Boundary](0006-ADR-shell-python-responsibility-boundary.md)
