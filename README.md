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
| `READY_FOR_IMPLEMENTATION` | Task is defined and Claude Code should implement. |
| `IMPLEMENTED` | Claude Code finished and no review is required. |
| `READY_FOR_REVIEW` | Claude Code finished and Codex should review. |
| `REVIEW_DONE` | Codex reviewed and user decides next step. |
| `BLOCKED` | Work is blocked. Reason must be documented. |
| `WAITING_FOR_USER` | User input or approval is needed. |

## Current Scope

This repository intentionally starts simple:

1. reusable templates
2. manual install instructions
3. optional install script later
4. Codex skill later
5. Claude Code skill later

Avoid jumping directly to automation before the manual workflow is stable.