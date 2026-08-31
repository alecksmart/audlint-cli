# Brownfield Evidence and Focused Proof

## Current cause

`player_content_sync` prints destination, count, size, deletion text, and a `[y synchronize, any other key cancel]` prompt directly into the selector region. Its caller then prints `[any key Continue]`, re-enters raw mode, and redraws. Output remains mixed with album rows until that extra key is pressed. `q` itself already exits directly and must stay that way.

## Change boundary

- Keep preflight and manifest construction before any deleting command.
- After valid preflight, begin the existing mirror immediately; no confirmation branch remains.
- Clear or repaint the owned content region so running output cannot share physical rows with stale album content.
- On completion or failure, re-enter selector input and redraw automatically. Show one concise outcome in a stable selector-owned location and clear or replace it on the next relevant action.
- Adapt current confirmation/cancellation tests into direct-start and clean-redraw tests. Do not remove destructive safety, real-rsync mirror, empty-selection, rsync failure, or flush failure coverage.

## Sanity-test stages

1. Red: change/add named PTY tests proving one `w` begins a valid sync, one `q` exits, no confirmation or continue prompt appears, and album rows do not mix with progress/results.
2. Green: run only those named interaction tests.
3. Destructive regression: run the unsafe-path, manifest, empty-selection, real temporary mirror, rsync failure, flush failure, and retry tests.
4. Focused integration: run `python3 -m unittest test.test_player_content_creator`, then `python3 -m unittest test.test_library_browser_smoke test.test_audlint_maintain_smoke`.
5. Confirm the `_VA`, Cyrillic, and selected-size child tests are present and passing. Only then run `make check` once as the campaign's complete release gate.
