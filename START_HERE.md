# Start Here

Five minutes. Saves the two mistakes almost everyone makes.

## What this is

Two AI coding agents on one Git task with different jobs: one implements, a different
one reviews, and you approve. The point is not speed. The point is that no single agent
both writes the code and declares it good.

What it is **not**: not background automation, not a chat bridge between tools, and not
something that commits, pushes or releases on its own.

## The safety model

Three roles - **Master** routes, **Implementer** writes, **Reviewer** checks. The
Reviewer is never the same tool as the Implementer, enforced in code. You are not one
of the three: you are the approval authority. Commit, push, tag, release, deploy,
database changes and secrets all stop and wait for you, and commit and release each
require you to type an exact authorization string. No flag turns that off.

## What installing does

It copies protocol files into your project and stops. No hooks, no behavior change,
nothing activated. The skill only wakes when you select `codex-claude-handoff` in
`/skills`, mention `$codex-claude-handoff`, or name it. If nothing seems different
after installing, that is correct.

## Your first task

Run everything from your project root.

```powershell
.\scripts\handoff.ps1 doctor
.\scripts\handoff.ps1 start "add a health check endpoint"
.\scripts\handoff.ps1 work
```

`doctor` confirms the install, read-only. `start` opens one task, archiving any previous
one first. `work` is the command for whenever you are unsure: it prints the state and
the single next action.

Then `.\scripts\handoff.ps1 next` prints the prompt for the next agent, and says so if
that turn can run automatically. When the Reviewer approves:

```powershell
.\scripts\handoff.ps1 commit-approved -Message "your message" -Authorize "I_AUTHORIZE_COMMIT"
```

## It blocked me

It will. Blocking is the product, not a malfunction. These four come up first.

**`Role checkpoint: BLOCKED - the current role binding and AI_HANDOFF.md are out of sync.`**

The task on disk names different agents than your role configuration, usually left over
from a finished task. Retire it by opening the next one - the old record is archived
with a verified checksum first, so nothing is lost:

```powershell
.\scripts\handoff.ps1 start "your next request"
```

**`AI_HANDOFF.md Changed Files does not exactly match git status`**

What you declared and what you changed are different sets. See both lists side by side:

```powershell
.\scripts\handoff.ps1 commit-check
```

It prints "Files from AI_HANDOFF.md Changed Files" above "Git status files to commit".
Add the missing paths to the `## Changed Files` section of `AI_HANDOFF.md`, or drop the
stray change with `git checkout -- path/to/file`. Spell paths the way Git prints them:
repository-relative, forward slashes, no quotes, no leading `./`.

**`AI_HANDOFF.md must be State: REVIEW_DONE and Waiting For: User`**

You are committing before the Reviewer approved. Take the outstanding turn:

```powershell
.\scripts\handoff.ps1 review-run
.\scripts\handoff.ps1 review-apply
```

If your reviewer tool is not callable, use `.\scripts\handoff.ps1 next` and hand the
turn over manually. `work` tells you which case you are in.

**`WARNING: AI_HANDOFF.md was not reset because non-local working-tree changes exist.`**

A new task must start from a known state. Set your work aside, then run `start` again:

```powershell
git stash push -u -m "before handoff task"
```

`git stash pop` brings it back afterwards.

The rule behind all four: when the protocol cannot verify something, it stops instead of
guessing.

## Stopping and leaving

Automated turns are bounded before they start - a time limit, a turn limit and a spend
cap, all printed first. `.\scripts\handoff.ps1 status` says whether a turn is running.
`.\scripts\handoff.ps1 stop` ends one; it touches no Git state and no task state.

To remove the protocol, delete only the paths it owns. `.agents/` and `.claude/` are
shared directories that may hold other tools' configuration, so remove the protocol's
subfolder inside them, not the folder itself:

```
.ai/
.agents/skills/codex-claude-handoff/
.claude/skills/codex-claude-handoff/
scripts/handoff.ps1
scripts/handoff.sh
```

Then delete any coordination files left in the project root - `AI_HANDOFF.md`,
`AI_SEQUENCE.md`, `NEXT_TURN.md`, `USER_REQUEST.md`, `HANDOFF_RUN.json` - and drop the
`# Codex-Claude handoff protocol` block from `.gitignore`.

## Where next

- **Install or update it?** `QUICKSTART.md`
- **How does it work?** `HOW_IT_WORKS.md`
- **Which model per role?** `MODEL_GUIDANCE.md`
- **Everything, in detail.** `README.md`

## One honest expectation

This is slower than letting one agent do everything. That is the trade. Use it where
being wrong is expensive, and skip it where it is not.
