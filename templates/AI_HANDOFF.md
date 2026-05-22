# AI Handoff

## Status
- State: WAITING_FOR_USER
- Waiting For: User
- Last Updated By: User
- Last Updated At: YYYY-MM-DD
- Current Task: Initial setup

## Last Update
- Tool: User
- Date: YYYY-MM-DD
- Task: Installed the Codex-Claude handoff protocol files.

## Done
- Added `AGENTS.md`
- Added `CLAUDE.md`
- Added `AI_HANDOFF.md`
- Added `.gitignore` rule to keep `AI_HANDOFF.md` local/private if desired

## Changed Files
- None yet

## Verification
- Build: not run
- Lint: not run
- Tests: not run
- Manual Check: protocol files installed

## Open Issues
- Define the first task for Codex or Claude Code.

## Risks / Notes
- `AI_HANDOFF.md` is dynamic and may contain local project context. Decide whether to keep it out of Git.
- `AGENTS.md` and `CLAUDE.md` are stable protocol files and should usually be committed.

## Next Recommended Step
- User: ask Codex to analyze the next task, or set `State: NEEDS_ANALYSIS` / `Waiting For: Codex` with a specific task.
- For risky tasks (migrations, auth, architecture changes), Codex may set `State: PLAN_REQUIRED` to require a plan before implementation.
- For tasks with missing information, Codex may set `State: NEEDS_INVESTIGATION` to gather evidence first.
