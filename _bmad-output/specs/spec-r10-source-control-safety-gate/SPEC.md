---
id: SPEC-r10-source-control-safety-gate
companions:
  - source-control-safety-policy.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# R10 Source-Control Safety Gate

## Why

Generated corpus artifacts containing private media-library metadata reached Git history. Rewriting the branch, making the repository private, and ignoring the known output directory contained the incident but did not prevent similar content from being committed: ignored files can be force-added, specialist secret scanners do not reliably recognize music-library metadata, and the release gate does not inspect commit candidates. Audlint maintainers need a deterministic local audit that blocks unsafe repository content without repeating it in diagnostics.

## Capabilities

- **CAP-1**
  - **intent:** Maintainers can invoke one authoritative source-control audit directly and receive a deterministic verdict.
  - **success:** Zero-argument `bin/audlint-source-audit.sh` audits every authoritative source with byte-identical ordered output for identical inputs; `--prospective` provides a separate non-authoritative index-only remediation view and `--help` is the only other accepted argument.

- **CAP-2**
  - **intent:** The authoritative release ceremony includes the source-control audit after the existing test target without changing that target.
  - **success:** `make test` still runs the core and legacy test suites, while `make check` preserves its existing checks, completes `make test`, then invokes `make source-audit` in that order even under parallel Make.

- **CAP-3**
  - **intent:** The audit evaluates every in-scope repository state that can contribute unsafe committed content.
  - **success:** Temporary-repository tests independently detect findings in current `HEAD`, the full Git index, modified tracked files, effectively non-ignored untracked candidates, and protected or repository-ignored tracked paths; an unsafe `HEAD` remains blocking after an index repair, and unborn `HEAD` is handled as an empty source.

- **CAP-4**
  - **intent:** The audit applies an Audlint-owned, portable version-1 policy for unsafe paths, artifacts, secrets, machine paths, and private media metadata.
  - **success:** Implementation-owned algorithms and mandatory catalog members, strict indexed policy schemas, parsing boundaries, aggregate limits, and Git-state behavior in `source-control-safety-policy.md` produce the same verdict on supported macOS and Linux environments using only synthetic positive and negative fixtures; policy data cannot weaken the mandatory floor or supply executable patterns.

- **CAP-5**
  - **intent:** Maintainers can locate and review every finding or execution error without the audit disclosing matched evidence.
  - **success:** Deterministic JSONL records preserve the permitted repository-relative path while tests prove that complete secret, metadata, private-key, machine-path, absolute-repository-path, and raw-tool-error values are absent from both output streams.

- **CAP-6**
  - **intent:** Maintainers can approve one narrow occurrence without storing the sensitive value or suppressing another occurrence.
  - **success:** A staged, reviewed allowlist entry matching exact rule, encoded repository-relative path, and occurrence fingerprint suppresses only the unchanged exemptible finding across sources; path, mode, content, record, or occurrence changes invalidate it, while source movement alone does not.

- **CAP-7**
  - **intent:** Maintainers can prove and adopt the gate safely without private or live data.
  - **success:** Fixture-only verification covers all companion cases; after policy, allowlist, implementation, documentation, and tests are staged, a new redacted authoritative audit records an exact reviewed disposition for every finding and the complete `make check` passes without broad baselines, private inputs, or changes to R3 behavior.

## Constraints

- Exit status is `0` when clean, `1` when findings exist, and `2` for usage, policy, Git, containment, resource, mutation, or execution errors.
- Authoritative mode always evaluates current `HEAD` independently. `--prospective` evaluates only the complete index, is never authoritative, and is never used by `make check`.
- Enumeration starts at the Git top level, retains raw repository-relative path bytes, does not follow symlinks, does not open paths outside the repository, and never enumerates or mentions effectively ignored untracked files.
- Protected or repository-ignored tracked paths are decided from minimal Git path, mode, and object-identity metadata; no worktree or Git-blob content is read for those candidates.
- Runtime policy and reviewed exceptions come only from stage-0 index blobs for `.audlint-source-audit-policy.json` and optional `.audlint-source-audit-allowlist.json`, both in Git mode `100644`; matching contained regular non-symlink worktree copies are mandatory.
- The implementation owns fixed matching algorithms, mandatory rule and catalog members, bootstrap ceilings, and security minimums. Indexed policy may add only validated declarative values under those primitives and may not execute regular expressions or weaken the floor.
- Audit phases, Git routing, collision namespaces, POSIX symlink evaluation, occurrence ordering, and all per-candidate and aggregate limits follow the exact fail-closed companion contract.
- Version one has no network or third-party runtime dependency. It uses Bash 5, Git, Python 3 standard-library facilities, and existing repository tooling with supported macOS/Linux behavior.
- The executable entry stays thin; reusable scanning and policy behavior belongs in `lib/py/` or `lib/sh`. The developer-only entry is not installed as a product command.
- Verification uses only temporary Git repositories and synthetic strings. It never reads a real music library, live SQLite data, mounted sync destinations, the operator-designated mounted test-library path, or ignored benchmark artifacts.
- R10 remains separate from R3. Existing product commands, `make test`, R3.1–R3.5, benchmarking, staging, instrumentation, finalization, and analyzer behavior remain unchanged.
- Git hooks are not installed or treated as the authoritative gate.

## Non-goals

- Copyright or legal-status adjudication.
- Malware scanning or general static application security testing.
- Dependency or CVE scanning.
- Network-backed scanning.
- Automatic cleanup commits, history rewriting, or repository visibility changes.
- Installing or managing Git hooks.
- Reading ignored private files.
- Replacing specialist secret scanners in every threat class.

## Success signal

A maintainer can stage the strict policy and any reviewed exact exceptions, then run `bin/audlint-source-audit.sh`, `make source-audit`, or `make check`; unsafe content in any authoritative source stops the command with deterministic redacted records, while policy weakening and unsafe Git state fail closed. The unchanged tests run before the audit and a newly reviewed staged repository passes on macOS and Linux. `--prospective` can prove that a proposed index snapshot is clean without weakening the independently blocking `HEAD` verdict.
