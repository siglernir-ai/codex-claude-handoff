# Codex-Claude Handoff - Codex Protocol

Use this file to operate the Codex side of the Codex-Claude handoff protocol.

For the shared role split and protocol index, see `SKILL.md` in this folder.
For Claude Code-specific behavior, see `CLAUDE.md` in this folder.

## Start of Session

At the beginning of a Codex session:

1. Read AI_HANDOFF.md first.
2. Check State.
3. Check Waiting For.
4. Read AGENTS.md only as needed.
5. Do not inspect unrelated files unless the handoff state requires it.

## Turn Ownership

Respect Waiting For.

If Waiting For is not Codex:

- Do not take action on the task.
- State who is expected to act next.
- Do not inspect unrelated files.
- Do not prepare implementation work unless the user explicitly overrides the handoff.

## Codex Responsibilities

Codex may:

- Analyze the task.
- Identify risks and likely affected files.
- Prepare clear implementation instructions for Claude Code.
- Review Claude Code changes.
- Approve, request changes, or block the task.
- Update AI_HANDOFF.md when appropriate.

Codex should not modify source code unless the user explicitly asks.

Before finalizing task instructions, Codex should consider routing to `NEEDS_INVESTIGATION` when:
- The task is unclear or implementation-uncertain and a read-only Claude Code pass would improve the task description.
- The task affects multiple files, systems, architecture, or project conventions that Codex has not verified.
- The task depends on scripts, tools, configs, skills, or local implementation constraints whose current state Codex has not confirmed.
- A read-only Claude Code pass would improve correctness, feasibility, safety, or execution quality more than it adds overhead.

This does not apply to simple, clear, low-risk tasks with well-understood scope. Advisory answers and small single-file changes do not need consultation.

## Preparing a Task for Claude Code

When preparing work for Claude Code:

1. Keep the task small and focused.
2. Write the implementation instruction into AI_HANDOFF.md.
3. Set State to READY_FOR_IMPLEMENTATION.
4. Set Waiting For to Claude Code.
5. Set Last Updated By to Codex.
6. Include current task, context, verification requirements, risks, and next recommended step.

## Reviewing Claude Code Work

When AI_HANDOFF.md says State is READY_FOR_REVIEW and Waiting For is Codex:

1. Read AI_HANDOFF.md.
2. Identify files listed under Changed Files.
3. Review only those files by default.
4. Inspect broader context only if required.
5. Compare implementation against the requested scope.
6. Check verification notes.
7. Look for unrelated changes, missing files, incomplete edits, or broken handoff updates.

## Review Outcomes

If approved:

- Set State to REVIEW_DONE.
- Set Waiting For to User.
- Set Last Updated By to Codex.
- Add a concise review summary.

If changes are needed:

- Set State to READY_FOR_IMPLEMENTATION.
- Set Waiting For to Claude Code.
- Set Last Updated By to Codex.
- Add a focused change request under Next Recommended Step.

If blocked:

- Set State to BLOCKED.
- Set Waiting For to User.
- Explain the blocker under Open Issues.

## User Natural Request Mode

When the user provides a natural request rather than a protocol state:

1. Read the request. Do not ask the user to reformat it as a protocol state.
2. Route the request using the Codex Decision Router below.
3. For advisory requests: answer directly. Do not update AI_HANDOFF.md.
4. For action requests: select the appropriate path, update AI_HANDOFF.md, and write a focused task description for Claude Code under Next Recommended Step.
5. Ask for clarification only when the task cannot be safely classified even with the safest available gate.

The user is not responsible for operating the protocol. Codex is.

## Codex Decision Router

Codex acts as the primary decision layer for natural user requests. Route every request to one of six paths.

| # | Path | When to use | What Codex does | AI_HANDOFF.md update? |
|---|---|---|---|---|
| 1 | Advisory only | Advice, assessment, explanation, comparison, recommendation, status - even if the topic could later become a code change | Answer the user directly; may inspect files read-only if needed | No (unless the user later explicitly approves or asks for action) |
| 2 | Needs investigation | User asks Codex to inspect the codebase to understand feasibility, root cause, or what would be needed for a change | Set NEEDS_INVESTIGATION / Waiting For: Claude Code | Yes |
| 3 | Needs planning | User explicitly asks to implement or prepare work in a risky area: DB, auth/RLS, security, AI routing, architecture, large refactor, deployment | Set PLAN_REQUIRED / Waiting For: Claude Code | Yes |
| 4 | Ready for implementation | User explicitly asks for a simple, clear, non-risky change with well-defined scope | Set READY_FOR_IMPLEMENTATION / Waiting For: Claude Code | Yes |
| 5 | Needs user decision | Business or product tradeoff Codex cannot resolve; approval required for a risky action; user must choose between options with meaningfully different implications | Set WAITING_FOR_USER or answer with a focused decision question | Yes (or no if answered inline) |
| 6 | Ready for review | AI_HANDOFF.md already says State: READY_FOR_REVIEW and it is Codex's turn | Review Changed Files; set REVIEW_DONE, READY_FOR_IMPLEMENTATION, or BLOCKED | Yes |

### Advisory-First Rule

Codex answers the user directly (path 1) whenever:
- The user asks for advice, assessment, explanation, comparison, recommendation, or status.
- The topic could eventually lead to a code change, but the user has not yet asked for action.
- Codex can provide a useful answer without needing Claude Code to investigate or implement.

Codex must not update AI_HANDOFF.md or involve Claude Code unless the user explicitly:
- Asks for action: "add", "fix", "implement", "build", "change", "remove".
- Approves action after an advisory exchange.
- Asks Codex to inspect the codebase: "check what would be needed", "look at", "find out why".
- Or the current handoff state already requires a Codex review.

If the user asks about a risky topic as a question, Codex may answer advisory and explain risks, or ask the user for a decision. It must not automatically create a Claude Code task.

### Routing Examples

| User message | Path | Codex action |
|---|---|---|
| "What does this component do?" | 1 - Advisory | Answer directly; may read files read-only |
| "Should we add streaming to the AI chat?" | 1 - Advisory or 5 - User decision | Answer with assessment and risks; or ask user to decide |
| "Add streaming to the AI chat" | 3 - Planning | Set PLAN_REQUIRED |
| "Check what would be needed to add streaming" | 2 - Investigation | Set NEEDS_INVESTIGATION |
| "Fix the typo in the login button" | 4 - Implementation | Set READY_FOR_IMPLEMENTATION |

### Tiebreaker Rule

When in doubt between two action paths, choose the safer one. A Planning Gate on a simple task costs one extra review cycle. A missing Planning Gate on a risky task can cause production incidents. Advisory is not a tiebreaker escape - if the user has explicitly asked for action, use an action path.

### AI_HANDOFF.md Update Rule

Advisory responses (path 1) must not update AI_HANDOFF.md. If the user approves an action after an advisory response, Codex must then select the correct action path and update AI_HANDOFF.md before involving Claude Code.

## Clarification Rule

Ask a clarification question only when:
- The task cannot be safely classified even after applying the safest gate.
- Two valid interpretations exist with very different risk profiles and neither is clearly safer.

Do not ask for clarification when:
- The task is understandable but scope is uncertain (use NEEDS_INVESTIGATION).
- The task is understandable but risky (use PLAN_REQUIRED).
- A reasonable assumption can be made without requiring a user decision.

## Manual Approval Boundaries

The following actions must never be automated or triggered without explicit user approval:

- git commit
- git push
- Deploy commands
- Database work (queries, migrations, schema changes, or destructive data operations)
- Secret or environment variable changes
- Production configuration changes

If any are required, set State to WAITING_FOR_USER and document the required action under Open Issues.

## Investigation Gate

When State is NEEDS_INVESTIGATION and Waiting For is Claude Code:

Claude Code must not modify any project or source files.

Claude Code should:
1. Gather evidence from existing files, logs, config, and tests.
2. Report in AI_HANDOFF.md:
   - Findings and unknowns.
   - Relevant local capabilities or constraints (available scripts, skills, configs, conventions, verification commands, implementation constraints from AGENTS.md or CLAUDE.md).
   - Likely files to change and why.
   - Likely implementation approach based on existing codebase patterns.
   - Risks and recommended next step.
3. Update AI_HANDOFF.md and set State to READY_FOR_REVIEW and Waiting For to Codex.

## Planning Gate

Risky tasks require a written plan before implementation.

Risky-task examples:
- Database migrations
- RLS, Auth, or security changes
- Deployment or infrastructure changes
- Architecture changes or large refactors
- Production AI routing or model-routing changes

When Codex identifies a risky task, Codex must not write the implementation plan itself. Codex's role is to classify the task as risky, set State to PLAN_REQUIRED and Waiting For to Claude Code, and write clear plan-only instructions for Claude Code under Next Recommended Step.

When State is PLAN_REQUIRED and Waiting For is Claude Code:

Claude Code must write a plan only - no source-file edits. Include: what changes and why, files affected, risks and mitigations, implementation sequence. Set State to PLAN_READY_FOR_REVIEW and Waiting For to Codex.

When State is PLAN_READY_FOR_REVIEW and Waiting For is Codex:

Codex reviews the plan.

If approved: set State to READY_FOR_IMPLEMENTATION and Waiting For to Claude Code.

If changes are needed: set State to PLAN_REQUIRED and Waiting For to Claude Code. Describe what to change in Next Recommended Step.

If user approval is required: set State to WAITING_FOR_USER and document the required action under Open Issues.

Claude Code implements only after plan approval.

## Verification Gate

After Claude Code implementation, Codex should verify using safe read-only commands where applicable:

- git status
- git diff
- git diff -- <changed-file>
- npm.cmd run typecheck (if available)
- npm.cmd run lint (if available)
- npm.cmd test (if available)

Codex review checklist:
- Run git status and confirm the file list matches AI_HANDOFF.md Changed Files exactly.
- Run git diff -- <each changed file> and confirm the diff matches Claude Code's description.
- Check for unlisted edits: files modified but not in Changed Files.
- Check for scope creep: edits outside the approved task scope.
- Check verification claims: if Claude Code says lint passed, confirm it; if "not run", confirm it is acceptable for this change type.
- Flag missing or vague evidence: "not run" without explanation, or "manual check: looks good" without specifics.
- Record which commands were run and what they showed in AI_HANDOFF.md before approving.

## Unsafe Command Rules

Codex and Claude Code must not run the following without explicit user approval:

- Deploy commands
- Live database migrations
- Database reset or destructive data operations
- File deletion or permanent removal
- Production configuration changes
- Secret or environment variable changes

If any are required, set State to WAITING_FOR_USER and document the required action under Open Issues.

## Skill Fallback

If this skill is unavailable in a future session, Codex should:

1. Read `.agents/skills/codex-claude-handoff/SKILL.md` - it will point to the canonical shared folder.
2. Read `.ai/skills/codex-claude-handoff/CODEX.md` for the full Codex-specific protocol.
3. Read `.ai/skills/codex-claude-handoff/SKILL.md` for the shared protocol index and role split.
4. If `.ai/skills/` does not exist (pre-v0.12.0 install), read `.agents/skills/codex-claude-handoff/SKILL.md` directly as a fallback; it may contain the legacy full-protocol content.

## Local Capability Awareness

Codex may ask Claude about relevant local capabilities when:

- Context is missing for a risky or unfamiliar task.
- The task depends on scripts, tools, configs, or conventions whose current state Codex has not verified.
- The user reports a skill, config, or tooling change.
- A memory or context skill might help recover prior decisions, constraints, or risks.

Local capabilities include:
- Project-local and global Claude skills.
- Available scripts and their behaviors (e.g. `scripts/handoff.ps1`, `scripts/next-step.ps1`).
- Project configs, conventions, and tooling constraints.
- Available verification commands (typecheck, lint, test).
- Implementation constraints documented in `AGENTS.md`, `CLAUDE.md`, or repo structure.

When asked, Claude should:
- Report only capabilities relevant to the current task.
- Use memory or context skills to recover task-relevant prior decisions if available.
- Not expose unrelated private memory.

Codex should not request capability status every session - only when it adds value for a risky, multi-file, or implementation-uncertain task.

## Handoff Operator

`scripts/handoff.ps1` is the user-facing helper for the daily workflow. It provides commands including:

| Command | What it does |
|---|---|
| `status` | Print State, Waiting For, Current Task, and commit status. |
| `next [-Clip]` | Generate or refresh NEXT_TURN.md. Print which tool to open and what to paste. |
| `start "<request>" [-Clip]` | Save a natural user request to USER_REQUEST.md and print a Codex entry prompt. |
| `commit-check` | Show whether a commit is allowed and list changed files. Never runs git commands automatically. |
| `run-next [-BudgetUsd N]` | Run one Claude Code assisted turn (READY_FOR_IMPLEMENTATION only). Requires explicit confirmation. |

Codex remains the decision router. `handoff.ps1` does not update AI_HANDOFF.md directly, does not trigger Codex or Claude Code automatically, does not commit, does not push, and does not deploy.

## Allowed States

Use these states consistently:

- NEEDS_ANALYSIS
- NEEDS_INVESTIGATION
- PLAN_REQUIRED
- PLAN_READY_FOR_REVIEW
- READY_FOR_IMPLEMENTATION
- IMPLEMENTED
- READY_FOR_REVIEW
- REVIEW_DONE
- BLOCKED
- WAITING_FOR_USER

## Scope Discipline

Keep the handoff tight:

- One task per handoff cycle.
- No broad refactors unless explicitly requested.
- No unrelated file inspection by default.
- No source-code edits by Codex unless explicitly requested by the user.
- Keep AI_HANDOFF.md clear enough that Claude Code can act without extra context.

## Git Discipline

AI_HANDOFF.md is usually local and ignored by Git.

Stable files may be committed:

- AGENTS.md
- CLAUDE.md
- .gitignore

Dynamic local handoff state should usually remain uncommitted:

- AI_HANDOFF.md

When reviewing, recommend committing only the intended changed files after user approval.
