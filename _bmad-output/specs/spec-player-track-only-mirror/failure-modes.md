# Failure Modes and Edge Cases

## Failure contract

Any failed preflight invokes no player rsync. Once rsync begins, a failure may leave partial destination changes but never changes which paths are checked. A retry discards all prior temporary artifacts, takes a new snapshot, and converges from current checked state.

| Condition | Required outcome |
| --- | --- |
| No checked albums | Complete normal preflight; a successful global sync empties the player root. |
| Checked album has no eligible tracks | Store size zero; global sync contributes no album path, while browser transfer empties the requested album scope and may leave its empty root directory. |
| Zero-byte canonical track | Include and transfer it; add zero to the byte total. |
| Dot-file or any hidden directory component | Exclude it even when its extension is canonical; remove a destination copy on successful convergence. |
| Nested normal directory | Include eligible regular tracks and required ancestors. |
| Directory named with an audio extension | Treat it as a directory, never as a track. |
| Source file or directory symlink | Do not follow or copy it. A checked album root that becomes a symlink fails preflight. |
| FIFO, socket, device, or other special object | Do not size or transfer it; remove a destination copy in an owned scope. |
| Hard-linked regular tracks | Treat each eligible relative path independently and count each logical size. |
| Mounted descendant below an album | Traverse it as a real directory without modifying it. |
| Mixed-case canonical extension | Include it. Preserve all other name case literally. |
| `CUE`, `LOG`, `PDF`, `TXT`, `M3U`, `ZIP`, cache, database, image, or other noncanonical extension | Exclude it regardless of case; remove a destination copy in an owned scope. |
| ASCII control character in selected or eligible relative path | Fail before rule generation; do not silently omit the candidate. |
| Spaces, valid or invalid non-control UTF-8 bytes, leading dash, `#`, quotes, `*`, `?`, `[`, `]`, or backslash | Preserve literally through centralized byte-oriented filter escaping. |
| Exact duplicate, overlapping selected root, or ASCII-case destination collision | Fail before rsync. |
| Destination filesystem collapses additional case or Unicode forms | Rsync or destination postcondition fails; never report success. |
| Selected database rows change with the same count | Full ordered snapshot comparison fails before rsync. |
| Source appears, disappears, changes type, or changes logical size during transfer | Post-transfer source comparison fails; destination may reflect the earlier snapshot. |
| Size addition would overflow or `stat` is invalid | Fail sizing and do not update cached sizes. |
| Inventory, selection query, walk, sort, manifest write, rule write, or temporary creation fails | Invoke no rsync and report the failed stage. |
| Configured temporary directory is inside a protected tree | Use a validated safe system temporary directory or fail before creating artifacts. |
| Player destination is absent, broad, overlapping, inside a protected tree, unreadable, or unwritable | Invoke no rsync or deletion. |
| Browser source is outside the library or requested destinations collide | Fail the whole browser preflight before the first album transfer. |
| Rsync exits nonzero, including vanished-source or I/O errors | Report failure, skip flush and post-success wording, preserve checked paths, and allow retry. |
| Flush exits nonzero | Report failure; destination may already have converged; preserve checked paths and allow retry. |
| Source postcheck fails after flush | Report failure and allow retry; do not claim the transferred snapshot is current. |
| Destination contains a missing, extra, wrong-type, or wrong-size object | Report postcondition failure even when rsync and flush exited zero. |
| Signal interrupts generation or transfer | Cleanup owned temporary artifacts when the shell receives a trappable signal; never print success. |
| Policy-version refresh fails or database is locked | Preserve old sizes, checked rows, and old policy version; perform no transfer. |

Postcondition comparison proves path, object type, and logical size. It relies on successful rsync for file content and does not add independent checksumming.
