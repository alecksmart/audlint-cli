# ADR-0003: Require Bash 5 with macOS and Linux Portability

## Status
Accepted

## Record type
Historical

## Context
Audlint is primarily a shell CLI/TUI and uses Bash 5 features. It is installed and exercised on macOS and Linux distributions whose standard utilities differ in path, option, and temporary-file behavior.

## Decision
Require Bash 5 for shell entry points and shared shell libraries. Preserve supported macOS and Linux behavior through BSD/GNU-compatible helpers, portable path and temporary-file handling, and distro-focused checks. Keep Bash-version, shebang, feature, and parse consistency in the local release gate.

## Evidence
- `AGENTS.md:29-33` explicitly requires Bash 5 plus macOS/Linux portability; commit `4aa2e7ca095ddea32bf7ede365c4e95f281cf88c` records that repository policy.
- `README.md:64-109` requires Bash 5 and documents macOS, Debian/Ubuntu, and Fedora setup.
- `Makefile:119-144` includes `bash5-check` in `make check`.
- `test/sh/bash5_consistency.sh:3-10,92-99,155-168` identifies itself as the Bash 5 migration guard and probes the required features.
- `test/test_bootstrap_portability.py:42-149` verifies BSD/GNU utility fallbacks.
- `test/distro/debian12_check.sh:12-28`, `test/distro/ubuntu24_check.sh:12-28`, and `test/distro/fedora41_check.sh:12-27` exercise supported Linux environments.
- The Bash 5 guard first appears in retained history at commit `b67676a502d9810cd7a84bca37aaaedd11a58b5d`.

## Rationale
The repository explicitly records Bash 5 migration consistency and cross-platform support. The README directs systems with an older Bash to use a package-managed Bash. Original rationale is not recoverable from repository evidence.

## Consequences
- Implementations may use the Bash 5 features covered by the consistency guard.
- Bash 3 compatibility is not required.
- Cross-cutting shell changes must account for BSD/GNU differences and portable temporary-file and path behavior.
- Portability verification is split between local tests and separate Linux Docker checks.

## Alternatives
None recovered from repository evidence.

## Related decisions
- [ADR-0006: Prefer the Shell Orchestration and Python Computation Boundary](0006-ADR-shell-python-responsibility-boundary.md)
