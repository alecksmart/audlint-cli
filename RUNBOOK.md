# RUNBOOK.md

Local runbook for the `audlint-cli` project — an open-source release of the music library browser pipeline, migrated from the internal `encoding-tools` project.

## Status
- Date: 2026-02-22
- Current project root: `/Users/alec/Projects/audlint-cli`
- Legacy source is a symlink: `.legacy-project -> /Users/alec/Projects/encoding-tools`
- Migration complete on branch: `develop`
- Scripts use the same names as the legacy project (no prefix renaming).
- Baseline project checks currently pass: `make bash5-check`, `make test`

## Non-negotiable rules
- Source project stays intact (no edits in `.legacy-project` target).
- Executable scripts go to `bin/`.
- Shared libraries go to `lib/sh/` and `lib/py/`.
- Tests go to `test/`.
- Scripts use the same filenames as the legacy project — no prefix convention.
- `install.sh` is only a `.env` generator and is the only root binary.
- Root `Makefile` is the only Makefile in this project.
- Documentation is rewritten from scratch.
- Restore browser functionality 1:1 from legacy behavior (do not remove features).

## Legacy source inventory (library browser scope)
Primary target:
- `.legacy-project/spectrogram-analyzer/library_browser.sh`

Direct sourced deps from target script:
- `.legacy-project/lib/sh/bootstrap.sh`
- `.legacy-project/lib/sh/env.sh`
- `.legacy-project/lib/sh/deps.sh`
- `.legacy-project/lib/sh/table.sh`
- `.legacy-project/lib/sh/sqlite.sh`
- `.legacy-project/lib/sh/virtwin.sh`

Transitive runtime dep for table rendering:
- `.legacy-project/lib/py/rich_table.py`

External tool hooks referenced by browser and required to preserve 1:1 behavior:
- `bin/sync_music.sh`
- `bin/qty_seek.sh`
- `bin/any2flac.sh`
- `bin/lyrics_seek.sh`
- system tools: `sqlite3`, `rsync`, `sync`, `python3` + `rich`

## Current project layout
- `bin/*.sh` / `bin/*.py` — all executable scripts (same names as legacy)
- `lib/sh/*.sh` — shared shell libraries
- `lib/py/rich_table.py` — shared Python table helper
- `test/` — core test suite
- `test/legacy/` — migrated legacy tests
- `install.sh` — env generator only
- `Makefile` — single project Makefile

## Current script inventory (`bin/`)
- `audlint.sh` — main entrypoint / dispatcher
- `qty_seek.sh`
- `qty_compare.sh`
- `qty_test.sh`
- `spectre.sh`
- `spectre_eval.py`
- `quality_batch.py`
- `sync_music.sh`
- `any2flac.sh`
- `dff2flac.sh`
- `boost_album.sh`
- `boost_seek.sh`
- `lyrics_seek.sh`
- `lyrics_album.sh`
- `tag_writer.sh`
- `clear_tags.sh`

## Current validation baseline
- Root `Makefile` is active and is the only makefile in this repo.
- Root `install.sh` is active and only generates `.env`.
- Passing checks:
  - `make bash5-check`
  - `make test`
- `make lint` passes after SC2155/SC2086/SC2153 fixes in `bin/spectre.sh`, `bin/qty_test.sh`, `bin/boost_album.sh`.
- Latest full test status: `Ran 123 tests ... OK (skipped=14)`.

## Known behavior to preserve from legacy context
- DB table model centered on `album_quality` with queue-related `scan_roadmap` support.
- SQLite pragmas: `journal_mode=WAL`, `synchronous=NORMAL`, `temp_store=MEMORY`.
- Backup guard: DB integrity check before rotating daily/weekly/monthly zip backups.
- Recoded marker semantics: `last_recoded_at > 0`.
- Search/filter/sort behavior and interactive key workflows should remain stable unless intentionally redesigned.

## Restrictions in current dev environment
- Network access is restricted in this agent environment.
- Local allowlist command runner blocks some commands (for example `rg` there), but workspace file tools and sandboxed shell are available.
- Must not modify the symlink target source project.

## Runtime resources confirmed by user
- Most required system binaries are expected to be available on `$PATH`.
- Python virtualenv binaries are available under: `$HOME/bin/python-venvs/encoding-tools/` (access on request).
- Real library path: `/Volumes/Music/Library`
- Real DB path: `/Volumes/Music/Library/library.sqlite` (access on request).
- If any missing binary/tool is needed, explicitly ask user to provide/install it.

## Resolved decisions
1. Keep all existing functionality and actions 1:1; do not remove features even if currently unavailable in this environment.
2. Keep transfer functionality (`t`) in scope.
3. No env-var namespace migration; prioritize path/include correctness and behavior parity.
4. Tests are first-class for this project from iteration 1; use partial prioritized TDD and build a working baseline suite.
5. Scripts use the same filenames as in the legacy project — no prefix convention.

## Requested roadmap follow-ups
- UI/UX guard: when `DST_USER_HOST` is unset/blank, hide `[s Sync]` and other remote-sync UI/actions in `library_browser.sh`.
- Remote config policy: `DST_PATH` is optional and should not be treated as mandatory when `DST_USER_HOST` is unset.
- Auth refactor (future): `SSH_KEY` must remain optional; support non-key SSH auth flows (agent/default identity/password-based external setup) without treating key path as required.

## Agent Session Handling (adapted from legacy `AGENTS.md`)
### On session start
1. Load MCP memory nodes for this project context (including shared migration/workflow nodes when available).
2. Read this file (`RUNBOOK.md`) fully before making edits.
3. Check recent baseline with `git log --oneline -5` and compare against memory/session notes.
4. Do these steps silently before user-facing execution.

### On session end / handoff
- Persist key decisions and outcomes to MCP memory (completed chunks, commit hashes, quirks, workflow changes).
- Record current branch/HEAD and working-tree cleanliness.
- Capture blockers/open follow-ups so the next agent can continue without rediscovery.

## Development Principles Handling (adapted from legacy `AGENTS.md`)
### Commit discipline
- One clear commit per logical changeset.
- No amend/squash/history rewrite unless explicitly requested.
- Never force-push.
- Keep commit messages structured (`type(scope): summary`).
- Include co-author trailer when required by user/project policy.

### Branch and history policy for this repo
- `feat/library-browser-migration` history is kept local.
- Do not push feature-branch commit history from `feat/library-browser-migration` to `origin`.
- Integrate migration work to `main` via squash merge only.
- Push only the resulting squash commit(s) on `main` when instructed.
- Do not delete `feat/library-browser-migration` unless explicitly requested.

### Code standards
- Use Bash 5 shebang for shell scripts: `#!/opt/homebrew/bin/bash`.
- Keep shared logic in `lib/sh/`; avoid duplicating business logic in entry scripts.
- Keep compatibility aliases thin when needed.
- Use portable `mktemp` templates ending with bare `XXXXXX`.
- Keep responses and inline comments concise and technical.

### DB and migration safety
- Treat SQLite schema/data operations as safety-critical.
- Stop scheduled jobs/cron before destructive schema/purge operations.
- Backup DB before destructive migrations.
- Preserve runtime pragmas and schema contracts required by browser workflows.

### Testing discipline
- Run `make test` before/after meaningful changes.
- Run `make bash5-check` when shell scripts are added/edited.
- Keep legacy migration tests deterministic (isolated temp dirs, stubbed subprocess tools).
- Preserve known behavioral quirks unless explicitly asked to change semantics.
