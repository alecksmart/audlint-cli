---
id: SPEC-lyrics-cached-backoff-exit-contract
companions: []
sources:
  - ../../planning-artifacts/adoption-baseline.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability only.

# Lyrics Cached-Backoff Exit Contract

## Why

`lyrics_album.sh` currently reports failure when an album produces no lyrics, even when every eligible track was intentionally deferred by an unexpired cached-not-found retry window. That false failure breaks the established no-op contract for operators and batch callers while adding no actionable failure signal.

## Capabilities

- **CAP-1**
  - **intent:** Operators and callers can distinguish an intentional cached-backoff deferral from a lyrics-processing failure through the command exit status.
  - **success:** When every eligible track is deferred by an unexpired cached-not-found retry window, `lyrics_album.sh` prints the cached revisit message, performs no network fetch, and exits zero; an actual embed failure still exits nonzero and remains visible to `lyrics_seek.sh`.

## Constraints

- Only the all-eligible-tracks-deferred cached-backoff outcome becomes successful; actual processing failures must remain nonzero.
- A deferred track must not trigger a remote lyrics request or alter the existing cache retry-window behavior.
- Preserve Bash 5 and macOS/Linux portability and reuse existing shared audio, lyrics-cache, SQLite, and terminal policy.
- Verification must use temporary fixtures, run the targeted lyrics tests before the complete local suite, and never touch a real music library or live database.

## Non-goals

- Changing the retry duration, cache schema, cache lookup matching, or cached revisit message.
- Redefining exit behavior for fresh not-found responses, missing tags, unsupported codecs, or directories with no audio files.
- Reworking lyrics fetching, embedding, batch traversal, or unrelated database maintenance behavior.

## Success signal

The cached-not-found backoff regression test passes with status zero and no network call, while the embed-failure and batch failure-propagation tests continue to pass with nonzero status.
