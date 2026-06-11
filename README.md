# Codex-Claude Handoff

A simple collaboration protocol for using **Codex** and **Claude Code** together in the same software project.

The goal is to avoid copy-pasting long context between tools.

## Concept

The protocol is organized around three roles, bound to concrete tools in `.ai/roles/ROLE_ASSIGNMENT.md`:

- **Master** acts as advisor, architect, task writer, and decision router.
- **Implementer** acts as the implementation agent (and a read-only repo-local partner during investigation/planning).
- **Reviewer** independently reviews implementation against approved scope.
- The user remains the approval point.

Default binding: Master = Codex, Reviewer = Codex, Implementer = Claude Code. Roles can be reassigned with user approval without rewriting the protocol. All roles coordinate through a shared file: `AI_HANDOFF.md`.

## Files

```text
templates/
  AGENTS.md
  CLAUDE.md
  AI_HANDOFF.md
  gitignore-snippet.txt
```

### `AGENTS.md`

Project context plus the Master + Reviewer protocol. Read by the tool that follows the `AGENTS.md` convention (by default Codex), which resolves its role via `.ai/roles/ROLE_ASSIGNMENT.md`.

Use it for:

- project context
- architecture rules
- Master + Reviewer role behavior
- review rules
- coordination flow

### `CLAUDE.md`

Operational entry file for Claude Code. Resolves its role via `.ai/roles/ROLE_ASSIGNMENT.md` (default: Implementer).

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

On macOS/Linux:

```bash
bash scripts/next-step.sh
```

`--copy-prompt` is not supported in the Bash version; copy the prompt manually. `--prepare-file` is supported.

The script reads `AI_HANDOFF.md` and prints the current `State`, `Waiting For`, and `Current Task`, followed by a recommended prompt based on the current state. Add `-CopyPrompt` to also copy the prompt to the clipboard. The script also prints a warning when the handoff looks inconsistent.

### PrepareFile Mode

Add `-PrepareFile` to write `NEXT_TURN.md` to the project root:

```powershell
.\scripts\next-step.ps1 -PrepareFile
```

`NEXT_TURN.md` is an entry brief derived from the current `AI_HANDOFF.md` state. It surfaces the actor, action, and `Next Recommended Step` so the target tool can orient before reading the full handoff file.

With `NEXT_TURN.md` written, paste this into the target tool:

```text
Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state.
```

`NEXT_TURN.md` does not replace `AI_HANDOFF.md`. The target tool must still read `AI_HANDOFF.md` before acting. `AI_HANDOFF.md` remains the source of truth.

`NEXT_TURN.md` is ephemeral and local - it is always re-generated and must never be committed. The install script adds it to `.gitignore` automatically.

You can combine both flags:

```powershell
.\scripts\next-step.ps1 -PrepareFile -CopyPrompt
```

This writes `NEXT_TURN.md` and also copies the tool prompt to your clipboard. `-PrepareFile` prints the short paste to the terminal; `-CopyPrompt` preserves its existing behavior of copying the protocol prompt (`$PromptText`) to the clipboard.

## Handoff Operator

A higher-level helper script with named commands for the daily workflow.

Run from your project root:

```powershell
.\scripts\handoff.ps1 <command>
```

On macOS/Linux:

```bash
bash scripts/handoff.sh <command>
```

### `status`

Print the current state, waiting party, task, and commit status in plain English.

```powershell
.\scripts\handoff.ps1 status
```

Example output:

```
State:        REVIEW_DONE
Waiting For:  User
Task:         v0.9.1 - Encoding-safe handoff instructions
Commit:       ALLOWED - the Reviewer approved. Commit only the files listed under Changed Files.
Roles:        Master=Codex, Reviewer=Codex, Implementer=Claude Code
```

### `next`

Generate or refresh `NEXT_TURN.md` and print exactly which tool to open and what to paste.

```powershell
.\scripts\handoff.ps1 next
.\scripts\handoff.ps1 next -Clip   # also copies the paste instruction to clipboard
```

### `start "<natural user request>"`

Save your request to the local ignored file `USER_REQUEST.md` and print a ready-made Master entry prompt.

```powershell
.\scripts\handoff.ps1 start "Add better error handling to the AI chat component"
.\scripts\handoff.ps1 start "Add better error handling to the AI chat component" -Clip
```

The Master remains the decision router. The prompt tells the Master tool to read `USER_REQUEST.md`, `AI_HANDOFF.md`, and local protocol instructions before routing.

`USER_REQUEST.md` is ephemeral and local - it is never committed. The install script adds it to `.gitignore` automatically.

### `commit-check`

Show whether a commit is allowed and which files to commit. Never runs git commands automatically.

```powershell
.\scripts\handoff.ps1 commit-check
```

When `State: REVIEW_DONE` and `Waiting For: User`, the command lists the changed files and prints suggested `git add`, `git commit`, and `git push` commands as text only. You run them yourself after confirming the list.

### `cycle [-BudgetUsd N]`

Run one bounded handoff cycle: at most one Claude Code Implementer turn, then prepare the
next handoff (typically the Reviewer prompt) and stop. Requires `npx`; a network connection
is needed only if the package is not cached.

```powershell
.\scripts\handoff.ps1 cycle
.\scripts\handoff.ps1 cycle -BudgetUsd 5   # raise the budget cap
```

`run-next` is a fully supported alias of `cycle` (same implementation, kept for backward
compatibility).

**Eligible state:** `cycle` only automates `State: READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer`, and only when the Implementer is bound to Claude Code. All other states are blocked with a message and exit code 1.

**Blocked states and manual workflow:**

| State | Waiting For | What to do instead |
|---|---|---|
| READY_FOR_IMPLEMENTATION | Implementer (Claude Code) | Eligible - cycle proceeds |
| NEEDS_INVESTIGATION | Implementer | Blocked - run `next` and paste manually |
| PLAN_REQUIRED | Implementer | Blocked - run `next` and paste manually |
| Any | Master | Blocked - open the Master tool and paste the prompt |
| Any | Implementer (not Claude Code) | Blocked - that tool has no local CLI; paste manually |
| Any | User | Blocked - see AI_HANDOFF.md |

Investigation and planning states are blocked because the Claude Code CLI cannot safely restrict file edits to `AI_HANDOFF.md` only in non-interactive mode.

**What cycle does:**
1. Checks eligibility (state, turn ownership, Implementer binding, clean working tree).
2. Refreshes `NEXT_TURN.md` (intentional local handoff-file write).
3. Checks that Claude Code is available via `npx --yes @anthropic-ai/claude-code`.
4. Prints the command it is about to run.
5. Requires you to type exactly `yes` before proceeding.
6. Runs one Claude Code turn with these constraints:
   - `--permission-mode acceptEdits` - file edits auto-accepted in non-interactive mode
   - `--disallowed-tools "Bash"` - shell execution explicitly blocked
   - `--max-budget-usd N` - hard spending cap (default: $2)
   - `--no-session-persistence` - session not saved or resumed
7. Re-reads `AI_HANDOFF.md` after the turn.
8. If the new state is `READY_FOR_REVIEW` / `Waiting For: Reviewer`: refreshes
   `NEXT_TURN.md` for the Reviewer, copies the paste instruction to the clipboard, and stops.
   Otherwise it reports the next actor (tool + role) and stops, or routes an inconsistent
   handoff to the User with exit code 6. `cycle` never runs a second tool turn.

**The Reviewer turn is not automated.** `cycle` prepares and displays the Reviewer handoff;
you paste it into the Reviewer tool yourself. The default Reviewer (Codex) has no local CLI,
and automatic review of an automated implementation would weaken the independent-review
invariant.

**Bash is blocked during the assisted turn.** Claude Code cannot run tests, typecheck, or lint. Run these manually after the turn completes.

**No automatic commit, push, or deploy.** `cycle` never calls `git add`, `git commit`, `git push`, deploy commands, DB commands, or secret commands.

**No Master automation.** The default Master (Codex) has no local CLI, so Master turns always remain manual. `cycle` only automates an Implementer bound to Claude Code.

**macOS/Linux.** `cycle` requires PowerShell (`handoff.ps1`). If you have `pwsh` on macOS/Linux, use `pwsh scripts/handoff.ps1 cycle`. Without `pwsh`, use `bash scripts/handoff.sh next` to generate `NEXT_TURN.md` and paste the prompt manually. `bash scripts/handoff.sh cycle` prints a blocked message and exits 1.

**npx first-run behavior.** `npx --yes @anthropic-ai/claude-code` downloads the package automatically on first run. If the network is unavailable and the package is not cached, the preflight check fails and `cycle` exits with code 3.

**Exit codes:** 0 success, 1 blocked, 2 cancelled, 3 prerequisite missing, 4 NEXT_TURN.md failure, 5 Claude Code error, 6 turn succeeded but the post-turn handoff is inconsistent (`Waiting For` mismatch or unrecognized state - resolve in AI_HANDOFF.md before continuing).

---

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

Prepare a focused Implementer task in AI_HANDOFF.md.
Set State: READY_FOR_IMPLEMENTATION.
Set Waiting For: Implementer.
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
Set Waiting For: Reviewer.
List changed files, verification results, open issues, risks, and the next recommended step.
```

## Natural Request Mode

You do not need to know the protocol states. Paste your request into the Master tool
(Codex by default) and it will classify the task, choose the appropriate gate, set
`AI_HANDOFF.md`, and give the Implementer a focused instruction.

Example:

```text
Add better error handling to the AI chat component.
```

The Master classifies this, selects a gate if needed, and updates `AI_HANDOFF.md`.
You still approve all commits, pushes, deploys, DB work, migrations, secrets, and
production changes.

The Master uses a six-path decision router for natural requests: advisory (answer directly, no handoff), investigation, planning, implementation, user decision, and review. Advisory-first means the Master answers questions and advisory requests directly without creating an Implementer task - only explicit action requests ("add", "fix", "implement") trigger a handoff. Risky topics phrased as questions stay advisory or route to a user decision, not automatic Implementer tasks.

## Daily Workflow

Run this from the project root:

```powershell
.\scripts\next-step.ps1
```

On macOS/Linux:

```bash
bash scripts/next-step.sh
```

The script reads `AI_HANDOFF.md` and prints a three-block turn dashboard:

- **Handoff Status** - current State, Waiting For, and Current Task.
- **Next Action** - the role/tool that should act next, the action required, and whether a commit is allowed.
- **Prompt** - a ready-to-paste prompt, printed only when the next role is the Master or the Implementer.

The script resolves the next role to the bound tool. Paste the Prompt into that tool. The tool acts, updates `AI_HANDOFF.md`, and the cycle continues.

The `Commit:` line in Next Action is the commit signal:

- `Commit: ALLOWED` means the Reviewer has approved. Commit only the files listed under Changed Files.
- `Commit: Blocked - ...` means a review or decision is still pending. Do not commit.

Do not commit `AI_HANDOFF.md`.

## Short Workflow Example

A typical handoff cycle looks like this:

1. **The Master prepares the task.** The Master reads `AI_HANDOFF.md`, analyzes the request, and writes a focused implementation task. It sets `State: READY_FOR_IMPLEMENTATION` and `Waiting For: Implementer`.

2. **The Implementer implements the scoped task.** The Implementer reads `CLAUDE.md` and `AI_HANDOFF.md`, implements only the requested scope, and makes no unrelated changes.

3. **The Implementer updates `AI_HANDOFF.md` to `READY_FOR_REVIEW`.** After finishing, the Implementer records changed files, verification results, and risks, then sets `State: READY_FOR_REVIEW` and `Waiting For: Reviewer`.

4. **The Reviewer reviews only `Changed Files`.** The Reviewer reads `AI_HANDOFF.md` and reviews only the files listed under the `Changed Files` section. It sets `State: REVIEW_DONE` and `Waiting For: User`.

5. **User commits only the real source changes.** The user reviews the result and commits the approved source files. `AI_HANDOFF.md` is not committed.

`AI_HANDOFF.md` is a working coordination file - it tracks current task state between tools and sessions. It is not a source file and should stay out of version control. A `.gitignore` rule for it is included in `gitignore-snippet.txt` and applied automatically by the install script. The user remains the final approval point for all commits and pushes.

## Protocol Gates

Three optional gates can be inserted before or after implementation depending on task risk.

### Investigation Gate

Use when information is missing before a task can be scoped.

The Master sets `State: NEEDS_INVESTIGATION`. The Implementer gathers evidence only - no source-file edits. The Implementer reports findings and sets `State: READY_FOR_REVIEW`.

### Planning Gate

Use for risky tasks (DB migrations, RLS/Auth, security, deployment, architecture changes, large refactors, production AI routing) or any time the goal is to exercise or enforce the Planning Gate before implementation.

**The Master must not write the implementation plan itself.** The Master's role is to: classify the task as risky or plan-required; set `State: PLAN_REQUIRED` and `Waiting For: Implementer`; write clear plan-only instructions under `Next Recommended Step`.

The Implementer writes a plan only - no source-file edits - and sets `State: PLAN_READY_FOR_REVIEW` and `Waiting For: Reviewer`.

The Reviewer reviews the plan. Outcomes: approve (`READY_FOR_IMPLEMENTATION`), request changes (`PLAN_REQUIRED`), or require user approval (`WAITING_FOR_USER`).

### Verification Gate

After every Implementer implementation, the Reviewer should verify using safe read-only commands (`git status`, `git diff`, typecheck, lint, tests where available). The Reviewer must compare actual changes against `Changed Files` and detect scope creep or unlisted edits before approving.

Good verification evidence includes:
- **Commands Run:** list each command and a short result summary (e.g. "git diff: 3 files changed, 28 insertions, 4 deletions")
- **Skipped commands:** state why (e.g. "lint: not run - documentation change only")
- **Manual Check:** state expected vs actual, not just "looks good"

Vague entries like "not run" or "not applicable" without explanation are not sufficient evidence for the Reviewer to approve.

### Unsafe Command Rules

No role may run the following without explicit user approval:

- Deploy commands
- Live database migrations
- Database reset or destructive data operations
- File deletion or permanent removal
- Production configuration changes
- Secret or environment variable changes

If any are required, set `State: WAITING_FOR_USER` and document the required action under `Open Issues`.

### Skill Fallback

If the `codex-claude-handoff` skill is unavailable, the Master should read `.agents/skills/codex-claude-handoff/SKILL.md` and follow it as local protocol instructions, then confirm the current role binding in `.ai/roles/ROLE_ASSIGNMENT.md`.

### Claude Skill Awareness

The Master may ask the Implementer whether relevant project-local or global Claude skills exist when context is missing for a risky task, the user reports a skill change, or a memory/context skill might help recover prior decisions, constraints, or risks.

When asked, the Implementer should report only relevant skills. Memory or context skills may be used to recover task-relevant prior decisions, constraints, and risks. The Implementer must not expose unrelated private memory. The Master should not ask every session - only when it adds value.

### v0.3.0 Out of Scope (now tracked in ROADMAP.md)

The following were deferred at the v0.3.0 phase. They are now tracked as future milestones
in [ROADMAP.md](ROADMAP.md).

- Full automation between Codex and Claude Code
- File watcher or event-driven orchestration
- Full orchestration CLI (`cycle`/`run-next` run a single bounded turn for `READY_FOR_IMPLEMENTATION` only; full multi-turn orchestration remains out of scope)
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

### v0.3.1 validation - Planning Gate and Verification Gate

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

### v0.6.0 validation - Codex-Led Operating Mode

The v0.6.0 Codex-Led Operating Mode was validated successfully in the real gym project.

Verified behavior:

- The gym project was updated to v0.6.0 without overwriting project-specific `AGENTS.md` context.
- The user gave Codex a natural AI chat improvement request without specifying a State or Gate.
- Codex classified the task as `NEEDS_INVESTIGATION`.
- Claude Code performed a read-only investigation without modifying source files.
- Codex reviewed the findings and narrowed the work to a safe UI-only implementation.
- Claude Code implemented the approved two-file change in `app/chat/chat-interface.tsx` and `app/my-plan/chat-system.tsx`.
- Codex reviewed and approved.
- User committed and pushed: `0ca1576 Improve AI chat error state UX`.
- Final gym status was clean.

## Shared Skill Architecture

The protocol ships with a shared canonical skill folder that both Codex and Claude Code can discover via lightweight adapter stubs.

### Layout

```text
.ai/roles/ROLE_ASSIGNMENT.md        <- role-to-tool binding
.ai/skills/codex-claude-handoff/    <- shared source of truth
  README.md        human-facing overview
  SKILL.md         shared protocol index and role model (skill entrypoint)
  MASTER.md        Master + Reviewer protocol: decision router, gates, states, review
  IMPLEMENTER.md   Implementer protocol: investigation mode, planning mode, implementation
  CODEX.md         Codex entry pointer (resolves role -> MASTER.md or IMPLEMENTER.md)
  CLAUDE.md        Claude Code entry pointer (resolves role -> IMPLEMENTER.md or MASTER.md)
  CAPABILITIES.md  agent capability profile (tool strengths + default role binding)
  VERSION          installed protocol version

.agents/skills/codex-claude-handoff/SKILL.md   <- Codex discovery adapter
.claude/skills/codex-claude-handoff/SKILL.md   <- Claude Code discovery adapter
```

The adapter files are small stubs. All protocol content lives in `.ai/skills/codex-claude-handoff/`.

### File Roles

| File | Role |
|---|---|
| `.ai/roles/ROLE_ASSIGNMENT.md` | Role-to-tool binding (Master / Implementer / Reviewer) |
| `.ai/skills/codex-claude-handoff/SKILL.md` | Shared source of truth - protocol index and role model |
| `.ai/skills/codex-claude-handoff/MASTER.md` | Master + Reviewer role protocol |
| `.ai/skills/codex-claude-handoff/IMPLEMENTER.md` | Implementer role protocol |
| `.ai/skills/codex-claude-handoff/CODEX.md` | Codex entry pointer - resolves Codex's role |
| `.ai/skills/codex-claude-handoff/CLAUDE.md` | Claude Code entry pointer - resolves Claude Code's role |
| `.agents/skills/codex-claude-handoff/SKILL.md` | Codex-facing discovery adapter - points to `.ai/` |
| `.claude/skills/codex-claude-handoff/SKILL.md` | Claude Code-facing discovery adapter - points to `.ai/` |
| Root `CLAUDE.md` | Claude Code **operational entry** file (customized per project) - separate from the skill folder |
| `AI_HANDOFF.md` | Execution state - dynamic, local, not committed |

Root `CLAUDE.md` remains the Claude Code operational behavior file. It is not replaced by the skill folder.

### Install

The installer copies the canonical shared folder and both adapter stubs into target projects. Existing files are never overwritten.

### Skill Location Distinction

Codex and Claude Code discover the protocol through different channels:

- **Codex** reads `.agents/skills/codex-claude-handoff/SKILL.md` (its skill-discovery location), which points to the canonical `.ai/skills/codex-claude-handoff/` folder.
- **Claude Code** is driven by `CLAUDE.md` and the current `AI_HANDOFF.md`. Its own skill-discovery location is `.claude/skills/`, where an adapter stub also points to `.ai/`.

Because of this, when asked to "find the handoff skill", Claude Code should not search only `.claude/skills/`. If the protocol is installed, also check `.agents/skills/codex-claude-handoff/SKILL.md` and the canonical `.ai/skills/codex-claude-handoff/` folder.

## Codex Skill

This repository includes a Codex Skill for the handoff protocol.

Codex adapter path:

```text
.agents/skills/codex-claude-handoff/SKILL.md
```

This adapter points to the canonical shared protocol at `.ai/skills/codex-claude-handoff/`. When active, Codex reads `CODEX.md`, which resolves its current role via `.ai/roles/ROLE_ASSIGNMENT.md` and sends it to the matching role protocol (`MASTER.md` by default), plus `SKILL.md` for the shared index.

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

PowerShell (`install.ps1`) and Bash (`install.sh`) install scripts are available for Windows and macOS/Linux respectively.

Use them to install the handoff protocol files into another project without copying manually.

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

On macOS/Linux, use the Bash installer:

```bash
bash scripts/install.sh /path/to/your-project
```

Example:

```bash
bash scripts/install.sh ~/projects/my-project
```

After install, mark the Bash scripts executable:

```bash
chmod +x /path/to/your-project/scripts/handoff.sh /path/to/your-project/scripts/next-step.sh
```

### What the installer does

The installer copies these files into the target project:

**Root protocol files:**
```text
AGENTS.md
CLAUDE.md
AI_HANDOFF.md
```

**Shared canonical skill architecture:**
```text
.ai/skills/codex-claude-handoff/VERSION
.ai/skills/codex-claude-handoff/README.md
.ai/skills/codex-claude-handoff/SKILL.md
.ai/skills/codex-claude-handoff/MASTER.md
.ai/skills/codex-claude-handoff/IMPLEMENTER.md
.ai/skills/codex-claude-handoff/CODEX.md
.ai/skills/codex-claude-handoff/CLAUDE.md
.ai/skills/codex-claude-handoff/CAPABILITIES.md
.ai/roles/ROLE_ASSIGNMENT.md
```

**Tool-specific skill adapters:**
```text
.agents/skills/codex-claude-handoff/SKILL.md
.claude/skills/codex-claude-handoff/SKILL.md
```

**Workflow scripts:**
```text
scripts/handoff.ps1
scripts/next-step.ps1
scripts/handoff.sh
scripts/next-step.sh
```

It also creates or updates:

```text
.gitignore
```

and ensures these rules exist:

```gitignore
AI_HANDOFF.md
NEXT_TURN.md
USER_REQUEST.md
```

### Safety behavior

The installer does not overwrite existing protocol files or skill files.

If any of these files already exist in the target project, they are skipped:

**Root files:**
```text
AGENTS.md
CLAUDE.md
AI_HANDOFF.md
```

**Skill files:**
```text
.ai/skills/codex-claude-handoff/VERSION
.ai/skills/codex-claude-handoff/README.md
.ai/skills/codex-claude-handoff/SKILL.md
.ai/skills/codex-claude-handoff/MASTER.md
.ai/skills/codex-claude-handoff/IMPLEMENTER.md
.ai/skills/codex-claude-handoff/CODEX.md
.ai/skills/codex-claude-handoff/CLAUDE.md
.ai/skills/codex-claude-handoff/CAPABILITIES.md
.ai/roles/ROLE_ASSIGNMENT.md
.agents/skills/codex-claude-handoff/SKILL.md
.claude/skills/codex-claude-handoff/SKILL.md
```

**Workflow scripts:**
```text
scripts/handoff.ps1
scripts/next-step.ps1
scripts/handoff.sh
scripts/next-step.sh
```

This prevents accidental loss of project-specific instructions, customized skill adapters, or customized workflow scripts.

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
.ai/skills/codex-claude-handoff/VERSION
.ai/skills/codex-claude-handoff/README.md
.ai/skills/codex-claude-handoff/SKILL.md
.ai/skills/codex-claude-handoff/MASTER.md
.ai/skills/codex-claude-handoff/IMPLEMENTER.md
.ai/skills/codex-claude-handoff/CODEX.md
.ai/skills/codex-claude-handoff/CLAUDE.md
.ai/skills/codex-claude-handoff/CAPABILITIES.md
.ai/roles/ROLE_ASSIGNMENT.md
.agents/skills/codex-claude-handoff/SKILL.md
.claude/skills/codex-claude-handoff/SKILL.md
scripts/handoff.ps1
scripts/next-step.ps1
scripts/handoff.sh
scripts/next-step.sh
```

`AI_HANDOFF.md` should not appear in `git status`, because it should remain local and ignored by Git. Same for `NEXT_TURN.md` and `USER_REQUEST.md`.

Then verify the workflow scripts work:

```powershell
.\scripts\handoff.ps1 status
.\scripts\handoff.ps1 next
```

On macOS/Linux (Bash):

```bash
bash scripts/handoff.sh status
bash scripts/next-step.sh
```

Both should run successfully from the target project root.

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

Set the first task manually, or ask the Master to prepare it.

Typical starting state:

```md
State: NEEDS_ANALYSIS
Waiting For: Master
```

After the Master prepares an Implementer task, it should set:

```md
State: READY_FOR_IMPLEMENTATION
Waiting For: Implementer
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

### 1. User asks the Master to analyze a task

The Master reads:

```text
AI_HANDOFF.md
AGENTS.md
```

Then the Master prepares the task for the Implementer by setting:

```md
State: READY_FOR_IMPLEMENTATION
Waiting For: Implementer
```

### 2. The Implementer implements

The Implementer reads:

```text
AI_HANDOFF.md
CLAUDE.md
AGENTS.md
```

The Implementer implements only the requested scope.

After finishing, the Implementer updates `AI_HANDOFF.md` and sets:

```md
State: READY_FOR_REVIEW
Waiting For: Reviewer
```

### 3. The Reviewer reviews

The Reviewer reviews only files listed under:

```md
## Changed Files
```

Then the Reviewer sets:

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

## Two-Way Dialogue

The protocol supports scoped, two-directional questions so the Master and the Implementer can resolve uncertainty without escalating to the user. Each exchange is a discrete turn - there is no automatic loop, and commit stays blocked while a dialogue state is active.

- `QUESTION_FOR_MASTER` - The Implementer asks the Master a scoped question (ambiguous scope, a design choice the Master owns). The Master answers, then returns the working state.
- `QUESTION_FOR_IMPLEMENTER` - The Master asks the Implementer a scoped question (repo reality, feasibility, verification). The Implementer answers read-only.
- `RE_GATE_REQUESTED` - The Implementer finds mid-implementation that the task is riskier or larger than scoped; the Master re-routes it through the Decision Router.

Questions and answers are logged under a `## Dialogue / Open Questions` section in `AI_HANDOFF.md`. The pre-v0.13.0 names `QUESTION_FOR_CODEX` and `QUESTION_FOR_CLAUDE` are still accepted by the workflow scripts as aliases.

## Allowed States

| State | Meaning |
|---|---|
| `NEEDS_ANALYSIS` | The Master should analyze before the Implementer can start. |
| `NEEDS_INVESTIGATION` | Investigation needed; the Implementer gathers evidence only, no source edits. |
| `PLAN_REQUIRED` | Risky task; the Implementer writes a plan only before implementation. |
| `PLAN_READY_FOR_REVIEW` | Plan written; the Reviewer reviews before approving implementation. |
| `READY_FOR_IMPLEMENTATION` | Task is defined and the Implementer should implement. |
| `IMPLEMENTED` | The Implementer finished and no review is required. |
| `READY_FOR_REVIEW` | The Implementer finished and the Reviewer should review. |
| `REVIEW_DONE` | The Reviewer reviewed and the user decides next step. |
| `QUESTION_FOR_MASTER` | The Implementer asked the Master a scoped question; no source edits while waiting. |
| `QUESTION_FOR_IMPLEMENTER` | The Master asked the Implementer a scoped question; the Implementer answers read-only. |
| `RE_GATE_REQUESTED` | The Implementer found the task riskier/larger than scoped; the Master re-routes. |
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

See [ROADMAP.md](ROADMAP.md) for the full milestone plan and acceptance criteria.

## Release Discipline

The following checklist applies before bumping a version and creating a release commit.
Both the Master and the Implementer should verify these before handing off to the Reviewer.

See [ROADMAP.md](ROADMAP.md) for planned milestones and their acceptance criteria.

### Release Checklist

- Working tree status understood: `git status --short --branch` shows only intended changes.
- Version files updated: `.ai/skills/codex-claude-handoff/VERSION` and its `templates/` mirror
  both contain the new version string.
- Changelog entry added: `CHANGELOG.md` has a top entry for the new version.
- Canonical/template mirrors checked: every file in `.ai/skills/codex-claude-handoff/` has a
  matching file in `templates/.ai/skills/codex-claude-handoff/` with identical content.
- Scripts checked: if any `.ps1` script was changed, run the PowerShell parser on it
  (`[System.Management.Automation.Language.Parser]::ParseFile`) and confirm zero syntax errors.
  If scripts were not changed, note that parser checks were skipped.
- `git diff --check`: no trailing whitespace or line-ending issues.
- Changed files accurate: the `Changed Files` list in `AI_HANDOFF.md` matches
  `git status --short --untracked-files=all` before the Reviewer reviews. (`git diff --stat`
  shows tracked file changes but omits new untracked files; use the status command instead.)
- Local-only files not staged: `AI_HANDOFF.md`, `NEXT_TURN.md`, and `USER_REQUEST.md` do not
  appear in the staged file list.

### v0.4.0 validation

v0.4.0 was validated in the real `gym` project with a small AI chat wording task.
The workflow confirmed that `next-step.ps1` can guide the user through Codex -> Claude Code -> Codex -> User using short ready-to-paste prompts.
