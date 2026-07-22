# AI Handoff

## Status
- State: WAITING_FOR_USER
- Waiting For: User
- Last Updated By: User
- Last Updated At: YYYY-MM-DD
- Current Task: Initial setup

## Last Update
- Actor: User
- Date: YYYY-MM-DD
- Task: Installed the Codex-Claude handoff protocol files.

## Task Actors
- Implementer: Claude Code
- Reviewer: Codex

## Done
- Installed the project-local protocol and both Skill entry points.
- Added local coordination files and their `.gitignore` rules.
- Kept root `AGENTS.md` and `CLAUDE.md` unchanged in default opt-in mode.

## Changed Files
- None yet

## Verification
- Commands Run: [list commands, or "none - documentation change"]
- Build: [result or not run]
- Lint: [result or not run]
- Tests: [result or not run]
- Manual Check: [expected vs actual, or not applicable]

## Dialogue / Open Questions
- None
- (When State is QUESTION_FOR_MASTER, QUESTION_FOR_IMPLEMENTER, or RE_GATE_REQUESTED, log one scoped exchange per turn here. Format: "[Q <Asker> -> <Responder>] ..." then "[A <Responder>] ..." - works both directions: "[Q Implementer -> Master] ..." / "[A Master] ..." for QUESTION_FOR_MASTER, and "[Q Master -> Implementer] ..." / "[A Implementer] ..." for QUESTION_FOR_IMPLEMENTER. Each exchange is a discrete turn; no auto-loop.)

## Open Issues
- Define the first task for the Master or the Implementer.

## Risks / Notes
- `AI_HANDOFF.md` is dynamic and may contain local project context. Decide whether to keep it out of Git.
- Stable files under `.agents/`, `.ai/`, `.claude/`, and `scripts/` should be reviewed and committed after setup.

## Next Recommended Step
- User: ask the Master to analyze the next task, or set `State: NEEDS_ANALYSIS` / `Waiting For: Master` with a specific task.
- For risky tasks (migrations, auth, architecture changes), the Master may set `State: PLAN_REQUIRED` to require a plan before implementation.
- For tasks with missing information, the Master may set `State: NEEDS_INVESTIGATION` to gather evidence first.
