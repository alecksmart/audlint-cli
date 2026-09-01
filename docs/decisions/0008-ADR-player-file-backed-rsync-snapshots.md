# ADR-0008: Compile Player Snapshots into File-Backed Rsync Rules

## Status
Accepted

## Record type
Contemporary

## Context
Player payload sizing and transfer must select the same files. Player Content currently sizes directories through the shared negative payload predicate, then builds several ordered rsync arguments for every checked album. The argument list grows with selection count, while the negative rules can admit files that sizing or future exclusions did not intend.

The player root must also converge in one deletion-capable operation. An exact file list passed through `--files-from` represents transfer membership well but does not independently make omitted root content and deselected album trees part of rsync's deletion scope.

The mechanism must preserve Bash 5 and macOS/Linux portability, avoid source-side rule files, and fail closed before destructive work when any snapshot or rule artifact is incomplete.

## Decision
Before any player rsync, build a complete snapshot of eligible regular track paths beneath the owned source scope. Use that same snapshot for per-album logical byte totals and transfer membership.

Compile the snapshot into one ordered rsync merge-filter file. Emit required parent-directory includes, exact regular-file includes, and one terminal catch-all exclusion. Escape literal rsync filter metacharacters centrally. Reject control-character paths that the portable line-oriented rule format cannot represent safely.

Stream selection manifests, track snapshots, size rows, and rules through secure temporary files. Do not retain per-album or per-track rules in Bash arrays. The rsync command line contains fixed options plus one merge-file reference, so argv size is independent of selected album and track count.

Create temporary artifacts with restrictive permissions and checked writes outside the library, player, repository, and database directory. Expose only complete artifacts to rsync and clean owned temporary paths on normal and trappable failure exits.

Player Content uses one library-root rsync with deletion enabled. Browser transfer uses the same compiled policy in album-scoped rsync calls after every requested source and destination passes preflight. Use excluded-content deletion so the terminal exclusion removes rather than protects unwanted destination objects. Do not enable source symlink, device, or special-file transfer, and do not use `--ignore-errors`.

Report success only after rsync and the existing flush command succeed, the source path/type/logical-size snapshot remains unchanged, and the owned destination scope contains exactly the expected paths, object types, and logical sizes. This postcondition relies on rsync for content copying and does not add independent checksumming.

Any temporary creation, traversal, sizing, sorting, rule generation, selection comparison, rsync, flush, source-stability, or destination-postcondition failure reports failure. Pre-rsync failures invoke no player rsync. Post-rsync failure preserves checked paths and may leave partial destination changes; retry rebuilds every artifact and converges.

## Evidence
- `bin/audlint-maintain.sh:370-422` constructs parent and selected album rules as growing Bash arrays.
- `lib/sh/player.sh:111-173` separately walks files for sizing and appends the current payload filters to caller argv.
- `bin/audlint.sh:3812-3930` sizes a browser manifest and invokes album-scoped rsync with the shared argv filter.
- `test/test_player_content_creator.py:413-484,576-620` proves the existing root mirror, zero-selection deletion, failure preservation, and retry boundaries with temporary fixtures.
- `test/test_library_browser_smoke.py:1389-1536` proves the former browser filter and its preservation of excluded destination content.
- `_bmad-output/specs/spec-player-track-only-mirror/architecture.md`, `failure-modes.md`, and `verification.md` define the approved exact snapshot, ordered rules, edge behavior, and proof plan.
- On 2026-09-01, Alec approved file-backed ordered rules as a separate, replaceable mechanism decision.

## Rationale
One exact snapshot prevents sizing and transfer code from independently discovering payload membership. A single ordered merge file preserves rsync's first-match rule semantics while moving variable rule volume out of process argv.

Keeping the global Player Content operation rooted at the library preserves source-relative layout and gives rsync authority to delete deselected and unrelated destination paths. `--delete-excluded` ensures excluded objects are deletion candidates rather than protected receiver content.

Postcondition verification prevents a zero rsync status from becoming a false success when the destination filesystem cannot represent the intended names or retains an extra object.

## Consequences
- Rule-file size grows with eligible path count, but rsync argv and Bash rule arrays do not.
- Snapshot generation performs a complete non-following walk of checked album content before transfer.
- Source changes during the operation can turn an otherwise successful transfer into a reported failure.
- Destination filesystems that collapse names by case or normalization can fail postcondition verification.
- Control-character track paths fail closed rather than being silently dropped or ambiguously encoded.
- Successful Player Content synchronization removes excluded and deselected destination content in the same root-wide rsync operation.
- A future mechanism may replace compiled merge filters only by explicitly superseding this ADR while preserving ADR-0007.

## Alternatives
- Put all ordered include and exclude rules directly in argv. Rejected because argv grows with album and track count.
- Use separate `--include-from` and `--exclude-from` files. Rejected because traversal, exact includes, and the terminal exclusion need one explicit rule order; one include file containing `+` and `-` rows is only a less clear merge file.
- Use `--files-from` alone. Rejected because omitted root content and deselected album trees are not reliably covered by its deletion scope.
- Generate album-plus-extension patterns instead of exact file rules. Rejected because transfer membership can differ from the completed size snapshot.
- Run one Player Content rsync per checked album. Rejected because it cannot remove deselected albums and unrelated player-root content in one owned mirror.
- Delete unwanted destination paths with custom shell code. Rejected because it creates a second destructive path implementation beside rsync.
- Write `.rsync-filter` files into album directories. Rejected because source-library content must remain untouched.
- Build a temporary symlink tree and dereference it. Rejected because source replacement can race dereferencing, temporary inode usage grows per track, and interrupted cleanup is larger.

## Related decisions
- [ADR-0003: Require Bash 5 with macOS and Linux Portability](0003-ADR-bash5-portability.md)
- [ADR-0004: Keep Automated Verification Away from Real Operator Resources](0004-ADR-real-resource-verification-safety.md)
- [ADR-0006: Prefer the Shell Orchestration and Python Computation Boundary](0006-ADR-shell-python-responsibility-boundary.md)
- [ADR-0007: Keep Player Destinations Track-Only](0007-ADR-player-track-only-destinations.md)
