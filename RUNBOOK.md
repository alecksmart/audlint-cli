# RUNBOOK.md

Local agent runbook for `audlint-cli` — open-source release of the music library browser pipeline, migrated from the internal `encoding-tools` project.

## Agent Session Protocol

### On session start ("Restore from RUNBOOK.md")

1. Read this file (`RUNBOOK.md`) fully.
2. Run `mcp__memory__search_nodes` for `audlint-cli` to load MCP project context.
3. Run `git log --oneline -5` to confirm HEAD and compare against memory notes.
4. Do all steps silently before any user-facing output.

### On session end / handoff

- Persist key decisions, commit hashes, quirks, completed chunks to MCP memory under `audlint-cli`.
- Record current branch/HEAD and working-tree cleanliness.
- Capture open follow-ups so the next agent can continue without rediscovery.

---

## Project Status

- Date: 2026-03-30
- Project root: `/Users/alec/Projects/audlint-cli`
- Active branch: `main`
- Local HEAD: `89b56ab` (`refactor(analyze): decode tracks once per file`)
- Remote-tracking public release branch: `main` (tracks `origin/main`)
- Public release status: live on GitHub
- Latest public release commit on `origin/main`: `af1d2af` (`release: v1.2.0 (squash from bugfix/post-v1.1.0)`)
- Latest public release tag: `v1.2.0`
- GitHub release URL: `https://github.com/alecksmart/audlint-cli/releases/tag/v1.2.0`
- Remote branch policy (public phase): keep public release history flattened on `main`; keep extra local history private unless the user explicitly wants it published.
- `main` is the only public integration branch; do not assume `develop` or old bugfix branches are current.
- Tracked worktree status before this documentation refresh: clean
- Protected local backup branch: `backup/v1.0.0-beta-local` (anchored by locked worktree `/private/tmp/audlint-cli-backup-v1.0.0-beta`).
- Legacy source symlink: `.legacy-project -> /Users/alec/Projects/encoding-tools` (read-only reference; never edit).
- Migration complete. Scripts use the same filenames as the legacy project. No prefix convention.

## Non-negotiable Rules

- Source project stays intact — no edits to `.legacy-project` target.
- This is an ad-hoc one-PC installation: no backward compatibility layers/aliases/shims are required.
- Prefer cleanup and a single canonical naming/config path over compatibility wrappers.
- Executable scripts go to `bin/`.
- Shared libraries go to `lib/sh/` and `lib/py/`.
- Tests go to `test/` (core) and `test/legacy/` (migrated legacy suite).
- Scripts use the same filenames as the legacy project — no prefix convention.
- `install.sh` is only a `.env` generator; it is the only root-level binary.
- Root `Makefile` is the only Makefile in this project.
- Documentation is rewritten from scratch — do not copy internal docs.
- Keep all planning roadmaps in `RUNBOOK.md`; do not create standalone `*_ROADMAP.md` files once completed.
- Remove completed roadmap/technical-debt items from the live lists once finished; do not keep done items in active sections.

## Project Layout

```
bin/           executable scripts (same names as legacy)
lib/sh/        shared shell libraries
lib/py/        shared Python helpers
test/          core test suite (test_*.py)
test/legacy/   migrated legacy test suite (test_legacy_*.py)
test/sh/       shell consistency checks
install.sh     .env generator only
Makefile       single project Makefile
```

## Script Inventory (`bin/`)

- `audlint.sh` — main entrypoint / dispatcher
- `audlint-task.sh`, `audlint-value.sh`, `audlint-analyze.sh`, `audlint-spectre.sh`
- `audlint-analyze-corpus.sh`
- `audlint-dataset.sh`
- `audlint-maintain.sh`, `audlint-doctor.sh`, `audlint-codec-probe.sh`
- `qty_compare.sh`, `spectre.sh`
- `sync_music.sh`
- `any2flac.sh`, `dff2flac.sh`, `cue2flac.sh`
- `boost_album.sh`, `boost_seek.sh`
- `lyrics_seek.sh`, `lyrics_album.sh`
- `tag_writer.sh`, `clear_tags.sh`

## Shared Libraries (`lib/`)

Shell: `audio.sh`, `bootstrap.sh`, `codec_caps.sh`, `deps.sh`, `encoder.sh`, `env.sh`, `ffprobe.sh`, `profile.sh`, `python.sh`, `rich.sh`, `secure_backup.sh`, `seek.sh`, `sqlite.sh`, `table.sh`, `ui.sh`, `util.sh`, `virtwin.sh`
Python: `dr_grade.py`, `genre_lookup.py`, `profile_norm.py`, `rich_table.py`, `spectre_image.py`

## Validation Baseline

- `make bash5-check` — passes (`88/88`)
- `make test` — passes: core `239` (`skipped=1`) + legacy `67`
- `python3 -m unittest discover -s test -p 'test_*.py'` — last known pass before this refactor: `216` tests, `skipped=1`
- `make fmt-check` — passes
- `make lint` — passes
- Docker distro harnesses — last known pass: Debian 12, Ubuntu 24.04, Fedora 41
- Docker distro harness rerun on `2026-03-15` is currently blocked locally because Docker cannot reach `~/.docker/run/docker.sock`

Run `make test` before and after any meaningful change. Run `make bash5-check` when shell scripts are added or edited.

## Known Behavior to Preserve

- DB model: `album_quality` table with `scan_roadmap` queue support.
- SQLite pragmas: `journal_mode=WAL`, `synchronous=NORMAL`, `temp_store=MEMORY`.
- DB backup: integrity check before rotating daily/weekly/monthly zip bundles.
- Recoded marker: `last_recoded_at > 0` (not a keep-flag).
- VA album keying: `album_artist` tag preferred over per-track artist.
- Re-scan guard: workflows that rewrite tags must re-stamp `checked_at` to avoid mtime-driven requeue loop.
- Portable `mktemp`: templates must end with bare `XXXXXX` (BSD/GNU compatible).
- Interactive key workflows, filter/sort/search behavior: stable unless intentionally redesigned.

## Restrictions in Dev Environment

- Network access is restricted in the agent environment.
- Local allowlist command runner blocks some commands — use workspace file tools and sandboxed shell.
- Must not modify the symlink target source project.

## MCP Remote-Dev Usage Policy

- Prefer `remote-dev` tools for persistent/shared infra whenever possible:
  - `kv_*` for project/session settings and lightweight state.
  - `pg_*` for structured queries/analytics.
  - `milvus_*`, `qdrant_*`, `weaviate_*` for vector-store operations.
- Current runtime note (2026-02-25): `embed_text` and `rerank` can be very slow due to no GPU.
  - Avoid them in tight interactive loops.
  - Prefer cached/precomputed embeddings and batched calls until the upgraded server is available.
- `remote-dev` shell may be unreliable in this environment; do not depend on it for core workflow.

## Runtime Resources

- System binaries expected on `$PATH`.
- Python virtualenv: `$HOME/bin/python-venvs/encoding-tools/` (request access when needed).
- Real library path: `/Volumes/Music/Library`
- Real DB: `/Volumes/Music/Library/library.sqlite` (request access when needed).

## Resolved Decisions

1. Scripts use the same filenames as the legacy project — no `audlint_` prefix.
2. All existing functionality kept 1:1 including transfer (`t`), recode, lyrics, maintain, log actions.
3. Backward compatibility is not required at this stage; keep only canonical `AUDLINT_*` config names and remove legacy aliases when touched.
4. Tests are first-class from iteration 1 — partial prioritized TDD, deterministic, isolated temp dirs.
5. `RUNBOOK.md` is the operational agent runbook and must be kept current with branch/release policy changes.
6. Public Git history policy:
   - Keep `main` as the only public integration branch unless the user explicitly decides otherwise.
   - Publish flattened release snapshots on `main`.
   - Tag releases from `main` (never from local backup/dev refs).
7. Local post-release practice:
   - Small follow-up commits may stack locally on `main` until the user approves the next push/release.
   - Keep any extra local branch history private unless the user explicitly asks to publish it.
8. Main library sync must not use SSH going forward:
   - Use local `rsync` to the mounted destination directory as the canonical sync path.
9. Public release policy after go-live:
   - Prefer flattened release snapshots on `main`.
   - Keep recode authority centralized in `audlint-analyze.sh`; downstream binaries should delegate instead of inventing parallel policy knobs.

## Roadmap

### Recently completed (2026-03-05 to 2026-03-30)

1. Browser table cleanup:
   - Removed `RE` column from list view; kept `RECODE` as canonical action indicator.
   - Fixed row parsing/indexing regression that leaked raw epoch values under `LAST CHECKED`.

2. Inspect reliability:
   - Fixed inspect codec detection to force audio stream probing (`a:0`) and ignore cover-art `mjpeg` streams.
   - Added regression test coverage for attached-picture stream edge case.

3. Header/status UX:
   - Added cached grade percentage stats to top status line.
   - Restored left-aligned status format with `|` separator and styled `>>>` + muted grade stats text.

4. Cross-distro verification tooling:
   - Added `test/distro/debian12_check.sh`.
   - Added `test/distro/ubuntu24_check.sh`.
   - Added `test/distro/fedora41_check.sh`.

5. Public docs improvement:
   - Added dependency install command blocks in `README.md` for macOS, Debian/Ubuntu, and Fedora.

6. Prompt normalization:
   - Standardized prompt spacing across `audlint.sh`, `audlint-maintain.sh`, and `virtwin` footer flows.
   - Kept confirmation prompts readable and aligned (`[y Action, n Cancel] >` style).
   - Added PTY smoke assertions for maintenance prompt/result spacing and compare-view footer separation.

7. Refactor cleanup audit:
   - Verified FFT analysis is already extracted to `lib/py/audlint_analyze.py`; `bin/audlint-analyze.sh` already delegates analysis/fingerprinting to the helper.
   - Verified track DR fuzzy matching is already extracted to `lib/py/track_dr.py` and reused by active callers.
   - Removed these stale carryover items from the active roadmap.

8. Linux distro hardening:
   - Ran the Debian 12, Ubuntu 24.04, and Fedora 41 Docker validation harnesses successfully.
   - Fixed distro harness package gaps by installing `zip` in all three images.
   - Hardened rich-table Python selection so host-specific `.env` interpreter paths fall back to a working local `python3` with `rich`.
   - Removed hard `tput` dependency from `audlint.sh` non-interactive/terminal fallback paths.

9. Install dependency guidance follow-up:
   - Added `zip` to the Linux runtime dependency docs in `README.md`.
   - Added `zip` to `install.sh` package guidance and sanity-check required binaries.
   - Closed the `install.sh` dependency install unification follow-up item.

10. `aus` calibration quality upgrade (image classifier):
   - Added a `tesseract` CLI fallback so `audlint-spectre.sh` works without the Python `pytesseract` module.
   - Enabled scratch calibration workflows by teaching `spectre.sh` and `audlint-analyze.sh` to discover symlinked audio files.
   - Re-tuned `spectre_image.py` around real exported album spectrograms from the local library:
     - fixed full-frame ffmpeg spectrogram handling so they are not misread as pane layouts
     - switched axis OCR to left-side frequency ladders and added ladder-based 22.05/24/48/96 kHz inference
     - removed false `lossy`/`brickwall` penalties for authentic Nyquist-aligned 44.1/48 kHz exports
     - aligned near-ceiling 24/48/96 kHz frames to `48000/24`, `96000/24`, and `192000/24` profile families
     - capped stat-less image quality classes conservatively (`C` for CD/48k-class, `B` for hi-res-class) so bandwidth alone does not imply excellent mastering
   - Locked the behavior with unit, fixture, and smoke coverage.
   - Current calibration pack used scratch exports for:
     - Queen `1986 - Live Magic`
     - Tony Iommi & Glenn Hughes `2005 - Fused`
     - The Hardkiss `2017 - Perfection Is A Lie`
     - Måneskin `2018 - Il Ballo Della Vita`
     - Go_A `2020 - Solovey`
     - Waxahatchee `2024 - Tigers Blood`
     - Jean-Michel Jarre `2024 - Versailles 400 (Live)`
     - Sleep Token `2025 - Even In Arcadia`
   - Result:
     - exact exported-image profile agreement vs `auv`: 6/8
     - sample-rate-family agreement vs `auv`: 8/8
     - known Queen false-CD regression fixed (`44100/16` -> `96000/24`)
   - Important limit: exported spectrogram images cannot reliably recover `16` vs `24` bit depth at the same sample rate. `auv` / `audlint-analyze.sh` remains the exact recode authority.

11. `cue2flac --check-upscale` target-selection hardening (2026-03-09):
   - Fixed a regression where `cue2flac.sh --check-upscale` could choose an intermediate target such as `48000/24` by analyzing only a first-file excerpt instead of the full referenced source set.
   - `cue2flac.sh` now stages all referenced CUE sources, runs album-wide `audlint-analyze` across that full set, and keeps the analyzer's best-fit target profile while capping it to the lowest referenced source profile to avoid upscaling any file.
   - Locked the behavior with targeted regressions for:
     - low-bandwidth `96k` sources resolving to `44100/24`
     - true `192k -> 96k` cases staying at `96000/24`
     - multi-file CUEs analyzing all referenced sources, not only the first file
     - multi-file opaque `WV` CUEs analyzing all preconverted sources
     - mixed-source CUEs capping to the lowest referenced source profile without forcing unnecessary downgrade below the analyzer result
   - Real repro fixed:
     - Chris Rea `1989 - The Road To Hell (WEA 246285-1, WX 317, Europe)`
     - pre-fix `cue2flac --check-upscale` dry-run chose `48000/24`
     - post-fix dry-run chooses `44100/24`, matching later library scan/recode authority
   - Session commits:
     - `3d3fa5d` `fix(cue2flac): analyze all sources for upscale checks`
     - `7e06a39` `test(cue2flac): harden multi-file upscale regressions`
     - `8d56294` `test(cue2flac): lock 96k target selection`
   - Validation:
     - `python3 test/legacy/test_legacy_cue2flac_cli_smoke.py` passes (`22` tests)

12. Post-release stabilization and terminal cleanup (2026-03-30):
   - Cleared the outstanding shellcheck failures in:
     - `bin/audlint-doctor.sh`
     - `bin/sync_music.sh`
     - `lib/sh/audio.sh`
   - Fixed non-interactive `/dev/tty` cleanup noise in `audlint.sh` by routing terminal cleanup and prompt helpers through safe shared fd-open helpers in `lib/sh/bootstrap.sh`.
   - Added a UI regression proving `audlint.sh --help` exits without `/dev/tty` stderr noise while preserving PTY-based quit / Ctrl-C cleanup behavior.
   - Validation:
     - `python3 test/test_ui_regression.py` passes
     - `make lint` passes
     - `make bash5-check` passes
     - `make test` passes

13. Analyzer corpus runner for trusted-vs-weak labels (2026-03-30):
   - Added `bin/audlint-analyze-corpus.sh` plus `lib/py/audlint_analyze_corpus.py`.
   - The corpus manifest accepts `trusted` and `weak` entries so analyzer validation can proceed without pretending old audlint-derived library labels are ground truth.
   - Trusted mismatches fail the run; weak mismatches are reported as warnings so they can still guide tuning without blocking.
   - This is the intended bridge until a larger externally sourced trusted corpus is available.
   - Validation:
     - `python3 test/test_audlint_analyze_corpus_smoke.py` passes
     - `make lint` passes
     - `make bash5-check` passes
     - `make test` passes

14. Boost auto-gain safety tuning (2026-03-11):
   - Centralized auto-boost policy in `lib/sh/audio.sh` so `any2flac.sh`, `boost_album.sh`, `cue2flac.sh`, and `dff2flac.sh` all use the same target ceiling, minimum-apply threshold, signed gain formatting, and absolute-threshold comparison.
   - Lowered the finished-file auto-boost ceiling to `-1.5 dBTP` to leave safer headroom after resampling instead of pushing recodes close to full scale.
   - Fixed hot-source handling so auto-boost may apply attenuation as well as positive gain; previously negative gains were skipped because only positive thresholds enabled the path.
   - Updated operator-facing output to print signed gain values consistently for enabled and skipped boost paths.
   - Locked the behavior with smoke coverage for both headroom-available and hot-source attenuation cases across:
     - `boost_album.sh`
     - `any2flac.sh --with-boost`
     - `cue2flac.sh`
     - `dff2flac.sh`
   - Session commits:
     - `e128c20` `fix(boost): lower auto-gain ceiling for recodes`
     - `b33793c` `fix(boost): apply signed auto-gain for hot sources`

15. Encoder output readability pass (2026-03-11):
   - Added shared output-formatting helpers in `lib/sh/ui.sh` for highlighted values, signed gains, and differentiated input/output paths.
   - `any2flac.sh` now uses the shared UI layer and colorizes its target profile, boost summary, per-file source -> target lines, and completion summary.
   - `cue2flac.sh`, `dff2flac.sh`, and `boost_album.sh` now highlight key calculated values and make encoder input/output paths easier to scan in long runs.
   - Kept `NO_COLOR` / non-TTY behavior unchanged so existing smoke output remains stable in tests and logs.
   - Session commit:
     - `49eeecc` `fix(ui): colorize encoder io summaries`
   - Validation:
     - `make bash5-check` passes (`84/84`)
     - `make test` passes (`195` tests, `skipped=1`)

16. Task-maintenance visibility and rescan correctness (2026-03-12):
   - Colorized `audlint-task` progress values so codec/profile fields stand out in long maintenance runs.
   - Preserved color through `audlint-maintain.sh` log piping by forcing color on the task side and falling back to raw ANSI escapes when `tput` is unavailable.
   - Fixed a discovery churn bug where freshly scanned albums could be requeued immediately because scan-side writes bumped album directory mtimes after `last_checked_at` was stamped.
   - Moved successful `audlint-task` `last_checked_at` stamping to the end of the scan path and renamed misleading UI/log counters from `queue` / `queued` to `pending` / `roadmap_pending`.
   - Session commits:
     - `be3af64` `fix(ui): colorize task progress values`
     - `b069bfc` `fix(ui): preserve task colors through maintain logs`
     - `e58c704` `fix(task): stop requeueing freshly scanned albums`
   - Validation:
     - `make bash5-check` passes (`84/84`)
     - `python3 test/legacy/test_legacy_audlint_task_db.py` passes (`43` tests)

17. Support greeter toggle and install default (2026-03-12):
   - Added the colored `>>> Slava Ukraini!` support greeter after grade stats in `audlint.sh`.
   - Added `AUDL_HIDE_SUPPORT_GREETER` handling so the greeter can be hidden without code changes.
   - `install.sh` now writes `AUDL_HIDE_SUPPORT_GREETER=1` by default for new `.env` files; this workstation may override it locally.
   - Session commits:
     - `ef55a42` `fix(ui): add status salute after grade stats`
     - `84f471d` `fix(config): add greeter hide flag`
   - Validation:
     - `make bash5-check` passes

18. Config and installer normalization pass (2026-03-13 to 2026-03-15):
   - Standardized the support-greeter flag spelling to `AUDL_HIDE_SUPPORT_GREETER` everywhere in tracked code.
   - Added `AUDL_BIN_PATH` as the canonical installed-bin location, defaulting to `$HOME/.local/bin`, and threaded it through `install.sh`, `Makefile`, docs, and task examples.
   - Hardened `install.sh` path prompts so values like `$AUDL_PATH/library.sqlite` expand correctly during validation.
   - Added workstation-friendly prompt defaults for the full `.env` shape, then simplified Python configuration so only `AUDL_PYTHON_BIN` remains authoritative.
   - `install.sh` now defaults `AUDL_PYTHON_BIN` to `/usr/bin/python3` on Linux and `python3` elsewhere.
   - Session commits:
     - `d448c9b` `fix(config): standardize greeter hide flag`
     - `7ce1c64` `feat(config): add audl bin path setting`
     - `2d85002` `fix(install): expand prior env vars in path prompts`
     - `e857b65` `feat(install): add workstation config defaults`
     - `5ff9df5` `feat(config): unify python bin setting`
   - Validation:
     - install smoke tests pass
     - `make bash5-check` passes (`84/84`)
     - `make test` passes (`199` tests, `skipped=1`) at the config-unification checkpoint

19. Browser exit cleanup hardening (2026-03-15):
   - `audlint.sh` now performs terminal cleanup from `EXIT`, `INT`, and `TERM` traps instead of only from the normal interactive quit path.
   - Interactive teardown now restores the scroll region, resets terminal state, and clears the screen through the real terminal device when available.
   - Added PTY regression coverage for `SIGINT` so Ctrl-C exits leave the terminal clean.
   - Session commit:
     - `a5ccb32` `fix(ui): clear terminal on audlint exit`
   - Validation:
     - `python3 -m unittest discover -s test -p 'test_ui_regression.py'` passes
     - `make bash5-check` passes (`84/84`)
     - `make test` passes (`200` tests, `skipped=1`)

20. Exact recode verification mode and analyzer unification (2026-03-29 to 2026-03-30):
   - Reworked `auz` / `audlint-analyze` so recode decisions follow one authority:
     - downgrade only when a source is fake-upscaled or above the family ceiling
     - resolve the underlying family as `44100` or `48000`
     - pick the leanest preserving target inside that family, capped at `176.4/24` or `192/24`
   - Threaded the analyzer verdict through `audlint-value.sh`, `audlint-task.sh`, `cue2flac.sh`, `any2flac.sh`, and `dff2flac.sh` so recode targets and upscale flags stay aligned.
   - `audlint-analyze.sh` keeps `--exact` as the only manual override, but default auto mode now:
     - runs the fast pass first
     - reruns exact automatically when album confidence is low
     - returns the exact result transparently to downstream tools
   - Removed downstream `--exact` flags from `audlint-value.sh`, `cue2flac.sh`, and `any2flac.sh`; they now rely on analyzer auto mode instead of exposing their own pass-through switches.
   - User-facing binaries now surface the analyzer fallback notice:
     - `Got low confidence in fast test, running exact mode...`
   - Added regression coverage for exact-mode cache separation, auto fallback, surfaced fallback notices, and DSD / multi-file CUE edge cases.
   - Session commits:
     - `3b38d11` `feat(analyze): add exact recode verification mode`
     - `cf35e4d` `feat(analyze): auto-rerun exact on low confidence`
     - `50479d2` `feat(analyze): surface exact fallback notice`
   - Validation:
     - `python3 test/test_audlint_analyze_logic.py` passes
     - `python3 test/test_audlint_analyze_cache_smoke.py` passes
     - `python3 test/test_any2flac_smoke.py` passes
     - `python3 test/test_audlint_value_smoke.py` passes
     - `python3 test/test_cue2flac_smoke.py` passes
     - `python3 test/test_dff2flac_smoke.py` passes
     - `python3 test/test_audlint_task_smoke.py` passes
     - `python3 test/legacy/test_legacy_qty_compare_cli.py` passes
     - `make bash5-check` passes (`84/84`)
     - `make test` passes (`216` tests, `skipped=1`)

21. Public README/open-source polish (2026-03-13 to 2026-03-15):
   - Refreshed the root `README.md` for GitHub-first presentation: public intro copy, screenshot placement, main features, workflow diagram, dependencies/quick-start ordering, maintenance/paranoia mode notes, safety disclaimer, and supported library layout guidance.
   - Moved repo-layout detail into `docs/README.md` and kept the root README focused on end-user understanding.
   - Updated the main-window screenshot and refined diagram wording around backup/paranoia mode and transfer destinations.
   - Latest docs commits in this pass:
     - `d3239e3` `docs(readme): update main window screenshot`
     - `f6b4dbc` `docs(readme): refresh intro wording and workflow label`
     - `752a421` `docs(readme): expand feature and layout examples`
     - `7fd0f7f` `docs(readme): label backup flow as paranoia mode`

22. Release-validation snapshot (2026-03-15):
   - Host-side release suite is green: `make test` and direct `python3 -m unittest discover -s test -p 'test_*.py'` both pass with `200` tests and `skipped=1`.
   - Docker-backed Linux reruns were attempted for Debian 12, Ubuntu 24.04, and Fedora 41, but all three are currently blocked by the local Docker daemon/socket being unavailable.

23. Public launch and release publication (2026-03-15 to 2026-03-29):
   - Final release-facing README wording was polished and the main-window screenshot was restored to the previous version before publishing.
   - `develop` advanced to `fa3bab4` (`docs(readme): polish release copy and restore screenshot`).
   - `main` was published as a flattened public snapshot at `4fb0de9` (`release: v1.1.0 (squash from develop)`).
   - Annotated tag `v1.1.0` was created and pushed.
   - GitHub release page was published with brief notes:
     - `Public release snapshot with install/config cleanup, browser and maintenance improvements, and refreshed open-source docs.`
   - Post-release working branch created from `develop`:
     - `bugfix/post-v1.1.0`
   - Follow-up public snapshot:
   - `main` advanced to `af1d2af` (`release: v1.2.0 (squash from bugfix/post-v1.1.0)`)
   - annotated tag `v1.2.0` was created and pushed
   - release notes highlighted analyzer/recode-rule hardening and `--exact` support

24. Decode-once analyzer engine refactor (2026-03-30):
   - Replaced the old per-window decode path in `lib/py/audlint_analyze.py` with a decode-once execution model:
     - one ffprobe JSON metadata probe per track when available
     - one PCM decode per track into a temp raw file
     - fast/exact/auto-fallback window analysis reused from that same decode instead of respawning ffmpeg/sox for every window
   - Preserved the existing shell wrapper and JSON contract:
     - same `source-fingerprint`, `config-fingerprint`, and `analyze` commands
     - same album/track decision fields for downstream `audlint-value`, `audlint-task`, `any2flac`, `cue2flac`, and `dff2flac`
     - same album-level fake-upscale/family/target reduction rules
   - Exact-mode behavior is now adaptive on the new engine:
     - mono is still analyzed first
     - stereo channel analysis is only added in exact mode when mono confidence stays low
     - auto exact fallback reuses the first decode instead of decoding the track a second time
   - Added regression coverage to prove the new contract:
     - auto mode exact fallback uses a single decode
     - Python analyzer reuses a single metadata probe per track
   - Session commit:
     - `89b56ab` `refactor(analyze): decode tracks once per file`
   - Validation:
     - `python3 test/test_audlint_analyze_logic.py` passes
     - `python3 test/test_audlint_analyze_cache_smoke.py` passes
     - `python3 test/test_audlint_value_smoke.py` passes
     - `python3 test/test_any2flac_smoke.py` passes
     - `python3 test/test_cue2flac_smoke.py` passes
     - `python3 test/test_dff2flac_smoke.py` passes
     - `python3 test/test_audlint_task_smoke.py` passes
     - `make test` passes: core `222` (`skipped=1`) + legacy `67`

25. Hybrid analyzer strategy switcher for huge sources (2026-03-30):
   - Added internal `fast`, `segment`, and `full` execution strategies in `lib/py/audlint_analyze.py`.
   - Large/expensive sources now prefer segment seek-decodes instead of unconditional full-track decode:
     - WavPack / APE / DSD-family files
     - large cue-backed images
     - very long tracks / album-length files
   - Preserved the existing shell wrapper and JSON contract while adding debug telemetry for strategy choice and fallback.
   - Session commit:
     - `b25c2a7` `feat(analyze): add hybrid strategy switcher`
   - Validation:
     - `python3 test/test_audlint_analyze_logic.py` passes
     - `python3 test/test_audlint_analyze_cache_smoke.py` passes
     - `make test` passes

26. Dataset builder for trusted WAV sources (2026-03-30):
   - Added `bin/audlint-dataset.sh` to build analyzer datasets from trusted WAV albums.
   - The builder creates:
     - bit-perfect trusted-source copies in `real/<profile>/`
     - clean lower-profile references in `real/44100_16/` and `real/48000_24/` when they are true downsample targets
     - lossy-to-FLAC fake-upscale buckets for MP3, AAC, and Opus variants
     - empty `edge_cases/` placeholders for manual additions
   - It skips existing outputs unless `--force` is provided and uses bounded ffmpeg worker parallelism.
   - Validation:
     - `python3 test/test_audlint_dataset_smoke.py` passes
     - `make lint` passes
     - `make bash5-check` passes
     - `make test` passes

### Active

1. **Post-`v1.2.0` stabilization queue**
   - Current working branch:
     - `main`
   - Local unpublished follow-ups already landed:
     - `dae8885` `feat(value): add exact analyzer mode`
     - `cf35e4d` `feat(analyze): auto-rerun exact on low confidence`
     - `50479d2` `feat(analyze): surface exact fallback notice`
     - `89b56ab` `refactor(analyze): decode tracks once per file`
     - `b25c2a7` `feat(analyze): add hybrid strategy switcher`
     - `6b85f56` `feat(analyze): refine hybrid decision confidence`
     - `a0571e8` `fix(value): surface dr14meter failures`
     - `f83d283` `fix(value): retry dr14meter int24 wav albums`
     - `82bef83` `fix(lint): clear current shellcheck failures`
   - Highest-signal follow-ups discovered during release validation:
     - rerun the Debian 12 / Ubuntu 24.04 / Fedora 41 Docker harnesses once the local Docker daemon is reachable again

2. **Analyzer Decision Refinement**
   - **Priority**
     - Prepend this work ahead of the parallelism roadmap.
     - Treat the decode path as done foundation work:
       - `89b56ab` `refactor(analyze): decode tracks once per file`
       - `b25c2a7` `feat(analyze): add hybrid strategy switcher`
     - Keep CLI/output contracts stable while refining decisions.
     - Accuracy changes must keep the common path fast; do not accept a blanket slowdown without clear evidence.
   - **Current decision-layer goals**
     - Make segment mode the default authority for large/expensive sources.
     - Split statistical confidence from decision confidence.
     - Accept stable segment results without full fallback when the classification is consistent.
     - Fall back to full only for disagreement, family inconsistency, boundary ambiguity, or true no-signal cases.
     - Require stronger evidence before `downgrade_fake_upscale`, especially for large downgrades like `192000 -> 44100`.
     - Use adaptive segment counts so strong agreement can stop after `2-3` useful segments instead of always spending the full budget.
   - **Decision-model upgrades**
     - Aggregate per-segment votes, not only median cutoff.
     - Track consistency bands around the median cutoff instead of treating variance alone as authority.
     - Use high-frequency presence as a downgrade guard rather than a downgrade requirement.
     - Prefer abrupt cutoff/brickwall evidence over weak-ultrasonic-energy absence for hi-res material.
     - Add explicit fallback reasons:
       - `fallback_due_to_disagreement`
       - `fallback_due_to_family_inconsistency`
       - `fallback_due_to_boundary_ambiguity`
   - **Validation**
     - Benchmark before/after every analyzer-decision change on 2-3 representative albums, including at least one huge cue/image or WavPack case.
     - Build a labeled regression corpus covering true `44.1`, true `48`, fake `48`, fake `96/192`, sparse genuine hi-res, DSD-family examples, and misleading spectrogram exports.
     - Use `audlint-dataset.sh` to synthesize trusted/fake seed corpora from known-good WAV albums before adding them to the corpus runner.
     - Use `audlint-analyze-corpus.sh` as the corpus runner so trusted and weak labels are tracked separately.
     - Current trusted in-library anchor is `/Volumes/Music/Hijacked` (`96000/24` genuine); the rest of the library should be treated as weak labels because it was encoded by earlier audlint versions.
     - For future trusted references, prefer external publisher/reference catalogs rather than self-labeled library output.
     - Add regression coverage for false-positive protection and fallback-on-conflict before changing thresholds again.

3. **Parallelize analyze / prep / recode worker pools**
   - **Next restore reminder**
     - Remind the user at session restore that analyzer exactness comes first, then this roadmap.
   - **Baseline and guardrails**
     - Measure current wall-clock time for `audlint-analyze`, `cue2flac`, `any2flac`, and `dff2flac` on 2-3 representative albums.
     - Define hard constraints: deterministic output, stable file naming/order, no metadata races, no partial-replace behavior, bounded temp-disk usage.
     - Keep SoX internal threading as-is; parallelism should be process-level in audlint, not "force more SoX threads".
   - **`audlint-analyze` parallel workers**
     - Add album-level worker parallelism in `bin/audlint-analyze.sh` / `lib/py/audlint_analyze.py`.
     - Parallelize per-track analysis first, not per-window analysis.
     - Add `AUDLINT_ANALYZE_JOBS` with a conservative default and hard cap.
     - Keep final album target reduction deterministic by collecting worker results and reducing once.
   - **Shared worker-pool pattern**
     - Extract a small shell helper for bounded background jobs and ordered result collection.
     - Reuse one worker-pool model across `any2flac`, `dff2flac`, and `cue2flac` instead of duplicating queue logic in each script.
     - Standardize env var naming and caps across the converter scripts.
   - **Prep-stage parallelism**
     - `cue2flac`: parallelize opaque-source pre-convert for `wv` / `ape` / `dsf` / `dff`, and evaluate segment extraction parallelism only if it stays safe.
     - `any2flac`: review whether preflight/probe steps beyond true-peak analysis should use workers.
     - `dff2flac`: keep existing parallel analysis but align it with the shared worker helper.
   - **Encode-stage parallelism**
     - Add bounded per-track encode jobs to `encoder.sh` callers, not inside `encoder.sh` itself.
     - Use temp outputs plus atomic rename so a failed worker never replaces a good file.
     - Preserve album-level validations and finalization after all workers complete.
   - **Logging and UX**
     - Keep output ordered by track number even when work is parallel.
     - Show compact worker status (`workers=...`, active/completed counts).
     - Avoid interleaved raw worker logs; collect per-track summaries instead.
   - **Resource controls**
     - Default jobs to something like `min(cpu_cores, 4)`.
     - Add explicit per-script caps.
     - Consider serial fallback for lossy transcodes, huge temp-WAV workflows, or network-mounted volumes.
   - **Failure model**
     - One track failure should fail the album job cleanly without partial replacement.
     - Preserve backup dirs and temp dirs on failure with a clear summary.
     - Keep reruns idempotent.
   - **Tests**
     - Add regression coverage for ordered outputs, bounded worker count, failure cleanup, and no partial replacement.
     - Add smoke coverage for `AUDLINT_ANALYZE_JOBS`, `CUE2FLAC_JOBS`, `ANY2FLAC_JOBS`, and `DFF2FLAC_JOBS`.
     - Add one equivalence test proving parallel mode picks the same target/profile as serial mode.
   - **Rollout order**
     - Phase A: `audlint-analyze` worker parallelism.
     - Phase B: `cue2flac` prep parallelism.
     - Phase C: encode worker pools in `any2flac`, `cue2flac`, and `dff2flac`.
     - Phase D: unify worker helper and polish logging/UI.
   - **Recommendation**
     - Start with `audlint-analyze` first; it is the highest leverage and lowest risk because it is read-only and easiest to benchmark.

### Technical debt

- None currently. Add only live, unfinished debt items here.

## Commit Discipline

- One clear commit per logical changeset.
- Commit every meaningful chunk during active work; do not leave multiple substantive changes uncommitted.
- No amend/squash/history rewrite unless explicitly requested.
- Never force-push.
- Structured messages: `type(scope): summary`.
- Post-launch default: push `origin/main` + release tags; keep any extra local branches/history private unless the user explicitly wants them published.

## Code Standards

- Bash shebang: `#!/usr/bin/env bash`.
- Shared logic in `lib/sh/` — avoid duplicating business logic in entry scripts.
- Portable `mktemp` templates ending with bare `XXXXXX`.
- Concise inline comments only where logic is non-obvious.
