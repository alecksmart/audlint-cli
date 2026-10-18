# ADR-0004: Keep Automated Verification Away from Real Operator Resources

## Status
Accepted

## Record type
Historical

## Context
Audlint can rewrite audio, tags, and artwork; mutate a SQLite catalog; and synchronize to mounted destinations. Those operations make ordinary automated verification unsafe when pointed at operator-owned resources.

## Decision
Do not run automated verification against a real music library, live SQLite database, mounted sync or backup destination, or destructive audio, tag, or artwork workflow. Use temporary fixtures and stub external tools. Require explicit human approval before operating on those real resources.

Narrow live integration checks must require a deliberate opt-in and must not be inferred safe merely because a command offers a dry-run mode.

## Evidence
- `AGENTS.md:8-13` records the rule as repository policy; commit `4aa2e7ca095ddea32bf7ede365c4e95f281cf88c` records that policy in retained history.
- `docs/architecture/OVERVIEW.md:91-99` documents current destructive-operation safeguards, test isolation, and the opt-in real-crontab exception.
- `test/test_sync_music_smoke.py:20-57,101-129` uses temporary source and destination fixtures and a stubbed rsync.
- `test/test_audlint_maintain_smoke.py:396-414` requires `AUDLINT_USE_REAL_CRONTAB=1` before the real-crontab test.
- At the time of this decision, `sync_music.sh --dry-run` still deleted source metadata files. The current implementation excludes those files from transfer without removing them; this historical observation remains the reason a dry-run label alone is not trusted.

## Rationale
The repository explicitly identifies the protected resource classes and the human-approval boundary. Original rationale is not recoverable from repository evidence.

## Consequences
- Default verification remains isolated and reproducible without risking operator media or destinations.
- Temporary fixtures and tool stubs are required even for destructive-path coverage.
- Ordinary tests cannot prove every behavior of real mounts, libraries, or databases.
- A command's dry-run label is not sufficient evidence that it is non-mutating.

## Alternatives
None recovered from repository evidence.

## Related decisions
None recovered from repository evidence.
