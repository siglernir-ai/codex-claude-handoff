# Quick Start

Install `codex-claude-handoff` into one project and activate it only for the tasks
that should use the Codex -> Claude Code -> Codex review workflow.

## Before you start

Install Git, Node.js, Codex Desktop, and use a Claude account that can run Claude
Code. Your target project should be a Git repository with a clean baseline commit.

Claude Code requires a one-time sign-in on a new computer:

```powershell
npx.cmd --yes @anthropic-ai/claude-code
```

Complete the browser sign-in, then close Claude Code. You do not need to open it
manually for normal handoff tasks after that.

## Windows: install the pinned release

Open PowerShell in the project folder and paste this one command. The installer
uses the current folder automatically; do not enter or edit a project path:

```powershell
$setup = Join-Path $env:TEMP "codex-claude-handoff-setup.ps1"; Invoke-WebRequest "https://raw.githubusercontent.com/siglernir-ai/codex-claude-handoff/v3.1.8/bootstrap.ps1" -OutFile $setup; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup
```

The default install is **opt-in**. It does not add root `AGENTS.md` or `CLAUDE.md`
files and does not change normal Codex behavior.

Commit the installed project-local skill files before starting real work:

```powershell
git add .agents .ai .claude scripts .gitignore
git commit -m "Install codex-claude-handoff v3.1.8"
```

Check the installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 doctor
```

## Use it for one task

Open the target project in Codex Desktop. Enter `/skills`, select
`codex-claude-handoff`, and then describe the task:

```text
Fix the login form validation and run the full protocol. Stop before commit.
```

That explicit skill selection is the activation boundary. If you do not select or
mention the skill, Codex works normally in the project.

The workflow may analyze, call Claude Code as Implementer, review with Codex, and run
safe local tests. It stops before commit, push, tag, release, deploy, database work,
or secret changes until the user explicitly authorizes the relevant action.

## Optional always-on mode

Only project owners who want every Codex/Claude session routed through the protocol
should install root instructions:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AlwaysOn
```

`-AlwaysOn` is not the default because it changes agent behavior for the entire
project.

## Updating an installed copy

Download the newer pinned bootstrap script and run it with `-Force`. In opt-in mode,
this refreshes only managed protocol files and leaves project root instructions alone.

Projects upgraded from v3.1.7 or older may still contain the bundled always-on
`AGENTS.md` and `CLAUDE.md`. Migrate them only when those files were not customized:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Project $project -Version v3.1.8 -Force -DisableAlwaysOn
```

The migration compares both root files to the bundled templates before removal. It
fails safely instead of deleting customized project instructions.

## Local clone alternative

Users who prefer to inspect the package before running it can clone the tag and run
the local installer:

```powershell
git clone --branch v3.1.8 --single-branch https://github.com/siglernir-ai/codex-claude-handoff.git C:\Tools\codex-claude-handoff
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\codex-claude-handoff\install.ps1 -Project C:\Projects\MY_PROJECT
```
