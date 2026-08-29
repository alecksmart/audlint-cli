---
title: Audlint Consolidated Product Roadmap
type: roadmap
status: active
created: 2026-08-29
updated: 2026-08-29
baseline_commit: 82c2b56
planning_model: ad-hoc pull; no sprints
---

# Audlint Consolidated Product Roadmap

## Purpose

This is the single product roadmap for Audlint. It consolidates the current
repository baseline, deleted Git roadmaps and TODOs, retired runbook planning,
and the archived private service plan.

The roadmap expresses direction and sequencing, not implemented behavior.
Code, tests, and the current architecture remain authoritative for what exists.

## Product direction

Audlint is currently a local Bash 5 and Python CLI/TUI for inspecting and
maintaining a music library. The near- and medium-term objective is to make that
product safer, more evidence-driven, faster, and easier to operate without
splitting policy across entry scripts.

A self-hosted Go/React service remains a possible remote product direction. It
is not an active rewrite, committed architecture, or near-term implementation
track. It may advance only after the CLI foundation is mature and a fresh
product decision revalidates the archived assumptions.

## Planning model

Development is ad hoc and pull-based. This roadmap does not use sprints,
velocity, sprint status, or time-box commitments.

Each roadmap item has a stable ID and advances independently through these
states:

- `candidate` — retained direction, not ready to start.
- `ready` — bounded enough to select next.
- `active` — implementation or discovery is underway.
- `blocked` — cannot advance without a named decision or external condition.
- `done` — exit gate is verified against code, tests, or a decision artifact.
- `parked` — deliberately outside the active horizon; not rejected.
- `retired` — superseded or explicitly abandoned.

Priorities express logical urgency, not dates:

- `P0` — protect data, truthful command semantics, trustworthy analyzer
  decisions, and a reproducible release baseline.
- `P1` — improve correctness and make analyzer decisions evidence-backed.
- `P2` — improve performance after correctness is measurable.
- `P3` — improve operator experience and maintainability.
- `P4` — explore or build a materially new product surface.

When an item is selected:

- A small, bounded code change should become a `bmad-spec` before
  implementation.
- A large capability or product-direction change should first become a product
  brief or PRD, followed by an architecture decision when system boundaries
  change.
- Implementation status belongs in its spec or code evidence, not in a sprint
  tracker.
- Completing work does not delete its roadmap ID; move it to the completion
  ledger with verification evidence.

## Roadmap invariants

All horizons preserve these constraints unless a later human-approved product
decision explicitly changes them:

1. Audio files and embedded tags remain authoritative for media content.
2. SQLite contains derived analysis plus operator-managed state and is not
   assumed to be completely reconstructible.
3. Destructive recode, metadata, artwork, deletion, sync, and backup workflows
   require explicit operator control and recoverable behavior.
4. Automated verification normally uses temporary fixtures. The explicitly
   approved `/Volumes/Music/Tests` analyzer corpus may be used read-only through
   temporary staging that keeps analyzer caches and other generated files out
   of the corpus. Never use a real music library, live SQLite database, mounted
   sync destination, or destructive audio flow for automated verification.
5. `audlint-analyze` remains the single recode-decision authority; callers may
   add workflow safety but must not recreate analyzer policy.
6. Shared policy belongs in `lib/sh/` or `lib/py/`; `bin/` entry scripts remain
   orchestration layers.
7. Canonical profiles remain `SR_HZ/BITS` after shared normalization.
8. Bash 5 and macOS/Linux portability remain required.
9. Performance work may not weaken deterministic output, failure atomicity, or
   no-upscale and lossy-source guardrails.
10. A web service must wrap or replace CLI contracts deliberately; archived
    service documents are evidence, not instructions.

## Consolidated roadmap

| Order | ID | Priority | Horizon | State | Outcome |
| ---: | --- | --- | --- | --- | --- |
| 1 | R3 | P0 | Analyzer evidence | ready | Establish trustworthy accuracy and runtime baselines from the approved test corpus. |
| 2 | R3A | P0 | Analyzer execution | candidate | Remove repeated analysis and redundant probing without weakening decisions. |
| 3 | R0 | P0 | Trustworthy baseline | ready | Establish a current, reproducible quality and release baseline. |
| 4 | R1 | P0 | Mutation safety | ready | Make dry-run, backup, and recovery semantics truthful across every mutating workflow. |
| 5 | R2 | P0 | Continuous verification | candidate | Automate the portable release gate without replacing local verification. |
| 6 | R4 | P1 | Analyzer contract | candidate | Finish convergence on one structured analyzer decision contract. |
| 7 | R5 | P1 | Analyzer refinement | candidate | Tune decisions only from corpus evidence and measured regressions. |
| 8 | R6 | P2 | Analysis parallelism | candidate | Parallelize per-track analysis safely and deterministically. |
| 9 | R7 | P2 | Conversion parallelism | candidate | Unify bounded prep/encode workers with atomic failure behavior. |
| 10 | R8 | P3 | Terminal accessibility | ready | Add explicit terminal themes, including a readable light palette. |
| 11 | R9 | P3 | Operator clarity | candidate | Make configuration, diagnostics, and recovery contracts easier to understand. |
| 12 | G0 | P4 | Service decision gate | parked | Revalidate whether a Go/React service should exist at all. |
| 13 | G1–G8 | P4 | Service delivery | parked | Build the service incrementally only after G0 approval. |

### R0 — Establish the current baseline

**State:** `ready`

**Why now:** The latest release tag is `v1.3.0`, while current `main` contains
later analyzer, BMAD adoption, lyrics, and architecture work. Historical test
counts and distro results are not a current release verdict.

**Scope:**

- Run the current `make check` gate from a clean fixture-safe environment.
- Run the Debian 12, Ubuntu 24.04, and Fedora 41 harnesses when Docker is
  available.
- Record toolchain versions, pass/fail totals, skipped tests, and environmental
  blockers in a new verification artifact.
- Decide whether the commits after `v1.3.0` constitute the next release
  candidate; do not infer a release or publish automatically.
- Reconcile current documentation if test counts or release facts have drifted.

**Exit gate:** A dated verification artifact describes current `main`; the
local quality gate passes, and every distro harness either passes or has an
explicitly accepted blocker.

**Next BMAD artifact:** bounded verification spec.

### R1 — Make mutation, dry-run, backup, and recovery semantics truthful

**State:** `ready`

**Why now:** Current architecture records that some filesystem actions remain
available independently of database writeability, paranoia backup is opt-in and
does not cover every mutation, database ZIP rotation is not documented as a
transaction-consistent snapshot, and `sync_music.sh --dry-run` still removes
macOS sidecars before invoking rsync.

**Scope:**

- Inventory every command that can mutate audio, tags, artwork, sidecars,
  SQLite state, player destinations, sync destinations, crontab, or backups.
- Make every advertised dry-run path free of mutations, or rename and document
  it if a preparatory mutation is intentionally retained.
- Define one operator-visible precondition and recovery contract for each
  destructive class.
- Decide which mutation classes require the shared paranoia backup and close
  accidental coverage gaps without silently enabling expensive behavior.
- Define and test a transaction-consistent SQLite backup method, or explicitly
  narrow the guarantee if the rotating bundles remain operational copies.
- Add only temporary-fixture tests; do not validate against the real library or
  mounted destinations.

**Exit gate:** A checked-in mutation matrix maps every destructive command to
confirmation, dry-run behavior, backup coverage, atomicity, failure cleanup,
and recovery; focused tests enforce the highest-risk contracts.

**Next BMAD artifact:** safety-contract spec, split by mutation class if the
initial audit proves too broad.

### R2 — Automate the portable quality gate

**State:** `candidate`

**Dependency:** R0 establishes the reproducible commands and environment.

**Scope:**

- Add CI for lint, formatting, Bash 5 consistency, core tests, and legacy tests.
- Exercise the supported Linux baselines without making CI the only release
  gate.
- Keep macOS-specific portability covered by local or dedicated validation
  where hosted runners cannot reproduce the environment reliably.
- Pin or report important toolchain versions so failures are diagnosable.
- Keep all test fixtures isolated and non-destructive.

**Exit gate:** A clean change receives the same essential verdict locally and
in automation, with documented exceptions for environment-specific checks.

**Next BMAD artifact:** CI/release-gate spec.

### R3 — Build the analyzer evidence base

**State:** `ready`

**Priority:** `P0`

**Why before tuning or broad parallelism:** The corpus runner and dataset
builder exist, but the repository has no durable representative corpus manifest
or current benchmark record. `/Volumes/Music/Tests` is now explicitly approved
as the read-only analyzer test corpus. Earlier library-derived labels remain
weak evidence unless their provenance is independently established.

**Approved external corpus:**

- `/Volumes/Music/Tests/real` contains profile families including 44.1/16,
  44.1/24, 48/24, 96/24, and 192/24 material.
- `/Volumes/Music/Tests/fake` contains labeled MP3, AAC, and Opus upscale cases
  at multiple source bitrates.
- `/Volumes/Music/Tests/edge_cases` contains low-pass mastering, noisy live,
  and vinyl-rip cases that are likely to expose false downgrade decisions.
- Treat the directory as immutable input. The corpus runner must stage albums
  in a temporary directory or provide an equivalent no-write mode so
  `.sox_album_profile`, `.sox_album_done`, reports, and conversion outputs are
  never written into `/Volumes/Music/Tests`.
- Keep copyrighted or oversized audio outside Git. Commit only manifests,
  checksums, human-reviewed labels, generation recipes, and benchmark results.

**Scope:**

- Define a versioned corpus manifest format and provenance rules for `trusted`
  versus `weak` labels.
- Inventory the approved external corpus and record stable relative paths,
  checksums, codec/container metadata, expected source profile, expected
  decision, label provenance, and whether the expectation is trusted or weak.
- Cover genuine 44.1 kHz and 48 kHz families, fake 48/96/192 kHz, sparse genuine
  high-resolution content, DSD-family sources, large CUE/WavPack cases, and
  misleading spectrogram exports.
- Keep copyrighted or oversized audio outside Git when required; retain
  reproducible metadata, checksums, generation recipes, and expected decisions.
- Use `audlint-dataset.sh` for synthetic trusted/fake derivatives and
  `audlint-analyze-corpus.sh` as the verdict runner.
- Extend corpus output to record wall-clock time, track count, metadata-probe
  count, decode-operation count, selected strategy, fast-to-exact fallback,
  segment-to-full fallback, decision confidence, and failure reason.
- Record cold-cache and warm-cache serial baselines for `audlint-analyze` and
  `audlint-value`, then read-only or dry-run timing for `cue2flac`, `any2flac`,
  and `dff2flac` where the command can guarantee no source mutation.
- Never treat previous Audlint output as trusted ground truth merely because it
  already exists in a library database.

**Exit gate:** The corpus runner fails on trusted mismatches, reports weak
mismatches without laundering them into truth, writes nothing into the approved
corpus, and produces a reproducible accuracy/runtime baseline that identifies
cache hits, repeated work, and expensive fallback classes.

**Next BMAD artifact:** corpus and benchmark spec.

### R3A — Make analyzer execution trustworthy and proportionate

**State:** `candidate`

**Priority:** `P0`

**Dependency:** R3 establishes the preserved decisions and runtime baseline.

**Why next:** Static inspection shows that the shared analyzer wrapper reuses a
valid profile only when the album also has an `already done` marker. An
unchanged album that still needs conversion can therefore be spectrally
reanalyzed by scans, comparisons, browser inspection, and converters. JSON
mode always performs a fresh analysis; the Python engine processes tracks
serially, normally consults both `ffprobe` and `soxi`, and may escalate a
low-confidence track from fast segments to exact segments and then a full
decode. `audlint-value` adds an unconditional DR14 pass and can request a second
fresh analyzer pass when cached fields are incomplete.

**Investigation and implementation order:**

1. `bin/audlint-analyze.sh`: separate cache validity from the `already done`
   state and define explicit cached-summary versus fresh-detail behavior.
2. `lib/py/audlint_analyze.py`: consolidate normal metadata probing, expose
   probe/decode counters, and quantify expensive fallback paths.
3. `bin/audlint-analyze-corpus.sh` and
   `lib/py/audlint_analyze_corpus.py`: enforce decision equivalence and report
   performance evidence for every change.
4. `bin/audlint-value.sh`: prevent partial-cache double analysis and add a
   fingerprinted DR14 result cache if the R3 measurements justify it.
5. `lib/sh/audio.sh` and `bin/audlint-task.sh`: eliminate duplicate album
   metadata work and direct analyzer retries that the canonical result can
   satisfy.
6. Inspect converter-specific overhead in this order: `cue2flac.sh`,
   `dff2flac.sh`, then `any2flac.sh`. Treat `qty_compare.sh` and `audlint.sh` as
   consumers until shared paths are corrected.

Do not tune spectral thresholds or introduce analyzer parallelism in R3A.
Those changes remain in R5 and R6 after equivalence and bottleneck evidence
exist.

**Exit gate:** Unchanged albums reuse valid analyzer and DR evidence according
to an explicit invalidation contract; trusted corpus decisions remain
unchanged; normal metadata probing and fallback costs are measured; repeated
calls from value, scan, comparison, browser, and conversion paths meet the
performance envelope established in the bounded spec.

**Next BMAD artifact:** analyzer execution and cache-contract spec.

### R4 — Complete analyzer-contract convergence

**State:** `candidate`

**Dependencies:** R3 supplies evidence for behavioral preservation; R3A makes
cache and execution semantics explicit.

The old roadmap asked for separate statistical and decision confidence,
explicit fallback reasons, and decision classes such as `keep_source`,
`cap_highres_ceiling`, and `downgrade_fake_upscale`. Those foundations now
exist in current code, so this item is an audit and convergence pass rather than
a restart.

**Scope:**

- Document the structured analyzer JSON and profile-cache boundary as a stable
  internal contract.
- Audit `audlint-task.sh`, `audlint-value.sh`, `any2flac.sh`, `cue2flac.sh`, and
  `dff2flac.sh` for reconstructed or duplicated recode policy.
- Move remaining canonical codec/profile normalization to the shared Bash or
  Python authority that owns it.
- Preserve workflow-specific rendering, prompts, safety guards, and execution
  in the entry scripts.
- Remove dead compatibility-era branches only when tests and corpus evidence
  prove that the canonical contract replaces them.

**Exit gate:** Each downstream caller consumes structured decisions without
deriving policy from display strings; contract tests cover all decision classes
and fallback reasons.

**Next BMAD artifact:** analyzer-contract consolidation spec.

### R5 — Refine analyzer decisions from evidence

**State:** `candidate`

**Dependencies:** R3, R3A, and R4.

**Scope:**

- Change thresholds or voting logic only for a named corpus failure or measured
  false-positive/false-negative class.
- Preserve segment mode as the efficient path for large sources and reserve
  full analysis for disagreement, family inconsistency, boundary ambiguity, or
  no-signal outcomes.
- Require stronger evidence for large fake-upscale downgrades than for keeping
  a source or applying a family ceiling.
- Retain high-frequency presence as a keep/downgrade guard and favor abrupt
  cutoff evidence over mere absence of ultrasonic energy.
- Benchmark accuracy and runtime before and after each decision change.

**Exit gate:** Every decision change improves or preserves the trusted corpus,
has explicit regression coverage, and stays within an agreed runtime envelope.

**Next BMAD artifact:** one bounded spec per decision class or corpus failure.

### R6 — Parallelize non-destructive analysis first

**State:** `candidate`

**Dependencies:** R3 establishes the benchmark; R3A removes avoidable serial
work; R4 stabilizes the contract.

Existing code already has bounded analysis workers in parts of `any2flac.sh`
and `dff2flac.sh`, but no unified per-track `audlint-analyze` worker model.

**Scope:**

- Parallelize tracks, not windows, in the analyzer.
- Use a conservative configurable job count with a hard cap.
- Collect results before deterministic album reduction.
- Keep output ordering stable and prevent interleaved raw logs.
- Coordinate derived sidecar and cache writes so workers cannot corrupt or race
  shared album state.
- Bound memory and temporary-disk usage; provide a serial fallback for large or
  network-backed sources.
- Prove serial/parallel decision equivalence and clean cancellation.

**Exit gate:** Representative workloads improve measurably while decisions,
ordering, caches, and failure results remain equivalent to serial mode.

**Next BMAD artifact:** analyzer worker-pool spec.

### R7 — Unify safe prep and encode worker pools

**State:** `candidate`

**Dependency:** R6 proves the worker and result-collection pattern on the
read-only path.

**Scope:**

- Extract one bounded worker/result pattern instead of maintaining separate
  ad-hoc loops in converter entry scripts.
- Parallelize opaque-source preparation in `cue2flac` before parallelizing
  destructive finalization.
- Add bounded per-track encoding at caller level while keeping encoder policy in
  shared helpers.
- Write temporary outputs and use atomic rename; one failed track must fail the
  album without partially replacing good source files.
- Preserve backups and diagnostic artifacts on failure while keeping reruns
  idempotent.
- Standardize job settings, caps, ordered summaries, and resource reporting.

**Exit gate:** Conversion results are serial-equivalent, worker counts are
bounded, failures leave no partial replacement, and all supported workflows
have focused fixture coverage.

**Next BMAD artifacts:** separate prep-worker and encode-worker specs.

### R8 — Add accessible terminal themes

**State:** `ready`

**Provenance:** This is the unresolved README TODO added by `66f912c`, removed
by `4b7a0cc`, and later carried into the archived service roadmap.

**Scope:**

- Define semantic terminal color roles in the shared UI layer.
- Provide current/dark and readable light-terminal palettes.
- Preserve `NO_COLOR` and non-TTY behavior.
- Apply the shared roles to `audlint.sh`, maintenance/task windows, and shared
  widgets rather than adding per-script palettes.
- Add PTY and snapshot-style assertions for contrast-critical statuses,
  prompts, failures, selections, and disabled actions.

**Exit gate:** Operators can select or auto-detect a documented theme; light,
dark, and no-color modes remain readable and behaviorally identical.

**Next BMAD artifact:** terminal-theme spec.

### R9 — Improve operator clarity and recovery guidance

**State:** `candidate`

**Dependencies:** R1 establishes the safety and recovery contracts.

**Scope:**

- Make `audlint-doctor.sh` report capability readiness by workflow rather than
  only a flat dependency inventory.
- Document which state is authoritative, derived, backed up, or recoverable.
- Surface consistent failure summaries and next actions across long-running
  scan, artwork, lyrics, transfer, and conversion flows.
- Keep `.env` configuration canonical and avoid introducing a second config
  authority before any service decision.

**Exit gate:** A new operator can identify whether a workflow is safe to run,
why it failed, and which recovery action is supported without consulting
private planning material.

**Next BMAD artifact:** operator-diagnostics product spec.

## Remote service perspective

### G0 — Revalidate the service as a product decision

**State:** `parked`

**Priority:** `P4`

**Promotion condition:** The CLI correctness, safety, and performance foundation
is mature enough that a service would expose stable contracts rather than freeze
current implementation accidents into an API.

The archived plan proposed a self-hosted Go binary with an embedded React SPA,
REST/WebSocket APIs, SQLite/GORM storage, Docker distribution, and optional AWS
paid services. That plan is useful discovery material but contains stale or
unproven assumptions:

- It treats `spectre_eval.py` as the unchanged analysis authority, while the
  current product routes recode policy through `audlint-analyze` and shared
  Python modules.
- It assumes a read-only music mount while also planning browser-triggered
  recode, lyrics, transfer, artwork, and tag-writeback actions.
- Optional authentication and permissive CORS are insufficiently resolved for
  a network UI capable of destructive library actions.
- Planned `jobs`, soft deletes, queue priority, and multi-database support do not
  exist in the current SQLite contract.
- GORM, pure-Go SQLite, Postgres/MySQL portability, AWS, licensing, and paid-tier
  demand were design hypotheses, not validated requirements.
- The target market, pricing, adoption, and support burden were estimates rather
  than research-backed commitments.

**Required decision work:**

- Create a fresh product brief that validates the user problem, current CLI
  pain, target deployment model, and whether a browser adds enough value.
- Decide whether the service is read-only, write-capable, or separated into
  permission tiers.
- Threat-model LAN exposure, authentication, CSRF/CORS, filesystem mounts,
  subprocess execution, secrets, and destructive approvals.
- Rebase the architecture on current analyzer, SQLite, sync, artwork, lyrics,
  backup, and exit-status contracts.
- Choose SQLite-only versus multi-database scope from demonstrated user need.
- Treat monetization and cloud services as independent product decisions.

**Exit gate:** An approved product brief and PRD establish user value and scope;
an architecture decision proves the service can preserve CLI safety and data
contracts. Until then, no service implementation is roadmap-ready.

### G1–G8 — Conditional service sequence

All service milestones remain `parked`. Their ordering is preserved as a remote
dependency chain, but technical choices are provisional until G0.

| ID | Archived mapping | Conditional outcome | Entry gate |
| --- | --- | --- | --- |
| G1 | W0 | Minimal service skeleton, health check, embedded UI build, and fixture-only CI. | G0 approved architecture. |
| G2 | W1 | Read-only paginated/searchable library browser using the real current SQLite contract. | G1 plus API contract tests. |
| G3 | W2 | Album detail, analysis evidence, and notes with explicit ownership semantics. | G2 and mutable-state decision. |
| G4 | W3 | Live scan orchestration with cancellation, progress, and deterministic queue recovery. | Stable analyzer contract and worker model from R4/R6. |
| G5 | W4 | Recode, transfer, artwork, and lyrics jobs with explicit approval, isolation, logs, and recovery. | R1 safety contracts and service threat model proven. |
| G6 | W5–W6 | Settings, maintenance, per-album rescan, and keep/dismiss controls without competing config or DB authorities. | G5 plus migration/rollback design. |
| G7 | W7 | Accessible responsive UI, onboarding, documented deployment, multi-arch packaging, and release operations. | End-to-end fixture suite and upgrade/rollback proof. |
| G8 | W8 | Optional paid/cloud capabilities such as genre proxy or encrypted backup. | Demonstrated adoption, separate business decision, privacy/security review, and G7 maturity. |

The archived exclusions remain sensible defaults for service discovery: no
music player, downloader, general-purpose tag manager, mobile app, multi-user
system, or hosted SaaS unless a later product brief explicitly changes scope.

## Completion and retirement ledger

These historical plans are represented here so they are not accidentally
reintroduced as unfinished work:

| Item | Disposition | Evidence |
| --- | --- | --- |
| Canonical profile normalization and fuzzy input | `done` | Roadmap added at `55b4eda`, removed as completed at `e28409e`; current shared profile helpers and tests exist. |
| Database/query, metadata/probe, shared UI, and duplicate legacy-test debt pass | `done` | Runbook debt list was emptied through the March 2026 implementation/removal commits. |
| Lint cleanup and non-interactive TTY noise | `done` | `82bef83` and `e09e689`; later release baselines recorded passing gates. |
| Analyzer decode-once and hybrid segment foundations | `done` | `89b56ab`, `b25c2a7`, and current analysis tests. |
| Structured decision classes, confidence separation, and fallback reasons | `done` as foundation; follow-up in R4/R5 | Current `lib/py/audlint_analyze.py`, `audlint-value` JSON, and tests contain the planned contract vocabulary. |
| Lyrics cached-backoff exit contract | `done` | Implementation artifact status is `done`; commit `2601437`. |
| Terminal light-theme TODO | `open`, promoted to R8 | Removed from README without implementation evidence. |
| Original Go/React rewrite as active direction | `retired` | BMAD adoption baseline explicitly says it was not adopted; preserved conditionally as G0–G8. |

## Extension protocol

To extend this roadmap without turning it into an unstructured backlog:

1. Add one stable ID under the horizon whose prerequisite naturally precedes
   it; do not renumber existing IDs.
2. State the operator or product outcome, not only the implementation idea.
3. Give it one state, one priority, dependencies, an exit gate, and source
   provenance.
4. Mark uncertain technical choices as hypotheses.
5. Put completed work in the ledger with code/test/decision evidence.
6. Put rejected or superseded work in the ledger as `retired`; do not silently
   delete historical direction.
7. Promote only one bounded item at a time into a build spec unless the user
   explicitly chooses parallel work.
8. Do not add sprint metadata. Dates may record evidence or an external
   deadline, but they do not imply a sprint cadence.

## Source register

| Source | Role in consolidation |
| --- | --- |
| `/Volumes/Music/Tests`, explicitly approved 2026-08-29 | External read-only analyzer corpus: real profile families, known fake upscales, and edge cases. Audio remains outside Git; manifests and evidence belong in BMAD artifacts. |
| `docs/architecture/OVERVIEW.md`, verified 2026-08-29 | Current implementation shape, state ownership, safety boundaries, and release gate. |
| `_bmad-output/planning-artifacts/adoption-baseline.md` | Current product direction and explicit retirement of the Go/React draft. |
| `_bmad-output/specs/spec-lyrics-cached-backoff-exit-contract/` and implementation artifact | Completed recent BMAD intent and verification evidence. |
| Archived `RUNBOOK.md`, dated 2026-04-17 | Historical active analyzer refinement and worker-pool roadmaps; read only as evidence. |
| Git history of `RUNBOOK.md`, especially `47de8f2` and subsequent debt-removal commits | Original technical-debt inventory and its completion trail. |
| Deleted `PROFILE_NORMALIZATION_ROADMAP.md` (`55b4eda` → `e28409e`) | Completed profile-normalization plan. |
| Deleted README TODO (`66f912c` → `4b7a0cc`) | Unresolved terminal-theme requirement. |
| Archived `.PLANNING/01` through `.PLANNING/08` | Retired business, architecture, API, database, frontend, deployment, feature, and milestone hypotheses for the remote service horizon. |
| Current code, tests, Git history, and release tags through `82c2b56` | Reconciliation of planned work with implemented behavior. |

The archived private workspace was read directly from
`/tmp/audlint-pre-bmad-harness-2026-08-28.tgz` without restoring it. Its recorded
SHA-256 is `d132c785fccb5b197a0cdb73a8b4127ae469540d5ba20800964f8866523df9ec`.
