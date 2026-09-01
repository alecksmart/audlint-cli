---
title: 'Player Track-Only Exact Mirror'
type: 'feature'
created: '2026-09-01'
status: 'done'
baseline_commit: 'a5f4c3367d8041509310559d58132e4790e81ec2'
review_loop_iteration: 0
context:
  - '{project-root}/docs/decisions/0004-ADR-real-resource-verification-safety.md'
  - '{project-root}/docs/decisions/0007-ADR-player-track-only-destinations.md'
  - '{project-root}/docs/decisions/0008-ADR-player-file-backed-rsync-snapshots.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Player Content and browser transfers use separate negative payload filters. They can copy cover art and unknown files, size a different set than they transfer, grow rsync arguments with selection size, and report success without proving source stability or exact destination convergence.

**Approach:** Implement the approved canonical track-only policy with one completed source snapshot, file-backed ordered rsync rules, explicit owned-scope cleanup, cache-policy migration, and post-transfer checks. Keep the existing inventory, path-keyed checked state, safety guards, selector behavior, and retryable non-atomic model.

## Boundaries & Constraints

**Always:** Treat `_bmad-output/specs/spec-player-track-only-mirror/SPEC.md` and every declared companion as settled requirements. `lib/sh/audio.sh` is the only extension authority; eligible payloads are non-symlink regular files below validated roots, with no hidden component or ASCII control byte and an ASCII-case-insensitive canonical extension. Build one exact source snapshot and derive both logical byte totals and ordered literal rsync rules from it. Use secure, checked, cleaned temporary files outside protected trees; keep variable rules out of argv. Complete all Player Content and browser preflight before destructive work, retain checked paths on every failure, and use only temporary fixtures for verification.

**Ask First:** Stop and report a precise contradiction between the approved contract, accepted ADRs, and implementation evidence; stop before any real-library, live-database, or mounted-player access; do not commit, push, merge, or release.

**Never:** Do not change source-library contents; follow or transfer source symlinks or special files; add probing, capacity enforcement, atomic swaps, browser ownership outside requested album scopes, metadata-derived browser destination fallback, or automatic player cleanup. Do not weaken destination safety, zero-selection emptying, checked-state persistence, display-only free-space reporting, or Bash 5/macOS/Linux portability.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Global mirror | Checked temporary albums with tracks, hidden files, artwork, special files, legacy and deselected destination content | Player root has only selected snapshot tracks and required directories; zero selection empties it | Any preflight failure invokes no rsync and preserves checks |
| Browser transfer | Several library-relative temporary albums plus excluded destination content and untouched player albums | Each requested album subtree exactly matches its track snapshot; all other player areas remain unchanged | Collision or unsafe/outside-library source prevents every transfer |
| Change or tool failure | Selection changes, source type/size changes, artifact creation/rule/rsync/flush/postcheck fails | No success report; temporary artifacts are removed; a retry uses a fresh snapshot and converges | Checked state and old cache version/rows survive failed migration |

</frozen-after-approval>

## Code Map

- `lib/sh/audio.sh` -- replace duplicated 19-extension globs in `audio_collect_files` and `audio_find_iname_args` with the registry and basename predicate.
- `lib/sh/player.sh` -- retain path and free-space helpers; replace negative payload sizing/filter helpers with secure snapshot, byte, ordered-rule, literal escaping, and source/destination comparison helpers.
- `lib/sh/bootstrap.sh` -- reuse path resolution and portable logical-byte stat support; do not reimplement it in entry scripts.
- `lib/sh/sqlite.sh` -- extend path-keyed Player Content selection persistence and existing `app_meta` with atomic cached-size/payload-policy refresh.
- `bin/audlint-maintain.sh` -- preserve inventory/selector flow and broad-root guard; replace per-album rsync argv and pre-copy cache update with global snapshot-driven convergence.
- `bin/audlint.sh` -- preserve browser selection UI and one post-transfer flush; require library-relative sources and all-request preflight, then use album-scoped snapshots and verification.
- `test/test_player_content_creator.py`, `test/test_library_browser_smoke.py`, `test/test_audlint_maintain_smoke.py` -- retain inventory/UI coverage while replacing former negative-filter expectations.
- `docs/architecture/OVERVIEW.md`, `README.md`, and focused player-transfer documentation -- update only after behavior exists.

## Tasks & Acceptance

**Execution:**
- [x] `lib/sh/audio.sh` and `lib/sh/player.sh` -- establish the registry, strict eligibility, completed snapshot builders, secure staging, ordered merge-rule compiler, bounded rsync options, and manifest comparators.
- [x] `lib/sh/sqlite.sh` -- add a versioned, all-or-nothing refresh of checked cached sizes from completed snapshot data.
- [x] `bin/audlint-maintain.sh` -- make Player Content revalidate inventory and selected order, preflight, snapshot, migrate, transfer once from the library root, flush, and verify source plus full owned destination root.
- [x] `bin/audlint.sh` -- preflight every browser request and destination before the first transfer; converge only requested album subtrees through exact album rule files, flush once, then verify every requested source and scope.
- [x] `test/test_player_payload_policy.py` and existing focused test modules -- add temporary-fixture coverage for parity, unusual literals, migration, cleanup, preflight, bounded argv, stage failures, retry, and portable real-rsync behavior where available.
- [x] `docs/architecture/OVERVIEW.md`, `README.md`, and applicable public player-transfer docs -- document the implemented track-only ownership and retry behavior.

**Acceptance Criteria:**
- Given every canonical extension in mixed case and mixed non-track fixture files, when a snapshot is built, then the snapshot, cached sizes, rules, and transferred paths identify the same eligible regular files.
- Given selected and deselected Player Content albums plus legacy root content, when global synchronization succeeds, then the validated root equals the selected snapshot only; given no selected albums, it is empty.
- Given multiple valid browser albums, when transfer succeeds, then each requested subtree equals its eligible snapshot and unrequested areas are unchanged; invalid, colliding, or outside-library requests run no rsync.
- Given any pre-rsync artifact, selection, migration, or preflight failure, when the operation exits, then it reports the stage and retains checks; given an rsync, flush, source, or destination postcheck failure, then it reports no success and a later unchanged retry converges.
- Given a destination unable to represent the expected path/type/size state, when rsync returns zero, then destination verification still fails closed.

## Spec Change Log

## Design Notes

The completed snapshot is the transfer contract: it is made once before copying, gives all byte totals, and compiles to a deterministic ordered rsync merge file. The global Player Content operation owns the validated player root, while a browser operation owns only each derived requested album subtree.

## Verification

**Commands:**
- `python3 -m unittest test.test_player_payload_policy` -- expected: registry, snapshot, rule, literal, bounded-argv, and available real-rsync cases pass using temporary fixtures.
- `python3 -m unittest test.test_player_content_creator` -- expected: global convergence, migration, failures, retries, and state preservation pass.
- `python3 -m unittest test.test_library_browser_smoke` -- expected: scoped browser convergence and complete preflight pass.
- `python3 -m unittest test.test_player_payload_policy test.test_player_content_creator test.test_library_browser_smoke test.test_audlint_maintain_smoke` -- expected: focused cross-flow regression suite passes.
- `make check` -- expected: the project release gate passes once after focused verification.

## Suggested Review Order

**Transfer contract**

- Global exact convergence from one source snapshot and file-backed ordered rules.
  [`audlint-maintain.sh:316`](../../bin/audlint-maintain.sh#L316)

- Browser preflights all owned subtrees before any destructive album transfer.
  [`audlint.sh:3810`](../../bin/audlint.sh#L3810)

**Shared safety mechanics**

- One canonical extension registry prevents divergent transfer membership.
  [`audio.sh:7`](../../lib/sh/audio.sh#L7)

- Secure staging, checked walks, literal rules, and postcondition manifests.
  [`player.sh:147`](../../lib/sh/player.sh#L147)

- Atomic snapshot-size cache refresh also advances the payload-policy marker.
  [`sqlite.sh:549`](../../lib/sh/sqlite.sh#L549)

**Proof and public contract**

- Temporary-fixture policy tests cover track-only snapshots and destination equality.
  [`test_player_payload_policy.py:10`](../../test/test_player_payload_policy.py#L10)

- Player Content and browser smoke tests prove scoped real-rsync convergence.
  [`test_player_content_creator.py:277`](../../test/test_player_content_creator.py#L277)

- The Makefile release suite now includes the focused policy module.
  [`Makefile:21`](../../Makefile#L21)
