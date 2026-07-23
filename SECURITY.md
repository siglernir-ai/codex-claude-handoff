# Security and Trust Model

`codex-claude-handoff` is designed for supervised local development workflows.
It coordinates Codex and Claude Code through files in the user's project folder.

## Local Files

The workflow uses local coordination files such as:

- `AI_HANDOFF.md`
- `AI_SEQUENCE.md`
- `USER_REQUEST.md`
- `NEXT_TURN.md`
- `CODEX_REVIEW_LAST.md`
- `CLAUDE_IMPLEMENTER_LAST.md`
- `CLAUDE_IMPLEMENTER_COMMAND.md`

These files can contain task context, file names, command summaries, review notes,
and model evidence. They are added to `.gitignore` by the installer and should not
be committed.

## Approval Boundaries

The workflow is intentionally fail-closed around sensitive actions.

It must not perform these actions without explicit user authorization:

- Git commit.
- Git push.
- Git tag or release.
- Deployment.
- Database changes or migrations.
- Secret or token changes.
- Production configuration changes.
- Role swaps.

The `commit-approved` and release commands require exact authorization strings.
This is intentional. The user remains the approval point.

## Secrets

Do not paste secrets into `AI_HANDOFF.md`, `USER_REQUEST.md`, `NEXT_TURN.md`, or
agent chat windows unless your organization has explicitly approved that handling.

The workflow does not require `ANTHROPIC_API_KEY` for the default OAuth-based
Claude Code path. Avoid adding API keys only to make automation more convenient
unless you have reviewed your organization's secret-management policy.

## Command Transparency

Automated Claude Code turns capture sanitized command evidence. Prompt content and
system prompt content are redacted in command captures, while the shape of the
command remains visible for review.

The workflow may also capture model and subagent evidence when the tool exposes it.
This evidence is best-effort transparency, not a security boundary.

## Fresh Install Review

Before running this in a new project:

1. Inspect `QUICKSTART.md`.
2. Inspect `HOW_IT_WORKS.md`.
3. Run `scripts/handoff.ps1 doctor`.
4. Confirm `.gitignore` excludes the local coordination files.
5. Start with a small non-production task.

## skills.sh Public Beta Package

The v3.3.2 Skill package is self-contained. Its first-use setup runs a bundled local
installer and does not download or execute additional remote code. Setup requires an
existing Git repository and explicit user approval. It installs in opt-in mode, runs
`doctor`, and does not commit, push, tag, release, deploy, change databases, or change
secrets.

The same complete Skill payload is present in the Codex and Claude Code discovery
locations so either source selected by a compatible skills client has the installer
and templates it references. Users should pin a release tag for audited deployments
and review the Skill source before use.

## Reporting Issues

For the public beta, use the [GitHub bug-report form](https://github.com/siglernir-ai/codex-claude-handoff/issues/new?template=bug_report.yml)
for non-sensitive problems and include:

- The command that was run.
- The handoff state from `scripts/handoff.ps1 work`.
- `git status --short --branch`.
- Any non-secret error output.

Do not include credentials, proprietary customer data, private keys, access tokens,
or production secrets in issue reports.

Do not open a public issue for a suspected vulnerability or accidental secret
exposure. Use [GitHub Private Vulnerability Reporting](https://github.com/siglernir-ai/codex-claude-handoff/security/advisories/new)
instead. If that path is unavailable, contact the repository owner privately before
disclosing technical details.
