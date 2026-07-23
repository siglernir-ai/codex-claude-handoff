# Five-Minute Demo

## What this demo proves

The demo proves one narrow claim: Codex and Claude Code can operate as an
accountable engineering pair on one supervised Git task. Codex establishes scope,
Claude Code implements through durable project-local state, Codex independently
challenges and reviews the result, and the workflow reaches the user approval gate
before commit.

It does not attempt to prove full unattended autonomy, deployment safety, or
performance on a large production change.

## Recording setup

- Use a disposable Git repository with a clean baseline commit.
- Open the same repository folder in VS Code, Codex, and Claude Code.
- Sign in to Claude Code before recording.
- Install v3.3.0 for both agents and complete the bundled setup.
- Run `doctor` and keep its `PASS` result visible briefly.
- Set terminal zoom so the state and command output remain readable at 1080p.
- Record the entire run. Cuts may remove waiting time, but never remove an error,
  retry, warning, or user approval.

## Install and preflight

```powershell
npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.agents\skills\codex-claude-handoff\scripts\setup.ps1 -Project .
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 doctor
git status --short --branch
```

Expected preflight:

- `doctor` ends with `Doctor result: PASS`.
- Git has a clean baseline before the task starts.
- Codex and Claude Code point to the same folder.

## The user prompt

In Codex, enter `/skills`, select `codex-claude-handoff`, and submit this exact
request:

```text
Run a small end-to-end handoff demo in this clean repository.

Create HANDOFF_DEMO_RESULT.md with exactly three sections:
1. Task - one sentence describing this demo.
2. Implementer - state that Claude Code created the file through the handoff.
3. Safety - state that no commit, push, tag, release, deploy, database, or secret action was run.

Use Codex as Master and Reviewer and Claude Code as Implementer. You may use the bounded local automation with a total Claude budget of up to USD 2 and a 240-second timeout. Run relevant safe verification. Stop at REVIEW_DONE before commit and show me the evidence and the guarded next action.
```

## Expected workflow

1. Codex reads the Skill and confirms the current role binding.
2. Codex writes or routes the task in `AI_HANDOFF.md`.
3. The bounded Claude Code turn creates only `HANDOFF_DEMO_RESULT.md` and moves the
   handoff to review.
4. Codex reviews the exact changed-file scope and the requested content.
5. The state reaches `REVIEW_DONE / Waiting For: User`.
6. The user receives guarded commit guidance. No commit is run during the demo.

The automation may use the equivalent of:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 loop -Yes -IncludeMaster -IncludeReviewer -MaxTurns 5 -SessionBudgetUsd 2 -TimeoutSeconds 240
```

The exact command should be shown by the tool rather than silently hidden.

## Final evidence shot

Run or ask Codex to show:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 user-next
git status --short --branch
Get-Content .\HANDOFF_DEMO_RESULT.md
```

The recording should visibly contain:

- `State: REVIEW_DONE` and `Waiting For: User`.
- Claude Code named as Implementer and Codex named as Reviewer.
- Exactly one task file in Git status.
- The requested three sections in the file.
- A commit command offered as the next action, not already executed.

## 45-second edit

| Time | Screen | Caption |
|---|---|---|
| 0-4s | VS Code with Codex and terminal | "One drives. One challenges. Neither ships alone." |
| 4-9s | `doctor` result | "Project-local, explicit, and health-checked." |
| 9-15s | User submits the exact prompt | "The user states the task and spend boundary." |
| 15-25s | Handoff state and Claude turn | "Codex routes. Claude Code implements." |
| 25-34s | Codex review output | "The Implementer cannot approve its own work." |
| 34-41s | `REVIEW_DONE / User` | "The workflow stops before commit." |
| 41-45s | GitHub and skills.sh links | "The handoff is transport. Accountability is the product." |

## Failure policy

If the run times out, greets instead of acting, changes an extra file, or fails a
review guard, keep that evidence. Do not recreate the result file manually for the
recording. Diagnose the failure, fix the product, and record a new complete run.

## Evidence already available

The launch claim is also backed by the public v3.3.0 acceptance work:

- 221 protocol checks passed.
- A clean install from the public v3.3.0 tag installed the Skill for Codex and
  Claude Code.
- Bundled setup completed and `handoff.ps1 doctor` returned `PASS`.
- The public release ZIP matched its published SHA-256 checksum.

## Recorded public-beta run

The live run was completed on 2026-07-23 and rendered as:

- `assets/codex-claude-handoff-live-demo.mp4`
- `assets/codex-claude-handoff-live-demo.gif`
- `assets/codex-claude-handoff-live-demo-poster.png`

The recording preserves a real failed-closed Reviewer preflight caused by a
non-exact Changed Files entry. Only the local coordination line was repaired; the
task deliverable was not edited. Codex then reviewed the file read-only and the
workflow reached `REVIEW_DONE / Waiting For: User` with no task commit. Full scope
and transcript hashes are documented in `LIVE_DEMO_EVIDENCE.md`.
