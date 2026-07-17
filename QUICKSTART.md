# Quick Start

Use this when you just downloaded `codex-claude-handoff` and want to install it into a real project.

## 1. Install into your project

Run this from the `codex-claude-handoff` repo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Project C:\Users\Nir\projects\MY_PROJECT
```

If the protocol is already installed and you intentionally want to refresh it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Project C:\Users\Nir\projects\MY_PROJECT -Force
```

## 2. Open the target project

```powershell
cd C:\Users\Nir\projects\MY_PROJECT
```

Open Codex and Claude Code on this same folder.

## 3. Check the install

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 doctor
```

## 4. See what to do next

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 work
```

## 5. Start a task

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 start "Describe the change you want"
```

For the manual path, paste the printed Master prompt into Codex.

## 6. Optional: run one bounded autonomous session

To opt the Codex Master, Claude Code Implementer, and Codex Reviewer into one
explicitly authorized session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 loop -IncludeMaster -IncludeReviewer -MaxTurns 3 -BudgetUsd 2 -SessionBudgetUsd 6 -TimeoutSeconds 600
```

Confirm once when prompted. Add `-Yes` only when you intentionally want to skip that
single prompt. The loop stops at the User before commit. It never automates push, tag,
release, deploy, database, or secret actions.

## Daily Rule

When unsure, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 work
```

Commit only through the guarded command printed after review:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 commit-approved -Message "..." -Authorize "I_AUTHORIZE_COMMIT"
```

