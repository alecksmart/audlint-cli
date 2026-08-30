---
title: 'Move Corpus Reference Out of Root README'
type: 'chore'
created: '2026-08-30'
status: 'done'
route: 'one-shot'
---

# Move Corpus Reference Out of Root README

## Intent

**Problem:** The user-facing root README exposed internal corpus and R3 maintainer workflows.

**Approach:** Move every root README corpus section into a maintainer-facing corpus reference and link it from the documentation index.

## Suggested Review Order

**Audience boundary**

- Keeps internal corpus operations out of the end-user README.
  [`README.md:187`](../../README.md#L187)

- States the maintainer audience and preserves the corpus lifecycle reference.
  [`corpus.md:1`](../../docs/corpus.md#L1)

**Documentation navigation**

- Makes the corpus reference discoverable from the documentation index.
  [`README.md:3`](../../docs/README.md#L3)
