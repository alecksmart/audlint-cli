# Brownfield Evidence and Focused Proof

## Current cause

`player_content_read_selector_key` recognizes jump input only when the character matches `[A-Za-z]`. `player_content_selector_jump` then lowercases and compares the first display character. The parser therefore rejects Cyrillic input before the jump logic can use it.

## Change boundary

- Extend Escape-letter recognition and comparison for complete Cyrillic letters used by Ukrainian names.
- Keep one jump token per terminal character and preserve current delayed Escape handling.
- Keep the existing ASCII cycling test as a regression guard.
- Keep the UI footer wording unless a minimal clarification is needed; `Esc+letter jump` already describes both alphabets.

## Sanity-test stages

1. Red: add one named PTY test with at least two Cyrillic groups sharing an initial and one different Cyrillic initial; prove first jump, cycle, wrap, and unmatched no-op.
2. Green: run only the new named test while fixing input recognition.
3. Regression: run the existing ASCII Escape-letter test and arrow/navigation tests, then `python3 -m unittest test.test_player_content_creator`.
4. Stop after the focused module passes. Do not run `make check` yet.
