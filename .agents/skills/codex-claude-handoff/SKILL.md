---
name: codex-claude-handoff
description: Use this skill when working in a project that coordinates Codex and Claude Code through AGENTS.md, CLAUDE.md, and AI_HANDOFF.md. Codex acts by default as advisor, architect, task writer, and reviewer while Claude Code acts as the implementation agent.
---

# Codex-Claude Handoff Skill

## Purpose

Use this skill to operate the Codex side of the Codex-Claude handoff protocol.

Default role split:

- Codex acts as advisor, architect, task writer, and reviewer.
- Claude Code acts as the implementation agent.
- The user remains the approval point.

This is the recommended default. A project may override it explicitly in AGENTS.md, CLAUDE.md, or AI_HANDOFF.md, but the override must be documented clearly.

## Required Project Files

When this protocol is active, expect these files in the project root:

- AGENTS.md
- CLAUDE.md
- AI_HANDOFF.md

Use AGENTS.md for Codex behavior, project context, architecture rules, and review rules.

Use CLAUDE.md for Claude Code behavior.

Use AI_HANDOFF.md for current state, current task, changed files, verification, risks, and next step.

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

## Investigation Gate

When State is NEEDS_INVESTIGATION and Waiting For is Claude Code:

Claude Code must not modify any project or source files.

Claude Code should:
1. Gather evidence from existing files, logs, config, and tests.
2. Report findings, unknowns, risks, and recommended next step.
3. Update AI_HANDOFF.md and set State to READY_FOR_REVIEW and Waiting For to Codex.

## Planning Gate

Risky tasks require a written plan before implementation.

Risky-task examples:
- Database migrations
- RLS, Auth, or security changes
- Deployment or infrastructure changes
- Architecture changes or large refactors
- Production AI routing or model-routing changes

When State is PLAN_REQUIRED and Waiting For is Claude Code:

Claude Code must write a plan only — no source-file edits. Include: what changes and why, files affected, risks and mitigations, implementation sequence. Set State to PLAN_READY_FOR_REVIEW and Waiting For to Codex.

When State is PLAN_READY_FOR_REVIEW and Waiting For is Codex:

Codex reviews the plan.

If approved: set State to READY_FOR_IMPLEMENTATION and Waiting For to Claude Code.

If changes are needed: set State to PLAN_REQUIRED and Waiting For to Claude Code. Describe what to change in Next Recommended Step.

Claude Code implements only after plan approval.

## Verification Gate

After Claude Code implementation, Codex should verify using safe read-only commands where applicable:

- git status
- git diff
- git diff -- <changed-file>
- npm.cmd run typecheck (if available)
- npm.cmd run lint (if available)
- npm.cmd test (if available)

Codex must:
- Compare Claude's reported Changed Files against actual git diff output.
- Detect scope creep — edits to files not listed under Changed Files.
- Detect unlisted changes — files modified but not reported.
- Confirm verification results match Claude's claims before approving.

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

1. Read .agents/skills/codex-claude-handoff/SKILL.md if it exists in the project.
2. Follow its contents as local protocol instructions.

## Claude Skill Awareness

Codex may ask Claude whether relevant project-local or global Claude skills exist when:

- Context is missing for a risky or unfamiliar task.
- The user reports a skill change.
- A memory or context skill might help recover prior decisions, constraints, or risks.

When asked, Claude should:
- Report only relevant skills.
- Use memory/context skills to recover task-relevant prior decisions if available.
- Not expose unrelated private memory.

Codex should not ask for skill status every session — only when it adds value.

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
