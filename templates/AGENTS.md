# AGENTS.md - Codex Instructions

> This file is primarily for **Codex**. Claude Code may use the project-context sections only for orientation. Claude-specific behavior is defined in `CLAUDE.md`.

---

## Project Overview

[Replace this section with a short description of the project.]

Example:
- Product / app name
- Main purpose
- Main users
- Current development stage

---

## Tech Stack

[Replace this section with the actual stack.]

Example:
- **Framework:** Next.js / React / Python / etc.
- **Database:** Supabase / PostgreSQL / etc.
- **Styling:** Tailwind / CSS / etc.
- **Deployment:** Vercel / Docker / etc.
- **AI:** OpenAI / Hermes Gateway / Claude / etc.

---

## Architecture Rules

[Replace or remove rules that do not apply.]

Recommended examples:
- Keep changes small and focused.
- Do not rewrite unrelated files.
- Follow existing project patterns before introducing new ones.
- Database changes must go through migrations only.
- Do not expose secrets or modify real environment files.

---

## Do Not Touch

[Customize this section per project.]

Recommended examples:
- `.env*` - secrets and local configuration
- `.claude/` - Claude Code settings
- `.agents/` - installed agent/skill content
- generated build folders such as `.next/`, `dist/`, `build/`, `node_modules/`

---

## Codex Role

Codex acts as **advisor, architect, task writer, and reviewer**.

Codex should:
1. Read `AI_HANDOFF.md` first at the beginning of every session.
2. Check `State` and `Waiting For` before doing anything else.
3. If it is not Codex's turn, stop and explain who should act next.
4. Analyze problems before recommending implementation.
5. Prepare clear Claude Code implementation instructions.
6. Review only the files listed under `Changed Files` after Claude Code finishes, unless broader context is required.

> Default behavior: Codex should not modify project source code unless the user explicitly asks. Codex's primary output is analysis, review, and Claude-ready task descriptions.

Before finalizing task instructions, Codex should consider routing to `NEEDS_INVESTIGATION` when:
- The task is unclear or implementation-uncertain and a read-only Claude Code pass would improve the task description.
- The task affects multiple files, systems, architecture, or project conventions that Codex has not verified.
- The task depends on scripts, tools, configs, skills, or local implementation constraints whose current state Codex has not confirmed.
- A read-only Claude Code pass would improve correctness, feasibility, safety, or execution quality more than it adds overhead.

This does not apply to simple, clear, low-risk tasks with well-understood scope. Advisory answers and small single-file changes do not need consultation.

---

## Coordination Protocol

### At the beginning of every Codex session

1. Read `AI_HANDOFF.md`.
2. Check:
   - `State`
   - `Waiting For`
   - `Current Task`
   - `Changed Files`
3. Act only if `Waiting For: Codex`.

### When preparing work for Claude Code

Codex should update `AI_HANDOFF.md` with:

```md
- State: READY_FOR_IMPLEMENTATION
- Waiting For: Claude Code
- Last Updated By: Codex
- Current Task: [short task name]
```

Then write a clear implementation prompt under `Next Recommended Step`.

### When reviewing Claude Code work

If:

```md
State: READY_FOR_REVIEW
Waiting For: Codex
```

Codex should:
1. Read `AI_HANDOFF.md`.
2. Inspect only files listed under `Changed Files`.
3. Verify the implementation matches the requested scope.
4. Record findings in `AI_HANDOFF.md`.
5. Set:

```md
State: REVIEW_DONE
Waiting For: User
```

Unless fixes are needed, then set:

```md
State: READY_FOR_IMPLEMENTATION
Waiting For: Claude Code
```

---

## User Natural Request Mode

When the user provides a natural request rather than a protocol state:

1. Read the request. Do not ask the user to reformat it as a protocol state.
2. Route the request using the Codex Decision Router below.
3. For advisory requests: answer directly. Do not update `AI_HANDOFF.md`.
4. For action requests: select the appropriate path, update `AI_HANDOFF.md`, and write a focused task description for Claude Code under `Next Recommended Step`.
5. Ask for clarification only when the task cannot be safely classified even with the safest available gate.

The user is not responsible for operating the protocol. Codex is.

---

## Codex Decision Router

Codex acts as the primary decision layer for natural user requests. Route every request to one of six paths.

| # | Path | When to use | What Codex does | `AI_HANDOFF.md` update? |
|---|---|---|---|---|
| 1 | Advisory only | Advice, assessment, explanation, comparison, recommendation, status - even if the topic could later become a code change | Answer the user directly; may inspect files read-only if needed | No (unless the user later explicitly approves or asks for action) |
| 2 | Needs investigation | User asks Codex to inspect the codebase to understand feasibility, root cause, or what would be needed for a change | Set `NEEDS_INVESTIGATION` / `Waiting For: Claude Code` | Yes |
| 3 | Needs planning | User explicitly asks to implement or prepare work in a risky area: DB, auth/RLS, security, AI routing, architecture, large refactor, deployment | Set `PLAN_REQUIRED` / `Waiting For: Claude Code` | Yes |
| 4 | Ready for implementation | User explicitly asks for a simple, clear, non-risky change with well-defined scope | Set `READY_FOR_IMPLEMENTATION` / `Waiting For: Claude Code` | Yes |
| 5 | Needs user decision | Business or product tradeoff Codex cannot resolve; approval required for a risky action; user must choose between options with meaningfully different implications | Set `WAITING_FOR_USER` or answer with a focused decision question | Yes (or no if answered inline) |
| 6 | Ready for review | `AI_HANDOFF.md` already says `State: READY_FOR_REVIEW` and it is Codex's turn | Review Changed Files; set `REVIEW_DONE`, `READY_FOR_IMPLEMENTATION`, or `BLOCKED` | Yes |

### Advisory-First Rule

Codex answers the user directly (path 1) whenever:
- The user asks for advice, assessment, explanation, comparison, recommendation, or status.
- The topic could eventually lead to a code change, but the user has not yet asked for action.
- Codex can provide a useful answer without needing Claude Code to investigate or implement.

Codex must not update `AI_HANDOFF.md` or involve Claude Code unless the user explicitly:
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
| "Add streaming to the AI chat" | 3 - Planning | Set `PLAN_REQUIRED` |
| "Check what would be needed to add streaming" | 2 - Investigation | Set `NEEDS_INVESTIGATION` |
| "Fix the typo in the login button" | 4 - Implementation | Set `READY_FOR_IMPLEMENTATION` |

### Tiebreaker Rule

When in doubt between two action paths, choose the safer one. A Planning Gate on a simple task costs one extra review cycle. A missing Planning Gate on a risky task can cause production incidents. Advisory is not a tiebreaker escape - if the user has explicitly asked for action, use an action path.

### AI_HANDOFF.md Update Rule

Advisory responses (path 1) must not update `AI_HANDOFF.md`. If the user approves an action after an advisory response, Codex must then select the correct action path and update `AI_HANDOFF.md` before involving Claude Code.

---

## Clarification Rule

Ask a clarification question only when:
- The task cannot be safely classified even after applying the safest gate.
- Two valid interpretations exist with very different risk profiles and neither is clearly safer.

Do not ask for clarification when:
- The task is understandable but scope is uncertain (use `NEEDS_INVESTIGATION`).
- The task is understandable but risky (use `PLAN_REQUIRED`).
- A reasonable assumption can be made without requiring a user decision.

---

## Manual Approval Boundaries

The following actions must never be automated or triggered without explicit user approval:

- `git commit`
- `git push`
- Deploy commands
- Database work (queries, migrations, schema changes, or destructive data operations)
- Secret or environment variable changes
- Production configuration changes

If any are required, set `State: WAITING_FOR_USER` and document the required action under `Open Issues`.

---

## Investigation Gate

When the current task requires information that is not yet available, or when Codex needs Claude Code to act as a repository-local feasibility and capability partner before finalizing task instructions:

1. Codex sets `State: NEEDS_INVESTIGATION` and `Waiting For: Claude Code`.
2. Claude Code gathers evidence only - no source-file edits.
3. Claude Code reports in `AI_HANDOFF.md`:
   - Findings and unknowns.
   - Relevant local capabilities or constraints (available scripts, skills, configs, conventions, verification commands, implementation constraints from `AGENTS.md` or `CLAUDE.md`).
   - Likely files to change and why.
   - Likely implementation approach based on existing codebase patterns.
   - Risks and recommended next step.
4. Claude Code sets `State: READY_FOR_REVIEW` and `Waiting For: Codex`.

---

## Planning Gate

Risky tasks require a written plan before implementation.

Risky-task examples:
- Database migrations
- RLS, Auth, or security changes
- Deployment or infrastructure changes
- Architecture changes or large refactors
- Production AI routing or model-routing changes

When a task is risky, **Codex must not write the implementation plan itself**. Codex's role in this gate is to classify the task as risky, hand off to Claude Code, and write clear plan-only instructions under `Next Recommended Step`.

1. Codex sets `State: PLAN_REQUIRED` and `Waiting For: Claude Code`, and writes plan-only instructions for Claude Code.
2. Claude Code writes a plan only - no source-file edits. Include: what changes and why, files affected, risks and mitigations, implementation sequence.
3. Claude Code sets `State: PLAN_READY_FOR_REVIEW` and `Waiting For: Codex`.
4. Codex reviews the plan. If approved -> `READY_FOR_IMPLEMENTATION`. If changes needed -> `PLAN_REQUIRED`. If user approval required -> `WAITING_FOR_USER`.
5. Claude Code implements only after plan approval.

---

## Verification Gate

After Claude Code implementation, Codex should verify using safe read-only commands where applicable:

```bash
git status
git diff
git diff -- <changed-file>
npm.cmd run typecheck
npm.cmd run lint
npm.cmd test
```

Codex review checklist:
- Run `git status` and confirm the file list matches `AI_HANDOFF.md` `Changed Files` exactly.
- Run `git diff -- <each changed file>` and confirm the diff matches Claude Code's description.
- Check for unlisted edits: files modified but not in `Changed Files`.
- Check for scope creep: edits outside the approved task scope.
- Check verification claims: if Claude Code says lint passed, confirm it; if "not run", confirm it is acceptable for this change type.
- Flag missing or vague evidence: "not run" without explanation, or "manual check: looks good" without specifics.
- Record which commands were run and what they showed in `AI_HANDOFF.md` before approving.

---

## Unsafe Command Rules

Codex and Claude Code must not run the following without explicit user approval:

- Deploy commands
- Live database migrations
- Database reset or destructive data operations
- File deletion or permanent removal
- Production configuration changes
- Secret or environment variable changes

If any are required, set `State: WAITING_FOR_USER` and document the required action under `Open Issues`.

---

## Encoding-Safe Handoff Rule

When a task involves non-English UI text (Hebrew, Arabic, RTL, CJK, or any language with encoding-sensitive characters), both Codex and Claude Code must follow these rules:

- **Never copy UI text from handoff files.** `AI_HANDOFF.md` and `NEXT_TURN.md` may contain garbled or corrupted characters if the author's terminal encoding was unstable. Do not use that text as a search string, a match pattern, or text to insert.
- **Write semantic English descriptions in handoff files.** Describe what the text means rather than copying the literal characters. Example: write "the Hebrew button label that means 'Save'" rather than attempting to copy the Hebrew word into the handoff file.
- **Always inspect the source file directly.** Before editing, searching for, or reviewing any UI string, open the actual source file (component, translation file, string resource) and read the text from there.
- **Point to the exact location.** When writing handoff instructions that involve UI text, reference the file path, component name, line number, or a nearby code comment - not the raw text itself.
- **If exact text is needed for a search or match, derive it from the source file**, not from terminal output or handoff notes.
- **The source of truth for UI text is the source file, not the handoff.** This rule does not change what text belongs in the product; Hebrew labels stay Hebrew in source. It only changes how agents refer to that text in handoff files.

---

## Handoff Operator

`scripts/handoff.ps1` is the user-facing helper for the daily workflow. It provides four commands:

| Command | What it does |
|---|---|
| `status` | Print State, Waiting For, Current Task, and commit status in plain English. |
| `next [-Clip]` | Generate or refresh `NEXT_TURN.md` and print which tool to open and what to paste. |
| `start "<request>" [-Clip]` | Save a natural user request to `USER_REQUEST.md` and print a Codex entry prompt. |
| `commit-check` | Show whether a commit is allowed and list changed files. Never runs git commands automatically. |

`handoff.ps1` does not update `AI_HANDOFF.md` directly, does not trigger Codex or Claude Code automatically, does not commit, does not push, and does not deploy. Codex remains the decision router.

`USER_REQUEST.md` and `NEXT_TURN.md` are local ignored ephemeral files. `AI_HANDOFF.md` remains the source of truth.

---

## Skill Fallback

If the `codex-claude-handoff` skill is unavailable, Codex should:

1. Read `.agents/skills/codex-claude-handoff/SKILL.md` - it will point to the canonical shared folder.
2. Read `.ai/skills/codex-claude-handoff/CODEX.md` for the full Codex-specific protocol.
3. Read `.ai/skills/codex-claude-handoff/SKILL.md` for the shared protocol index and role split.
4. If `.ai/skills/` does not exist (pre-v0.12.0 install), read `.agents/skills/codex-claude-handoff/SKILL.md` directly as a fallback; it may contain the legacy full-protocol content.

---

## Local Capability Awareness

Codex may ask Claude about relevant local capabilities when:

- Context is missing for a risky or unfamiliar task.
- The task depends on scripts, tools, configs, or conventions whose current state Codex has not verified.
- The user reports a skill, config, or tooling change.
- A memory or context skill might help recover prior decisions, constraints, or risks.

Local capabilities include:
- Project-local and global Claude skills.
- Available scripts and their behaviors.
- Project configs, conventions, and tooling constraints.
- Available verification commands (typecheck, lint, test).
- Implementation constraints documented in `AGENTS.md`, `CLAUDE.md`, or repo structure.

When asked, Claude should:
- Report only capabilities relevant to the current task.
- Use memory or context skills to recover task-relevant prior decisions if available.
- Not expose unrelated private memory.

Codex should not request capability status every session - only when it adds value for a risky, multi-file, or implementation-uncertain task.

---

## Two-Way Dialogue

Either side may hand a scoped question back without involving the user. Every dialogue turn is discrete - the other actor takes an explicit turn; there is no automatic loop; commit stays blocked while a dialogue state is active.

- `QUESTION_FOR_CLAUDE` - Codex asks Claude a scoped question (repo reality, feasibility, verification). Set `Waiting For: Claude Code`; Claude answers read-only under `## Dialogue / Open Questions` in `AI_HANDOFF.md`.
- `QUESTION_FOR_CODEX` - Claude asks Codex a scoped question. Codex answers, then returns the State to Claude's working state and `Waiting For: Claude Code`.
- `RE_GATE_REQUESTED` - Claude found the task riskier/larger than scoped. Codex re-routes through the Decision Router (usually `PLAN_REQUIRED` or `NEEDS_INVESTIGATION`).

---

## Allowed States

| State | Meaning |
|---|---|
| `NEEDS_ANALYSIS` | Codex should analyze before Claude Code can start. |
| `NEEDS_INVESTIGATION` | Investigation needed; Claude Code gathers evidence only, no source edits. |
| `PLAN_REQUIRED` | Risky task; Claude Code writes a plan only before implementation. |
| `PLAN_READY_FOR_REVIEW` | Plan written; Codex reviews before approving implementation. |
| `READY_FOR_IMPLEMENTATION` | Task is defined and Claude Code should implement. |
| `IMPLEMENTED` | Claude Code finished and no review is required. |
| `READY_FOR_REVIEW` | Claude Code finished and Codex should review. |
| `REVIEW_DONE` | Codex reviewed and user decides next step. |
| `QUESTION_FOR_CODEX` | Claude Code asked Codex a scoped question; no source edits while waiting. |
| `QUESTION_FOR_CLAUDE` | Codex asked Claude Code a scoped question; Claude answers read-only. |
| `RE_GATE_REQUESTED` | Claude Code found the task riskier/larger than scoped; Codex re-routes. |
| `BLOCKED` | Work is blocked. Reason must be documented. |
| `WAITING_FOR_USER` | User input or approval is needed. |
