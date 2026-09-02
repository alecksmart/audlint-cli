# Technology Reality Closure Review

## Verdict

**Changes required.** The revision resolves the original critical gaps: Unicode segmentation now has versioned repository-owned data, libc and undeclared packages no longer define width, Python Unicode-version variance is explicit, the persistent process has a failure lifecycle, macOS/Linux production probes are required, and accepted SQLite/player/virtwin helpers remain the implementation seed. One high and two medium ambiguities remain.

Review evidence is limited to the repository and local runtimes. The local Python set spans 3.11.15/Unicode 14.0.0 through 3.14.5/Unicode 16.0.0; Bash 5.3.15 passes the 100-check repository gate.

## High

### TRC-1 — The conservative cell-width rule is internally contradictory

**Evidence:** AD-4 first says a cluster is two cells if it contains any East Asian Ambiguous, Wide, or Fullwidth scalar, then says combining and format continuations add zero. Unicode 14 classifies ordinary combining marks such as U+0301 COMBINING ACUTE ACCENT and U+0308 COMBINING DIAERESIS as East Asian Ambiguous. Therefore the literal first rule makes `e + U+0301` two cells, while the continuation rule makes the same cluster one cell. Variation Selector-16 is also both combining and East Asian Ambiguous. The rule does not state precedence. It also says unsupported clusters use “fixed-width replacement cells” without fixing that width.

**Impact:** Independent model, clipping, caret, and PTY-oracle implementations can produce different widths for the exact combining/emoji cases the contract requires. A shifted search caret or premature/late clipping remains possible even though libc was removed.

**Required correction:** Define width over grapheme roles, not “any scalar”: state whether only the cluster’s printable base participates in East Asian Width, define explicit emoji/variation/keycap handling, make combining/format precedence unambiguous, define the no-base case, and fix the replacement-cluster width numerically. Add explicit expected-width fixtures for `e\u0301`, VS15/VS16 text/emoji presentation, keycaps, flags, modifiers, ZWJ emoji, CJK, and an Ambiguous base.

## Medium

### TRC-2 — Protocol artifacts have schemas but no secure publication/ownership lifecycle

**Evidence:** AD-5 sends inventory, event/effect, frame, and effect artifacts by filesystem path. The model returns `STATE(frame-artifact, …)`, so at least frame artifacts appear model-created. The rule requires rejection of truncation/oversize but does not say which side allocates each path, where it may live, how restrictive permissions and protected-root exclusion are enforced, how completeness becomes atomic, or which side removes it after success, rejection, timeout, crash, and `STOP`. The existing `player_secure_temp_create` is a Bash player helper; it is not directly callable from the Python model. Current player snapshot writers prove a safe create/stage/move pattern, but the revised protocol does not adopt that pattern explicitly.

**Impact:** Implementations can disagree on producer/consumer ownership, observe partially written frames, leak one artifact per event, or create protocol files under unsafe locations. Truncation detection alone does not make publication atomic.

**Required correction:** Assign allocation, publication, validation, and cleanup per artifact direction. The simplest compatible rule is controller-created secure paths outside protected roots, passed to the model for checked stage-then-atomic-replace publication, followed by consumer-owned unlink in every terminal path. If the model allocates instead, bind an equivalent repository-owned Python helper and return only validated paths within its owned temporary directory.

### TRC-3 — Unicode-data floor and fallback conflict at startup

**Evidence:** AD-4 says the configured Python “must expose Unicode data `>=14.0.0`,” then says a Unicode-data incompatibility selects ASCII glyphs, replacement rendering, and ASCII-only search. AD-10 requires checks for both the Unicode-data floor and fallback, but does not resolve whether a runtime below 14.0 is rejected, enters degraded mode, or is supported. The repository currently documents only generic Python 3, while the supported distro baselines are new enough to meet Unicode 14.

**Impact:** The controller startup path and acceptance tests can legitimately choose incompatible outcomes for the same configured interpreter. A degraded mode would also contradict a hard minimum unless it is explicitly an unsupported emergency behavior.

**Required correction:** Choose one policy: either reject selector entry below Unicode 14 with bounded feedback and reserve fallback for locale/rendering incompatibility, or explicitly support a degraded ASCII mode below the floor and remove “must.” Record the version comparison as parsed numeric components and route interpreter selection through `AUDL_PYTHON_BIN`; the existing NumPy-specific selector is not the right gate.

## Closed findings

- **Grapheme implementability:** checked-in Unicode 14 Grapheme Break and Extended Pictographic ranges plus UAX #29 conformance fixtures are sufficient to implement segmentation without runtime `regex` or `wcwidth`.
- **Unicode version variance:** NFC/full-casefold for post-14 characters is explicitly runtime-relative; cross-version byte identity is no longer implied.
- **Persistent process:** one outstanding request, unbuffered launch, descriptor closure, timeout/EOF/crash handling, ambiguous-commit behavior, child termination/reaping, and terminal-finalizer ordering are now binding and locally feasible with Bash 5.
- **Portability proof:** AD-10 now requires the Bash gate and affected macOS/Linux checks to exercise the production Unicode floor/fallback, cell policy, protocol lifecycle, and key parser.
- **Accepted helper reuse:** AD-3 extends the existing SQLite transaction owner; AD-7 extends virtwin geometry without adding a second scroll owner; AD-9 reuses the implemented file-backed snapshot/filter/root-rsync/postcheck pipeline without an alternate walk or rule array.

## Closure condition

Resolve TRC-1 before finalization. TRC-2 and TRC-3 also belong in the spine because they determine cross-language interoperability and startup behavior; they are not merely helper-level implementation choices.
