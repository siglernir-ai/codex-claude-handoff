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

### Keys and MCP connections

Agents must never open files that hold credentials. Since v3.9.0 the protocol enforces
that in three places:

- **Before a turn.** The installer adds deny rules to `.claude/settings.json`, so Claude
  Code's file tools cannot open `.env`, `.env.local`, `.mcp.json` or
  `.codex/config.toml`. The programs that use those files still load them. Codex exposes
  no documented per-path read deny, so this layer covers Claude Code only.
- **After a turn.** Every automated turn's local captures are searched for credential
  shapes. A match is redacted in place and the run stops with exit 13: a key that passed
  through an agent session is exposed, so rotate it.
- **In `doctor`.** MCP configuration that holds a key as literal text is reported, and so
  are missing deny rules. Values are never printed.

Prefer an MCP server's browser (OAuth) login where it has one, so no key is stored at
all. Otherwise keep the key in an environment variable and reference it by name -
`${NAME}` in Claude Code's `.mcp.json`, `env_http_headers` or `bearer_token_env_var` in
Codex's `config.toml` - so one variable serves both tools and no file holds the value.

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

The v3.4.0 Skill package is self-contained. Its first-use setup runs a bundled local
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
