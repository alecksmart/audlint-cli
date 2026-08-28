# AI Development with BMAD

Audlint uses a pinned BMAD harness for AI-assisted planning, implementation,
and review.

## Installed baseline

- BMAD Core: `6.11.0`
- BMad Method (BMM): `6.11.0`
- Tool integrations: Claude Code and Codex
- Test Architect (TEA): not installed
- MCP servers: not used

Team configuration and installer-managed modules live in `_bmad/`. Generated
tool skills live in `.claude/skills/` and `.agents/skills/`. Personal settings
such as `_bmad/config.user.toml` and `.claude/settings.local.json` are ignored.

## Reinstall the pinned harness

Run from the repository root:

```bash
npx --yes bmad-method@6.11.0 install \
  --directory . \
  --modules bmm \
  --tools claude-code,codex \
  --yes --all-stable \
  --set core.project_name=audlint-cli \
  --set core.document_output_language=English \
  --set core.output_folder=_bmad-output \
  --set bmm.project_knowledge=docs
```

Do not add TEA or MCP integrations without an explicit project decision. The
existing Makefile and unittest suites remain the testing authority.

Start a fresh AI session in this repository and invoke `bmad-help`. Use the
smallest BMAD path that fits the work: `bmad-build` for one bounded change,
`bmad-spec` plus stories for an epic, and the full planning flow only for a
multi-epic product direction.

Do not hand-edit installer-managed files or generated skills. Put durable team
overrides in `_bmad/custom/` and rerun the pinned installer to refresh generated
content.
