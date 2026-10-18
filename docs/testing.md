# Python test-suite tiers

`make test` is the fast editing loop. `make test-integration` holds the broad,
environment-shaped, and slower regression coverage. `make test-all` invokes the
two explicit file lists in one `unittest` process, so their union runs once.
`make check` is the release gate: lint, format, Bash 5 validation, `test-all`,
then the source audit.

## Measurement record

All timings below were taken on 2026-08-31 on macOS 26.6.2 (build 25G83),
arm64, with Python 3.14.5. The CPU model is unavailable in this sandbox.
Fixtures use the system temporary directory on `/System/Volumes/Data` (23 GiB
available when measured). The repository was at
`7c30559c4fa7026267fc3bf272ab79e457a64adb` before this change. Timings are
directional because filesystem cache state and external-process startup vary.

Before changing the suite, `time make test` executed 460 tests and skipped one
in `6:35.52` wall time: top-level discovery reported `382 tests in 266.395s`
plus one skip, and legacy discovery reported `78 tests in 128.297s`. The named
pre-change suite profiles were:

| File | Command | Tests | Wall time |
| --- | --- | ---: | ---: |
| [`test_legacy_audlint_task_db.py`](../test/legacy/test_legacy_audlint_task_db.py) | `python3 -m unittest test.legacy.test_legacy_audlint_task_db` | 43 | 1:38.85 |
| [`test_library_browser_smoke.py`](../test/test_library_browser_smoke.py) | `python3 -m unittest test.test_library_browser_smoke` | 23 | 48.43s |
| [`test_cue2flac_smoke.py`](../test/test_cue2flac_smoke.py) | `python3 -m unittest test.test_cue2flac_smoke` | 28 | 34.19s |
| [`test_audlint_analyze_cache_smoke.py`](../test/test_audlint_analyze_cache_smoke.py) | `python3 -m unittest test.test_audlint_analyze_cache_smoke` | 19 | 28.19s |
| [`test_any2flac_smoke.py`](../test/test_any2flac_smoke.py) | `python3 -m unittest test.test_any2flac_smoke` | 25 | 22.97s |

The final captured focused commands passed in 1:29.81, 44.40s, 32.59s,
18.81s, and 17.43s respectively. The final `time make test` passed 190 tests
in `1:01.18`.

## Classification

Every `test/test_*.py` and `test/legacy/test_*.py` file is listed below. The
counts total 464 collected cases: the targets execute 463 and skip one
class-level opt-in case. A grouped time means the file is timed through the
target named in the next column, rather than repeatedly in isolation.

| File | Tests | Timing | Classification | Release target | Reason |
| --- | ---: | --- | --- | --- | --- |
| `test/legacy/test_legacy_qty_compare_cli.py` | 7 | FAST group | FAST | `test-all` | Small CLI argument and output contracts. |
| `test/test_audio_probe_smoke.py` | 6 | FAST group | FAST | `test-all` | Focused probe and cache contracts. |
| `test/test_audlint_analyze_logic.py` | 26 | FAST group | FAST | `test-all` | Pure analyzer decision logic. |
| `test/test_audlint_dataset_smoke.py` | 3 | FAST group | FAST | `test-all` | Small deterministic dataset CLI fixture. |
| `test/test_audlint_doctor_smoke.py` | 4 | FAST group | FAST | `test-all` | Focused diagnostics fixture. |
| `test/test_audlint_source_audit_smoke.py` | 17 | FAST group | FAST | `test-all` | Source-audit safety behavior. |
| `test/test_audlint_task_smoke.py` | 2 | FAST group | FAST | `test-all` | Small scanner smoke fixture. |
| `test/test_audlint_value_smoke.py` | 6 | FAST group | FAST | `test-all` | Focused quality-value boundary. |
| `test/test_bootstrap_portability.py` | 3 | FAST group | FAST | `test-all` | Portable bootstrap checks. |
| `test/test_bootstrap_tty.py` | 2 | FAST group | FAST | `test-all` | Focused TTY helper contract. |
| `test/test_deps_path_smoke.py` | 1 | FAST group | FAST | `test-all` | PATH construction contract. |
| `test/test_dr_grade.py` | 23 | FAST group | FAST | `test-all` | Pure grading thresholds. |
| `test/test_install_sh_smoke.py` | 8 | FAST group | FAST | `test-all` | Isolated installer rendering. |
| `test/test_makefile_contract.py` | 3 | 0.054s focused | FAST | `test-all` | Guards tier coverage, disjointness, and `check` ordering. |
| `test/test_lyrics_smoke.py` | 5 | FAST group | FAST | `test-all` | Small lyrics command fixtures. |
| `test/test_player_content_creator.py` | 34 | FAST group | FAST | `test-all` | Deterministic content-creator behavior. |
| `test/test_profile_norm.py` | 5 | FAST group | FAST | `test-all` | Profile normalization unit coverage. |
| `test/test_secure_backup.py` | 4 | FAST group | FAST | `test-all` | Focused backup safety checks. |
| `test/test_spectre_calibration_cases.py` | 1 | FAST group | FAST | `test-all` | Single calibration assertion. |
| `test/test_spectre_cli_smoke.py` | 6 | FAST group | FAST | `test-all` | Focused spectre smoke target remains available. |
| `test/test_spectre_image.py` | 21 | FAST group | FAST | `test-all` | Image-analysis unit behavior. |
| `test/test_sqlite_profile_normalization.py` | 3 | FAST group | FAST | `test-all` | Narrow schema normalization checks. |
| `test/test_sqlite_query_plan_smoke.py` | 8 | FAST group | FAST | `test-all` | Focused SQLite query-plan contracts. |
| `test/test_sync_music_smoke.py` | 8 | FAST group | FAST | `test-all` | Local rsync and mount stubs with safety checks. |
| `test/legacy/test_legacy_audlint_task_db.py` | 43 | 1:27.65 focused | INTEGRATION / DEEP REGRESSION | `test-all` | Broad scanner, SQLite, queue, and failure contracts. |
| `test/legacy/test_legacy_boost_audio_cli_smoke.py` | 7 | 6.43s baseline | INTEGRATION / DEEP REGRESSION | `test-all` | Conversion and destructive-workflow coverage. |
| `test/legacy/test_legacy_tags_scripts.py` | 21 | 14.75s baseline | INTEGRATION / DEEP REGRESSION | `test-all` | Tagging, lyrics, and filesystem safety coverage. |
| `test/test_any2flac_smoke.py` | 25 | 17.36s focused | INTEGRATION / DEEP REGRESSION | `test-all` | Conversion and replacement safety paths. |
| `test/test_audlint_analyze_cache_smoke.py` | 19 | 18.85s focused | INTEGRATION / DEEP REGRESSION | `test-all` | Decode timeouts, cache, and analyzer fallback behavior. |
| `test/test_audlint_analyze_corpus_baseline.py` | 15 | integration group | INTEGRATION / DEEP REGRESSION | `test-all` | Corpus publication and evidence regression coverage. |
| `test/test_audlint_analyze_corpus_benchmark.py` | 16 | integration group | INTEGRATION / DEEP REGRESSION | `test-all` | Broad staged benchmark and safety evidence. |
| `test/test_audlint_analyze_corpus_smoke.py` | 26 | integration group | INTEGRATION / DEEP REGRESSION | `test-all` | Corpus integrity, provenance, and staged-input safety. |
| `test/test_audlint_maintain_smoke.py` | 15 | integration group | INTEGRATION / DEEP REGRESSION | `test-all` | Maintenance UI and cron-shaped behavior. |
| `test/test_cover_smoke.py` | 16 | 13.51s baseline | INTEGRATION / DEEP REGRESSION | `test-all` | Artwork mutation and fetch safety coverage. |
| `test/test_cue2flac_smoke.py` | 28 | 33.55s focused | INTEGRATION / DEEP REGRESSION | `test-all` | CUE conversion, profile, and output contracts. |
| `test/test_dff2flac_smoke.py` | 10 | 10.72s baseline | INTEGRATION / DEEP REGRESSION | `test-all` | DFF conversion and profile safety. |
| `test/test_library_browser_smoke.py` | 23 | 46.84s focused | INTEGRATION / DEEP REGRESSION | `test-all` | Browser PTY, transfer, and signal regression coverage. |
| `test/test_ui_regression.py` | 10 | 7.46s baseline | INTEGRATION / DEEP REGRESSION | `test-all` | Terminal rendering and interactive regression coverage. |

No file is REDUNDANT or OBSOLETE. No tests were removed or merged: each file
remains in exactly one tier and in the release suite. The `legacy` directory
was not used as classification evidence; its files are in their tiers because
of the concrete contracts above.

## Fixture changes and isolation evidence

- `test_legacy_audlint_task_db.py` builds the read-only command and `lib/sh`
  runtime once. Each case still receives its own database, lock, discovery
  cache, media tree, and executable stubs.
- `test_library_browser_smoke.py` uses the source `lib/` as a directory
  symlink only where a copied browser is needed; each test keeps its copied
  browser, `.env`, database, and media fixture.
- `test_cue2flac_smoke.py` keeps its per-case mutable command copy and points
  only its read-only shell library at the source tree.
- `test_audlint_analyze_cache_smoke.py` hard-links normal immutable stubs when
  supported, otherwise replaces a partial tree with `copy2` output; a stub is
  unlinked before a case replaces it, preventing fixture leakage.
- `test_any2flac_smoke.py` uses the same hard-link-or-clean-copy fallback and
  routes per-case logs through `STUB_LOG_DIR`; albums, outputs, and logs remain
  case-local.

## Final verification

| Command | Result | Wall time / evidence |
| --- | --- | --- |
| `time make test` | PASS, exit 0, 190 tests | 60.562s unittest; 1:01.18 wall |
| `time make test-integration` | PASS, exit 0, 273 run + 1 skipped | 302.147s unittest |
| `time make test-all` | PASS, exit 0, 463 run + 1 skipped | 366.262s unittest; 6:06.96 wall |
| `time make check` | PASS, exit 0 | Lint, format, Bash 5 (100 pass, 0 fail), `test-all` (463 run + 1 skipped in 362.800s), then source audit (`status=clean`, 0 findings/errors); 6:27.28 wall. |
