# Quick Start

Use this when you just downloaded `codex-claude-handoff` and want to install it into a real project.

## 1. Install into your project

Run this from the `codex-claude-handoff` repo:

```powershell
.\install.ps1 -Project C:\Users\Nir\projects\MY_PROJECT
```

If the protocol is already installed and you intentionally want to refresh it:

```powershell
.\install.ps1 -Project C:\Users\Nir\projects\MY_PROJECT -Force
```

## 2. Open the target project

```powershell
cd C:\Users\Nir\projects\MY_PROJECT
```

Open Codex and Claude Code on this same folder.

## 3. Check the install

```powershell
.\scripts\handoff.ps1 doctor
```

## 4. See what to do next

```powershell
.\scripts\handoff.ps1 work
```

## 5. Start a task

```powershell
.\scripts\handoff.ps1 start "Describe the change you want"
```

Paste the printed Master prompt into Codex.

## Daily Rule

When unsure, run:

```powershell
.\scripts\handoff.ps1 work
```

Commit only through the guarded command printed after review:

```powershell
.\scripts\handoff.ps1 commit-approved -Message "..." -Authorize "I_AUTHORIZE_COMMIT"
```

