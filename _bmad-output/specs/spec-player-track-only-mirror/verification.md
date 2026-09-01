# Acceptance and Repository Verification

## Focused acceptance

1. **Canonical policy parity:** derive tests from the canonical extension registry. For every extension, prove lowercase and mixed-case regular files are sized and included. Combine near-miss extensions, images, CUE, LOG, PDF, TXT, M3U, ZIP, caches, and databases in the same fixture and prove they are excluded.
2. **Path and type boundary:** combine direct and nested tracks, hidden directories, dot-files, zero-byte tracks, hard links, a directory with an audio-looking name, source symlinks, and a FIFO. Prove only eligible regular paths enter the snapshot and the source tree is unchanged.
3. **Literal names:** cover spaces, Unicode, invalid non-control UTF-8 bytes, leading dash, `#`, quotes, rsync glob metacharacters, and backslashes with real temporary rsync. Prove control-character candidates fail before rsync and destination case collisions fail closed.
4. **Global migration cleanup:** seed a temporary player with previously copied covers, hidden caches, documents, unrelated root files, a destination symlink, a selected legacy album, and a deselected album. One real Player Content sync leaves exactly the selected source-relative track snapshot and required directories; compare the source fixture before and after.
5. **Browser scope:** request multiple validated albums, seed their destinations with excluded files, and keep an unrequested album plus unrelated content elsewhere. Prove all requests preflight before transfer, requested albums converge, unrequested album trees remain unchanged, an outside-library source fails, and exact or case-fold destination collision invokes no rsync.
6. **Size and rule identity:** inspect the completed snapshot, per-album cached sizes, generated exact rules, rsync result, and destination manifest. Prove they describe the same file paths and logical sizes.
7. **Policy migration:** start with checked rows containing old-policy sizes and no `player_payload_policy_version`. Prove one complete refresh updates all sizes and the version atomically; one injected measurement or database failure changes neither.
8. **Zero and empty boundaries:** prove zero selection empties only a validated temporary player and a checked zero-track album contributes size zero and no global destination subtree.
9. **Race and retry:** replace the selected database set with another set of the same count, then separately mutate a source snapshot during transfer. Both attempts fail without losing checked paths; a later unchanged attempt succeeds and converges.
10. **Failure stages:** inject safe temporary-location, `mktemp`, walk, `stat`, sort, manifest write, rule write, rsync, flush, source-postcheck, and destination-postcheck failures. Pre-rsync failures invoke no rsync; every failure avoids success wording and preserves checked paths.
11. **Bounded generation:** use a temporary 1,600-album selection with many tracks. Assert command argv contains one merge-file reference and no per-album or per-track rules, and rule generation does not retain a growing Bash rule array.
12. **Portable rsync semantics:** run the focused real-rsync fixture with GNU rsync and macOS-compatible openrsync when available. Prove merge ordering, literal escaping, excluded deletion, special-file refusal, zero-selection deletion, and empty-directory pruning.

All real-rsync tests use temporary source and destination fixtures. No test may resolve or enumerate the configured operator library, live SQLite database, or mounted player.

## Test placement

- Add a focused helper module such as `test/test_player_payload_policy.py` for registry, snapshot, rule compiler, and literal escaping behavior.
- Update `test/test_player_content_creator.py` for exact global mirror, cached-size migration, zero selection, failures, postconditions, and retry.
- Update `test/test_library_browser_smoke.py` for track-only scoped convergence, source-relative enforcement, complete preflight, collision, and source preservation.
- Retain relevant `test/test_audlint_maintain_smoke.py` and browser integration coverage rather than duplicating terminal behavior.

## Verification order

During implementation, run the nearest named test while changing each helper or flow. Then run:

```bash
python3 -m unittest test.test_player_payload_policy
python3 -m unittest test.test_player_content_creator
python3 -m unittest test.test_library_browser_smoke
python3 -m unittest \
  test.test_player_payload_policy \
  test.test_player_content_creator \
  test.test_library_browser_smoke \
  test.test_audlint_maintain_smoke
```

Run applicable Debian, Ubuntu, and Fedora distro checks after the focused integration set when their environment is available. Run the repository release gate once after the complete implementation:

```bash
make check
```

Do not repeatedly run the full gate between focused fixes. No CI workflow replaces this local release gate.
