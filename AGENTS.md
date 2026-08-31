<!-- bmad:context -->
<!-- Verified 2026-08-29 against 2601437. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## audlint-cli

Source-available Bash 5 and Python CLI/TUI for inspecting and maintaining local music libraries. BMAD Core+BMM is the only AI development harness; configuration lives in `_bmad/` and planning/implementation artifacts live in `_bmad-output/`.

## Policy

- Do not use MCP servers or MCP-backed knowledge stores; use the local shell and repository files.
- Do not read, create, or restore runbook files. Put product intent in BMAD artifacts and implemented behavior in code, tests, and focused public docs.
- Never operate on a real music library, live SQLite database, mounted sync destination, or destructive audio/tag/artwork workflow without explicit user approval; use temporary fixtures for automated verification. See [ADR-0004](docs/decisions/0004-ADR-real-resource-verification-safety.md).
- Do not treat BMAD planning output as implemented behavior; verify claims against current code and tests.

## Where things are

- Executable commands: `bin/`; keep entry scripts thin.
- Shared shell policy and mechanics: `lib/sh/`; shared Python analysis: `lib/py/`.
- Core, legacy, portability, and distro checks: `test/`.
- Current implemented architecture and cross-component contracts: `docs/architecture/OVERVIEW.md`.
- BMAD installation and team customization: `_bmad/`; generated tool skills: `.agents/skills/` and `.claude/skills/`.
- Public usage documentation: `README.md` and `docs/`.

## Running and verifying

- Prefer the closest targeted unittest while iterating; the complete local suite takes about six minutes.
- No CI workflow is currently tracked, so local Makefile checks are the release gate. The fail-closed source audit is governed by [ADR-0005](docs/decisions/0005-ADR-source-control-safety-gate.md).

## Conventions that differ from defaults

- Extend an existing helper in `lib/sh/` or `lib/py/` instead of duplicating parsing, encoding, artwork, SQLite, or terminal UI policy in an entry script. See [ADR-0006](docs/decisions/0006-ADR-shell-python-responsibility-boundary.md).
- Preserve Bash 5 plus macOS/Linux portability, including BSD/GNU command differences and portable `mktemp` templates. See [ADR-0003](docs/decisions/0003-ADR-bash5-portability.md).
- Keep audio profiles in canonical `SR_HZ/BITS` form after shared normalization.

## Known pitfalls

- Confirm the working directory is `audlint-cli` before reading project instructions; a prior session restored an unrelated repository from injected context.

<!-- /bmad:context -->

---

## Human-Readable Artifact Style

**BMAD artifact readability:** All human-readable planning/specification artifacts
must use concise plain English. Preserve required BMAD headings, schemas,
identifiers, code/API names, and technical precision, but avoid methodology
jargon and abstract enterprise language where ordinary words work. Explain
unavoidable specialist terms on first use. Prefer concrete statements about
what the software does, what changes, what must remain unchanged, and how
success is verified. Do not make artifacts longer merely to explain terminology.

When presenting a BMAD artifact to the user, summarize it first in plain English:
what is wrong, what is changing, what is not changing, and how the change will be
proven to work. Show technical details only where the user needs them to make a
decision.

---

## Release Branch Policy

- `main` represents the stable released state.
- Prepare each release on a temporary `release/<version>` branch created from `main`.
- During release preparation, treat the release branch as the integration target instead of `main`.
- Do not merge or push release-preparation changes to `main` without explicit operator approval.
- After final verification, stop for approval before merging the release branch into `main`.
- Delete the temporary release branch after the release is completed.
