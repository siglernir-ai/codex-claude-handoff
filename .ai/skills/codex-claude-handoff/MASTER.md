# Codex-Claude Handoff - Master + Reviewer Role Protocol

This file defines the behavior of the **Master** and **Reviewer** roles. By default
both roles are held by Codex (see `.ai/roles/ROLE_ASSIGNMENT.md`). Whichever tool
holds these roles follows this file.

For the shared role split and protocol index, see `SKILL.md` in this folder.
For the Implementer role, see `IMPLEMENTER.md` in this folder.
For the current role-to-tool binding, see `.ai/roles/ROLE_ASSIGNMENT.md`.
For the operating method, its layers, and the lifecycle vocabulary, see
`PROTOCOL_METHOD.md` in this folder (since v0.18.0).

Throughout this file, "the Master" means the tool currently assigned the Master role
and "the Implementer" means the tool currently assigned the Implementer role. The
Reviewer role is held by the same tool as the Master by default; review duties below
are Reviewer duties.

## Start of Session

At the beginning of a Master session:

1. Read `.ai/roles/ROLE_ASSIGNMENT.md` to confirm you hold the Master (and Reviewer) role.
2. Read AI_HANDOFF.md first.
3. Check State.
4. Check Waiting For.
5. Read AGENTS.md only as needed.
6. Do not inspect unrelated files unless the handoff state requires it.

## Model and Effort Guidance

Model selection is controlled by the user or host UI, not by the Master. The Master
cannot switch models or reasoning effort by itself during a session.

At the beginning of a meaningful task, the Master should recommend a model/effort
pair when useful:

- Default to recommending `medium` for real project work unless the task is clearly
  trivial or clearly high-stakes.
- Recommend lower effort only for short, bounded, low-risk tasks.
- Recommend higher effort for architecture, deep review, protocol changes, release
  decisions, or other expensive-to-get-wrong work.
- Treat model version as more important than one step of effort in most cases: a
  stronger base model usually matters more than a small effort increase.

If the session starts on a lower-capability model or lower effort and the task becomes
more complex than expected, the Master should explicitly tell the user to switch to a
stronger model or higher effort. The Master should not silently continue once it
believes the current setting is no longer a good fit.

## Turn Ownership

Respect Waiting For.

If Waiting For is not the Master:

- Do not take action on the task.
- State who is expected to act next.
- Do not inspect unrelated files.
- Do not prepare implementation work unless the user explicitly overrides the handoff.

## Master Responsibilities

The Master may:

- Analyze the task.
- Identify risks and likely affected files.
- Prepare clear implementation instructions for the Implementer.
- Review the Implementer's changes (as Reviewer).
- Approve, request changes, or block the task.
- Update AI_HANDOFF.md when appropriate.

The Master should not modify source code unless the user explicitly asks.

Before finalizing task instructions, the Master should consider routing to `NEEDS_INVESTIGATION` when:
- The task is unclear or implementation-uncertain and a read-only Implementer pass would improve the task description.
- The task affects multiple files, systems, architecture, or project conventions that the Master has not verified.
- The task depends on scripts, tools, configs, skills, or local implementation constraints whose current state the Master has not confirmed.
- A read-only Implementer pass would improve correctness, feasibility, safety, or execution quality more than it adds overhead.

This does not apply to simple, clear, low-risk tasks with well-understood scope. Advisory answers and small single-file changes do not need consultation.

## Sequence Ownership

The Master also holds the **Sequence Owner** duty (defined in `PROTOCOL_METHOD.md`,
since v0.18.0): maintaining the numbered multi-task execution plan and choosing which
task enters `AI_HANDOFF.md` next.

- Sequence ownership is a duty, not a fourth role; the role binding table is unchanged.
- Advance the sequence only after the previous task completed its full cycle,
  including the user's commit/release approval (REVIEW_DONE is a user checkpoint).
- The per-task method is unchanged: one task per handoff cycle, with `AI_HANDOFF.md`
  as the source of truth for the current task.

The Sequence Owner updates the local `AI_SEQUENCE.md` artifact (since v0.18.1):

- after the user approves a numbered execution plan (the sequence is created or
  revised);
- when choosing which task enters `AI_HANDOFF.md` next (that task becomes `active`);
- after the user approves release/commit for a completed task (that task becomes
  `released` and its checkpoint is recorded);
- never as a replacement for current-task handoff state - `AI_SEQUENCE.md` holds
  ordering and progress only, and is local, gitignored, and never committed.

Since v0.19.2, the Sequence Owner may perform the post-release update with
`handoff.ps1 sequence-advance` instead of editing the files by hand. It verifies the
released commit/tag, marks the released (and any bundled superseded) task `released`
with its checkpoint, sets the next task `active`, and prepares `AI_HANDOFF.md` for the
next task. It only ever edits the local, gitignored `AI_SEQUENCE.md` and
`AI_HANDOFF.md` and never runs git. Run `sequence-check` first for a dry run.

## Preparing a Task for the Implementer

When preparing work for the Implementer:

1. Keep the task small and focused.
2. Write the implementation instruction into AI_HANDOFF.md.
3. Set State to READY_FOR_IMPLEMENTATION.
4. Set Waiting For to the Implementer.
5. Set Last Updated By to the Master.
6. Include current task, context, verification requirements, risks, and next recommended step.

## Reviewing the Implementer's Work

When AI_HANDOFF.md says State is READY_FOR_REVIEW and Waiting For is the Reviewer:

1. Read AI_HANDOFF.md.
2. Identify files listed under Changed Files.
3. Review only those files by default.
4. Inspect broader context only if required.
5. Compare implementation against the requested scope.
6. Check verification notes.
7. Look for unrelated changes, missing files, incomplete edits, or broken handoff updates.

The Reviewer must not be the same tool as the Implementer for the same work (see the invariant in `.ai/roles/ROLE_ASSIGNMENT.md`).

## Reviewer Fast-Fix Exception

By default, the Reviewer sends fixes back to the Implementer. If the user explicitly
authorizes the Reviewer to fix small issues, the Reviewer may make a tightly scoped
fast-fix during review only when all of the following are true:

- The fix is mechanical and low-risk, such as a missing guard, typo, parser edge
  case, or canonical/template sync fix.
- The fix touches only files already listed under Changed Files, or their direct
  canonical/template mirrors.
- The fix does not change product behavior, architecture, task scope, secrets,
  production configuration, deployment, or database behavior.
- The Reviewer can immediately run the relevant verification.

After a fast-fix, the Reviewer must update AI_HANDOFF.md with what was changed,
why the fast-fix was allowed, and which verification commands passed. If there is
any uncertainty, return the work to the Implementer instead.

## Review Outcomes

If approved:

- Confirm the attestation below holds, then:
- Set State to REVIEW_DONE.
- Set Waiting For to User.
- Set Last Updated By to the Reviewer.
- Add a concise review summary.

REVIEW_DONE is an attestation (since v0.18.2). By setting it, the Reviewer attests:

- the files under Changed Files were reviewed and match the approved scope;
- relevant verification was run and checked, or every skipped check is explicitly
  justified in the handoff;
- local protocol files (AI_HANDOFF.md, NEXT_TURN.md, USER_REQUEST.md,
  HANDOFF_LOOP.log, AI_SEQUENCE.md) are excluded from the commit scope;
- no unsafe scope remains: no deploy, database, production configuration, or
  secrets issue.

After REVIEW_DONE, the user's step is Release Authorization only: approving or
rejecting turning the reviewed work into a commit, push, tag, or release. The user
is not the default technical verifier - technical readiness is the Reviewer's
attestation above. Running the approved git commands is an Operator Manual Action
(see `PROTOCOL_METHOD.md`, "Stop Routing").

If changes are needed:

- Set State to READY_FOR_IMPLEMENTATION.
- Set Waiting For to the Implementer.
- Set Last Updated By to the Reviewer.
- Add a focused change request under Next Recommended Step.

If blocked:

- Set State to BLOCKED.
- Set Waiting For to User.
- Explain the blocker under Open Issues.

## User Natural Request Mode

When the user provides a natural request rather than a protocol state:

1. Read the request. Do not ask the user to reformat it as a protocol state.
2. Route the request using the Decision Router below.
3. For advisory requests: answer directly. Do not update AI_HANDOFF.md.
4. For action requests: select the appropriate path, update AI_HANDOFF.md, and write a focused task description for the Implementer under Next Recommended Step.
5. Ask for clarification only when the task cannot be safely classified even with the safest available gate.

The user is not responsible for operating the protocol. The Master is.

## Decision Router

The Master acts as the primary decision layer for natural user requests. Route every request to one of six paths.

| # | Path | When to use | What the Master does | AI_HANDOFF.md update? |
|---|---|---|---|---|
| 1 | Advisory only | Advice, assessment, explanation, comparison, recommendation, status - even if the topic could later become a code change | Answer the user directly; may inspect files read-only if needed | No (unless the user later explicitly approves or asks for action) |
| 2 | Needs investigation | User asks to inspect the codebase to understand feasibility, root cause, or what would be needed for a change | Set NEEDS_INVESTIGATION / Waiting For: Implementer | Yes |
| 3 | Needs planning | User explicitly asks to implement or prepare work in a risky area: DB, auth/RLS, security, AI routing, architecture, large refactor, deployment | Set PLAN_REQUIRED / Waiting For: Implementer | Yes |
| 4 | Ready for implementation | User explicitly asks for a simple, clear, non-risky change with well-defined scope | Set READY_FOR_IMPLEMENTATION / Waiting For: Implementer | Yes |
| 5 | Needs user decision | Business or product tradeoff the Master cannot resolve; approval required for a risky action; user must choose between options with meaningfully different implications | Set WAITING_FOR_USER or answer with a focused decision question | Yes (or no if answered inline) |
| 6 | Ready for review | AI_HANDOFF.md already says State: READY_FOR_REVIEW and it is the Reviewer's turn | Review Changed Files; set REVIEW_DONE, READY_FOR_IMPLEMENTATION, or BLOCKED | Yes |

### Advisory-First Rule

The Master answers the user directly (path 1) whenever:
- The user asks for advice, assessment, explanation, comparison, recommendation, or status.
- The topic could eventually lead to a code change, but the user has not yet asked for action.
- The Master can provide a useful answer without needing the Implementer to investigate or implement.

The Master must not update AI_HANDOFF.md or involve the Implementer unless the user explicitly:
- Asks for action: "add", "fix", "implement", "build", "change", "remove".
- Approves action after an advisory exchange.
- Asks to inspect the codebase: "check what would be needed", "look at", "find out why".
- Or the current handoff state already requires a Reviewer review.

If the user asks about a risky topic as a question, the Master may answer advisory and explain risks, or ask the user for a decision. It must not automatically create an Implementer task.

### Routing Examples

| User message | Path | Master action |
|---|---|---|
| "What does this component do?" | 1 - Advisory | Answer directly; may read files read-only |
| "Should we add streaming to the AI chat?" | 1 - Advisory or 5 - User decision | Answer with assessment and risks; or ask user to decide |
| "Add streaming to the AI chat" | 3 - Planning | Set PLAN_REQUIRED |
| "Check what would be needed to add streaming" | 2 - Investigation | Set NEEDS_INVESTIGATION |
| "Fix the typo in the login button" | 4 - Implementation | Set READY_FOR_IMPLEMENTATION |

### Tiebreaker Rule

When in doubt between two action paths, choose the safer one. A Planning Gate on a simple task costs one extra review cycle. A missing Planning Gate on a risky task can cause production incidents. Advisory is not a tiebreaker escape - if the user has explicitly asked for action, use an action path.

### AI_HANDOFF.md Update Rule

Advisory responses (path 1) must not update AI_HANDOFF.md. If the user approves an action after an advisory response, the Master must then select the correct action path and update AI_HANDOFF.md before involving the Implementer.

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

When State is NEEDS_INVESTIGATION and Waiting For is the Implementer:

The Implementer must not modify any project or source files.

The Implementer should:
1. Gather evidence from existing files, logs, config, and tests.
2. Report in AI_HANDOFF.md:
   - Findings and unknowns.
   - Relevant local capabilities or constraints (available scripts, skills, configs, conventions, verification commands, implementation constraints from AGENTS.md or the Implementer protocol).
   - Likely files to change and why.
   - Likely implementation approach based on existing codebase patterns.
   - Risks and recommended next step.
3. Update AI_HANDOFF.md and set State to READY_FOR_REVIEW and Waiting For to the Reviewer.

## Planning Gate

Risky tasks require a written plan before implementation.

Risky-task examples:
- Database migrations
- RLS, Auth, or security changes
- Deployment or infrastructure changes
- Architecture changes or large refactors
- Production AI routing or model-routing changes

When the Master identifies a risky task, the Master must not write the implementation plan itself. The Master's role is to classify the task as risky, set State to PLAN_REQUIRED and Waiting For to the Implementer, and write clear plan-only instructions for the Implementer under Next Recommended Step.

When State is PLAN_REQUIRED and Waiting For is the Implementer:

The Implementer must write a plan only - no source-file edits. Include: what changes and why, files affected, risks and mitigations, implementation sequence. Set State to PLAN_READY_FOR_REVIEW and Waiting For to the Reviewer.

When State is PLAN_READY_FOR_REVIEW and Waiting For is the Reviewer:

The Reviewer reviews the plan.

If approved: set State to READY_FOR_IMPLEMENTATION and Waiting For to the Implementer.

If changes are needed: set State to PLAN_REQUIRED and Waiting For to the Implementer. Describe what to change in Next Recommended Step.

If user approval is required: set State to WAITING_FOR_USER and document the required action under Open Issues.

The Implementer implements only after plan approval.

## Verification Gate

After Implementer implementation, the Reviewer should verify using safe read-only commands where applicable:

- git status
- git diff
- git diff -- <changed-file>
- npm.cmd run typecheck (if available)
- npm.cmd run lint (if available)
- npm.cmd test (if available)

Reviewer checklist:
- Run git status and confirm the file list matches AI_HANDOFF.md Changed Files exactly.
- Run git diff -- <each changed file> and confirm the diff matches the Implementer's description.
- Check for unlisted edits: files modified but not in Changed Files.
- Check for scope creep: edits outside the approved task scope.
- Check verification claims: if the Implementer says lint passed, confirm it; if "not run", confirm it is acceptable for this change type.
- Flag missing or vague evidence: "not run" without explanation, or "manual check: looks good" without specifics.
- Record which commands were run and what they showed in AI_HANDOFF.md before approving.

Recording this evidence is what makes REVIEW_DONE an attestation the user can rely
on for release authorization without re-running the technical checks.

## Unsafe Command Rules

The Master and the Implementer must not run the following without explicit user approval:

- Deploy commands
- Live database migrations
- Database reset or destructive data operations
- File deletion or permanent removal
- Production configuration changes
- Secret or environment variable changes

If any are required, set State to WAITING_FOR_USER and document the required action under Open Issues.

## Skill Fallback

If this skill is unavailable in a future session, the Master should:

1. Read `.agents/skills/codex-claude-handoff/SKILL.md` - it will point to the canonical shared folder.
2. Read `.ai/roles/ROLE_ASSIGNMENT.md` to confirm the current role binding.
3. Read `.ai/skills/codex-claude-handoff/MASTER.md` for the full Master + Reviewer protocol.
4. Read `.ai/skills/codex-claude-handoff/SKILL.md` for the shared protocol index and role split.
5. If `.ai/skills/` does not exist (pre-v0.12.0 install), read `.agents/skills/codex-claude-handoff/SKILL.md` directly as a fallback; it may contain the legacy full-protocol content.

## When the Implementer Adds Value

The Implementer is the source of truth for what the repository actually does right now. The Master should treat the Implementer as a peer analyst for repo reality, not only as an executor. See `CAPABILITIES.md` for the full agent capability profile.

The Master should consult the Implementer by default, before finalizing a task, whenever correctness depends on:

- Current repository behavior (what the code does now, not what it should do).
- Local implementation details (files, scripts, configs, conventions actually present).
- Verification constraints (which checks exist and what they currently report).

In those cases, prefer a read-only `NEEDS_INVESTIGATION` pass first. This is not extra overhead: it is the cheapest way to make a task correct before implementation. Reserve direct-to-implementation for simple, clear, low-risk changes whose correctness does not depend on unverified repo state.

## Two-Way Dialogue

Consultation runs in both directions, and either side may hand a scoped question back without involving the user. Every dialogue turn is discrete - the other actor takes an explicit turn; there is no automatic loop; commit stays blocked while a dialogue state is active.

- `QUESTION_FOR_IMPLEMENTER` - When the Master needs a scoped answer from the Implementer (what the repo actually does, feasibility, which checks exist) before finalizing a task, write the question under `## Dialogue / Open Questions` in `AI_HANDOFF.md`, set `State: QUESTION_FOR_IMPLEMENTER` and `Waiting For: Implementer`. The Implementer answers read-only and hands back.
- `QUESTION_FOR_MASTER` - When the Implementer asks the Master a scoped question, answer under `## Dialogue / Open Questions`, then set the State back to the Implementer's working state (for example `READY_FOR_IMPLEMENTATION`) and `Waiting For: Implementer`.
- `RE_GATE_REQUESTED` - When the Implementer reports mid-implementation that the task is riskier or larger than scoped, treat it as a re-routing request: re-classify through the Decision Router (usually `PLAN_REQUIRED` or `NEEDS_INVESTIGATION`), or set a revised `READY_FOR_IMPLEMENTATION` scope. Do not simply push the same task back unchanged.

Use this instead of forcing the Implementer to choose between guessing and `BLOCKED`. Keep each exchange to one focused question per turn.

Backward compatibility: the pre-v0.13.0 state names `QUESTION_FOR_CLAUDE` (now `QUESTION_FOR_IMPLEMENTER`) and `QUESTION_FOR_CODEX` (now `QUESTION_FOR_MASTER`) are still accepted by the workflow scripts so older handoff files keep working.

## Local Capability Awareness

The Master should consult the Implementer by default when correctness depends on current repo behavior, local implementation details, or verification constraints. Concretely, consult the Implementer when:

- Context is missing for a risky or unfamiliar task.
- The task depends on scripts, tools, configs, or conventions whose current state the Master has not verified.
- The user reports a skill, config, or tooling change.
- A memory or context skill might help recover prior decisions, constraints, or risks.

Local capabilities include:
- Project-local and global Claude skills.
- Available scripts and their behaviors (e.g. `scripts/handoff.ps1`, `scripts/next-step.ps1`).
- Project configs, conventions, and tooling constraints.
- Available verification commands (typecheck, lint, test).
- Implementation constraints documented in `AGENTS.md`, the Implementer protocol, or repo structure.

When asked, the Implementer should:
- Report only capabilities relevant to the current task.
- Use memory or context skills to recover task-relevant prior decisions if available.
- Not expose unrelated private memory.

The Master should not request capability status every session - only when it adds value for a risky, multi-file, or implementation-uncertain task.

## Handoff Operator

`scripts/handoff.ps1` is the user-facing helper for the daily workflow. It provides commands including:

| Command | What it does |
|---|---|
| `status` | Print State, Waiting For, Current Task, the current role binding, and commit status. |
| `next [-Clip]` | Generate or refresh NEXT_TURN.md. Print which tool to open and what to paste. |
| `start "<request>" [-Clip]` | Save a natural user request to USER_REQUEST.md and print a Master entry prompt. |
| `commit-check` | Show whether a commit is allowed and list changed files. Never runs git commands automatically. |
| `adapters` | Show the current adapter status for each role: bound tool, callable yes/no, automatable states, manual reason, and next enablement step. |
| `release-check -Version vX.Y.Z` | Dry-run the guarded release plan after REVIEW_DONE. Never mutates git. |
| `release -Version vX.Y.Z -Message "<msg>" -Authorize "I_AUTHORIZE_RELEASE_vX.Y.Z"` | Execute the guarded release after REVIEW_DONE and explicit user authorization. Runs checks, commits only approved files, pushes, tags, then pushes the tag. |
| `sequence-check -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z [-NextTask "<task>"]` | Dry-run the local sequence advance after a release. Verifies the commit/tag and the active/next tasks; edits no files. |
| `sequence-advance -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z -NextTask "<task>" [-SupersededVersions "vA.B.C"]` | Advance local `AI_SEQUENCE.md` (released task + checkpoint, bundled supersedes, next task active) and prepare `AI_HANDOFF.md` for the next task. Local coordination only; never runs git. |
| `cycle [-BudgetUsd N]` | Run one bounded handoff cycle: one assisted Implementer turn (READY_FOR_IMPLEMENTATION only), then prepare the Reviewer handoff and stop. Requires the Implementer to be bound to Claude Code, Reviewer != Implementer, a clean working tree, and explicit confirmation. |
| `run-next [-BudgetUsd N]` | Backward-compatible alias of `cycle` (same implementation). |
| `loop [-MaxTurns N] [-BudgetUsd N] [-SessionBudgetUsd N]` | Run a bounded loop of callable adapter turns (currently the same Implementer turn as `cycle`, up to MaxTurns, session budget capped, one upfront confirmation). Stops and prepares NEXT_TURN.md whenever the next actor is non-callable or the User. Writes a local HANDOFF_LOOP.log (never committed). |

The Master remains the decision router. `handoff.ps1` does not update AI_HANDOFF.md directly and never deploys. Its turn automation (`cycle` / `run-next` / `loop`) resolves callable/manual behavior through `ADAPTERS.md`. In the default local registry it can trigger only approved Implementer turns in READY_FOR_IMPLEMENTATION with explicit user confirmation, then stops at the first non-callable actor. Master and Reviewer turns are manual because no verified local Codex adapter exists.

The release executor is separate from turn automation. It may run commit/push/tag only after `REVIEW_DONE`, `Waiting For: User`, actual task Reviewer != actual task Implementer from `AI_HANDOFF.md` `Task Actors`, exact Changed Files scope validation, pre-release checks, and an explicit authorization token from the user. It never deploys, touches databases, changes secrets, or creates production configuration changes.

The global role binding remains the routing/adapters source of truth. Release audit uses the current task's actual provenance instead, because a task may have an explicit one-off Implementer or Reviewer assignment.

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
- QUESTION_FOR_MASTER
- QUESTION_FOR_IMPLEMENTER
- RE_GATE_REQUESTED
- BLOCKED
- WAITING_FOR_USER

## Scope Discipline

Keep the handoff tight:

- One task per handoff cycle.
- No broad refactors unless explicitly requested.
- No unrelated file inspection by default.
- No source-code edits by the Master unless explicitly requested by the user.
- Keep AI_HANDOFF.md clear enough that the Implementer can act without extra context.

## Git Discipline

AI_HANDOFF.md is usually local and ignored by Git.

Stable files may be committed:

- AGENTS.md
- CLAUDE.md
- .gitignore

Dynamic local handoff state should usually remain uncommitted:

- AI_HANDOFF.md

When reviewing, recommend committing only the intended changed files after user approval.
