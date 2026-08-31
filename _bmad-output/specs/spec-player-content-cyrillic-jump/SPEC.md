---
id: SPEC-player-content-cyrillic-jump
companions:
  - brownfield.md
  - ../spec-player-content-creator/player-content-contract.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete contract for this fix.

# Player Content Creator Cyrillic Jump Navigation

## Why

The selector displays Cyrillic artist folders, including Ukrainian content, but its Escape-letter parser accepts ASCII letters only. Operators need the existing fast group-jump interaction to work for the visible Cyrillic alphabet too.

## Capabilities

- **CAP-1**
  - **intent:** The operator can press Escape followed by a Cyrillic letter to jump among matching Cyrillic artist groups.
  - **success:** Under a UTF-8 locale, PTY fixtures prove Cyrillic jumps select the first matching group, repeated jumps cycle and wrap across matching groups, and ASCII jumps, arrows, bare Escape, delayed input, and unmatched-key behavior remain unchanged.

## Constraints

- Accept one complete supported letter after Escape without splitting or corrupting its UTF-8 bytes.
- Compare against the first normalized display character and preserve current cycle/wrap semantics.
- Preserve CSI/SS3 arrows, human-paced Escape-letter timing, no-op unmatched input, cursor visibility, bounded redraw, and footer layout.
- Preserve Bash 5 and macOS/Linux behavior; use existing terminal helpers or the appropriate shared helper boundary rather than adding competing input policy.
- Follow the focused verification stages in `brownfield.md`; do not run the full release gate in this task.

## Non-goals

- Transliteration between Cyrillic and Latin letters.
- Full-text search, locale switching, keyboard-layout mapping, or jumps for symbols and digits.
- Changing artist grouping or sort order.

## Success signal

The same `Esc+letter` gesture visibly cycles through Ukrainian/Cyrillic artist headings and the existing ASCII navigation regression cases remain green.

## Assumptions

- The supported terminal environment provides a UTF-8 locale, consistent with already displaying the Cyrillic folder names.
