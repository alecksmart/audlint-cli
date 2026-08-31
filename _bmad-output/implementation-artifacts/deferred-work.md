- source_spec: `_bmad-output/implementation-artifacts/spec-player-content-sync-flow.md`
  summary: Repair the source-audit Markdown-table parser or the pre-existing selected-size implementation spec so `make check` can complete its source-audit stage.
  evidence: `make check` ran all 470 tests successfully, then `bin/audlint-source-audit.sh` reproducibly failed with `AUDIT_PARSE_FAILED` while scanning the committed `_bmad-output/implementation-artifacts/spec-player-content-selected-size.md`, before the current sync-flow artifact.
