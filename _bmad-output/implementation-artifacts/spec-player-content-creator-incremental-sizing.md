---
title: 'Player Content Creator Incremental Sizing'
type: 'bugfix'
created: '2026-08-30'
status: 'done'
route: 'one-shot'
---

# Player Content Creator Incremental Sizing

## Intent

**Problem:** Opening Player Content Creator scanned every album payload before rendering, so large libraries appeared unresponsive.

**Approach:** Render the selector immediately with visible sizing progress, calculate one album between input polls, and preserve accurate totals when selection changes before sizing finishes.

## Suggested Review Order

**Responsive selector loop**

- Displays a clear sizing state before any full-library payload scan completes.
  [`audlint-maintain.sh:124`](../../bin/audlint-maintain.sh#L124)

- Polls for input and sizes one cached album between redraws.
  [`audlint-maintain.sh:138`](../../bin/audlint-maintain.sh#L138)

- Avoids treating the unsized sentinel as real selected bytes.
  [`audlint-maintain.sh:317`](../../bin/audlint-maintain.sh#L317)

**Regression proof**

- Exercises sizing-state display and unsized persisted-album recovery.
  [`test_player_content_creator.py:64`](../../test/test_player_content_creator.py#L64)
