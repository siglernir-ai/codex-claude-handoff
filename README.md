# Codex-Claude Handoff

A simple collaboration protocol for using **Codex** and **Claude Code** together in the same software project.

The goal is to avoid copy-pasting long context between tools.

## Concept

- **Codex** acts as advisor, architect, task writer, and reviewer.
- **Claude Code** acts as the implementation agent.
- Both tools coordinate through a shared file: `AI_HANDOFF.md`.
- The user remains the approval point.

## Files

```text
templates/
  AGENTS.md
  CLAUDE.md
  AI_HANDOFF.md
  gitignore-snippet.txt
```

### `AGENTS.md`

Instructions for Codex.

Use it for:

- project context
- architecture rules
- Codex role
- review rules
- coordination flow

### `CLAUDE.md`

Instructions for Claude Code.

Use it for:

- implementation behavior
- scope discipline
- required handoff updates
- verification reporting

### `AI_HANDOFF.md`

Dynamic handoff file between Codex and Claude Code.

Use it for:

- current state
- who acts next
- current task
- changed files
- verification results
- risks and next step

### `gitignore-snippet.txt`

Optional `.gitignore` rule for keeping `AI_HANDOFF.md` out of Git.

## Next Step Script

A helper script prints the current handoff state and a ready-to-paste prompt.

Run from your project root:

```powershell
.\scripts\next-step.ps1
```

The script reads `AI_HANDOFF.md` and prints the current `State`, `Waiting For`, and `Current Task`, followed by a recommended prompt based on the current state.

## Quick Prompts

Use these short prompts to run the handoff workflow without rewriting the protocol each time.

### Short form

For Codex:

```text
Use the codex-claude-handoff skill. Read AI_HANDOFF.md and continue from the current state.
```

For Claude Code:

```text
Read CLAUDE.md and AI_HANDOFF.md. Continue the protocol from the current state.
```

### Start a Codex review

```text
Use the codex-claude-handoff skill.

Read AI_HANDOFF.md and review the files listed under Changed Files.
Only review the requested scope.
Update AI_HANDOFF.md with your review result.
```

### Ask Codex to prepare a Claude Code task

```text
Use the codex-claude-handoff skill.

Prepare a focused Claude Code implementation task in AI_HANDOFF.md.
Set State: READY_FOR_IMPLEMENTATION.
Set Waiting For: Claude Code.
Keep the scope limited to the requested files.
```

### Start a Claude Code implementation session

```text
Read CLAUDE.md and AI_HANDOFF.md.

Implement only the current task in AI_HANDOFF.md.
Keep changes limited to the requested scope.
After finishing, update AI_HANDOFF.md with changed files, verification, risks, and next step.
```

### Ask Claude Code to update AI_HANDOFF.md after implementation

```text
Update AI_HANDOFF.md for the work you just completed.

Set State: READY_FOR_REVIEW.
Set Waiting For: Codex.
List changed files, verification results, open issues, risks, and the next recommended step.
```

## Natural Request Mode

You do not need to know the protocol states. Paste your request into Codex and it
will classify the task, choose the appropriate gate, set `AI_HANDOFF.md`, and give
Claude Code a focused instruction.

Example:

```text
Add better error handling to the AI chat component.
```

Codex classifies this, selects a gate if needed, and updates `AI_HANDOFF.md`.
You still approve all commits, pushes, deploys, DB work, migrations, secrets, and
production changes.

## Daily Workflow

Run this from the project root:

```powershell
.\scripts\next-step.ps1
```

The script prints the current state and a ready-to-paste prompt.
Paste the prompt into Codex or Claude Code.
The tool acts, updates `AI_HANDOFF.md`, and the cycle continues.

## Short Workflow Example

A typical handoff cycle looks like this:

1. **Codex prepares the task.** Codex reads `AI_HANDOFF.md`, analyzes the request, and writes a focused implementation task. It sets `State: READY_FOR_IMPLEMENTATION` and `Waiting For: Claude Code`.

2. **Claude Code implements the scoped task.** Claude Code reads `CLAUDE.md` and `AI_HANDOFF.md`, implements only the requested scope, and makes no unrelated changes.

3. **Claude Code updates `AI_HANDOFF.md` to `READY_FOR_REVIEW`.** After finishing, Claude Code records changed files, verification results, and risks, then sets `State: READY_FOR_REVIEW` and `Waiting For: Codex`.

4. **Codex reviews only `Changed Files`.** Codex reads `AI_HANDOFF.md` and reviews only the files listed under the `Changed Files` section. It sets `State: REVIEW_DONE` and `Waiting For: User`.

5. **User commits only the real source changes.** The user reviews the result and commits the approved source files. `AI_HANDOFF.md` is not committed.

`AI_HANDOFF.md` is a working coordination file — it tracks current task state between tools and sessions. It is not a source file and should stay out of version control. A `.gitignore` rule for it is included in `gitignore-snippet.txt` and applied automatically by the install script. The user remains the final approval point for all commits and pushes.

## Protocol Gates

Three optional gates can be inserted before or after implementation depending on task risk.

### Investigation Gate

Use when information is missing before a task can be scoped.

Codex sets `State: NEEDS_INVESTIGATION`. Claude Code gathers evidence only — no source-file edits. Claude Code reports findings and sets `State: READY_FOR_REVIEW`.

### Planning Gate

Use for risky tasks (DB migrations, RLS/Auth, security, deployment, architecture changes, large refactors, production AI routing) or any time the goal is to exercise or enforce the Planning Gate before implementation.

**Codex must not write the implementation plan itself.** Codex's role is to: classify the task as risky or plan-required; set `State: PLAN_REQUIRED` and `Waiting For: Claude Code`; write clear plan-only instructions under `Next Recommended Step`.

Claude Code writes a plan only — no source-file edits — and sets `State: PLAN_READY_FOR_REVIEW` and `Waiting For: Codex`.

Codex reviews the plan. Outcomes: approve (`READY_FOR_IMPLEMENTATION`), request changes (`PLAN_REQUIRED`), or require user approval (`WAITING_FOR_USER`).

### Verification Gate

After every Claude Code implementation, Codex should verify using safe read-only commands (`git status`, `git diff`, typecheck, lint, tests where available). Codex must compare actual changes against `Changed Files` and detect scope creep or unlisted edits before approving.

Good verification evidence includes:
- **Commands Run:** list each command and a short result summary (e.g. "git diff: 3 files changed, 28 insertions, 4 deletions")
- **Skipped commands:** state why (e.g. "lint: not run - documentation change only")
- **Manual Check:** state expected vs actual, not just "looks good"

Vague entries like "not run" or "not applicable" without explanation are not sufficient evidence for Codex to approve.

### Unsafe Command Rules

Codex and Claude Code must not run the following without explicit user approval:

- Deploy commands
- Live database migrations
- Database reset or destructive data operations
- File deletion or permanent removal
- Production configuration changes
- Secret or environment variable changes

If any are required, set `State: WAITING_FOR_USER` and document the required action under `Open Issues`.

### Skill Fallback

If the `codex-claude-handoff` skill is unavailable, Codex should read `.agents/skills/codex-claude-handoff/SKILL.md` and follow it as local protocol instructions.

### Claude Skill Awareness

Codex may ask Claude whether relevant project-local or global Claude skills exist when context is missing for a risky task, the user reports a skill change, or a memory/context skill might help recover prior decisions, constraints, or risks.

When asked, Claude should report only relevant skills. Memory or context skills may be used to recover task-relevant prior decisions, constraints, and risks. Claude must not expose unrelated private memory. Codex should not ask every session — only when it adds value.

### v0.3.0 Out of Scope

The following are explicitly out of scope for this protocol version:

- Full automation between Codex and Claude Code
- File watcher or event-driven orchestration
- Orchestration CLI
- Full shared memory layer
- `AI_SKILLS.md` registry
- Automatic model switching
- Token-budget system

## Tested Workflow

This protocol was tested in multiple stages.

### Manual install test

The template files were manually installed into a fresh test project.

Verified behavior:

- `AGENTS.md` was copied into the project root.
- `CLAUDE.md` was copied into the project root.
- `AI_HANDOFF.md` was copied into the project root.
- `.gitignore` was configured to ignore `AI_HANDOFF.md`.
- Git tracked only stable files.
- `AI_HANDOFF.md` remained local.

### End-to-end handoff test

A fresh test project was used to validate the workflow.

Verified behavior:

- A task was written into `AI_HANDOFF.md`.
- Claude Code implemented only the requested scope.
- Claude Code updated `AI_HANDOFF.md`.
- Codex reviewed only the file listed under `Changed Files`.
- Codex requested a correction when the output was incomplete.
- The correction was applied.
- Codex approved the final result.
- Only the intended changed file was committed.

### Codex Skill test

The Codex Skill was tested in a project with an active `AI_HANDOFF.md`.

Verified behavior:

- Codex read `AI_HANDOFF.md` first.
- Codex identified `State`.
- Codex identified `Waiting For`.
- Codex recognized when it was Codex's turn.
- Codex stated that it should review only files listed under `Changed Files`.
- Codex did not modify files during the read-only test.

### Package-level install test

The full package was tested in a fresh project using `scripts/install.ps1`.

Verified behavior:

- The installer copied `AGENTS.md`, `CLAUDE.md`, and `AI_HANDOFF.md`.
- The installer created `.gitignore`.
- `AI_HANDOFF.md` was correctly ignored by Git.
- Claude Code read the installed handoff files and created `PACKAGE_TEST.md`.
- Codex reviewed the result and requested a correction.
- Claude Code corrected the missing title.
- Codex approved the final result.
- Only the stable protocol files and the intended test output were committed.

### v0.3.1 validation — Planning Gate and Verification Gate

The v0.3.1 protocol gates were validated in a real project.

Verified behavior:

- Codex classified the task as risky and set `State: PLAN_REQUIRED` / `Waiting For: Claude Code`.
- Claude Code wrote a plan only and did not modify source files.
- Claude Code set `State: PLAN_READY_FOR_REVIEW` / `Waiting For: Codex`.
- Codex reviewed and approved the plan.
- Claude Code implemented the approved scope.
- Codex ran the Verification Gate using `git diff` and `npm.cmd run lint`.
- Codex caught two real issues: the timeout timer was not cleared after a successful AI response, and lint was reported inaccurately.
- Claude Code fixed the timeout cleanup and corrected the verification report.
- Codex approved.
- User committed and pushed: `9d037ed Improve AI chat production error handling`.
- Final gym status was clean.

## Codex Skill

This repository also includes a Codex Skill for the handoff protocol.

Skill path:

```text
.agents/skills/codex-claude-handoff/SKILL.md
```

The skill teaches Codex how to operate its side of the protocol.

It defines the default role split:

- Codex acts as advisor, architect, task writer, and reviewer.
- Claude Code acts as the implementation agent.
- The user remains the approval point.

When active, Codex should:

- Read `AI_HANDOFF.md` first.
- Check `State`.
- Check `Waiting For`.
- Avoid acting if it is not Codex's turn.
- Prepare focused tasks for Claude Code.
- Review only files listed under `Changed Files` by default.
- Update `AI_HANDOFF.md` when analysis or review is complete.

The skill does not replace the template files.

The project still needs:

```text
AGENTS.md
CLAUDE.md
AI_HANDOFF.md
```
Use the install script or manual install steps to place those files into the target project.

## Install Script

A PowerShell install script is available for Windows users.

Use it when you want to install the handoff protocol files into another project without copying them manually.

### Run the installer

From this repository root:

```powershell
.\scripts\install.ps1 -TargetPath "C:\path\to\your-project"
```

Example:

```powershell
.\scripts\install.ps1 -TargetPath "C:\Users\user\Desktop\projects\my-project"
```

If PowerShell blocks script execution, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -TargetPath "C:\path\to\your-project"
```

### What the installer does

The installer copies these files into the target project:

```text
AGENTS.md
CLAUDE.md
AI_HANDOFF.md
```

It also creates or updates:

```text
.gitignore
```

and ensures this rule exists:

```gitignore
AI_HANDOFF.md
```

### Safety behavior

The installer does not overwrite existing protocol files.

If any of these files already exist in the target project, they are skipped:

```text
AGENTS.md
CLAUDE.md
AI_HANDOFF.md
```

This prevents accidental loss of project-specific instructions.

### Verify after install

In the target project, run:

```powershell
git status
```

Expected result:

```text
AGENTS.md
CLAUDE.md
.gitignore
```

`AI_HANDOFF.md` should not appear in `git status`, because it should remain local and ignored by Git.

## Manual Install - Step by Step

Use these steps inside any project where you want Codex and Claude Code to coordinate through this protocol.

### 1. Copy the template files into your project root

From this repository, copy:

```text
templates/AGENTS.md
templates/CLAUDE.md
templates/AI_HANDOFF.md
templates/gitignore-snippet.txt
```

Into the root folder of your target project.

Your target project should then look like this:

```text
your-project/
  AGENTS.md
  CLAUDE.md
  AI_HANDOFF.md
  package.json
  app/
  src/
  ...
```

The exact project files may differ. The important point is that `AGENTS.md`, `CLAUDE.md`, and `AI_HANDOFF.md` sit at the project root.

### 2. Add the handoff file to `.gitignore`

Open your target project `.gitignore` file and add:

```gitignore
# Local AI handoff context
AI_HANDOFF.md
```

This keeps local task context out of Git.

If your project does not have a `.gitignore` file yet, create one.

On Windows PowerShell, you can create it safely with:

```powershell
Set-Content -Path .gitignore -Value "# Local AI handoff context`nAI_HANDOFF.md" -Encoding utf8
```

Then verify that `AI_HANDOFF.md` is ignored:

```bash
git status
```
Expected result: `AI_HANDOFF.md` should not appear in the list of files to commit.

### 3. Customize `AGENTS.md`

Open:

```text
AGENTS.md
```

Replace the placeholder sections with the real project context:

- Project Overview
- Tech Stack
- Architecture Rules
- Do Not Touch

This file tells Codex how to understand and review the project.

### 4. Review `CLAUDE.md`

Open:

```text
CLAUDE.md
```

Usually you do not need to change much here.

This file tells Claude Code how to behave:

- implement only approved tasks
- keep changes small
- update `AI_HANDOFF.md` after implementation
- report changed files and verification results

### 5. Start the first handoff

Open:

```text
AI_HANDOFF.md
```

Set the first task manually, or ask Codex to prepare it.

Typical starting state:

```md
State: NEEDS_ANALYSIS
Waiting For: Codex
```

After Codex prepares a Claude Code task, it should set:

```md
State: READY_FOR_IMPLEMENTATION
Waiting For: Claude Code
```

### 6. Commit the stable protocol files

Commit only the stable files:

```bash
git status
git add AGENTS.md CLAUDE.md .gitignore
git commit -m "Add Codex-Claude handoff protocol"
git push
```

Do not commit `AI_HANDOFF.md` if it is listed in `.gitignore`.

## Basic Workflow

### 1. User asks Codex to analyze a task

Codex reads:

```text
AI_HANDOFF.md
AGENTS.md
```

Then Codex prepares the task for Claude Code by setting:

```md
State: READY_FOR_IMPLEMENTATION
Waiting For: Claude Code
```

### 2. Claude Code implements

Claude Code reads:

```text
AI_HANDOFF.md
CLAUDE.md
AGENTS.md
```

Claude Code implements only the requested scope.

After finishing, Claude Code updates `AI_HANDOFF.md` and sets:

```md
State: READY_FOR_REVIEW
Waiting For: Codex
```

### 3. Codex reviews

Codex reviews only files listed under:

```md
## Changed Files
```

Then Codex sets:

```md
State: REVIEW_DONE
Waiting For: User
```

### 4. User approves and commits

The user commits the approved change.

Recommended Git flow:

```bash
git status
git add AGENTS.md CLAUDE.md .gitignore
git commit -m "Add Codex-Claude handoff protocol"
git push
```

Do not commit `AI_HANDOFF.md` if it is listed in `.gitignore`.

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
| `BLOCKED` | Work is blocked. Reason must be documented. |
| `WAITING_FOR_USER` | User input or approval is needed. |

## Current Scope

This repository currently includes:

1. reusable templates
2. manual install instructions
3. PowerShell install script
4. Codex Skill
5. tested manual, end-to-end, skill, and package-level workflows
6. protocol gates: Investigation Gate, Planning Gate, Verification Gate, unsafe command rules, skill fallback, Claude skill awareness

Next possible steps:

1. evaluate whether Claude Code needs a separate skill or whether `CLAUDE.md` is sufficient
2. improve cross-platform installation
3. add release/versioning once the workflow stabilizes

### v0.4.0 validation

v0.4.0 was validated in the real `gym` project with a small AI chat wording task.
The workflow confirmed that `next-step.ps1` can guide the user through Codex -> Claude Code -> Codex -> User using short ready-to-paste prompts.
