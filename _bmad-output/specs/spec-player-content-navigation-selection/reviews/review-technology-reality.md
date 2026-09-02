# Technology Reality Review

## Verdict

**Changes required before finalization.** The repository supports the broad Functional Core / Imperative Shell direction, Bash 5 dynamic file descriptors, a long-lived Python child, shared SQLite/player helpers, secure temporary artifacts, and the accepted file-backed rsync pipeline. The Unicode/display-cell decision is not yet technically supported as written, and the Python/process portability claims need explicit version and proof boundaries.

This review used repository evidence and the local runtime only, per project policy. Local baseline: macOS 26.6.2 arm64, Bash 5.3.15, Python 3.14.5 with Unicode 16.0.0 data, `C.UTF-8`, libc `wcwidth`/`wcswidth`, and rsync 3.4.4.

## Tier 1 — Must resolve

### T1.1 — Python standard-library Unicode data does not supply grapheme boundaries

**Spine assertion:** AD-4 says one Python kernel supplies grapheme boundaries and “uses Python standard-library Unicode data,” with no `regex` dependency.

**Reality evidence:** Python 3.14.5 `unicodedata` exposes normalization, category, combining class, East Asian width, and related scalar properties, but no grapheme-break or extended-pictographic property/API. The repository has no grapheme implementation or vendored Unicode break tables. The locally installed `regex` module is third-party under `site-packages`, is not declared by Audlint, and is absent from the project’s documented base requirements. The `wcwidth` Python package is not installed locally. Python scalar categories alone cannot fully implement Unicode extended grapheme clusters such as regional-indicator flags, emoji modifiers, and extended-pictographic ZWJ sequences without additional rules/data.

**Impact:** Two implementers can both claim “grapheme” while producing incompatible Backspace, clipping, and caret behavior. A purported complete implementation based only on combining marks would not satisfy the UX contract for arbitrary printable Unicode input.

**Required correction:** Bind an exact grapheme contract and data source. Viable no-runtime-dependency choices are a deliberately scoped, explicitly named cluster algorithm with matching accepted limitations, or repository-owned/versioned break-property tables plus a UAX #29 implementation. Do not imply that `unicodedata` already provides the missing segmentation data. Adding `regex` would require an explicit dependency/package-management decision and is not supported by the current spine.

### T1.2 — libc `wcswidth` does not establish the promised display-cell guarantee

**Spine assertion:** AD-4 selects a probed UTF-8-locale libc `wcswidth` service for display-cell measurement, with an ASCII-glyph/input fallback when it is unreliable.

**Reality evidence:** The symbol exists and works for ASCII, combining accents, CJK, and a simple emoji on this macOS runtime. It does not model terminal graphemes consistently: local `wcswidth` reports `✈️` as 1 cell, `👩‍💻` as 4, and `👍🏽` as 4 by summing code-point widths, even though the UX treats each sequence as one editable grapheme and terminals may present each as one composed glyph. libc width data is OS/locale dependent and does not know the terminal emulator’s emoji presentation policy. The repository has no existing probe, width abstraction, terminal capability handshake, or fixture that defines when the backend is “reliable.”

**Impact:** AD-8’s no-wrap/no-canvas-corruption guarantee can fail even when `wcswidth` returns a nonnegative value. Switching only disclosure/quote/truncation glyphs to ASCII and restricting newly typed text does not settle how existing Unicode artist/album labels are safely measured and displayed.

**Required correction:** Define the probe and fallback as an enforceable algorithm, including treatment of pre-existing non-ASCII labels. Either constrain the supported display repertoire and replace unsupported clusters with fixed-width placeholders, or bind a repository-owned width policy/table with explicit terminal assumptions. Keep libc `wcswidth` only as a qualified backend whose exact acceptance probes and failure behavior are testable; do not present it as generally authoritative.

## Tier 2 — Bind and prove before implementation handoff

### T2.1 — Python and Unicode versions are not part of the compatibility contract

**Spine assertion:** AD-4 relies on Python `str.casefold` and standard-library Unicode data, but the spine and product documentation require only “Python 3.”

**Reality evidence:** This machine has supported-looking Python installations with materially different Unicode databases: Python 3.11.15 / Unicode 14.0.0, 3.12.13 / 15.0.0, 3.13.13 / 15.1.0, and 3.14.5 / 16.0.0. `README.md`, `install.sh`, `Makefile`, and `docs/architecture/OVERVIEW.md` do not define a product minimum or frozen Unicode version. The existing `lib/sh/python.sh` is a NumPy-specific selector and is not a generic Python compatibility gate.

**Impact:** Casefold results, recognized characters, segmentation tables, and width classifications can vary across supported macOS/Linux installations. Tests passing on the current Python 3.14 runtime do not establish the same projection/editing behavior on Debian 12’s older Python baseline.

**Required correction:** State the minimum supported Python version and whether Unicode semantics are runtime-relative or frozen by repository-owned tables. If runtime-relative behavior is intentional, test invariant examples on every supported distro and avoid claims of cross-version byte-identical projections. Add a selector startup compatibility check through the existing `AUDL_PYTHON_BIN` configuration path; do not reuse the NumPy-only selector as-is.

### T2.2 — Persistent Python/FD mechanics are locally feasible but not repository-established

**Spine assertion:** The paradigm and AD-5 require one persistent Python model exchanging framed records over dedicated file descriptors; Deferred leaves startup mechanics and buffering to implementation.

**Reality evidence:** A local Bash 5.3 smoke probe successfully launched one unbuffered Python child with `coproc`, duplicated its input/output descriptors, exchanged a version/request/kind Unit-Separator record, closed every duplicate, and reaped the child. Current shared helpers already prove dynamic TTY descriptor allocation and `read -u`. However, the repository has no persistent Python service, model protocol, child-reaping helper, timeout/EOF contract, or test for coprocess descriptors. `test/sh/bash5_consistency.sh` verifies associative arrays, namerefs, mapfile, case conversion, globstar, shebangs, and parsing—but not `coproc`, descriptor duplication/closure, bidirectional framing, buffering, or child termination.

**Impact:** The direction is viable on the current machine, but cleanup, EOF, stalled-child, and descriptor-inheritance mistakes can hang the selector or prevent exactly-once terminal restoration. Deferring all startup mechanics leaves a real cross-story integration risk around a mandatory architectural choice.

**Required correction:** Keep exact helper names deferred, but make the protocol lifecycle non-deferred: configured interpreter resolution, unbuffered I/O, parent/child descriptor closure, one-request/one-response sequencing, timeout/EOF/error mapping, child termination/reaping, and controller-finalizer ordering. Add a no-TTY protocol smoke test and Bash 5 feature probe before treating the persistent-process assertion as established.

### T2.3 — macOS/Linux proof does not yet cover the new technology choices

**Spine assertion:** AD-7 binds ADR-0003, AD-10 makes width backends injectable, and Deferred calls the Bash 5 macOS/Linux floor inherited.

**Reality evidence:** The local Bash 5 guard passes 100 checks. Existing Debian 12, Ubuntu 24.04, and Fedora 41 harnesses exercise only narrow existing UI/cron paths; they do not install or test the selector’s Python Unicode backend, libc width behavior, persistent FD protocol, CSI/SS3 parser, or Player Content rsync path. No Linux runtime evidence for `C.UTF-8` selection or `wcswidth` behavior is present in the feature package.

**Impact:** Dependency injection proves model logic, not that the selected production backend exists and behaves acceptably on the supported distributions.

**Required correction:** Extend the applicable distro checks with production-backend probes for interpreter/version, locale, accepted/rejected width cases, persistent process/FD shutdown, and key parser inputs. Keep the pure injected tests, but do not use them as the only portability evidence.

## Tier 3 — Reality-checked and supported

### T3.1 — Bash 5 and low-level terminal/FD seed

- `/opt/homebrew/bin/bash` is 5.3.15 and the repository Bash gate passes.
- `lib/sh/bootstrap.sh` already owns portable TTY input/output FD opening, dynamic descriptor closure, and basic `stty` save/restore patterns.
- `lib/sh/virtwin.sh` owns the established preserved-header/scroll-region canvas.
- `bin/audlint-maintain.sh` contains the current selector raw-mode, caret, parser, resize, progress handoff, input-drain, and cleanup seed. Moving shared policy out of the entry script is a new extraction, not a pre-existing controller.

### T3.2 — SQLite mutation direction

- `lib/sh/sqlite.sh` is the existing SQLite policy owner and already uses `BEGIN IMMEDIATE` plus temporary-table guard patterns for all-or-nothing snapshot-size updates.
- The current membership helper mutates one path at a time; a complete add/remove manifest transaction does not yet exist. AD-3 correctly describes required new shared-helper work rather than current implementation.

### T3.3 — Player snapshot and synchronization stack

- `lib/sh/player.sh` currently provides restrictive temporary artifact creation, eligible-track snapshots, snapshot totals, ordered file-backed merge-filter compilation, destination snapshots, and exact postcheck helpers.
- `bin/audlint-maintain.sh` currently consumes one root rsync using `-r`, `--size-only`, deletion, excluded-content deletion, the merge file, flush, source re-snapshot, destination postcheck, and failure preservation.
- The local rsync is 3.4.4. Existing tests cover temporary-fixture GNU-rsync semantics; the accepted companion already calls for macOS-compatible openrsync coverage. AD-9’s reuse direction is grounded in current code.

### T3.4 — Secure artifacts and machine framing primitives

- `player_secure_temp_create` uses `umask 077`, portable `mktemp` templates, and protected-root exclusion. The snapshot/rule writers layer checked stage-then-move publication on those artifacts.
- Unit Separator plus LF framing is compatible with the repository’s existing control-character rejection and line-oriented snapshot formats. AD-5 still needs explicit protocol size/lifecycle tests, but it does not require an unavailable OS primitive.

## Final gate condition

Do not finalize AD-4 until T1.1 and T1.2 are replaced with an implementable, testable Unicode/text policy. T2.1–T2.3 may remain concise, but their version, lifecycle, and platform proof boundaries must be binding rather than implied by Deferred or generic injected tests.
