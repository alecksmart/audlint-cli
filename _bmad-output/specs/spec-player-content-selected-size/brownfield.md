# Brownfield Evidence and Focused Proof

## Current cause

Every available album starts with an unknown size and increments `sizing_pending`, even when unchecked. The title renders `Total: sizing… (<all albums processed>/<all albums>)`, while `total` itself accumulates only checked payloads. This mixes two meanings and delays a stable selected total behind a full-library walk.

## Change boundary

- Initialize pending size work from checked, available rows only.
- Render `Size` or equally explicit selected-size wording; any progress denominator is the checked set.
- When an unchecked available row is toggled on, size that row first and update checkbox, count, and size atomically after success.
- Preserve the exact unavailable checked-row rule: unknown bytes are not counted and synchronization remains blocked until the source is readable or deselected.

## Sanity-test stages

1. Red: add named tests for a small checked subset inside a large inventory, zero selection, and exact select/deselect payload deltas.
2. Green: run only those tests while changing sizing state.
3. Regression: run title/redraw, unavailable-row, persistence, and payload-parity cases, then `python3 -m unittest test.test_player_content_creator`.
4. Stop after the focused module passes. Do not run `make check` yet.
