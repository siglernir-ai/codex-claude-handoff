# How It Works

`codex-claude-handoff` is a supervised workflow for using Codex and Claude Code in the same project.

It is not magic background autonomy. The tools coordinate through local files in the project folder.

## Shared Folder Model

Codex and Claude Code must both be opened on the same project directory.

The important files are:

- `AI_HANDOFF.md` - the source of truth for the current task, state, next actor, changed files, verification, and review result.
- `USER_REQUEST.md` - the latest natural-language request from the user.
- `NEXT_TURN.md` - a generated brief for the next actor.
- `.ai/roles/ROLE_ASSIGNMENT.md` - binds Master, Reviewer, and Implementer to concrete tools.
- `.ai/skills/codex-claude-handoff/` - the protocol instructions.
- `scripts/handoff.ps1` - the local helper command.

## Roles

- **Codex as Master** routes requests and writes clear task instructions.
- **Claude Code as Implementer** investigates or edits files.
- **Codex as Reviewer** checks scope and verification.
- **User** approves commits, pushes, tags, releases, deploys, secrets, and production decisions.

The Implementer never approves its own work.

## Switching Roles

Roles are not permanently tied to one tool. With explicit user approval, the current
Master updates `.ai/roles/ROLE_ASSIGNMENT.md` and synchronizes the derived Task Actors
in `AI_HANDOFF.md` in the same turn. The Reviewer must never equal the Implementer.
Every new turn rereads the role table and fails closed if the handoff is stale.

## Normal Flow

1. User starts a request with `handoff.ps1 start`.
2. Codex reads `USER_REQUEST.md` and `AI_HANDOFF.md`.
3. Codex routes the task to investigation, implementation, review, or user decision.
4. Claude investigates or implements.
5. Codex reviews.
6. User approves the guarded commit.

## Daily Commands

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 work
```

Use `doctor` when setup feels wrong.

Use `work` whenever you do not know the next step.

## Automation Boundary

`cycle` can run one automated Claude Code Implementer turn for either implementation
or read-only investigation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 cycle -Yes -BudgetUsd 2 -TimeoutSeconds 240
```

`cycle` still stops for Codex review and user commit approval. For one explicitly authorized
session, `loop -IncludeMaster -IncludeReviewer` can run Master -> Claude Implementer -> Codex
Reviewer and then stops at the user's commit approval.

`NEEDS_INVESTIGATION` no longer requires opening Claude Code manually. The bounded runner
uses Claude Code `--safe-mode` to disable ambient plugins and hooks, and it fails closed if
an investigation changes any non-handoff file.

On Windows, keep the full `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`
prefix shown above. It works when the current execution policy is `Restricted` without
changing the machine-wide policy.

This project is designed for supervised human-in-the-loop use, not full unattended autonomy.

## Safety Model

- No commit without `commit-approved`.
- No push/tag/release without explicit user authorization.
- No deploy, database, secret, or production configuration changes without user approval.
- No-op turns fail closed.
- Timeouts and non-zero exits fail closed. The v3.1.5 exact-scope recovery exception only
  routes proven correction work to independent review; it never converts a failed turn into
  approval. In v3.1.6, that Reviewer also verifies relevant safe local checks and blocks when
  preservation or backward-compatibility requirements are not adequately demonstrated.
- Safe recovery routes only to the independent Reviewer; it is never implementation approval.
- Any extra file, no-change turn, or malformed handoff remains blocked.

## Recommended Practice

- Keep Codex and Claude Code opened on the same project folder.
- Work on one handoff task at a time.
- Start small.
- Use `work` before guessing.
- Use `doctor` when something feels off.
- Treat `AI_HANDOFF.md` as local coordination, not a file to commit.
