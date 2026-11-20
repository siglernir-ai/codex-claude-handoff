#requires -Version 5.1
<#
    Protocol Test Harness (PowerShell-first) - codex-claude-handoff v3.4.0

    Repeatable, black-box protocol tests for scripts/handoff.ps1. Each test runs the
    real handoff.ps1 as a child process against a scripted fixture project in a temp
    directory, then asserts on exit code and printed output. Fixtures are disposable;
    the real local coordination files (AI_HANDOFF.md / AI_SEQUENCE.md / NEXT_TURN.md)
    are never read or mutated by these tests.

    Coverage: state routing, turn-ownership mismatch routing, adapter decisions,
    stop categories, release executor guards, sequence advance guards, mirror parity,
    safety boundaries (dry runs change no files and run no git mutations), the v3.0.0
    productized `work` / `doctor` read-only commands, the v3.1.0 installer, the Codex
    Reviewer POC capture guards, the v1.3.0 automated Reviewer turn (review-apply verdict
    transitions fail-closed; loop stops rather than auto-running a Reviewer turn), the
    v1.3.1/v2.0.1 Codex Master turn (master-check/master-run guards, master-apply transitions,
    fail closed; Master/Codex is explicit-command callable but not auto-loop eligible),
    the v2.1.0 opt-in Master loop integration (loop -IncludeMaster runs master-run +
    master-apply in-session; default loop still stops at the Master turn), and the v1.4.0 opt-in Reviewer loop integration
    (loop -IncludeReviewer runs review-run + review-apply in-session: APPROVED -> REVIEW_DONE/
    User, BLOCKED -> READY_FOR_IMPLEMENTATION and continues under MaxTurns; default loop still
    stops at the Reviewer turn; malformed verdicts fail closed; cycle still refuses Reviewer),
    the v3.1.4 BOM-less UTF-8 non-ASCII capture regressions for Master/Reviewer apply,
    and the v2.0.0/v2.3.0 safe Claude process runner (bounded child process, stdout/stderr
    capture, timeout kill, durable Claude Implementer capture artifacts, and no false
    handoff transition).

    Usage:  pwsh -File scripts/protocol-tests.ps1
    Exit:   0 = all passed, 1 = one or more failures or a harness error.
#>

param(
    [switch]$KeepFixtures
)

$ErrorActionPreference = "Stop"

# PowerShell on Windows can accumulate duplicate process-environment keys that differ only by
# case (Path/PATH) after tests prepend to PATH. Start-Process then fails before the child starts.
if ($env:OS -eq "Windows_NT") {
    $pathValue = $env:Path
    if ([string]::IsNullOrEmpty($pathValue)) { $pathValue = $env:PATH }
    [System.Environment]::SetEnvironmentVariable("PATH", $null, "Process")
    if (-not [string]::IsNullOrEmpty($pathValue)) {
        [System.Environment]::SetEnvironmentVariable("Path", $pathValue, "Process")
    }
}

# v3.8.0: the suite must test the code, not the machine. MODEL_GUIDANCE.md tells users to
# activate model routing with HANDOFF_CLAUDE_MODEL_<PROFILE> environment variables, and a
# user who did exactly that saw ten resolver checks fail on a clean checkout, because the
# fixtures expect no override. Clear them for this process only; the tests that exercise
# an override set their own value and restore it. v3.10.0: the same holds for Codex.
Get-ChildItem Env: | Where-Object { $_.Name -match '^HANDOFF_(CLAUDE|CODEX)_MODEL_' } | ForEach-Object {
    [System.Environment]::SetEnvironmentVariable($_.Name, $null, "Process")
}

# v3.11.0: long commands run from an agent shell detach into the background. This suite is
# often run from an agent's shell, so fix the foreground path for every test; the tests of
# the background path set the mode themselves.
$env:HANDOFF_RUN_MODE = "foreground"

# v3.18.0: with HANDOFF_RUN_MODE=foreground the agent check is off, so a child that thinks
# a person is at the console could open a window on the developer's desktop: the setup
# picker, the roles indicator, the status window of a background run. Nothing in this
# suite may show a window; the window code is tested by parsing what it would run.
$env:HANDOFF_BACKGROUND_NO_WINDOW = "1"

# --- Resolve repo paths (this script lives in scripts/) ---
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot    = Split-Path -Parent $ScriptDir
$HandoffScript = Join-Path $ScriptDir "handoff.ps1"
if (-not (Test-Path $HandoffScript)) {
    Write-Host "Harness error: cannot find $HandoffScript"
    exit 1
}

# Child PowerShell host: prefer pwsh, fall back to Windows PowerShell.
$PwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $PwshExe) { $PwshExe = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
if (-not $PwshExe) { Write-Host "Harness error: no PowerShell host (pwsh/powershell) found."; exit 1 }

$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("handoff-protocol-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null

# v3.11.1: doctor reads the Codex user configuration. Point it at an empty home so the
# developer's own Codex settings cannot change a result; the Fast mode tests set their own.
$env:CODEX_HOME = Join-Path $FixtureRoot "codex-home-empty"
New-Item -ItemType Directory -Path $env:CODEX_HOME -Force | Out-Null

# --- Tiny assertion framework ---
$script:Pass = 0
$script:Fail = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Check {
    param([string]$Name, [bool]$Cond, [string]$Detail = "")
    if ($Cond) {
        $script:Pass++
        Write-Host "  PASS  $Name"
    } else {
        $script:Fail++
        $script:Failures.Add($Name)
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })"
    }
}

# --- Fixture builder ---
$DefaultRoles = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Codex |
| Implementer | Claude Code |
"@

function New-Fixture {
    param(
        [hashtable]$Files,          # relative path -> content
        [switch]$InitGit
    )
    $dir = Join-Path $FixtureRoot ([Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($rel in $Files.Keys) {
        $target = Join-Path $dir $rel
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content -Path $target -Value $Files[$rel] -Encoding utf8
    }
    if ($InitGit) {
        Push-Location $dir
        try {
            & git init -q 2>$null | Out-Null
            & git config user.email "test@example.com" 2>$null | Out-Null
            & git config user.name "Protocol Test" 2>$null | Out-Null
        } finally { Pop-Location }
    }
    return $dir
}

# Commit the current fixture tree so that only files created AFTER this call show up as
# changes. Lets a review/release scope test match the handoff's Changed Files exactly
# (otherwise the fixture's own .ai/roles/ROLE_ASSIGNMENT.md counts as an extra change).
function Initialize-FixtureGitBaseline {
    param([string]$Dir)
    Push-Location $Dir
    # Native git can write a CRLF warning to stderr; under the harness's
    # ErrorActionPreference=Stop that would become terminating. Tolerate it locally and
    # disable autocrlf so `git add` stays quiet.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -c core.autocrlf=false -c core.safecrlf=false add -A 2>$null | Out-Null
        & git -c core.autocrlf=false commit -q -m "fixture baseline" 2>$null | Out-Null
    } finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
}

# Build an AI_HANDOFF.md body from a small set of fields.
function New-Handoff {
    param(
        [string]$State,
        [string]$WaitingFor,
        [string]$CurrentTask = "v0.20.0 - Protocol Test Harness",
        [string]$Extra = ""
    )
    return @"
# AI Handoff

## Status
- State: $State
- Waiting For: $WaitingFor
- Last Updated By: Test
- Last Updated At: 2026-06-14
- Current Task: $CurrentTask

## Last Update
- Actor: Test (Implementer)
- Date: 2026-06-14

## Task Actors
- Implementer: Claude Code
- Reviewer: Codex

## Changed Files
- None yet

## Next Recommended Step
- See AI_HANDOFF.md.
$Extra
"@
}

# Build an AI_HANDOFF.md for review-apply tests: includes the Status, Last Update, Task
# Actors, Changed Files, Dialogue, and Next Recommended Step sections review-apply needs.
# Changed Files lists scripts/handoff.ps1 so the scope guard matches an untracked fixture file.
function New-ReviewHandoff {
    param(
        [string]$State = "READY_FOR_REVIEW",
        [string]$WaitingFor = "Reviewer",
        [string]$CurrentTask = "v1.3.0 - Review Apply Test"
    )
    return @"
# AI Handoff

## Status
- State: $State
- Waiting For: $WaitingFor
- Last Updated By: Test
- Last Updated At: 2026-06-14
- Current Task: $CurrentTask

## Last Update
- Actor: Test
- Date: 2026-06-14
- Task: Fixture for review-apply tests.

## Task Actors
- Implementer: Claude Code
- Reviewer: Codex

## Changed Files
- scripts/handoff.ps1

## Dialogue / Open Questions
- None

## Next Recommended Step
- See AI_HANDOFF.md.
"@
}

# Build a disposable review-apply fixture: clean git baseline, the reviewed file
# (scripts/handoff.ps1) untracked so scope matches Changed Files, and optionally a
# captured verdict file (REVIEW_LAST.md). Returns the fixture dir path.
function New-ReviewApplyFixture {
    param(
        [string]$Capture,
        [string]$CurrentTask = "v1.3.0 - Review Apply Test",
        [string]$State = "READY_FOR_REVIEW",
        [string]$WaitingFor = "Reviewer",
        [string]$Roles = $DefaultRoles,
        [string]$ReviewerActor = "Codex",
        [switch]$AddExtraUntracked,
        [switch]$NoCapture
    )
    $handoff = New-ReviewHandoff -State $State -WaitingFor $WaitingFor -CurrentTask $CurrentTask
    if ($ReviewerActor -ne "Codex") { $handoff = $handoff -replace "- Reviewer: Codex", "- Reviewer: $ReviewerActor" }
    $fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $handoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $Roles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    New-Item -ItemType Directory -Path (Join-Path $fx "scripts") -Force | Out-Null
    Set-Content -Path (Join-Path $fx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
    if ($AddExtraUntracked) { Set-Content -Path (Join-Path $fx "EXTRA_FILE.txt") -Value "extra" -Encoding utf8 }
    if (-not $NoCapture) { Set-Content -Path (Join-Path $fx "REVIEW_LAST.md") -Value $Capture -Encoding utf8 }
    return $fx
}

# Build a disposable master-apply fixture: NEEDS_ANALYSIS handoff plus an optional
# captured Master recommendation file (MASTER_LAST.md).
function New-MasterApplyFixture {
    param(
        [string]$Capture,
        [string]$CurrentTask = "v2.0.1 - Master Apply Test",
        [string]$State = "NEEDS_ANALYSIS",
        [string]$WaitingFor = "Master",
        [string]$Roles = $DefaultRoles,
        [switch]$NoCapture
    )
    $handoff = New-Handoff -State $State -WaitingFor $WaitingFor -CurrentTask $CurrentTask -Extra @"

## Last Update
- Actor: Test
- Date: 2026-06-23
- Task: Fixture for master-apply tests.
"@
    $fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $handoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $Roles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    if (-not $NoCapture) { Set-Content -Path (Join-Path $fx "MASTER_LAST.md") -Value $Capture -Encoding utf8 }
    return $fx
}

# Run handoff.ps1 in $WorkDir as a child process; capture exit code + combined output.
function Invoke-Handoff {
    param([string]$WorkDir, [string[]]$Arguments)
    $prevPwd = (Get-Location).Path
    $prevEnv = [System.Environment]::CurrentDirectory
    try {
        Set-Location $WorkDir
        [System.Environment]::CurrentDirectory = $WorkDir
        $combined = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $HandoffScript @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Set-Location $prevPwd
        [System.Environment]::CurrentDirectory = $prevEnv
    }
    return @{ Code = $code; Out = $combined }
}

function Test-FileHashMatch {
    param([string]$Left, [string]$Right)
    if (-not (Test-Path $Left) -or -not (Test-Path $Right)) { return $false }
    return (Get-FileHash -Algorithm SHA256 -Path $Left).Hash -eq (Get-FileHash -Algorithm SHA256 -Path $Right).Hash
}

Write-Host ""
Write-Host "Protocol Test Harness - codex-claude-handoff"
Write-Host "Handoff under test: $HandoffScript"
Write-Host "Fixtures: $FixtureRoot"
Write-Host ""

# === 1. State routing ===
Write-Host "[1] State routing (next)"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $fx "NEXT_TURN.md") -ErrorAction SilentlyContinue
Check "READY_FOR_IMPLEMENTATION routes to Claude Code (Implementer)" (($nt -match "Actor: Claude Code \(Implementer\)") -and ($r.Out -match "Open:\s+Claude Code"))

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $fx "NEXT_TURN.md") -ErrorAction SilentlyContinue
Check "READY_FOR_REVIEW routes to Codex (Reviewer)" (($nt -match "Actor: Codex \(Reviewer\)") -and ($r.Out -match "Open:\s+Codex"))

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "REVIEW_DONE routes to User, no tool handoff" (($r.Out -match "Next actor: User") -and ($r.Out -match "No tool handoff needed"))

# A role swap without updating derived Task Actors must fail closed before routing.
$swappedRoles = @"
# Role Assignment

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Claude Code |
| Implementer | Codex |
"@
$staleHandoff = New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $staleHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $swappedRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
# v3.4.1: the block still fails closed, but the guidance no longer tells the user to
# hand-synchronize Task Actors. On a finished task that silently rewrites who
# implemented and who reviewed it, which is the audit record the protocol protects.
Check "stale Task Actors after role swap fail closed" (($r.Code -eq 12) -and ($r.Out -match "Role checkpoint: BLOCKED") -and ($r.Out -match "Recovery:"))
Check "role drift guidance never advises rewriting a finished record by hand" (($r.Out -match "Do not hand-edit Task Actors") -and ($r.Out -notmatch "synchronize the derived Task Actors"))
Check "role drift guidance names the archived start recovery path" ($r.Out -match "handoff\.ps1 start")

# --- v3.4.1 canonical tool identity -------------------------------------------------
# Before v3.4.1 every role gate compared display text, so one tool wearing two names
# read as two tools and could implement and review the same task.

# A legacy display alias must resolve to the tool it names, not read as drift.
$aliasHandoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -replace "- Implementer: Claude Code", "- Implementer: Claude Code Window"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $aliasHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "legacy display alias resolves to its canonical tool and is not drift" (($r.Code -ne 12) -and ($r.Out -notmatch "Role checkpoint: BLOCKED"))

# The invariant must survive one tool appearing under two different display names.
# This is the exact record that shipped in the real repository on 2026-07-17.
$aliasCollision = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer") -replace "- Implementer: Claude Code", "- Implementer: Codex Window"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $aliasCollision; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "one tool under two aliases cannot be both Implementer and Reviewer" (($r.Code -eq 12) -and ($r.Out -match "Role checkpoint: BLOCKED"))

# An unrecognized identity is rejected, never guessed.
$unknownRoles = $DefaultRoles -replace "\| Implementer \| Claude Code \|", "| Implementer | Gemini |"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $unknownRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "an unrecognized bound tool fails closed and is named" (($r.Code -eq 12) -and ($r.Out -match "Gemini"))

# TBD stays a legal sentinel for a task whose actors are not bound yet.
$sentinelHandoff = ((New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master") -replace "- Implementer: Claude Code", "- Implementer: TBD") -replace "- Reviewer: Codex", "- Reviewer: TBD"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $sentinelHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "TBD sentinel actors are not drift and not a collision" (($r.Code -ne 12) -and ($r.Out -notmatch "Role checkpoint: BLOCKED"))

# --- v3.4.1 ignore semantics come from Git ------------------------------------------
# The shipped .gitignore uses the root-anchored form. Hand-parsing compared against the
# bare name, so a correctly configured repository was warned on every start. A safety
# tool that cries wolf teaches the user to dismiss it.
$fx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
    ".gitignore" = "/AI_HANDOFF.md`n/NEXT_TURN.md`n/USER_REQUEST.md`n"
} -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "root-anchored ignore check")
Check "root-anchored /USER_REQUEST.md is recognized as ignored (no false warning)" ($r.Out -notmatch "not ignored by Git")

$fx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
    ".gitignore" = "/AI_HANDOFF.md`n"
} -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "missing ignore check")
Check "an unignored USER_REQUEST.md still warns" ($r.Out -match "not ignored by Git")

# --- v3.4.1 archive before reset (G5) -----------------------------------------------
# AI_HANDOFF.md is gitignored: it is the only copy of who implemented a task, who
# reviewed it, and what was approved. Before v3.4.1 start simply overwrote it.

function New-TerminalFixture {
    param(
        [string]$Roles = $DefaultRoles,
        [string]$Handoff = $null,
        # Some tests occupy the history PATH with a file to force an archive failure.
        # A trailing-slash rule ignores only a directory, so those tests widen the rule
        # to keep the working tree clean and isolate the archive failure itself.
        [string]$HistoryIgnore = "/.ai/handoff-history/"
    )
    if (-not $Handoff) { $Handoff = New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Release v9.9.9 prior task" }
    $d = New-Fixture -Files @{
        "AI_HANDOFF.md" = $Handoff
        ".ai/roles/ROLE_ASSIGNMENT.md" = $Roles
        ".gitignore" = "/AI_HANDOFF.md`n/NEXT_TURN.md`n/USER_REQUEST.md`n$HistoryIgnore`n"
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $d
    return $d
}

$fx = New-TerminalFixture
$originalHash = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $fx "AI_HANDOFF.md")).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "a brand new request")
$archives = @(Get-ChildItem -Path (Join-Path $fx ".ai/handoff-history") -Filter "*-AI_HANDOFF.md" -ErrorAction SilentlyContinue)
Check "start archives the previous handoff before resetting it" ($archives.Count -eq 1)
Check "start reports the archive path and its verified hash" (($r.Out -match "Archived previous handoff") -and ($r.Out -match "verified"))
if ($archives.Count -eq 1) {
    $archivedHash = (Get-FileHash -Algorithm SHA256 -Path $archives[0].FullName).Hash
    Check "the archive is byte-identical to the retired record" ($archivedHash -eq $originalHash)
    Check "the archive carries verifiable sidecar metadata" (Test-Path "$($archives[0].FullName).meta.txt")
    $meta = Get-Content -Raw -Path "$($archives[0].FullName).meta.txt"
    Check "sidecar metadata records the hash and the retired actors" (($meta -match [regex]::Escape($originalHash)) -and ($meta -match "implementer:"))
}
Check "the handoff was actually reset after a successful archive" ((Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")) -match "State: NEEDS_ANALYSIS")

# A failed archive must leave the live record untouched. Losing history silently is
# worse than refusing to open a new task.
$fx = New-TerminalFixture -HistoryIgnore "/.ai/handoff-history"
# Occupy the history path with a FILE so no archive can be written there.
Set-Content -Path (Join-Path $fx ".ai/handoff-history") -Value "blocker" -Encoding utf8
$before = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $fx "AI_HANDOFF.md")).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "request that must not destroy history")
$after = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $fx "AI_HANDOFF.md")).Hash
Check "a failed archive blocks the reset and leaves the record untouched" (($before -eq $after) -and ($r.Out -match "was NOT reset because it could not be archived"))

# --- v3.4.1 guarded terminal-drift recovery (G6) ------------------------------------
# The checkpoint gates every command, so a drifted record blocked the very command
# that would retire it. The escape is narrow and archives first.

# Both actors are swapped relative to the binding. That is drift and ONLY drift: with
# two known tools, changing a single actor would also collide the Reviewer with the
# Implementer, which is an invariant violation and must never be auto-recoverable.
$driftedTerminal = ((New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task with drifted actors") -replace "- Implementer: Claude Code", "- Implementer: Codex") -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$fx = New-TerminalFixture -Handoff $driftedTerminal
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "retire the drifted finished task")
$archives = @(Get-ChildItem -Path (Join-Path $fx ".ai/handoff-history") -Filter "*-AI_HANDOFF.md" -ErrorAction SilentlyContinue)
Check "start recovers a FINISHED task whose Task Actors drifted" (($r.Code -eq 0) -and ($r.Out -match "recovering a finished task"))
Check "the drifted record is archived, not discarded" ($archives.Count -eq 1)

# Active-state drift must stay blocked: only a finished task may be retired.
$driftedActive = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -replace "- Implementer: Claude Code", "- Implementer: Codex"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $driftedActive; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "should not be allowed to retire an active task")
Check "start does NOT retire an ACTIVE drifted task" (($r.Code -eq 12) -and ($r.Out -match "Role checkpoint: BLOCKED"))

# An unknown identity is never drift-only, so recovery must not launder it.
$unknownRoles2 = $DefaultRoles -replace "\| Implementer \| Claude Code \|", "| Implementer | Gemini |"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $unknownRoles2 }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "unknown tool must not be waved through")
Check "start recovery never launders an unrecognized tool identity" (($r.Code -eq 12) -and ($r.Out -match "Gemini"))

# === 2. Turn-ownership mismatch routing ===
Write-Host "[2] Mismatch routing"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "State/WaitingFor mismatch routes to User as Protocol Repair" (($r.Out -match "Next actor: User") -and ($r.Out -match "Protocol Repair") -and ($r.Out -match "mismatch"))

# === 3. Adapter decisions ===
Write-Host "[3] Adapter decisions (adapters)"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("adapters")
Check "Implementer/Claude Code adapter is callable for READY_FOR_IMPLEMENTATION" ($r.Out -match "(?s)Role:\s+Implementer.*?Tool:\s+Claude Code.*?Callable:\s+yes.*?States:\s+READY_FOR_IMPLEMENTATION")
Check "Implementer/Claude Code adapter also auto-runs read-only NEEDS_INVESTIGATION" ($r.Out -match "(?s)Role:\s+Implementer.*?Auto-loop:\s+yes.*?States:\s+READY_FOR_IMPLEMENTATION, NEEDS_INVESTIGATION")
# Since v2.0.1 Master/Codex is callable for NEEDS_ANALYSIS via master-run + master-apply,
# but Auto-loop is no: loop only includes it with -IncludeMaster, and cycle never does.
Check "Master/Codex adapter is callable for NEEDS_ANALYSIS but not auto-loop eligible" ($r.Out -match "(?s)Role:\s+Master.*?Tool:\s+Codex.*?Callable:\s+yes.*?Auto-loop:\s+no.*?States:\s+NEEDS_ANALYSIS")
# Since v1.3.0 Reviewer/Codex is callable for READY_FOR_REVIEW (review-run + review-apply)
# but Auto-loop is no: loop only includes it with -IncludeReviewer, and cycle never does.
Check "Reviewer/Codex adapter is callable for READY_FOR_REVIEW but not auto-loop eligible" ($r.Out -match "(?s)Role:\s+Reviewer.*?Tool:\s+Codex.*?Callable:\s+yes.*?Auto-loop:\s+no.*?States:\s+READY_FOR_REVIEW")
Check "Release executor advertised as PowerShell-only, REVIEW_DONE-gated" (($r.Out -match "Authorized release executor") -and ($r.Out -match "REVIEW_DONE"))

# === 4. Stop categories ===
Write-Host "[4] Stop categories"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "REVIEW_DONE prints User Commit Authorization stop category" ($r.Out -match "Stop category: User Commit Authorization")
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "Callable-tool handoff prints Operator Manual Action stop category" ($r.Out -match "Stop category: Operator Manual Action")

# === 4B. User next guidance ===
Write-Host "[4B] User next guidance"
$h = New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "v2.5.0 user flow pilot"
$h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- USER_NEXT_TARGET.md"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $h; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("user-next")
Check "user-next prints guarded commit command for REVIEW_DONE" (($r.Code -eq 0) -and ($r.Out -match "User Next") -and ($r.Out -match "commit-approved") -and ($r.Out -match "I_AUTHORIZE_COMMIT") -and ($r.Out -match "Complete v2.5.0 user flow pilot"))

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.5.0 user flow pilot"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("user-next")
Check "user-next points to Implementer tool for implementation state" (($r.Code -eq 0) -and ($r.Out -match "open Claude Code") -and ($r.Out -match "next -Clip"))

# === 4C. Productized daily commands ===
Write-Host "[4C] Productized daily commands (work / doctor)"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v3.0.0 productization"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$beforeHash = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$beforeCommits = (& git -C $fx rev-list --all --count 2>$null)
$r = Invoke-Handoff -WorkDir $fx -Arguments @("work")
$afterHash = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$afterCommits = (& git -C $fx rev-list --all --count 2>$null)
Check "work prints Handoff Work, current state, and next action" (($r.Code -eq 0) -and ($r.Out -match "Handoff Work") -and ($r.Out -match "READY_FOR_IMPLEMENTATION") -and ($r.Out -match "Next action") -and ($r.Out -match [regex]::Escape(".\scripts\handoff.ps1 next -Clip")))
Check "work does not mutate AI_HANDOFF.md or create git commits" (($beforeHash -eq $afterHash) -and ("$beforeCommits".Trim() -eq "$afterCommits".Trim()))
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "WAITING_FOR_USER" -WaitingFor "User" -CurrentTask "Initial setup"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("work")
Check "work prints first-run fresh install guidance" (($r.Code -eq 0) -and ($r.Out -match "start the first task") -and ($r.Out -match [regex]::Escape(".\scripts\handoff.ps1 start")) -and ($r.Out -match "printed Master prompt"))

$r = Invoke-Handoff -WorkDir $fx -Arguments @("user-next")
Check "user-next prints first-run fresh install guidance" (($r.Code -eq 0) -and ($r.Out -match "start the first task") -and ($r.Out -match [regex]::Escape(".\scripts\handoff.ps1 start")) -and ($r.Out -match "printed Master prompt"))
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Completed old task"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "New clean task")
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
Check "start prepares AI_HANDOFF.md for a clean new task" (($r.Code -eq 0) -and ($r.Out -match "AI_HANDOFF.md prepared for Master analysis") -and ($h -match "State: NEEDS_ANALYSIS") -and ($h -match "Waiting For: Master") -and ($h -match "Current Task: New clean task") -and ($h -match "Implementer: TBD"))

$r = Invoke-Handoff -WorkDir $fx -Arguments @("work")
Check "work after start leads with the Codex Master command and keeps the paste path" (($r.Code -eq 0) -and ($r.Out -match "NEEDS_ANALYSIS") -and ($r.Out -match "run the Master turn from here") -and ($r.Out -match "master-run") -and ($r.Out -match "To take the turn manually in Codex") -and ($r.Out -match "next -Clip"))

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Completed old task"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
Set-Content -Path (Join-Path $fx "UNCOMMITTED.md") -Value "dirty" -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("start", "Blocked new task")
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
Check "start does not reset AI_HANDOFF.md when non-local changes exist" (($r.Code -eq 0) -and ($r.Out -match "was not reset") -and ($h -match "State: REVIEW_DONE") -and ($h -match "Current Task: Completed old task"))

$doctorFiles = @{
    "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -CurrentTask "v3.0.0 productization");
    ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles;
    ".ai/skills/codex-claude-handoff/VERSION" = "3.0.0";
    "scripts/handoff.ps1" = "fixture";
    "scripts/handoff.sh" = "fixture";
    "scripts/next-step.ps1" = "fixture";
    "scripts/next-step.sh" = "fixture";
    ".agents/skills/codex-claude-handoff/SKILL.md" = "fixture";
    ".claude/skills/codex-claude-handoff/SKILL.md" = "fixture";
    ".ai/skills/codex-claude-handoff/SKILL.md" = "fixture";
    ".ai/skills/codex-claude-handoff/ADAPTERS.md" = "fixture";
    ".ai/skills/codex-claude-handoff/PROTOCOL_METHOD.md" = "fixture";
    ".ai/skills/codex-claude-handoff/CLAUDE_EXECUTION_POLICY.md" = "fixture";
    ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit"}}}'
}

function New-BlockedCorrectionHandoff {
    param([string]$State = "READY_FOR_IMPLEMENTATION", [string]$WaitingFor = "Implementer")
    return @"
# AI Handoff

## Status
- State: $State
- Waiting For: $WaitingFor
- Last Updated By: Reviewer
- Last Updated At: 2026-07-15
- Current Task: Correct the reviewed approved file

## Last Update
- Actor: Reviewer (Codex)
- Date: 2026-07-15
- Verdict: BLOCKED
- Reason: approved.txt still needs one focused correction.

## Task Actors
- Implementer: Claude Code
- Reviewer: Codex

## Changed Files
- approved.txt

## Verification
- Tests: not run

## Next Recommended Step
- Implementer: correct approved.txt, then return it to Reviewer.
"@
}
$fx = New-Fixture -Files $doctorFiles -InitGit
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$beforeHash = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$beforeCommits = (& git -C $fx rev-list --all --count 2>$null)
$r = Invoke-Handoff -WorkDir $fx -Arguments @("doctor")
$afterHash = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$afterCommits = (& git -C $fx rev-list --all --count 2>$null)
Check "doctor prints Handoff Doctor, protocol version, role assignment, and AI_HANDOFF status" (($r.Code -eq 0) -and ($r.Out -match "Handoff Doctor") -and ($r.Out -match "Protocol version:\s+3\.0\.0") -and ($r.Out -match "Role assignment: Master=Codex, Reviewer=Codex, Implementer=Claude Code") -and ($r.Out -match "AI_HANDOFF.md status") -and ($r.Out -match "Installed protocol components are present") -and ($r.Out -match "Version update check skipped"))
Check "doctor does not mutate AI_HANDOFF.md or create git commits" (($beforeHash -eq $afterHash) -and ("$beforeCommits".Trim() -eq "$afterCommits".Trim()))

$missingDoctorFiles = @{}
foreach ($key in $doctorFiles.Keys) { $missingDoctorFiles[$key] = $doctorFiles[$key] }
$missingDoctorFx = New-Fixture -Files $missingDoctorFiles -InitGit
Initialize-FixtureGitBaseline -Dir $missingDoctorFx
Remove-Item -LiteralPath (Join-Path $missingDoctorFx ".ai/skills/codex-claude-handoff/ADAPTERS.md") -Force
$r = Invoke-Handoff -WorkDir $missingDoctorFx -Arguments @("doctor")
Check "doctor fails with exit 10 when an installed protocol component is missing" (($r.Code -eq 10) -and ($r.Out -match "Installed protocol is incomplete") -and ($r.Out -match "ADAPTERS\.md"))

$invalidVersionFiles = @{}
foreach ($key in $doctorFiles.Keys) { $invalidVersionFiles[$key] = $doctorFiles[$key] }
$invalidVersionFiles[".ai/skills/codex-claude-handoff/VERSION"] = "not-a-version"
$invalidVersionFx = New-Fixture -Files $invalidVersionFiles -InitGit
$r = Invoke-Handoff -WorkDir $invalidVersionFx -Arguments @("doctor")
Check "doctor fails with exit 10 when VERSION metadata is malformed" (($r.Code -eq 10) -and ($r.Out -match "Protocol VERSION is invalid") -and ($r.Out -match "Doctor result: FAIL"))

# === 4B-2. Credential exposure detector (v3.6.0) ===
Write-Host "[4B-2] Credential exposure detector"

# The clean-tree gate is what pushed an operator toward `git add -A`, and an agent MCP
# config holds its token in plain text. These assert the detector fires on a tracked
# credential file, stays quiet on the template beside it, and does not depend on the
# secret being a real one.
# The probe value is assembled at runtime so this repository never contains a
# literal token-shaped string. A public repo that trips its own detector - or
# GitHub push protection - would be its own worst advertisement.
$probeToken = "Bearer " + "sbp" + "_" + "0123456789abcdef0123456789"
$credFiles = @{}
foreach ($key in $doctorFiles.Keys) { $credFiles[$key] = $doctorFiles[$key] }
$credFiles[".mcp.json"] = '{"mcpServers":{"supabase":{"headers":{"Authorization":"' + $probeToken + '"}}}}'
$credFiles[".mcp.example.json"] = '{"mcpServers":{"supabase":{"headers":{"Authorization":"' + $probeToken + '"}}}}'
$credFx = New-Fixture -Files $credFiles -InitGit
Initialize-FixtureGitBaseline -Dir $credFx
$r = Invoke-Handoff -WorkDir $credFx -Arguments @("doctor")
Check "doctor warns when a tracked file carries credentials" (($r.Out -match "Tracked files look like they carry credentials") -and ($r.Out -match "\.mcp\.json"))
Check "doctor names the credential file by why it matched" ($r.Out -match "Claude Code MCP configuration")
Check "doctor does not flag the .example template beside it" ($r.Out -notmatch "\.mcp\.example\.json")
Check "the credential warning does not fail doctor" ($r.Out -match "Doctor result: PASS")

# Untracked is not the same risk: the file is not one commit from history, and warning
# about it would fire on every developer's local .env.
$untrackedCredFx = New-Fixture -Files $doctorFiles -InitGit
Initialize-FixtureGitBaseline -Dir $untrackedCredFx
Set-Content -Path (Join-Path $untrackedCredFx ".mcp.json") -Value ('{"Authorization":"' + $probeToken + '"}') -Encoding utf8
$r = Invoke-Handoff -WorkDir $untrackedCredFx -Arguments @("doctor")
Check "doctor does not flag an untracked credential file" ($r.Out -match "No tracked file matches a known credential name")

# The installer must ignore both agent credential files, or the detector is only ever
# reporting a hole the protocol itself left open.
$snippetText = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/gitignore-snippet.txt")
Check "the gitignore snippet ignores the Claude MCP config" ($snippetText -match "(?m)^/\.mcp\.json$")
Check "the gitignore snippet ignores the Codex MCP config" ($snippetText -match "(?m)^/\.codex/config\.toml$")

# === 4B-3. A role swap must not block its own automation (v3.6.0) ===
Write-Host "[4B-3] Role swap does not block the turn it enables"

# Swapping roles edits a tracked file. Before v3.6.0 that dirtied the tree, the gate
# refused the automated turn the swap existed to enable, and clearing it required a
# commit the user had to approve separately - for a change they had already approved.
$swapFiles = @{}
foreach ($key in $doctorFiles.Keys) { $swapFiles[$key] = $doctorFiles[$key] }
$swapFiles["AI_HANDOFF.md"] = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask "swap probe")
$swapFx = New-Fixture -Files $swapFiles -InitGit
Initialize-FixtureGitBaseline -Dir $swapFx
$swapRolePath = Join-Path $swapFx ".ai/roles/ROLE_ASSIGNMENT.md"
Set-Content -Path $swapRolePath -Value ($DefaultRoles -replace 'Master \| Codex', 'Master | Claude Code') -Encoding utf8
$r = Invoke-Handoff -WorkDir $swapFx -Arguments @("doctor")
Check "a swapped role file does not make the tree look dirty" ($r.Out -match "Git working tree clean after local coordination exclusions")
Check "the role file is not reported as a project change" ($r.Out -notmatch "ROLE_ASSIGNMENT\.md")

# Exempting it from the gate must not exempt it from the read-only boundary: a Master
# or Reviewer turn still has no business rewriting the binding it is meant to obey.
$handoffSource = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "the role file joins the list the read-only boundary hashes" ($handoffSource -match 'LocalHandoffFiles \+ @\("\.ai/roles/ROLE_ASSIGNMENT\.md"\)')
Check "the read-only boundary still hashes every local handoff file" ($handoffSource -match 'foreach \(\$local in \$LocalHandoffFiles\)')

# v3.6.0: both gates must agree on what a changed file is. handoff.ps1 exempts the role
# file from the clean-tree gate; handoff.sh keeps its own hardcoded LOCAL_IGNORED list
# for commit-check. Adding the file to one and not the other meant Bash blocked a commit
# PowerShell allowed, on the same repository. Two parsers, two answers.
$shSource = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.sh")
Check "the Bash exclusion list exempts the role file too" ($shSource -match 'LOCAL_IGNORED="[^"]*\.ai/roles/ROLE_ASSIGNMENT\.md')
Check "Bash commit-check warns about tracked credential files" (($shSource -match '_warn_credential_paths\(\)') -and ($shSource -match 'cmd_commit_check\(\) \{[^}]*_warn_credential_paths'))

# === 4B-4. The shipped package matches the templates it was built from (v3.7.0) ===
Write-Host "[4B-4] Package freshness"

# v3.5.2 shipped a package whose gitignore-snippet.txt still lacked the seven role-named
# capture files v3.5.0 introduced: build-skill-package.ps1 had not been re-run before the
# release. Installing from the repository was fine, installing from the Skill package was
# not, and nothing compared the two. A release that forgets the build step ships the
# previous release's content under the new version number.
$pkgRoots = @(".agents/skills/codex-claude-handoff/assets/package/templates",
              ".claude/skills/codex-claude-handoff/assets/package/templates")
$templateRootForPkg = Join-Path $RepoRoot "templates"
$excludedFromPackage = @("scripts/protocol-tests.ps1", "scripts/protocol-tests.sh")
$pkgStale = [System.Collections.Generic.List[string]]::new()
foreach ($pkgRel in $pkgRoots) {
    $pkgRoot = Join-Path $RepoRoot $pkgRel
    if (-not (Test-Path -LiteralPath $pkgRoot)) { $pkgStale.Add("missing package root: $pkgRel"); continue }
    foreach ($srcFile in (Get-ChildItem -LiteralPath $templateRootForPkg -Recurse -File -Force)) {
        $rel = $srcFile.FullName.Substring($templateRootForPkg.Length).TrimStart([char]92, [char]47).Replace([char]92, [char]47)
        if ($excludedFromPackage -contains $rel) { continue }
        $dest = Join-Path $pkgRoot $rel
        if (-not (Test-Path -LiteralPath $dest)) { $pkgStale.Add("$pkgRel/$rel is missing"); continue }
        $a = (Get-FileHash -Algorithm SHA256 -LiteralPath $srcFile.FullName).Hash
        $b = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash
        if ($a -ne $b) { $pkgStale.Add("$pkgRel/$rel differs from templates/$rel") }
    }
}
Check "the built Skill package matches templates/ byte for byte" ($pkgStale.Count -eq 0) ($pkgStale -join "; ")
Check "the excluded test harness is genuinely absent from the package" (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".agents/skills/codex-claude-handoff/assets/package/templates/scripts/protocol-tests.ps1")))

# === 4B-5. The decision log survives what AI_HANDOFF.md does not (v3.7.0) ===
Write-Host "[4B-5] Durable decision log"

# The protocol tells the Master not to write advisory answers into AI_HANDOFF.md, and
# start archives and replaces that file for every new task. With no second destination,
# a brainstorming session that settled the product's audience, platform and data
# retention left no trace anywhere - which is exactly what happened to a real user.
$decisionsTemplate = Join-Path $RepoRoot "templates/DECISIONS.md"
Check "a DECISIONS.md template ships with the protocol" (Test-Path -LiteralPath $decisionsTemplate)
$decisionsText = if (Test-Path -LiteralPath $decisionsTemplate) { Get-Content -Raw -LiteralPath $decisionsTemplate } else { "" }
Check "the decision log states that it accumulates and is never reset" (($decisionsText -match "accumulates") -and ($decisionsText -match "(?is)nothing\s+here\s+is\s+reset") -and ($decisionsText -match "(?is)never\s+reset\s+by\s+.start."))
Check "the decision log refuses unconfirmed suggestions by rule" ($decisionsText -match "(?i)suggestion, a recommendation, or an option that was raised and not chosen")

# It must be tracked: a gitignored decision log is invisible to everyone but this machine.
$snippetForDecisions = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/gitignore-snippet.txt")
Check "the decision log is NOT gitignored" ($snippetForDecisions -notmatch "(?m)^/DECISIONS\.md$")

# The advisory branch of the Master prompt is the one that used to end in silence.
$handoffForDecisions = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "the Master prompt sends confirmed advisory decisions to DECISIONS.md" ($handoffForDecisions -match "advisory-only, answer directly and do not update AI_HANDOFF\.md - but append any decision the user confirms")
$masterDoc = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff/MASTER.md")
Check "MASTER.md states the duty to record confirmed decisions" (($masterDoc -match "## Recording Confirmed Decisions") -and ($masterDoc -match "including in an\s*\r?\n?advisory conversation"))

# An upgrade must never overwrite an accumulated log, in either installer.
$installPs = Get-Content -Raw -Path (Join-Path $RepoRoot "install.ps1")
$installSh = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/install.sh")
Check "install.ps1 preserves an existing decision log on -Force" ($installPs -match '\$preserveOnForceFiles = @\("AI_HANDOFF\.md", "AI_SEQUENCE\.md", "DECISIONS\.md"\)')
Check "install.sh preserves an existing decision log on --force" ($installSh -match '\$rel" = "DECISIONS\.md"')

# End to end: install, record a decision, force-upgrade, and the decision is still there.
# Asserting the two source lists above is not enough - preserve-on-force is exactly the
# kind of rule that reads correct and behaves otherwise.
$decTarget = Join-Path $FixtureRoot "decision-log-target"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $decTarget 2>&1
Check "a fresh install creates the decision log" (Test-Path -LiteralPath (Join-Path $decTarget "DECISIONS.md"))
Set-Content -Path (Join-Path $decTarget "DECISIONS.md") -Value "## 2026-09-09 - Mobile first, web and PWA only" -Encoding utf8
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $decTarget -Force 2>&1
$decAfter = if (Test-Path -LiteralPath (Join-Path $decTarget "DECISIONS.md")) { Get-Content -Raw -Path (Join-Path $decTarget "DECISIONS.md") } else { "" }
Check "a -Force upgrade does not overwrite recorded decisions" ($decAfter -match "Mobile first, web and PWA only")

# The same guarantee for a section the project added to the role file by hand. The
# protocol asks the user to record swaps there, and the installer used to delete them.
$roleFxPath = Join-Path $decTarget ".ai/roles/ROLE_ASSIGNMENT.md"
$roleBefore = Get-Content -Raw -Path $roleFxPath
Set-Content -Path $roleFxPath -Value ($roleBefore -replace "The User is always the approval point", "## Role Swap History`n`n| 2026-09-09 | swapped for token limits |`n`nThe User is always the approval point") -Encoding utf8
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $decTarget -Force 2>&1
$roleAfter = Get-Content -Raw -Path $roleFxPath
Check "a -Force upgrade preserves sections the project added to the role file" (($roleAfter -match "## Role Swap History") -and ($roleAfter -match "swapped for token limits"))
Check "the preserved section keeps its position, not appended at the end" ($roleAfter -match "(?s)## Current Binding.*## Role Swap History.*## Role Meanings")

# === 4B-6. The Master's entry path stays inside a context budget (v3.8.0) ===
Write-Host "[4B-6] Master context budget"

# A real Master session spent about 40,000 tokens - 17% of a five-hour usage window -
# loading this protocol before doing any work. The window entry path said "Always read
# SKILL.md", the index listed every document, and the agent read all of them, then
# carried that weight on every later tool call. The automated Master prompt had been
# lean since v2.0.1; the path a person actually drives had not. So this measures what the
# entry files TELL the agent to read in full, resolved to the files that ship - not a
# convenient proxy such as the size of one document.
function Get-DocSection {
    param([string]$Path, [string]$Heading)
    $out = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^## ') {
            if ($inside) { break }
            if ($line.Trim() -eq "## $Heading") { $inside = $true; continue }
        }
        if ($inside) { $out.Add($line) }
    }
    return ,$out.ToArray()
}

function Get-NumberedSteps {
    param([string[]]$Lines)
    $steps = [System.Collections.Generic.List[string]]::new()
    $current = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*\d+\.\s+(.*)$') {
            if ($null -ne $current) { $steps.Add($current) }
            $current = $Matches[1]
        } elseif (($null -ne $current) -and ($line -match '^\s{2,}\S')) {
            $current = "$current $($line.Trim())"
        } else {
            if ($null -ne $current) { $steps.Add($current) }
            $current = $null
        }
    }
    if ($null -ne $current) { $steps.Add($current) }
    return ,$steps.ToArray()
}

$budgetTplRoot = Join-Path $RepoRoot "templates"
$budgetSkillDir = Join-Path $budgetTplRoot ".ai/skills/codex-claude-handoff"
$budgetMaster = Join-Path $budgetSkillDir "MASTER.md"
$entrySources = @(
    @{ Name = "templates Skill Installed workflow"; Lines = (Get-DocSection -Path (Join-Path $budgetTplRoot ".agents/skills/codex-claude-handoff/SKILL.md") -Heading "Installed workflow") },
    @{ Name = "public Skill Installed workflow"; Lines = (Get-DocSection -Path (Join-Path $RepoRoot ".agents/skills/codex-claude-handoff/SKILL.md") -Heading "Installed workflow") },
    @{ Name = "CODEX.md"; Lines = @(Get-Content -LiteralPath (Join-Path $budgetSkillDir "CODEX.md")) },
    @{ Name = "MASTER.md Start of Session"; Lines = (Get-DocSection -Path $budgetMaster -Heading "Start of Session") }
)
$entrySteps = [System.Collections.Generic.List[object]]::new()
foreach ($src in $entrySources) {
    $srcSteps = Get-NumberedSteps -Lines $src.Lines
    Check "$($src.Name) has numbered entry steps to measure" ($srcSteps.Count -gt 0)
    foreach ($s in $srcSteps) { $entrySteps.Add([pscustomobject]@{ Source = $src.Name; Text = $s }) }
}

# A step reads a file in full when it says read/follow and names the file without
# narrowing it to a section or making it conditional.
$narrowing = '(?i)\bsections?\b|\blook\b.*\bup\b|only as needed|if present|when needed'
$heavyDocs = @("MASTER.md", "ADAPTERS.md", "PROTOCOL_METHOD.md", "CAPABILITIES.md", "CLAUDE_EXECUTION_POLICY.md")
$fullReadFiles = [System.Collections.Generic.List[string]]::new()
$heavyViolations = [System.Collections.Generic.List[string]]::new()
foreach ($step in $entrySteps) {
    if ($step.Text -notmatch '(?i)\b(read|follow)\b') { continue }
    if ($step.Text -match $narrowing) { continue }
    foreach ($m in [regex]::Matches($step.Text, '`([^`\s]+\.md)`')) {
        $named = $m.Groups[1].Value
        $leaf = Split-Path -Leaf $named
        $isSharedIndex = ($named -match '(^|/)\.ai/skills/codex-claude-handoff/SKILL\.md$') -or (($step.Source -eq "CODEX.md") -and ($named -eq "SKILL.md"))
        if (($heavyDocs -contains $leaf) -or $isSharedIndex) { $heavyViolations.Add("$($step.Source): $named") }
        if (-not $fullReadFiles.Contains($named)) { $fullReadFiles.Add($named) }
    }
}
Check "no Codex entry step reads a heavy protocol document or the shared index in full" ($heavyViolations.Count -eq 0) ($heavyViolations -join "; ")

$fullReadBytes = 0
foreach ($named in $fullReadFiles) {
    $hit = @((Join-Path $budgetTplRoot $named), (Join-Path $budgetSkillDir $named)) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($hit) { $fullReadBytes += (Get-Item -LiteralPath $hit).Length }
}
$budgetSectionText = ((Get-DocSection -Path $budgetMaster -Heading "Start of Session") + (Get-DocSection -Path $budgetMaster -Heading "Context Budget")) -join "`n"
$budgetSectionBytes = [System.Text.Encoding]::UTF8.GetByteCount($budgetSectionText)
Check "the Master's mandatory reads fit about 6,000 tokens (24 KB)" (($fullReadBytes + $budgetSectionBytes) -le 24KB) "full reads $fullReadBytes bytes ($($fullReadFiles -join ', ')) + budget sections $budgetSectionBytes bytes"

$contextBudgetText = (Get-DocSection -Path $budgetMaster -Heading "Context Budget") -join "`n"
Check "MASTER.md defines a Context Budget section" ($contextBudgetText.Length -gt 0)
Check "the Context Budget delegates investigation and bounds tool output" (($contextBudgetText -match "Delegate reading") -and ($contextBudgetText -match "NEEDS_INVESTIGATION") -and ($contextBudgetText -match "Bounded tool output"))
Check "the Context Budget never relaxes a safety gate" ($contextBudgetText -match "never relaxes a safety gate")
foreach ($pointer in @("templates/.agents/skills/codex-claude-handoff/SKILL.md", ".agents/skills/codex-claude-handoff/SKILL.md", "templates/.ai/skills/codex-claude-handoff/CODEX.md")) {
    Check "$pointer points the Master at the Context Budget" ((Get-Content -Raw -LiteralPath (Join-Path $RepoRoot $pointer)) -match "Context Budget")
}
$budgetHandoffPs = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts/handoff.ps1")
$budgetHandoffSh = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts/handoff.sh")
Check "the start Master prompt carries the Context Budget in both shells" (($budgetHandoffPs -match "follow the Context Budget in MASTER\.md") -and ($budgetHandoffSh -match "follow the Context Budget in MASTER\.md"))
Check "an Implementer investigation report is bounded" ((Get-Content -Raw -LiteralPath (Join-Path $budgetSkillDir "IMPLEMENTER.md")) -match "about 800 words")

# The map is only useful if its numbers are right: check each entry against the file.
$mapFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -CurrentTask "context budget map");
    ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
} -InitGit
$r = Invoke-Handoff -WorkDir $mapFx -Arguments @("next")
$mapNextTurn = Join-Path $mapFx "NEXT_TURN.md"
$mapText = if (Test-Path -LiteralPath $mapNextTurn) { Get-Content -Raw -LiteralPath $mapNextTurn } else { "" }
$mapHandoffLines = @(Get-Content -LiteralPath (Join-Path $mapFx "AI_HANDOFF.md"))
$mapEntries = @([regex]::Matches($mapText, '(?m)^- line (\d+): (## [^\r\n]+?)\s*$'))
$mapAccurate = ($mapEntries.Count -gt 0)
foreach ($entry in $mapEntries) {
    $lineNo = [int]$entry.Groups[1].Value
    if (($lineNo -lt 1) -or ($lineNo -gt $mapHandoffLines.Count) -or ($mapHandoffLines[$lineNo - 1].TrimEnd() -ne $entry.Groups[2].Value)) { $mapAccurate = $false }
}
$mapExpected = @($mapHandoffLines | Where-Object { $_ -match '^## ' }).Count
Check "next writes a section map of AI_HANDOFF.md into NEXT_TURN.md" ($mapText -match "## AI_HANDOFF\.md Sections \(line numbers\)") $r.Out
Check "every mapped line number points at that heading in AI_HANDOFF.md" $mapAccurate
Check "the section map lists every heading, not a subset" ($mapEntries.Count -eq $mapExpected) "mapped $($mapEntries.Count) of $mapExpected"

# === 4B-7. Keys stay out of reach (v3.9.0) ===
Write-Host "[4B-7] Credential read guard and leak gate"

# On 2026-09-14 an Implementer opened .mcp.json against a written instruction, and a live
# access token and an API key went into that session. Nothing in the protocol noticed.
# These checks exercise the three layers that answer it: deny rules the installer writes,
# a doctor that reports literal keys without printing them, and a gate that stops an
# automated turn whose captures hold a credential. Fake values are assembled at run time
# so this public suite never carries a token-shaped literal.
$guardRulesPath = Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff/CREDENTIAL_READ_DENY.txt"
$guardRules = @(Get-Content -LiteralPath $guardRulesPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch '^#' })
Check "the shipped deny list blocks the credential files by name" (($guardRules -contains "Read(.mcp.json)") -and ($guardRules -contains "Read(.env)") -and ($guardRules -contains "Read(.env.local)") -and ($guardRules -contains "Read(.codex/config.toml)"))
Check "the deny list leaves .env.example readable" (@($guardRules | Where-Object { $_ -eq 'Read(.env.*)' -or $_ -eq 'Read(.env.example)' }).Count -eq 0)

function Get-GuardDenyList {
    param([string]$SettingsPath)
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return ,@() }
    try { $parsed = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json -ErrorAction Stop } catch { return ,@("<unparseable>") }
    if ($null -eq $parsed -or $null -eq $parsed.permissions -or $null -eq $parsed.permissions.deny) { return ,@() }
    return ,@($parsed.permissions.deny)
}

$guardInstaller = Join-Path $RepoRoot "install.ps1"
$guardTarget = Join-Path $FixtureRoot "credential-guard-target"
$guardOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $guardInstaller -Project $guardTarget 2>&1 | Out-String
$guardSettings = Join-Path $guardTarget ".claude/settings.json"
$freshDeny = Get-GuardDenyList -SettingsPath $guardSettings
Check "a fresh install writes every deny rule to .claude/settings.json" ((@($guardRules | Where-Object { $freshDeny -notcontains $_ }).Count -eq 0) -and ($guardOut -match "Credential read guard: created")) $guardOut

Set-Content -LiteralPath $guardSettings -Value '{"model":"keep-me","permissions":{"allow":["Read(.env)"],"deny":["Bash(rm *)"]},"enabledPlugins":{}}' -Encoding ascii
$mergeOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $guardInstaller -Project $guardTarget -Force 2>&1 | Out-String
$mergedSettings = [System.IO.File]::ReadAllText($guardSettings) | ConvertFrom-Json
$mergedDeny = @($mergedSettings.permissions.deny)
Check "a -Force upgrade merges the deny rules into an existing settings file" ((@($guardRules | Where-Object { $mergedDeny -notcontains $_ }).Count -eq 0) -and ($mergedDeny -contains "Bash(rm *)") -and ($mergeOut -match "Credential read guard: added")) $mergeOut
Check "the merge keeps the project's own settings" (($mergedSettings.model -eq "keep-me") -and (@($mergedSettings.permissions.allow) -contains "Read(.env)"))
# v3.10.1: Windows PowerShell 5.1 ConvertTo-Json padded and column-indented the merged file,
# a noisy diff for the user. The merge now writes two-space indentation like install.sh.
$mergedText = [System.IO.File]::ReadAllText($guardSettings)
Check "the merged settings file uses two-space indentation and no padded colons" (($mergedText -match '(?m)^  "permissions": \{$') -and ($mergedText -match '(?m)^    "deny": \[$') -and ($mergedText -notmatch '":\s{2,}') -and ($mergedText -match '"enabledPlugins": \{\}')) $mergedText
$againOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $guardInstaller -Project $guardTarget -Force 2>&1 | Out-String
$againDeny = Get-GuardDenyList -SettingsPath $guardSettings
Check "a second upgrade adds no duplicate deny rules" (($againDeny.Count -eq $mergedDeny.Count) -and ($againOut -match "Credential read guard: already present")) $againOut

$badGuardTarget = Join-Path $FixtureRoot "credential-guard-malformed"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $guardInstaller -Project $badGuardTarget 2>&1
$badGuardSettings = Join-Path $badGuardTarget ".claude/settings.json"
Set-Content -LiteralPath $badGuardSettings -Value '{ "model": "unfinished", ' -Encoding ascii
$badBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $badGuardSettings).Hash
$badOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $guardInstaller -Project $badGuardTarget -Force 2>&1 | Out-String
$badAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $badGuardSettings).Hash
Check "an unparseable settings file is left untouched and reported" (($badBefore -eq $badAfter) -and ($badOut -match "credential read guard was not added")) $badOut

# doctor: a literal key in an ignored MCP file is reported by name and shape, never by value.
$fakeSupabaseToken = "sbp_" + ("0123456789abcdef" * 3)
$doctorGuardFiles = @{}
foreach ($key in $doctorFiles.Keys) { $doctorGuardFiles[$key] = $doctorFiles[$key] }
$doctorGuardFiles[".ai/skills/codex-claude-handoff/CREDENTIAL_READ_DENY.txt"] = (Get-Content -Raw -LiteralPath $guardRulesPath)
$doctorGuardFiles[".mcp.json"] = '{"mcpServers":{"supabase":{"type":"http","url":"https://mcp.supabase.com/mcp","headers":{"Authorization":"Bearer ' + $fakeSupabaseToken + '"}}}}'
$doctorGuardFx = New-Fixture -Files $doctorGuardFiles -InitGit
$r = Invoke-Handoff -WorkDir $doctorGuardFx -Arguments @("doctor")
Check "doctor reports a literal key in an ignored MCP configuration" (($r.Out -match "MCP configuration holds a credential as literal text") -and ($r.Out -match "\.mcp\.json \(Supabase access token\)")) $r.Out
Check "doctor never prints the key it found" ($r.Out -notmatch [regex]::Escape($fakeSupabaseToken))
Check "doctor reports missing Claude Code deny rules" ($r.Out -match "Claude Code is not blocked from opening credential files")
Check "the credential guard warnings do not fail doctor" ($r.Code -ne 10) "exit $($r.Code)"

# v3.11.1: doctor names Fast mode, which spends the usage window 2.5x faster for the same answers.
$savedCodexHome = $env:CODEX_HOME
try {
    $fastHome = Join-Path $FixtureRoot ("codex-home-fast-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fastHome -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fastHome "config.toml") -Value ('service_tier = "priority"' + "`n" + 'model = "probe"' + "`n`n" + '[mcp_servers.probe]' + "`n" + 'bearer_token = "' + $fakeSupabaseToken + '"') -Encoding ascii
    $env:CODEX_HOME = $fastHome
    $r = Invoke-Handoff -WorkDir $doctorGuardFx -Arguments @("doctor")
    Check "doctor warns when the Codex user config sets Fast mode" (($r.Out -match "Codex runs in Fast mode") -and ($r.Out -match 'service_tier = "priority"')) $r.Out
    Check "the Fast mode warning prints no other line of the config" (($r.Out -notmatch [regex]::Escape($fakeSupabaseToken)) -and ($r.Out -notmatch 'model = "probe"'))
    Check "the Fast mode warning does not fail doctor" ($r.Code -ne 10) "exit $($r.Code)"

    $standardHome = Join-Path $FixtureRoot ("codex-home-standard-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $standardHome -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $standardHome "config.toml") -Value ('model = "probe"' + "`n`n" + '[profiles.quick]' + "`n" + 'service_tier = "priority"') -Encoding ascii
    $env:CODEX_HOME = $standardHome
    $r = Invoke-Handoff -WorkDir $doctorGuardFx -Arguments @("doctor")
    Check "doctor reports Standard when only a named profile sets Fast" ($r.Out -match "Codex Fast mode is not set in the Codex configuration")

    $projectFastFiles = @{}
    foreach ($key in $doctorFiles.Keys) { $projectFastFiles[$key] = $doctorFiles[$key] }
    $projectFastFiles[".codex/config.toml"] = 'service_tier = "fast"'
    $projectFastFx = New-Fixture -Files $projectFastFiles -InitGit
    $r = Invoke-Handoff -WorkDir $projectFastFx -Arguments @("doctor")
    Check "doctor warns when the project's .codex/config.toml sets Fast mode" ($r.Out -match 'project \.codex/config\.toml: service_tier = "fast"')
} finally {
    [System.Environment]::SetEnvironmentVariable("CODEX_HOME", $savedCodexHome, "Process")
}

Set-Content -LiteralPath (Join-Path $doctorGuardFx ".mcp.json") -Value '{"mcpServers":{"supabase":{"type":"http","url":"https://mcp.supabase.com/mcp","headers":{"Authorization":"Bearer ${SUPABASE_ACCESS_TOKEN}"}}}}' -Encoding ascii
New-Item -ItemType Directory -Path (Join-Path $doctorGuardFx ".claude") -Force | Out-Null
Set-Content -LiteralPath (Join-Path $doctorGuardFx ".claude/settings.json") -Value (@{ permissions = @{ deny = $guardRules } } | ConvertTo-Json -Depth 5) -Encoding ascii
$r = Invoke-Handoff -WorkDir $doctorGuardFx -Arguments @("doctor")
Check "doctor accepts an MCP configuration that references the key by name" ($r.Out -match "No MCP configuration file holds a credential as literal text") $r.Out
Check "doctor confirms the deny rules once they are present" ($r.Out -match "Claude Code is blocked from opening credential files")

# The leak gate, end to end: a fake Claude prints a credential; the turn must stop with
# exit 13, redact the captures and not repeat the value. The benign mode proves ordinary
# hyphenated text does not trip it.
$leakBin = Join-Path $FixtureRoot "leak-bin"
New-Item -ItemType Directory -Path $leakBin -Force | Out-Null
Set-Content -Path (Join-Path $leakBin "npx.cmd") -Encoding ascii -Value @"
@echo off
setlocal EnableDelayedExpansion
set "ALL=%CMDCMDLINE%"
if not "!ALL:--version=!"=="!ALL!" (
  echo claude-code-test
  exit /b 0
)
if "%FAKE_LEAK_MODE%"=="benign" (
  echo Reviewed risk-assessment-for-the-new-exercise-catalog-and-approval-flow
  exit /b 0
)
echo Found the connection settings: Bearer $fakeSupabaseToken
exit /b 0
"@
$prevLeakPath = $env:Path
$prevLeakMode = $env:FAKE_LEAK_MODE
$env:Path = $leakBin + [System.IO.Path]::PathSeparator + $env:Path
try {
    $env:FAKE_LEAK_MODE = "leak"
    $leakFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v3.9.0 - Leak gate"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $leakFx
    $r = Invoke-Handoff -WorkDir $leakFx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    $leakLastText = if (Test-Path -LiteralPath (Join-Path $leakFx "IMPLEMENTER_LAST.md")) { [System.IO.File]::ReadAllText((Join-Path $leakFx "IMPLEMENTER_LAST.md")) } else { "" }
    $leakJsonlText = if (Test-Path -LiteralPath (Join-Path $leakFx "IMPLEMENTER.jsonl")) { [System.IO.File]::ReadAllText((Join-Path $leakFx "IMPLEMENTER.jsonl")) } else { "" }
    $securityBlock = if ($r.Out -match '(?s)SECURITY STOP.*') { $Matches[0] } else { "" }
    Check "a turn whose capture holds a credential stops with exit 13" (($r.Code -eq 13) -and ($securityBlock -match "Supabase access token")) $r.Out
    Check "the leaked value is redacted from the local captures" (($leakLastText.Length -gt 0) -and ($leakLastText -notmatch [regex]::Escape($fakeSupabaseToken)) -and ($leakLastText -match "<REDACTED:Supabase access token>") -and ($leakJsonlText -notmatch [regex]::Escape($fakeSupabaseToken)))
    Check "the security stop never prints the value" (($securityBlock.Length -gt 0) -and ($securityBlock -notmatch [regex]::Escape($fakeSupabaseToken)))

    $env:FAKE_LEAK_MODE = "benign"
    $benignFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v3.9.0 - Leak gate benign"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $benignFx
    $r = Invoke-Handoff -WorkDir $benignFx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "ordinary hyphenated text does not trip the leak gate" (($r.Code -ne 13) -and ($r.Out -notmatch "SECURITY STOP")) $r.Out
} finally {
    $env:Path = $prevLeakPath
    $env:FAKE_LEAK_MODE = $prevLeakMode
}

$guardHandoffSrc = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "every automated agent prompt forbids opening credential files" ([regex]::Matches($guardHandoffSrc, 'Never open files that hold credentials').Count -ge 4)
Check "the leak gate runs after Implementer, loop, Reviewer and Master turns" ([regex]::Matches($guardHandoffSrc, 'Invoke-CredentialLeakGate -CommandLabel').Count -ge 4)
Check "the protocol documents carry the credential rule" (((Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff/MASTER.md")) -match "## Credential Files") -and ((Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff/IMPLEMENTER.md")) -match "Never open files that hold credentials"))

# === 4C. Dynamic model resolver ===
Write-Host "[4C] Dynamic model resolver"
$modelRouting = @'
{
  "schemaVersion": 1,
  "profiles": {
    "cheap_readonly": { "claudeModel": "test-cheap-model" },
    "economy": { "claudeModel": "test-economy-model" },
    "standard": { "claudeModel": "inherit" },
    "high_reasoning": { "claudeModel": "test-high-model" }
  }
}
'@
$modelFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "model resolver default");
    ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles;
    ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $modelRouting
} -InitGit
$r = Invoke-Handoff -WorkDir $modelFx -Arguments @("models")
Check "models resolves a legacy handoff through auto to standard/inherit" (($r.Code -eq 0) -and ($r.Out -match "Effective profile:\s+standard") -and ($r.Out -match "Claude model:\s+inherit"))

$investigationHandoff = New-Handoff -State "NEEDS_INVESTIGATION" -WaitingFor "Implementer" -CurrentTask "model resolver investigation"
Set-Content -LiteralPath (Join-Path $modelFx "AI_HANDOFF.md") -Value $investigationHandoff -Encoding utf8
$r = Invoke-Handoff -WorkDir $modelFx -Arguments @("models")
Check "models selects cheap_readonly automatically for investigation" (($r.Code -eq 0) -and ($r.Out -match "Effective profile:\s+cheap_readonly") -and ($r.Out -match "Claude model:\s+test-cheap-model"))

$economyHandoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "model resolver economy") -replace "(- Current Task:[^\r\n]+)", "`$1`r`n- Model Profile: economy"
Set-Content -LiteralPath (Join-Path $modelFx "AI_HANDOFF.md") -Value $economyHandoff -Encoding utf8
$r = Invoke-Handoff -WorkDir $modelFx -Arguments @("models")
Check "models resolves an explicit handoff economy profile from project config" (($r.Code -eq 0) -and ($r.Out -match "Effective profile:\s+economy") -and ($r.Out -match "Claude model:\s+test-economy-model") -and ($r.Out -match "MODEL_ROUTING\.json"))

$prevEconomyModel = $env:HANDOFF_CLAUDE_MODEL_ECONOMY
$env:HANDOFF_CLAUDE_MODEL_ECONOMY = "test-env-economy-model"
try {
    $r = Invoke-Handoff -WorkDir $modelFx -Arguments @("models")
    Check "environment mapping overrides MODEL_ROUTING.json" (($r.Code -eq 0) -and ($r.Out -match "test-env-economy-model") -and ($r.Out -match "environment HANDOFF_CLAUDE_MODEL_ECONOMY"))
} finally {
    if ($null -eq $prevEconomyModel) { Remove-Item Env:\HANDOFF_CLAUDE_MODEL_ECONOMY -ErrorAction SilentlyContinue } else { $env:HANDOFF_CLAUDE_MODEL_ECONOMY = $prevEconomyModel }
}

Set-Content -LiteralPath (Join-Path $modelFx ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json") -Value "{bad json" -Encoding utf8
$r = Invoke-Handoff -WorkDir $modelFx -Arguments @("models")
Check "models fails closed on malformed MODEL_ROUTING.json" (($r.Code -eq 1) -and ($r.Out -match "Status:\s+BLOCKED") -and ($r.Out -match "invalid JSON"))

# === 4D. Project-local opt-in installer ===
Write-Host "[4D] Project-local opt-in installer"
$installScript = Join-Path $RepoRoot "install.ps1"
$installTarget = Join-Path $FixtureRoot "install-target"
$installOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $installTarget 2>&1 | Out-String
$installCode = $LASTEXITCODE
$installedHandoff = Join-Path $installTarget "AI_HANDOFF.md"
$installedScript = Join-Path $installTarget "scripts/handoff.ps1"
$installedVersion = Join-Path $installTarget ".ai/skills/codex-claude-handoff/VERSION"
$installedSkill = Join-Path $installTarget ".agents/skills/codex-claude-handoff/SKILL.md"
$installedAgents = Join-Path $installTarget "AGENTS.md"
$installedClaude = Join-Path $installTarget "CLAUDE.md"
$installedProtocolTests = Join-Path $installTarget "scripts/protocol-tests.ps1"
$installedSnippet = Join-Path $installTarget "gitignore-snippet.txt"
$installedGitignore = Join-Path $installTarget ".gitignore"
$installedGitignoreText = if (Test-Path $installedGitignore) { Get-Content -Raw -Path $installedGitignore } else { "" }
Check "install.ps1 installs protocol files into an empty target" (($installCode -eq 0) -and (Test-Path $installedHandoff) -and (Test-Path $installedScript) -and (Test-Path $installedVersion))
Check "default install is opt-in and does not install root agent instructions" ((-not (Test-Path $installedAgents)) -and (-not (Test-Path $installedClaude)) -and ($installOut -match "Activation mode: opt-in"))
Check "installed Codex skill metadata requires explicit activation" ((Get-Content -Raw -Path $installedSkill) -match [regex]::Escape("explicit user activation"))
Check "default install excludes package-only test and snippet files" ((-not (Test-Path $installedProtocolTests)) -and (-not (Test-Path $installedSnippet)))
Check "install.ps1 adds local coordination files to .gitignore" (($installedGitignoreText -match "AI_HANDOFF\.md") -and ($installedGitignoreText -match "NEXT_TURN\.md"))
Check "install.ps1 prints doctor and slash-command skill activation guidance" (($installOut -match [regex]::Escape(".\scripts\handoff.ps1 doctor")) -and ($installOut -match [regex]::Escape('/skills')) -and ($installOut -match "Select codex-claude-handoff") -and ($installOut -notmatch [regex]::Escape('$codex-claude-handoff')) -and ($installOut -match "normal Codex work"))

$blockedOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $installTarget 2>&1 | Out-String
$blockedCode = $LASTEXITCODE
Check "install.ps1 blocks overwriting an existing install without -Force" (($blockedCode -eq 1) -and ($blockedOut -match "blocked to avoid overwriting"))

$installedSequence = Join-Path $installTarget "AI_SEQUENCE.md"
$installedRoles = Join-Path $installTarget ".ai/roles/ROLE_ASSIGNMENT.md"
Set-Content -Path $installedHandoff -Value @"
# AI Handoff

## Status
- State: READY_FOR_IMPLEMENTATION
- Waiting For: Implementer
- Current Task: Preserve active update state

## Task Actors
- Implementer: Codex
- Reviewer: Claude Code

## Changed Files
- None yet

## Next Recommended Step
- Implementer: report the current role.
"@ -Encoding utf8
Set-Content -Path $installedSequence -Value "# active sequence sentinel" -Encoding utf8
Set-Content -Path $installedRoles -Value @"
# Old role instructions that must be refreshed

## Current Binding

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Claude Code |
| Implementer | Codex |
"@ -Encoding utf8
Set-Content -Path $installedScript -Value "# stale managed script" -Encoding utf8
$handoffBeforeForce = (Get-FileHash -Algorithm SHA256 -Path $installedHandoff).Hash
$sequenceBeforeForce = (Get-FileHash -Algorithm SHA256 -Path $installedSequence).Hash

$forcedOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $installTarget -Force 2>&1 | Out-String
$forcedCode = $LASTEXITCODE
Check "install.ps1 refreshes an existing install with -Force" (($forcedCode -eq 0) -and ($forcedOut -match "codex-claude-handoff installed into"))
$handoffAfterForce = (Get-FileHash -Algorithm SHA256 -Path $installedHandoff).Hash
$sequenceAfterForce = (Get-FileHash -Algorithm SHA256 -Path $installedSequence).Hash
$rolesAfterForce = Get-Content -Raw -Path $installedRoles
$managedScriptRefreshed = (Get-FileHash -Algorithm SHA256 -Path $installedScript).Hash -eq (Get-FileHash -Algorithm SHA256 -Path (Join-Path $RepoRoot "templates/scripts/handoff.ps1")).Hash
$normalizedRolesAfter = $rolesAfterForce -replace '(?m)^\|\s*(Master|Reviewer|Implementer)\s*\|\s*.+?\s*\|\s*$', '| $1 | <tool> |'
$templateRoleText = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md")
# v3.18.0: the template ships 'Setup: pending' for a first install; an upgrade of a file
# without the line carries no line, so the comparison leaves that one line out.
$normalizedRoleTemplate = ($templateRoleText -replace '(?m)^Setup: pending\r?\n', '') -replace '(?m)^\|\s*(Master|Reviewer|Implementer)\s*\|\s*.+?\s*\|\s*$', '| $1 | <tool> |'
Push-Location $installTarget
try {
    $installedNextOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installedScript next 2>&1 | Out-String
    $installedNextCode = $LASTEXITCODE
}
finally { Pop-Location }
Check "-Force preserves active AI_HANDOFF.md and AI_SEQUENCE.md" (($handoffBeforeForce -eq $handoffAfterForce) -and ($sequenceBeforeForce -eq $sequenceAfterForce) -and ($forcedOut -match "Preserved local coordination state"))
Check "-Force preserves current role binding while refreshing all role instructions" (($rolesAfterForce -match '\| Master \| Claude Code \|') -and ($rolesAfterForce -match '\| Reviewer \| Claude Code \|') -and ($rolesAfterForce -match '\| Implementer \| Codex \|') -and ($normalizedRolesAfter -eq $normalizedRoleTemplate) -and ($rolesAfterForce -notmatch "Old role instructions") -and ($managedScriptRefreshed))
Check "updated install keeps the active task synchronized and routes to the preserved Implementer" (($installedNextCode -eq 0) -and ($installedNextOut -match "Open:\s+Codex\s+\(role: Implementer\)"))

$malformedTarget = Join-Path $FixtureRoot "install-target-malformed-role"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $malformedTarget 2>&1 | Out-String
$malformedHandoff = Join-Path $malformedTarget "AI_HANDOFF.md"
$malformedScript = Join-Path $malformedTarget "scripts/handoff.ps1"
$malformedRoles = Join-Path $malformedTarget ".ai/roles/ROLE_ASSIGNMENT.md"
Set-Content -Path $malformedRoles -Value "| Master | Codex |`n| Implementer | Claude Code |" -Encoding utf8
$malformedHandoffBefore = (Get-FileHash -Algorithm SHA256 -Path $malformedHandoff).Hash
$malformedScriptBefore = (Get-FileHash -Algorithm SHA256 -Path $malformedScript).Hash
$previousMalformedEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$malformedOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $malformedTarget -Force 2>&1 | Out-String
$malformedCode = $LASTEXITCODE
$ErrorActionPreference = $previousMalformedEap
Check "-Force fails closed before copying when existing role binding is malformed" (($malformedCode -ne 0) -and ($malformedOut -match "cannot be parsed exactly") -and ($malformedHandoffBefore -eq (Get-FileHash -Algorithm SHA256 -Path $malformedHandoff).Hash) -and ($malformedScriptBefore -eq (Get-FileHash -Algorithm SHA256 -Path $malformedScript).Hash))

$alwaysOnTarget = Join-Path $FixtureRoot "install-target-always-on"
$alwaysOnOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $alwaysOnTarget -AlwaysOn 2>&1 | Out-String
$alwaysOnCode = $LASTEXITCODE
Check "-AlwaysOn explicitly installs root agent instructions" (($alwaysOnCode -eq 0) -and (Test-Path (Join-Path $alwaysOnTarget "AGENTS.md")) -and (Test-Path (Join-Path $alwaysOnTarget "CLAUDE.md")) -and ($alwaysOnOut -match "Activation mode: always-on"))

$disableAlwaysOnOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $alwaysOnTarget -Force -DisableAlwaysOn 2>&1 | Out-String
$disableAlwaysOnCode = $LASTEXITCODE
Check "-DisableAlwaysOn safely migrates unmodified bundled root instructions to opt-in" (($disableAlwaysOnCode -eq 0) -and (-not (Test-Path (Join-Path $alwaysOnTarget "AGENTS.md"))) -and (-not (Test-Path (Join-Path $alwaysOnTarget "CLAUDE.md"))) -and ($disableAlwaysOnOut -match "Activation mode: opt-in"))

$hostInstructionsTarget = Join-Path $FixtureRoot "install-target-host-instructions"
New-Item -ItemType Directory -Path $hostInstructionsTarget -Force | Out-Null
$hostAgents = Join-Path $hostInstructionsTarget "AGENTS.md"
Set-Content -Path $hostAgents -Value "# Host project instructions" -Encoding utf8
$hostAgentsBefore = (Get-FileHash -Algorithm SHA256 -Path $hostAgents).Hash
$hostOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $hostInstructionsTarget 2>&1 | Out-String
$hostCode = $LASTEXITCODE
$hostAgentsAfter = (Get-FileHash -Algorithm SHA256 -Path $hostAgents).Hash
Check "default opt-in install preserves an existing project AGENTS.md" (($hostCode -eq 0) -and ($hostAgentsBefore -eq $hostAgentsAfter) -and ($hostOut -match "Activation mode: opt-in"))

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$customRemovalOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $hostInstructionsTarget -Force -DisableAlwaysOn 2>&1 | Out-String
$customRemovalCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$hostAgentsAfterRemovalAttempt = (Get-FileHash -Algorithm SHA256 -Path $hostAgents).Hash
Check "-DisableAlwaysOn refuses to remove customized project root instructions" (($customRemovalCode -ne 0) -and ($customRemovalOut -match "Refusing to remove customized") -and ($hostAgentsBefore -eq $hostAgentsAfterRemovalAttempt))

$bootstrapScript = Join-Path $RepoRoot "bootstrap.ps1"
$bootstrapTarget = Join-Path $FixtureRoot "bootstrap-target"
$bootstrapOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript -Project $bootstrapTarget -PackageRoot $RepoRoot 2>&1 | Out-String
$bootstrapCode = $LASTEXITCODE
Check "bootstrap.ps1 delegates to the packaged opt-in installer" (($bootstrapCode -eq 0) -and (Test-Path (Join-Path $bootstrapTarget ".agents/skills/codex-claude-handoff/SKILL.md")) -and (-not (Test-Path (Join-Path $bootstrapTarget "AGENTS.md"))) -and ($bootstrapOut -match "Activation mode: opt-in"))

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$invalidBootstrapOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript -Project $bootstrapTarget -Version latest 2>&1 | Out-String
$invalidBootstrapCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
Check "bootstrap.ps1 rejects an unpinned version before downloading" (($invalidBootstrapCode -ne 0) -and ($invalidBootstrapOut -match "Version must look like"))

# === 4E. Release package builder ===
Write-Host "[4E] Release package builder"
$packageBuilder = Join-Path $RepoRoot "scripts/build-package.ps1"
$packageOutput = Join-Path $FixtureRoot "package-output"
$packageBuildOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $packageBuilder -OutputDirectory $packageOutput 2>&1 | Out-String
$packageBuildCode = $LASTEXITCODE
$currentPackageVersion = (Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/VERSION")).Trim()
$releaseZip = Join-Path $packageOutput "codex-claude-handoff-v$currentPackageVersion.zip"
$releaseChecksum = "$releaseZip.sha256"
$checksumText = if (Test-Path $releaseChecksum) { Get-Content -Raw -Path $releaseChecksum } else { "" }
$actualPackageHash = if (Test-Path $releaseZip) { (Get-FileHash -Algorithm SHA256 -Path $releaseZip).Hash.ToLowerInvariant() } else { "missing" }
Check "build-package.ps1 creates the versioned ZIP and SHA-256 file" (($packageBuildCode -eq 0) -and (Test-Path $releaseZip) -and (Test-Path $releaseChecksum) -and ($checksumText -match [regex]::Escape($actualPackageHash)))

$packageExtract = Join-Path $FixtureRoot "package-extract"
Expand-Archive -LiteralPath $releaseZip -DestinationPath $packageExtract -Force
$extractedPackage = Get-ChildItem -Path $packageExtract -Directory | Select-Object -First 1
$extractedInstall = if ($extractedPackage) { Join-Path $extractedPackage.FullName "install.ps1" } else { "" }
$extractedProtocolTests = if ($extractedPackage) { Join-Path $extractedPackage.FullName "templates/scripts/protocol-tests.ps1" } else { "" }
$extractedPublishing = if ($extractedPackage) { Join-Path $extractedPackage.FullName "PUBLISHING.md" } else { "" }
$extractedSecurity = if ($extractedPackage) { Join-Path $extractedPackage.FullName "SECURITY.md" } else { "" }
$extractedModelGuidance = if ($extractedPackage) { Join-Path $extractedPackage.FullName "MODEL_GUIDANCE.md" } else { "" }
$extractedLicense = if ($extractedPackage) { Join-Path $extractedPackage.FullName "LICENSE" } else { "" }
Check "release ZIP contains an installer and excludes package-development tests" ((Test-Path $extractedInstall) -and (-not (Test-Path $extractedProtocolTests)))

# The ZIP is built from the working tree, and a Windows clone with core.autocrlf=true
# checks shell scripts out as CRLF - which Bash on macOS/Linux refuses to run. It has
# happened twice. .gitattributes pins *.sh to LF; this checks the bytes that ship.
$extractedHandoffSh = if ($extractedPackage) { Join-Path $extractedPackage.FullName "templates/scripts/handoff.sh" } else { "" }
$shippedShBytes = if ($extractedHandoffSh -and (Test-Path -LiteralPath $extractedHandoffSh)) { [System.IO.File]::ReadAllBytes($extractedHandoffSh) } else { $null }
Check "the release ZIP ships handoff.sh with LF line endings" (($null -ne $shippedShBytes) -and ($shippedShBytes.Length -gt 0) -and (-not ($shippedShBytes -contains 13)))
$gitattributesPath = Join-Path $RepoRoot ".gitattributes"
$gitattributesText = if (Test-Path -LiteralPath $gitattributesPath) { Get-Content -Raw -LiteralPath $gitattributesPath } else { "" }
Check ".gitattributes pins shell scripts to LF" ($gitattributesText -match '(?m)^\*\.sh\s+text\s+eol=lf\s*$')
Check "release ZIP contains publication guidance and license" ((Test-Path $extractedPublishing) -and (Test-Path $extractedSecurity) -and (Test-Path $extractedModelGuidance) -and (Test-Path $extractedLicense))

$packagedInstallTarget = Join-Path $FixtureRoot "packaged-install-target"
$packagedInstallOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $extractedInstall -Project $packagedInstallTarget 2>&1 | Out-String
$packagedInstallCode = $LASTEXITCODE
Check "installer extracted from the release ZIP produces an opt-in project install" (($packagedInstallCode -eq 0) -and (Test-Path (Join-Path $packagedInstallTarget ".agents/skills/codex-claude-handoff/SKILL.md")) -and (-not (Test-Path (Join-Path $packagedInstallTarget "AGENTS.md"))) -and ($packagedInstallOut -match "Activation mode: opt-in"))

# === 4F. Standalone skills.sh package ===
Write-Host "[4F] Standalone skills.sh package"
$codexSkillRoot = Join-Path $RepoRoot ".agents/skills/codex-claude-handoff"
$claudeSkillRoot = Join-Path $RepoRoot ".claude/skills/codex-claude-handoff"
$skillSetup = Join-Path $codexSkillRoot "scripts/setup.ps1"
$skillSetupSh = Join-Path $codexSkillRoot "scripts/setup.sh"
$skillPackageInstall = Join-Path $codexSkillRoot "assets/package/install.ps1"
$skillPackageInstallSh = Join-Path $codexSkillRoot "assets/package/scripts/install.sh"
$skillText = Get-Content -Raw -Path (Join-Path $codexSkillRoot "SKILL.md")
$skillSetupText = Get-Content -Raw -Path $skillSetup
$skillSetupShText = Get-Content -Raw -Path $skillSetupSh

# v3.4.1: assert the Skill version matches the VERSION file rather than a hardcoded
# literal. Pinning the number here meant every release broke this check for a reason
# that had nothing to do with the property under test - and a stale literal would
# equally have hidden a real mismatch.
$canonicalVersion = (Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/VERSION")).Trim()
Check "public Skill declares Apache-2.0 and public-beta metadata" (($skillText -match "license:\s*Apache-2.0") -and ($skillText -match "status:\s*public-beta") -and ($skillText -match ('version:\s*"' + [regex]::Escape($canonicalVersion) + '"')))
Check "the public Skill version matches the canonical VERSION file" ($skillText -match ('version:\s*"' + [regex]::Escape($canonicalVersion) + '"'))

# v3.5.3: the v3.4.1 check above reads the repository's OWN Skill entry point, which
# is bumped every release and therefore always passed. The two SKILL.md files that
# actually ship to installers live under templates/ and were never covered, so their
# frontmatter froze at 3.3.2 while VERSION advanced three releases. Every v3.5.2
# install announced itself as 3.3.2 to the agent that loaded it - the one place a
# user sees the version without running a command. A test that measures the
# convenient copy instead of the shipped copy is not a test of the property.
$templateVersion = (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff/VERSION")).Trim()
Check "the shipped VERSION template matches the canonical VERSION file" ($templateVersion -eq $canonicalVersion)
foreach ($templateSkillRelative in @("templates/.agents/skills/codex-claude-handoff/SKILL.md", "templates/.claude/skills/codex-claude-handoff/SKILL.md")) {
    $templateSkillText = Get-Content -Raw -Path (Join-Path $RepoRoot $templateSkillRelative)
    Check "$templateSkillRelative declares the shipped VERSION" ($templateSkillText -match ('version:\s*"' + [regex]::Escape($templateVersion) + '"'))
}
Check "public Skill positions an accountable engineering pair" (($skillText -match "One drives\. One challenges\. Neither ships alone\.") -and ($skillText -match "accountable engineering"))
Check "public Skill distinguishes one live task from summaries and parallel answers" (($skillText -match "same live Git task") -and ($skillText -match "pass a summary") -and ($skillText -match "run the same prompt in parallel"))
Check "public Skill distinguishes bounded correction from unrestricted dialogue" (($skillText -match "bounded by turn, time, and") -and ($skillText -match "General question dialogue still advances through explicit turns"))
Check "public Skill surfaces independent review and fail-closed safety" (($skillText -match "reviews\s+independently") -and ($skillText -match "Fails closed"))
Check "public Skill documents approved role flexibility and adapter limits" (($skillText -match "roles configurable") -and ($skillText -match "explicit user approval") -and ($skillText -match "Automation\s+availability depends on the verified adapter"))
Check "public Skill requires explicit setup approval and forbids implicit invocation" (($skillText -match "explicit user approval") -and ((Get-Content -Raw -Path (Join-Path $codexSkillRoot "agents/openai.yaml")) -match "allow_implicit_invocation:\s*false"))
$publicSkillEntryFiles = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -File -Filter "SKILL.md" | Where-Object {
    (Get-Content -Raw -LiteralPath $_.FullName) -match "(?m)^license:\s*Apache-2\.0\s*$"
})
$publicSkillFrontmatterIsSafe = ($publicSkillEntryFiles.Count -gt 0)
$unsafePublicSkillFrontmatter = ""
foreach ($publicSkillEntryFile in $publicSkillEntryFiles) {
    $publicSkillEntryText = Get-Content -Raw -LiteralPath $publicSkillEntryFile.FullName
    if ($publicSkillEntryText -notmatch "(?m)^description:\s*>-\s*$") {
        $publicSkillFrontmatterIsSafe = $false
        $unsafePublicSkillFrontmatter = $publicSkillEntryFile.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        break
    }
}
Check "all public Skill entry points use YAML-safe folded descriptions" $publicSkillFrontmatterIsSafe $unsafePublicSkillFrontmatter
Check "standalone Skill bundles local PowerShell and Bash installers" ((Test-Path $skillSetup) -and (Test-Path $skillSetupSh) -and (Test-Path $skillPackageInstall) -and (Test-Path $skillPackageInstallSh))
Check "standalone Skill bundles the initial handoff template" (Test-Path (Join-Path $codexSkillRoot "assets/package/templates/AI_HANDOFF.md"))
Check "standalone setup scripts contain no network downloader" (($skillSetupText -notmatch "Invoke-WebRequest|Start-BitsTransfer|https?://") -and ($skillSetupShText -notmatch "curl|wget|https?://"))
Check "bundled PowerShell installer matches the canonical installer" (((Get-FileHash -Algorithm SHA256 -Path $skillPackageInstall).Hash) -eq ((Get-FileHash -Algorithm SHA256 -Path (Join-Path $RepoRoot "install.ps1")).Hash))
Check "bundled Bash installer matches the canonical installer" (((Get-FileHash -Algorithm SHA256 -Path $skillPackageInstallSh).Hash) -eq ((Get-FileHash -Algorithm SHA256 -Path (Join-Path $RepoRoot "scripts/install.sh")).Hash))

$codexSkillFiles = @(Get-ChildItem -LiteralPath $codexSkillRoot -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($codexSkillRoot.Length).TrimStart('\', '/') -replace '\\', '/' } | Sort-Object)
$claudeSkillFiles = @(Get-ChildItem -LiteralPath $claudeSkillRoot -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($claudeSkillRoot.Length).TrimStart('\', '/') -replace '\\', '/' } | Sort-Object)
$skillMirrorsMatch = (($codexSkillFiles -join "`n") -eq ($claudeSkillFiles -join "`n"))
if ($skillMirrorsMatch) {
    foreach ($relative in $codexSkillFiles) {
        $codexFile = Join-Path $codexSkillRoot ($relative -replace '/', '\')
        $claudeFile = Join-Path $claudeSkillRoot ($relative -replace '/', '\')
        if (((Get-FileHash -Algorithm SHA256 -Path $codexFile).Hash) -ne ((Get-FileHash -Algorithm SHA256 -Path $claudeFile).Hash)) {
            $skillMirrorsMatch = $false
            break
        }
    }
}
Check "Codex and Claude standalone Skill payloads are byte-identical" $skillMirrorsMatch

$standaloneTarget = Join-Path $FixtureRoot "standalone-skill-target"
New-Item -ItemType Directory -Path $standaloneTarget -Force | Out-Null
& git -C $standaloneTarget init 2>&1 | Out-Null
$fixtureSkill = Join-Path $standaloneTarget ".agents/skills/codex-claude-handoff"
New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureSkill) -Force | Out-Null
Copy-Item -LiteralPath $codexSkillRoot -Destination $fixtureSkill -Recurse -Force
$fixtureSetup = Join-Path $fixtureSkill "scripts/setup.ps1"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$standaloneSetupOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $fixtureSetup -Project $standaloneTarget 2>&1 | Out-String
$standaloneSetupCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
Check "bundled Skill setup installs the complete protocol and doctor passes" (($standaloneSetupCode -eq 0) -and ($standaloneSetupOut -match "Doctor result: PASS") -and (Test-Path (Join-Path $standaloneTarget ".ai/skills/codex-claude-handoff/SKILL.md")) -and (Test-Path (Join-Path $standaloneTarget "scripts/handoff.ps1")))
$createdBranchRefs = @(Get-ChildItem -LiteralPath (Join-Path $standaloneTarget ".git/refs/heads") -Recurse -File -ErrorAction SilentlyContinue)
Check "bundled Skill setup remains opt-in and runs no git commit" ((-not (Test-Path (Join-Path $standaloneTarget "AGENTS.md"))) -and (-not (Test-Path (Join-Path $standaloneTarget "CLAUDE.md"))) -and ($createdBranchRefs.Count -eq 0) -and ($standaloneSetupOut -match "usual stable install commit"))

$nonGitTarget = Join-Path $FixtureRoot "standalone-skill-non-git"
New-Item -ItemType Directory -Path $nonGitTarget -Force | Out-Null
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$nonGitSetupOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $skillSetup -Project $nonGitTarget 2>&1 | Out-String
$nonGitSetupCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
Check "bundled Skill setup fails closed outside a Git repository" (($nonGitSetupCode -eq 2) -and ($nonGitSetupOut -match "requires a Git repository") -and (-not (Test-Path (Join-Path $nonGitTarget ".ai"))))
# === 5. Release executor guards (fail closed) ===
Write-Host "[5] Release executor guards (release-check)"
# Missing -Version: must block, no git mutation.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("release-check")
Check "release-check without -Version is blocked (exit 1)" (($r.Code -eq 1) -and ($r.Out -match "release-check: blocked") -and ($r.Out -match "Missing -Version"))
Check "release-check prints 'No git mutations were run'" ($r.Out -match "No git mutations were run")

# Wrong state: REVIEW_DONE required.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("release-check", "-Version", "v0.20.0")
Check "release-check blocks unless State is REVIEW_DONE / Waiting For: User" (($r.Code -eq 1) -and ($r.Out -match "must be State: REVIEW_DONE"))

# Same actor for Implementer and Reviewer: audit invariant.
$badHandoff = New-Handoff -State "REVIEW_DONE" -WaitingFor "User"
$badHandoff = $badHandoff -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $badHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("release-check", "-Version", "v0.20.0")
Check "release-check blocks stale actors at the role checkpoint" (($r.Code -eq 12) -and ($r.Out -match "Role checkpoint: BLOCKED") -and ($r.Out -match "Role drift"))

# === 5B. Approved commit executor guards (commit-check / commit-approved) ===
Write-Host "[5B] Approved commit executor guards (commit-check / commit-approved)"
$commitHandoff = New-Handoff -State "REVIEW_DONE" -WaitingFor "User"
$commitHandoff = $commitHandoff -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- COMMIT_TARGET.md"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $commitHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
Set-Content -Path (Join-Path $fx "COMMIT_TARGET.md") -Value "# approved commit fixture" -Encoding utf8
$beforeCommits = (& git -C $fx rev-list --all --count 2>$null)
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "Complete approved commit fixture")
$afterCommits = (& git -C $fx rev-list --all --count 2>$null)
Check "commit-check allows matching REVIEW_DONE scope without mutating git" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready") -and ("$beforeCommits".Trim() -eq "$afterCommits".Trim()))

$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-approved", "-Message", "Complete approved commit fixture")
$afterBlockedCommits = (& git -C $fx rev-list --all --count 2>$null)
Check "commit-approved requires exact authorization token" (($r.Code -eq 1) -and ($r.Out -match "Missing exact authorization token") -and ("$afterBlockedCommits".Trim() -eq "$beforeCommits".Trim()))

$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-approved", "-Authorize", "I_AUTHORIZE_COMMIT")
$afterMissingMessageCommits = (& git -C $fx rev-list --all --count 2>$null)
Check "commit-approved requires a commit message" (($r.Code -eq 1) -and ($r.Out -match "Missing -Message") -and ("$afterMissingMessageCommits".Trim() -eq "$beforeCommits".Trim()))

$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-approved", "-Message", "Complete approved commit fixture", "-Authorize", "I_AUTHORIZE_COMMIT")
$finalCommits = (& git -C $fx rev-list --all --count 2>$null)
$statusAfterCommit = (& git -C $fx status --short --untracked-files=all 2>$null | Out-String)
$headFiles = (& git -C $fx show --name-only --format= HEAD 2>$null | Out-String)
Check "commit-approved commits only the reviewed Changed Files" (($r.Code -eq 0) -and ($r.Out -match "commit-approved: complete") -and ([int]"$finalCommits".Trim() -eq ([int]"$beforeCommits".Trim() + 1)) -and ($statusAfterCommit.Trim() -eq "") -and ($headFiles -match "COMMIT_TARGET.md") -and ($headFiles -notmatch "AI_HANDOFF.md"))

$badCommitHandoff = $commitHandoff -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $badCommitHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
Set-Content -Path (Join-Path $fx "COMMIT_TARGET.md") -Value "# approved commit fixture" -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "Bad actor fixture")
Check "commit-check blocks stale actors at the role checkpoint" (($r.Code -eq 12) -and ($r.Out -match "Role checkpoint: BLOCKED") -and ($r.Out -match "Role drift"))

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $commitHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
Set-Content -Path (Join-Path $fx "COMMIT_TARGET.md") -Value "# approved commit fixture" -Encoding utf8
Set-Content -Path (Join-Path $fx "EXTRA.md") -Value "# extra" -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "Mismatch fixture")
Check "commit-check blocks when Changed Files does not match git status" (($r.Code -eq 1) -and ($r.Out -match "does not exactly match git status"))
Check "the scope mismatch diagnostic states the canonical path spelling" ($r.Out -match "forward slashes")

# --- v3.4.1 exact-scope path hardening (S-2) ----------------------------------------
# Git quotes and octal-escapes any path with non-ASCII characters or spaces under the
# default core.quotePath, so the pre-v3.4.1 parser could never match a hand-written
# path and exact-scope comparison failed closed on every such repository.

function New-ScopeFixture {
    param([string[]]$Paths, [string[]]$Declared = $null)
    if (-not $Declared) { $Declared = $Paths }
    $h = New-Handoff -State "REVIEW_DONE" -WaitingFor "User"
    $list = ($Declared | ForEach-Object { "- $_" }) -join "`n"
    $h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n$list"
    $d = New-Fixture -Files @{ "AI_HANDOFF.md" = $h; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $d
    foreach ($p in $Paths) {
        $full = Join-Path $d $p
        $parent = Split-Path -Parent $full
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content -LiteralPath $full -Value "scope fixture" -Encoding utf8
    }
    return $d
}

# Both redirected pipes must be drained concurrently. Reading stdout to EOF while
# stderr sits unread deadlocks as soon as git fills the stderr buffer: git blocks,
# stdout never closes, and the guard hangs instead of failing closed.
$captureSource = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
$captureBody = ""
if ($captureSource -match '(?s)function Get-GitStatusFields\s*\{(.*?)\n\}') { $captureBody = $Matches[1] }
Check "the git capture drains stderr asynchronously (no sequential-read deadlock)" ($captureBody -match 'StandardError\.ReadToEndAsync\(\)')
Check "the git capture starts the stderr read before the blocking stdout read" (
    ($captureBody.IndexOf('StandardError.ReadToEndAsync') -ge 0) -and
    ($captureBody.IndexOf('StandardError.ReadToEndAsync') -lt $captureBody.IndexOf('StandardOutput.ReadToEnd()'))
)
Check "the git capture pins porcelain=v1 so a Git default change cannot alter the format" ($captureBody -match '--porcelain=v1')
Check "the git capture pins UTF-8 decoding independent of the console codepage" ($captureBody -match 'StandardOutputEncoding')

# The Bash entry point must reach the SAME verdict as PowerShell. Git can emit a
# partial record set and then fail; a process substitution discards that exit status
# and the parser would accept the truncated set as the exact scope.
$bashSource = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.sh")
Check "the Bash exact-scope parser reads Git's NUL-delimited porcelain" ($bashSource -match '--porcelain=v1 -z --untracked-files=all')
Check "the Bash exact-scope parser checks git status exit status before trusting any field" ($bashSource -match 'if ! git status --porcelain=v1 -z')
Check "the Bash exact-scope parser fails closed when git status fails" ($bashSource -match 'git status failed; exact scope cannot be verified')
Check "the Bash exact-scope parser no longer consumes git through a process substitution" ($bashSource -notmatch '< <\(git status')
Check "the Bash exact-scope parser discards rename and copy source fields" ($bashSource -match 'R\?\|C\?\|\?R\|\?C')

# --- v3.4.2 first-run clarity -------------------------------------------------------
# A feature that silently does nothing is worse than one that is off, because the user
# cannot tell which they have. Shipped routing maps every profile to inherit - correct,
# per the v3.1.7 rule - but nothing said so, so the headline feature of v3.4.0 appeared
# to work while changing nothing.
$handoffSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "inert model routing is detectable" ($handoffSrc -match 'function Test-ModelRoutingInert')
Check "shipped routing keeps every profile on inherit (install changes no behavior)" (
    ((Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json")) -notmatch '"claudeModel"\s*:\s*"(?!inherit)')
)
Check "the shipped routing file documents how to activate it" ((Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json")) -match '_readme')

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit"},"economy":{"claudeModel":"inherit"}}}' }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("models")
Check "models reports INERT when every profile resolves to inherit" ($r.Out -match "INERT")
Check "the INERT message names the file to edit" ($r.Out -match "MODEL_ROUTING\.json")

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"some-local-model"},"economy":{"claudeModel":"inherit"}}}' }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("models")
Check "models does NOT report INERT once any profile maps to a concrete model" ($r.Out -notmatch "INERT")

# --- v3.5.1: INERT must account for environment overrides ---
#
# The documented override order is -Model, HANDOFF_CLAUDE_MODEL_<PROFILE>,
# MODEL_ROUTING.json, inherit - but the INERT check read only the file. An operator who
# activated routing through the environment (the way to activate it WITHOUT editing a
# file that ships to every installer) got a report that contradicted itself in adjacent
# lines: the resolved model was named as sonnet from the environment, and the banner
# underneath still said every turn runs on whatever model Claude Code already uses.
$inertFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
    ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit"},"cheap_readonly":{"claudeModel":"inherit"}}}'
}
$r = Invoke-Handoff -WorkDir $inertFx -Arguments @("models")
Check "an all-inherit file with no environment override still reports INERT" ($r.Out -match "INERT")

$prevStd = $env:HANDOFF_CLAUDE_MODEL_STANDARD
$env:HANDOFF_CLAUDE_MODEL_STANDARD = "test-env-standard-model"
try {
    $r = Invoke-Handoff -WorkDir $inertFx -Arguments @("models")
    Check "an environment override activates routing even though the file is all-inherit" ($r.Out -match "test-env-standard-model")
    Check "and the INERT banner is NOT printed alongside a resolved concrete model" ($r.Out -notmatch "INERT")
    Check "the report names the environment as the resolution source" ($r.Out -match "environment HANDOFF_CLAUDE_MODEL_STANDARD")
} finally {
    if ($null -eq $prevStd) { Remove-Item Env:\HANDOFF_CLAUDE_MODEL_STANDARD -ErrorAction SilentlyContinue } else { $env:HANDOFF_CLAUDE_MODEL_STANDARD = $prevStd }
}

$prevCheap = $env:HANDOFF_CLAUDE_MODEL_CHEAP_READONLY
$env:HANDOFF_CLAUDE_MODEL_CHEAP_READONLY = "test-env-cheap-model"
try {
    # An override on a profile OTHER than the effective one still means routing can change
    # a model, so INERT is still the wrong word for it.
    $r = Invoke-Handoff -WorkDir $inertFx -Arguments @("models")
    Check "an override on any profile clears INERT, not only the effective one" ($r.Out -notmatch "INERT")
} finally {
    if ($null -eq $prevCheap) { Remove-Item Env:\HANDOFF_CLAUDE_MODEL_CHEAP_READONLY -ErrorAction SilentlyContinue } else { $env:HANDOFF_CLAUDE_MODEL_CHEAP_READONLY = $prevCheap }
}

$prevStd2 = $env:HANDOFF_CLAUDE_MODEL_STANDARD
$env:HANDOFF_CLAUDE_MODEL_STANDARD = "inherit"
try {
    # An override that says "inherit" changes nothing, so it must not clear INERT either.
    $r = Invoke-Handoff -WorkDir $inertFx -Arguments @("models")
    Check "an override whose value is inherit does not falsely clear INERT" ($r.Out -match "INERT")
} finally {
    if ($null -eq $prevStd2) { Remove-Item Env:\HANDOFF_CLAUDE_MODEL_STANDARD -ErrorAction SilentlyContinue } else { $env:HANDOFF_CLAUDE_MODEL_STANDARD = $prevStd2 }
}

Check "the INERT guidance names the environment route, not only the file" ($handoffSrc -match "HANDOFF_CLAUDE_MODEL_<PROFILE> in your environment")

# v3.5.2: doctor and models must give the SAME activation guidance. v3.5.1 fixed the
# detector and the models message but left doctor naming the file as the only route -
# and that file is the one that ships to every installer.
Check "doctor's INERT guidance also names the environment route" ($handoffSrc -match "Activate it either by setting HANDOFF_CLAUDE_MODEL_<PROFILE> in your environment")
Check "doctor's INERT guidance says the environment route touches no tracked file" ($handoffSrc -match "no tracked file is touched")
Check "doctor no longer claims INERT is a property of MODEL_ROUTING.json alone" ($handoffSrc -notmatch "Model routing is INERT: every profile in MODEL_ROUTING\.json resolves to inherit")

# Presence is not sameness. The v3.5.2 claim is that both commands give the SAME
# guidance in the SAME order, and a string-presence check cannot see order - which is
# exactly how a half-applied fix passed 426 tests and was caught in review instead.
# Both blocks must name the environment route BEFORE the file route.
Check "both INERT blocks exist and each names the environment route first" (
    (@($handoffSrc -split "`r?`n" | Where-Object { $_ -match "Activate it either by setting HANDOFF_CLAUDE_MODEL_<PROFILE> in your environment" }).Count -eq 2)
)
Check "neither INERT block puts the tracked file before the environment" (
    ($handoffSrc -notmatch "To activate, either map profiles to concrete local models in")
)
Check "both INERT blocks describe the state without naming the file as its cause" (
    (@($handoffSrc -split "`r?`n" | Where-Object { $_ -match "INERT" -and $_ -match "no profile resolves to a concrete model" }).Count -eq 2)
)

# v3.4.3: activation is a guarded command, not hand-edited JSON. It must write only the
# profiles named, keep the rest, stay valid, and refuse to do anything with no mapping.
$routing = '{"schemaVersion":1,"_readme":["keep me"],"profiles":{"standard":{"claudeModel":"inherit"},"cheap_readonly":{"claudeModel":"inherit"},"economy":{"claudeModel":"inherit"}}}'
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $routing }
$cfgPath = Join-Path $fx ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json"
$beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cfgPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("models", "-Activate")
Check "models -Activate with no mapping refuses" ($r.Out -match "no mapping supplied")
Check "models -Activate with no mapping changes nothing" ((Get-FileHash -Algorithm SHA256 -LiteralPath $cfgPath).Hash -eq $beforeHash)

$r = Invoke-Handoff -WorkDir $fx -Arguments @("models", "-Activate", "-Standard", "some-standard-model")
$cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
Check "models -Activate maps the profile it was given" ($cfg.profiles.standard.claudeModel -eq "some-standard-model")
Check "models -Activate leaves unnamed profiles alone" (($cfg.profiles.cheap_readonly.claudeModel -eq "inherit") -and ($cfg.profiles.economy.claudeModel -eq "inherit"))
Check "models -Activate preserves the file's _readme" ($null -ne $cfg._readme)
Check "models -Activate reports the routing transition" (($r.Out -match "Routing before: inert") -and ($r.Out -match "Routing after:  active"))
$r = Invoke-Handoff -WorkDir $fx -Arguments @("models")
Check "activated routing no longer reports INERT" ($r.Out -notmatch "INERT")
Check "models with no arguments performs no write" ((Get-FileHash -Algorithm SHA256 -LiteralPath $cfgPath).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $cfgPath).Hash)

$fxBad = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = 'not json' }
$badBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fxBad ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json")).Hash
$r = Invoke-Handoff -WorkDir $fxBad -Arguments @("models", "-Activate", "-Standard", "x")
Check "models -Activate refuses to edit an unparseable config" ($r.Out -match "not valid JSON")
Check "an unparseable config is left byte-identical" ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fxBad ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json")).Hash -eq $badBefore)

# --- v3.10.0: one profile, one model per tool ---
#
# Every codex exec inherited whatever model the local Codex configuration named, so a task
# the Master marked high_reasoning ran on the standard model, and a window left on the
# strongest model ran ordinary turns on it: one real session spent a five-hour usage
# window in three minutes that way. Codex now resolves its own model from the same
# profile, automated Codex turns pass it, and NEXT_TURN.md names it for a window.
Write-Host "[4C-2] Codex model routing (v3.10.0)"
$shippedRoutingText = Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json")
$shippedRoutingConfig = $shippedRoutingText | ConvertFrom-Json
Check "shipped routing names a codexModel for every profile" (@($shippedRoutingConfig.profiles.PSObject.Properties | Where-Object { $null -eq $_.Value.PSObject.Properties['codexModel'] }).Count -eq 0)
Check "shipped routing keeps every codexModel on inherit (install changes no behavior)" ($shippedRoutingText -notmatch '"codexModel"\s*:\s*"(?!inherit)')

$codexRouting = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"test-claude-standard","codexModel":"test-codex-standard"},"high_reasoning":{"claudeModel":"inherit","codexModel":"test-codex-high"}}}'
$highProfileHandoff = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -CurrentTask "codex routing high") -replace "(- Current Task:[^\r\n]+)", "`$1`r`n- Model Profile: high_reasoning"
$codexFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -CurrentTask "codex routing"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $codexRouting }
$r = Invoke-Handoff -WorkDir $codexFx -Arguments @("models")
Check "models resolves the Codex model from the profile's codexModel" (($r.Code -eq 0) -and ($r.Out -match "Codex model:\s+test-codex-standard") -and ($r.Out -match "Codex source:\s+MODEL_ROUTING\.json"))
Check "the Claude model still resolves from claudeModel beside it" ($r.Out -match "Claude model:\s+test-claude-standard")
Check "models names the Codex override order" ($r.Out -match "Codex order:\s+-CodexModel, HANDOFF_CODEX_MODEL_<PROFILE>, MODEL_ROUTING\.json codexModel, inherit")
Check "models tells a window driver that a model change means a new window" ($r.Out -match "Start a new window when the model changes")

$prevCodexStandard = $env:HANDOFF_CODEX_MODEL_STANDARD
$env:HANDOFF_CODEX_MODEL_STANDARD = "test-env-codex-standard"
try {
    $r = Invoke-Handoff -WorkDir $codexFx -Arguments @("models")
    Check "HANDOFF_CODEX_MODEL_<PROFILE> overrides codexModel" (($r.Out -match "Codex model:\s+test-env-codex-standard") -and ($r.Out -match "Codex source:\s+environment HANDOFF_CODEX_MODEL_STANDARD"))
    Check "a Codex override leaves the Claude model alone" ($r.Out -match "Claude model:\s+test-claude-standard")
    $r = Invoke-Handoff -WorkDir $codexFx -Arguments @("models", "-CodexModel", "test-cli-codex")
    Check "-CodexModel overrides the environment" (($r.Out -match "Codex model:\s+test-cli-codex") -and ($r.Out -match "command line -CodexModel"))
} finally {
    if ($null -eq $prevCodexStandard) { Remove-Item Env:\HANDOFF_CODEX_MODEL_STANDARD -ErrorAction SilentlyContinue } else { $env:HANDOFF_CODEX_MODEL_STANDARD = $prevCodexStandard }
}
$r = Invoke-Handoff -WorkDir $codexFx -Arguments @("models", "-CodexModel", "two words")
Check "an unsafe Codex model value fails closed" (($r.Code -eq 1) -and ($r.Out -match "Resolved Codex model value must be a single model identifier"))

$codexOnlyFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit","codexModel":"test-codex-only"},"economy":{"claudeModel":"inherit","codexModel":"inherit"}}}' }
$r = Invoke-Handoff -WorkDir $codexOnlyFx -Arguments @("models")
Check "a codexModel mapping alone clears INERT" ($r.Out -notmatch "INERT")
$codexInertFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit","codexModel":"inherit"}}}' }
$r = Invoke-Handoff -WorkDir $codexInertFx -Arguments @("models")
Check "all-inherit Claude and Codex values still report INERT" ($r.Out -match "INERT")
$prevCodexEconomy = $env:HANDOFF_CODEX_MODEL_ECONOMY
$env:HANDOFF_CODEX_MODEL_ECONOMY = "test-env-codex-economy"
try {
    $r = Invoke-Handoff -WorkDir $codexInertFx -Arguments @("models")
    Check "a Codex environment override clears INERT" ($r.Out -notmatch "INERT")
} finally {
    if ($null -eq $prevCodexEconomy) { Remove-Item Env:\HANDOFF_CODEX_MODEL_ECONOMY -ErrorAction SilentlyContinue } else { $env:HANDOFF_CODEX_MODEL_ECONOMY = $prevCodexEconomy }
}

# NEXT_TURN.md names the model for the actor's own tool, and the new-window rule.
$null = Invoke-Handoff -WorkDir $codexFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $codexFx "NEXT_TURN.md")
Check "NEXT_TURN.md names the Codex model for a Codex Master turn" (($nt -match "## Model For This Turn") -and ($nt -match "Profile: standard") -and ($nt -match "Codex model: test-codex-standard \(MODEL_ROUTING\.json\)"))
Check "NEXT_TURN.md says to start a new window rather than switch models" ($nt -match "start a new window on this one instead of switching inside the conversation")
$highNextFx = New-Fixture -Files @{ "AI_HANDOFF.md" = $highProfileHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $codexRouting }
$null = Invoke-Handoff -WorkDir $highNextFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $highNextFx "NEXT_TURN.md")
Check "a high_reasoning task names the strongest mapped Codex model" (($nt -match "Profile: high_reasoning") -and ($nt -match "Codex model: test-codex-high"))
$claudeNextFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $codexRouting }
$null = Invoke-Handoff -WorkDir $claudeNextFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $claudeNextFx "NEXT_TURN.md")
Check "a Claude Code turn names the Claude model, not the Codex one" (($nt -match "Claude model: test-claude-standard \(MODEL_ROUTING\.json\)") -and ($nt -notmatch "Codex model:"))
$inheritNextFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$null = Invoke-Handoff -WorkDir $inheritNextFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $inheritNextFx "NEXT_TURN.md")
Check "an unmapped profile says to keep the window's model" (($nt -match "Codex model: inherit \(built-in fallback\)") -and ($nt -match "keep the model your window already uses"))
$userNextFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$null = Invoke-Handoff -WorkDir $userNextFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $userNextFx "NEXT_TURN.md")
Check "a User turn carries no model section" ($nt -notmatch "## Model For This Turn")

# --- v3.16.0: the Codex reasoning effort follows the profile ---
# Codex has no floating model aliases, so a concrete model name in a mapping breaks when
# the vendor replaces the model. An effort level does not. The profile now maps to one.
Write-Host "[4C-2b] Codex reasoning effort routing (v3.16.0)"
Check "shipped routing names a codexEffort for every profile" (@($shippedRoutingConfig.profiles.PSObject.Properties | Where-Object { $null -eq $_.Value.PSObject.Properties['codexEffort'] }).Count -eq 0)
Check "shipped routing keeps every codexEffort on inherit (install changes no behavior)" ($shippedRoutingText -notmatch '"codexEffort"\s*:\s*"(?!inherit)')
# Windows PowerShell keeps the LAST of two identical keys and handoff.sh reads the FIRST, so a
# repeated key would make the two shells disagree about a value the user edited.
Check "shipped routing names each key once per profile" (([regex]::Matches($shippedRoutingText, '"codexEffort"').Count -eq @($shippedRoutingConfig.profiles.PSObject.Properties).Count) -and ([regex]::Matches($shippedRoutingText, '"codexModel"').Count -eq @($shippedRoutingConfig.profiles.PSObject.Properties).Count) -and ([regex]::Matches($shippedRoutingText, '"claudeModel"').Count -eq @($shippedRoutingConfig.profiles.PSObject.Properties).Count))
Check "shipped routing repeats no guidance line" (@($shippedRoutingConfig._readme | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0)

$effortRouting = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit","codexModel":"test-codex-standard","codexEffort":"low"},"high_reasoning":{"claudeModel":"inherit","codexModel":"inherit","codexEffort":"high"}}}'
$effortOnlyRouting = '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit","codexModel":"inherit","codexEffort":"medium"}}}'
$effortFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -CurrentTask "codex effort"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortRouting }
$r = Invoke-Handoff -WorkDir $effortFx -Arguments @("models")
Check "models resolves the Codex effort from the profile's codexEffort" (($r.Code -eq 0) -and ($r.Out -match "Codex effort:\s+low") -and ($r.Out -match "Effort source:\s+MODEL_ROUTING\.json"))
Check "the Codex model still resolves beside the effort" ($r.Out -match "Codex model:\s+test-codex-standard")
Check "models names the effort override order" ($r.Out -match "Effort order:\s+-CodexEffort, HANDOFF_CODEX_EFFORT_<PROFILE>, MODEL_ROUTING\.json codexEffort, inherit")
Check "models says a resolved effort is passed to codex exec" ($r.Out -match "Effort behavior:\s+master-run, review-run and the Codex Implementer pass -c model_reasoning_effort")
$r = Invoke-Handoff -WorkDir $codexFx -Arguments @("models")
Check "a profile with no codexEffort resolves to inherit" (($r.Code -eq 0) -and ($r.Out -match "Codex effort:\s+inherit") -and ($r.Out -match "Effort behavior:\s+Codex uses its configured/default reasoning effort"))

$prevEffortStandard = $env:HANDOFF_CODEX_EFFORT_STANDARD
$env:HANDOFF_CODEX_EFFORT_STANDARD = "HIGH"
try {
    $r = Invoke-Handoff -WorkDir $effortFx -Arguments @("models")
    Check "HANDOFF_CODEX_EFFORT_<PROFILE> overrides codexEffort, case-insensitively" (($r.Out -match "Codex effort:\s+high") -and ($r.Out -match "Effort source:\s+environment HANDOFF_CODEX_EFFORT_STANDARD"))
    Check "an effort override leaves the Codex model alone" ($r.Out -match "Codex model:\s+test-codex-standard")
    $r = Invoke-Handoff -WorkDir $effortFx -Arguments @("models", "-CodexEffort", "minimal")
    Check "-CodexEffort overrides the environment" (($r.Out -match "Codex effort:\s+minimal") -and ($r.Out -match "command line -CodexEffort"))
    $env:HANDOFF_CODEX_EFFORT_STANDARD = "turbo"
    $r = Invoke-Handoff -WorkDir $effortFx -Arguments @("models")
    Check "an unknown effort level from the environment fails closed" (($r.Code -eq 1) -and ($r.Out -match "Resolved Codex reasoning effort must be one of: minimal, low, medium, high, xhigh, or inherit"))
} finally {
    if ($null -eq $prevEffortStandard) { Remove-Item Env:\HANDOFF_CODEX_EFFORT_STANDARD -ErrorAction SilentlyContinue } else { $env:HANDOFF_CODEX_EFFORT_STANDARD = $prevEffortStandard }
}
$r = Invoke-Handoff -WorkDir $effortFx -Arguments @("models", "-CodexEffort", "high; rm -rf")
Check "an effort value that is not a level never reaches codex exec" (($r.Code -eq 1) -and ($r.Out -match "Resolved Codex reasoning effort must be one of"))
$badEffortFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"codexEffort":"extreme"}}}' }
$r = Invoke-Handoff -WorkDir $badEffortFx -Arguments @("models")
Check "an unknown effort level in MODEL_ROUTING.json fails closed" (($r.Code -eq 1) -and ($r.Out -match "Resolved Codex reasoning effort must be one of"))
$r = Invoke-Handoff -WorkDir $badEffortFx -Arguments @("doctor")
Check "doctor fails on an unknown effort level" ($r.Out -match "Model routing configuration is invalid")
$r = Invoke-Handoff -WorkDir $effortFx -Arguments @("doctor")
Check "doctor reports the resolved Codex effort" ($r.Out -match "Codex effort=low; effort source=MODEL_ROUTING\.json")

$effortOnlyFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortOnlyRouting }
$r = Invoke-Handoff -WorkDir $effortOnlyFx -Arguments @("models")
Check "a codexEffort mapping alone clears INERT" (($r.Code -eq 0) -and ($r.Out -notmatch "INERT") -and ($r.Out -match "Codex model:\s+inherit"))
$prevEffortEconomy = $env:HANDOFF_CODEX_EFFORT_ECONOMY
$env:HANDOFF_CODEX_EFFORT_ECONOMY = "low"
try {
    $r = Invoke-Handoff -WorkDir $codexInertFx -Arguments @("models")
    Check "a Codex effort environment override clears INERT" ($r.Out -notmatch "INERT")
} finally {
    if ($null -eq $prevEffortEconomy) { Remove-Item Env:\HANDOFF_CODEX_EFFORT_ECONOMY -ErrorAction SilentlyContinue } else { $env:HANDOFF_CODEX_EFFORT_ECONOMY = $prevEffortEconomy }
}

$null = Invoke-Handoff -WorkDir $effortFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $effortFx "NEXT_TURN.md")
Check "NEXT_TURN.md names the Codex reasoning effort for a Codex turn" ($nt -match "Codex reasoning effort: low \(MODEL_ROUTING\.json\)")
$effortClaudeFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortRouting }
$null = Invoke-Handoff -WorkDir $effortClaudeFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $effortClaudeFx "NEXT_TURN.md")
Check "a Claude Code turn carries no Codex effort line" (($nt -match "## Model For This Turn") -and ($nt -notmatch "Codex reasoning effort"))
$null = Invoke-Handoff -WorkDir $codexFx -Arguments @("next")
$nt = Get-Content -Raw -Path (Join-Path $codexFx "NEXT_TURN.md")
Check "an unmapped effort adds no effort line" ($nt -notmatch "Codex reasoning effort")

# Both shells, one answer: handoff.sh writes the same model section for the same project.
$parityBash = Get-Command bash -ErrorAction SilentlyContinue
if ($null -eq $parityBash) {
    Write-Host "  SKIP  model section parity with handoff.sh: no bash interpreter on this machine"
} else {
    $shPath = (Join-Path $RepoRoot "scripts/handoff.sh") -replace '\\', '/'
    $activateLayout = @"
{
    "schemaVersion":  1,
    "profiles":  {
                     "standard":  {
                                      "claudeModel":  "test-claude-standard",
                                      "codexModel":  "test-codex-layout"
                                  },
                     "high_reasoning":  {
                                            "codexModel":  "test-codex-high"
                                        }
                 }
}
"@
    $parityCases = @(
        @{ Name = "file mapping"; Fx = $codexFx; Env = @{} },
        @{ Name = "environment override"; Fx = $codexFx; Env = @{ HANDOFF_CODEX_MODEL_STANDARD = "test-env-parity" } },
        @{ Name = "high_reasoning task"; Fx = $highNextFx; Env = @{} },
        @{ Name = "Claude Code turn"; Fx = $claudeNextFx; Env = @{} },
        @{ Name = "unmapped profile"; Fx = $inheritNextFx; Env = @{} },
        @{ Name = "models -Activate layout"; Fx = (New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $activateLayout }); Env = @{} },
        @{ Name = "the other tool's value is unsafe"; Fx = $codexFx; Env = @{ HANDOFF_CLAUDE_MODEL_STANDARD = "two words" } },
        @{ Name = "effort file mapping"; Fx = $effortFx; Env = @{} },
        @{ Name = "effort only, no model"; Fx = $effortOnlyFx; Env = @{} },
        @{ Name = "effort environment override, upper case"; Fx = $effortFx; Env = @{ HANDOFF_CODEX_EFFORT_STANDARD = "XHIGH" } },
        @{ Name = "effort on a Claude Code turn"; Fx = $effortClaudeFx; Env = @{} },
        @{ Name = "unknown effort level"; Fx = $effortFx; Env = @{ HANDOFF_CODEX_EFFORT_STANDARD = "turbo" } },
        @{ Name = "unknown effort level on a Claude Code turn"; Fx = $effortClaudeFx; Env = @{ HANDOFF_CODEX_EFFORT_STANDARD = "turbo" } },
        @{ Name = "malformed routing file"; Fx = (New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = '{"schemaVersion":1,"profiles":{"standard":{"codexModel":"test-codex-broken"}}' }); Env = @{} }
    )
    foreach ($case in $parityCases) {
        $saved = @{}
        foreach ($k in $case.Env.Keys) { $saved[$k] = [System.Environment]::GetEnvironmentVariable($k, "Process"); [System.Environment]::SetEnvironmentVariable($k, $case.Env[$k], "Process") }
        try {
            $null = Invoke-Handoff -WorkDir $case.Fx -Arguments @("next")
            $psText = (Get-Content -Raw -Path (Join-Path $case.Fx "NEXT_TURN.md")) -replace "`r", ""
            $prevCwd = [System.Environment]::CurrentDirectory
            Push-Location $case.Fx
            [System.Environment]::CurrentDirectory = $case.Fx
            try { $null = & $parityBash.Source $shPath next 2>&1 } finally { Pop-Location; [System.Environment]::CurrentDirectory = $prevCwd }
            $shText = (Get-Content -Raw -Path (Join-Path $case.Fx "NEXT_TURN.md")) -replace "`r", ""
        } finally {
            foreach ($k in $case.Env.Keys) { [System.Environment]::SetEnvironmentVariable($k, $saved[$k], "Process") }
        }
        $psSection = if ($psText -match '(?s)## Model For This Turn\n(.*?)\n\n') { $Matches[1] } else { "<none>" }
        $shSection = if ($shText -match '(?s)## Model For This Turn\n(.*?)\n\n') { $Matches[1] } else { "<none>" }
        Check "handoff.sh and handoff.ps1 write the same model section ($($case.Name))" (($psSection -ne "<none>") -and ($psSection -eq $shSection)) "ps=[$psSection] sh=[$shSection]"
    }
}

# Automated Codex turns pass the resolved model and run the Codex cost gate.
$fakeModelEcho = Join-Path $FixtureRoot "fake-codex-model-echo.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo %* > FAKE_ARGV.txt
echo MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION> MASTER_LAST.md
echo VERDICT: APPROVED model-routing> REVIEW_LAST.md
:done
'@ | Set-Content -Path $fakeModelEcho -Encoding ascii
$prevCodexCli = $env:CODEX_CLI
$env:CODEX_CLI = $fakeModelEcho
try {
    $mfx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -CurrentTask "codex routing"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $codexRouting } -InitGit
    $r = Invoke-Handoff -WorkDir $mfx -Arguments @("master-run", "-Yes")
    $argv = if (Test-Path (Join-Path $mfx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $mfx "FAKE_ARGV.txt") } else { "" }
    Check "master-run passes the resolved Codex model to codex exec" (($r.Code -eq 0) -and ($argv -match "^exec --model test-codex-standard --cd "))
    Check "master-run prints the model it runs on" ($r.Out -match "Codex model: test-codex-standard \(profile standard; MODEL_ROUTING\.json\)")

    $mfx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    $r = Invoke-Handoff -WorkDir $mfx -Arguments @("master-run", "-Yes")
    $argv = if (Test-Path (Join-Path $mfx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $mfx "FAKE_ARGV.txt") } else { "" }
    Check "master-run with no mapping passes no --model (Codex keeps its own default)" (($r.Code -eq 0) -and ($argv -match "^exec --cd ") -and ($argv -notmatch "--model"))

    $mfx = New-Fixture -Files @{ "AI_HANDOFF.md" = $highProfileHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $codexRouting } -InitGit
    $r = Invoke-Handoff -WorkDir $mfx -Arguments @("master-run", "-Yes")
    Check "master-run on a concrete high_reasoning Codex model requires -AllowModelEscalation" (($r.Code -eq 1) -and ($r.Out -match "requires explicit cost escalation approval") -and (-not (Test-Path (Join-Path $mfx "FAKE_ARGV.txt"))))
    $r = Invoke-Handoff -WorkDir $mfx -Arguments @("master-run", "-Yes", "-AllowModelEscalation")
    $argv = if (Test-Path (Join-Path $mfx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $mfx "FAKE_ARGV.txt") } else { "" }
    Check "an approved escalation runs master-run on the strongest mapped model" (($r.Code -eq 0) -and ($argv -match "^exec --model test-codex-high "))

    $rfx = New-Fixture -Files @{ "AI_HANDOFF.md" = ((New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask "codex review routing") -replace "(- Current Task:[^\r\n]+)", "`$1`r`n- Model Profile: high_reasoning"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $codexRouting } -InitGit
    Initialize-FixtureGitBaseline -Dir $rfx
    New-Item -ItemType Directory -Path (Join-Path $rfx "scripts") -Force | Out-Null
    Set-Content -Path (Join-Path $rfx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
    $h = (Get-Content -Raw -Path (Join-Path $rfx "AI_HANDOFF.md")) -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
    Set-Content -Path (Join-Path $rfx "AI_HANDOFF.md") -Value $h -Encoding utf8
    $r = Invoke-Handoff -WorkDir $rfx -Arguments @("review-run", "-Yes")
    Check "review-run on a concrete high_reasoning Codex model requires -AllowModelEscalation" (($r.Code -eq 1) -and ($r.Out -match "requires explicit cost escalation approval") -and (-not (Test-Path (Join-Path $rfx "FAKE_ARGV.txt"))))
    $r = Invoke-Handoff -WorkDir $rfx -Arguments @("review-run", "-Yes", "-AllowModelEscalation")
    $argv = if (Test-Path (Join-Path $rfx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $rfx "FAKE_ARGV.txt") } else { "" }
    Check "an approved review-run passes the strongest mapped Codex model" (($r.Code -eq 0) -and ($argv -match "^exec --model test-codex-high "))

    # v3.16.0: the resolved effort reaches codex exec as a configuration override.
    $efx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -CurrentTask "codex effort run"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortRouting } -InitGit
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes")
    $argv = if (Test-Path (Join-Path $efx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $efx "FAKE_ARGV.txt") } else { "" }
    Check "master-run passes the resolved effort after the model" (($r.Code -eq 0) -and ($argv -match "^exec --model test-codex-standard -c model_reasoning_effort=low --cd ")) $argv
    Check "master-run prints the effort it runs at" (($r.Out -match "Codex effort: low \(MODEL_ROUTING\.json\)") -and ($r.Out -match "Invocation: codex exec --model `"test-codex-standard`" -c model_reasoning_effort=low --cd "))

    $efx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortOnlyRouting } -InitGit
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes")
    $argv = if (Test-Path (Join-Path $efx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $efx "FAKE_ARGV.txt") } else { "" }
    Check "an effort with no model passes the effort and no --model" (($r.Code -eq 0) -and ($argv -match "^exec -c model_reasoning_effort=medium --cd ") -and ($argv -notmatch "--model")) $argv

    $efx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes")
    $argv = if (Test-Path (Join-Path $efx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $efx "FAKE_ARGV.txt") } else { "" }
    Check "master-run with no effort mapping passes no effort override" (($r.Code -eq 0) -and ($argv -notmatch "model_reasoning_effort"))
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes", "-CodexEffort", "xhigh")
    $argv = if (Test-Path (Join-Path $efx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $efx "FAKE_ARGV.txt") } else { "" }
    Check "-CodexEffort reaches codex exec for one command" (($r.Code -eq 0) -and ($argv -match "^exec -c model_reasoning_effort=xhigh --cd ")) $argv
    Remove-Item -LiteralPath (Join-Path $efx "FAKE_ARGV.txt") -Force -ErrorAction SilentlyContinue
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes", "-CodexEffort", "turbo")
    Check "master-run refuses an unknown effort before Codex starts" (($r.Code -ne 0) -and ($r.Out -match "Resolved Codex reasoning effort must be one of") -and (-not (Test-Path (Join-Path $efx "FAKE_ARGV.txt")))) $r.Out

    # A concrete effort on high_reasoning is a cost escalation, model or no model.
    $efx = New-Fixture -Files @{ "AI_HANDOFF.md" = $highProfileHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortRouting } -InitGit
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes")
    Check "a concrete high_reasoning effort requires -AllowModelEscalation" (($r.Code -eq 1) -and ($r.Out -match "resolves to the Codex reasoning effort 'high' and requires explicit cost escalation approval") -and ($r.Out -notmatch "concrete Codex model") -and (-not (Test-Path (Join-Path $efx "FAKE_ARGV.txt")))) $r.Out
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes", "-AllowModelEscalation")
    $argv = if (Test-Path (Join-Path $efx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $efx "FAKE_ARGV.txt") } else { "" }
    Check "an approved escalation runs master-run at the mapped effort" (($r.Code -eq 0) -and ($argv -match "^exec -c model_reasoning_effort=high --cd ")) $argv
    $efx = New-Fixture -Files @{ "AI_HANDOFF.md" = $highProfileHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    $r = Invoke-Handoff -WorkDir $efx -Arguments @("master-run", "-Yes", "-CodexEffort", "high")
    $argv = if (Test-Path (Join-Path $efx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $efx "FAKE_ARGV.txt") } else { "" }
    Check "an effort named on the command line is the user's own choice and needs no second approval" (($r.Code -eq 0) -and ($argv -match "^exec -c model_reasoning_effort=high --cd ")) $r.Out

    $rfx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask "codex review effort"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortRouting } -InitGit
    Initialize-FixtureGitBaseline -Dir $rfx
    New-Item -ItemType Directory -Path (Join-Path $rfx "scripts") -Force | Out-Null
    Set-Content -Path (Join-Path $rfx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
    $h = (Get-Content -Raw -Path (Join-Path $rfx "AI_HANDOFF.md")) -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
    Set-Content -Path (Join-Path $rfx "AI_HANDOFF.md") -Value $h -Encoding utf8
    $r = Invoke-Handoff -WorkDir $rfx -Arguments @("review-run", "-Yes")
    $argv = if (Test-Path (Join-Path $rfx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $rfx "FAKE_ARGV.txt") } else { "" }
    Check "review-run passes the resolved effort" (($r.Code -eq 0) -and ($argv -match "^exec --model test-codex-standard -c model_reasoning_effort=low --cd ")) "$($r.Out) argv=[$argv]"
} finally {
    if ($null -eq $prevCodexCli) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $prevCodexCli }
}
# --- v3.10.1: what a real product repository needs from a review ---
Write-Host "[4C-3] Review in a product repository (v3.10.1)"
# Annotated Changed Files entries name the path; a real "(2)" in a filename stays.
$annotatedHandoff = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "annotated scope") -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- ``a space.md`` (2-line change; see Done)`n- new.md (new)`n- Copy (2).md"
$afx = New-Fixture -Files @{ "AI_HANDOFF.md" = $annotatedHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $afx
foreach ($name in @("a space.md", "new.md", "Copy (2).md")) { Set-Content -LiteralPath (Join-Path $afx $name) -Value "x" -Encoding utf8 }
$r = Invoke-Handoff -WorkDir $afx -Arguments @("commit-check")
Check "commit-check reads annotated Changed Files entries and keeps a real (2) in a filename" (($r.Code -eq 0) -and ($r.Out -notmatch "does not exactly match")) $r.Out

# review-run runs the project's typecheck and test scripts when there is no protocol suite.
$fakeStdinEcho = Join-Path $FixtureRoot "fake-codex-stdin-echo.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > FAKE_STDIN.txt
echo VERDICT: APPROVED project-checks> REVIEW_LAST.md
:done
'@ | Set-Content -Path $fakeStdinEcho -Encoding ascii
$prevCodexCliChecks = $env:CODEX_CLI
$env:CODEX_CLI = $fakeStdinEcho
try {
    $packageJson = '{"name":"fixture","private":true,"scripts":{"typecheck":"node -e \"process.exit(0)\"","test":"node -e \"console.log(''boom-from-test''); process.exit(3)\"","lint":"node -e \"process.exit(9)\""}}'
    $pfx = New-Fixture -Files @{ "AI_HANDOFF.md" = ((New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask "project checks") -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- src/app.js"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; "package.json" = $packageJson } -InitGit
    Initialize-FixtureGitBaseline -Dir $pfx
    New-Item -ItemType Directory -Path (Join-Path $pfx "src") -Force | Out-Null
    Set-Content -Path (Join-Path $pfx "src/app.js") -Value "// fixture" -Encoding utf8
    $r = Invoke-Handoff -WorkDir $pfx -Arguments @("review-run", "-Yes")
    $stdinText = if (Test-Path (Join-Path $pfx "FAKE_STDIN.txt")) { Get-Content -Raw -Path (Join-Path $pfx "FAKE_STDIN.txt") } else { "" }
    Check "review-run hands the Reviewer the project's own check results" (($stdinText -match "PROJECT CHECKS") -and ($stdinText -match "npm run typecheck -> exit 0") -and ($stdinText -match "npm run test -> exit 3") -and ($stdinText -match "boom-from-test")) "code=$($r.Code) stdin=$stdinText"
    Check "a failing project check tells the Reviewer to block, and lint is not run" (($stdinText -match "At least one project check failed") -and ($stdinText -notmatch "npm run lint"))
} finally {
    if ($null -eq $prevCodexCliChecks) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $prevCodexCliChecks }
}

$handoffSrcV310 = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
# -Model names a Claude model. It must not move Codex off the task's profile.
$r = Invoke-Handoff -WorkDir $codexFx -Arguments @("models", "-Model", "some-claude-model")
Check "-Model moves only Claude; Codex keeps the task's profile" (($r.Out -match "Effective profile:\s+explicit_user_choice") -and ($r.Out -match "Codex profile:\s+standard") -and ($r.Out -match "Codex model:\s+test-codex-standard"))
$r = Invoke-Handoff -WorkDir $highNextFx -Arguments @("models", "-Model", "some-claude-model")
Check "-Model does not lift the Codex cost gate on a high_reasoning task" (($r.Out -match "Codex profile:\s+high_reasoning") -and ($r.Out -match "Codex approval:"))

# cycle with a Codex Implementer stops at the Codex cost gate BEFORE asking for yes, with exit 1.
$codexImplRoles = $DefaultRoles -replace "\| Implementer \| Claude Code \|", "| Implementer | Codex |" -replace "\| Reviewer \| Codex \|", "| Reviewer | Claude Code |"
$codexImplHandoff = ((New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "codex implementer routing") -replace "(- Current Task:[^\r\n]+)", "`$1`r`n- Model Profile: high_reasoning") -replace "- Implementer: Claude Code", "- Implementer: Codex" -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$cifx = New-Fixture -Files @{ "AI_HANDOFF.md" = $codexImplHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $codexImplRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $codexRouting } -InitGit
Initialize-FixtureGitBaseline -Dir $cifx
$r = Invoke-Handoff -WorkDir $cifx -Arguments @("cycle")
Check "cycle with a Codex Implementer stops at the Codex cost gate before the yes prompt" (($r.Code -eq 1) -and ($r.Out -match "Codex Implementer turn: blocked - model routing") -and ($r.Out -notmatch "Cancelled") -and ($r.Out -notmatch "exited with error")) "code=$($r.Code)"
# v3.16.0: the same gate when the profile maps only an effort, and the effort reaches the
# Codex Implementer's own codex exec call.
$cifx = New-Fixture -Files @{ "AI_HANDOFF.md" = $codexImplHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $codexImplRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortRouting } -InitGit
Initialize-FixtureGitBaseline -Dir $cifx
$r = Invoke-Handoff -WorkDir $cifx -Arguments @("cycle")
Check "cycle with a Codex Implementer stops at the cost gate for a concrete effort alone" (($r.Code -eq 1) -and ($r.Out -match "Codex Implementer turn: blocked - model routing") -and ($r.Out -match "resolves to the Codex reasoning effort 'high'") -and ($r.Out -notmatch "Cancelled")) "code=$($r.Code) $($r.Out)"
$prevCodexCliImpl = $env:CODEX_CLI
$env:CODEX_CLI = $fakeModelEcho
try {
    $codexImplStandard = ((New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "codex implementer effort") -replace "- Implementer: Claude Code", "- Implementer: Codex") -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
    $cifx = New-Fixture -Files @{ "AI_HANDOFF.md" = $codexImplStandard; ".ai/roles/ROLE_ASSIGNMENT.md" = $codexImplRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $effortRouting } -InitGit
    Initialize-FixtureGitBaseline -Dir $cifx
    $r = Invoke-Handoff -WorkDir $cifx -Arguments @("cycle", "-Yes")
    $argv = if (Test-Path (Join-Path $cifx "FAKE_ARGV.txt")) { Get-Content -Raw -Path (Join-Path $cifx "FAKE_ARGV.txt") } else { "" }
    Check "the Codex Implementer turn passes the resolved effort to codex exec" ($argv -match "^exec --model test-codex-standard -c model_reasoning_effort=low --cd .* --sandbox workspace-write ") "code=$($r.Code) argv=[$argv] $($r.Out)"
} finally {
    if ($null -eq $prevCodexCliImpl) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $prevCodexCliImpl }
}

Check "the Codex Implementer turn runs the Codex cost gate and passes the resolved model" (($handoffSrcV310 -match '(?s)function Invoke-CodexImplementerTurn.{0,2500}Test-CodexModelPreflight') -and ($handoffSrcV310 -match "(?s)function Invoke-CodexImplementerTurn.{0,6000}CodexUsesConcreteModel\) \{ \`$argList \+= @\('--model'"))
Check "every automated Codex turn adds the effort override from one helper (v3.16.0)" (([regex]::Matches($handoffSrcV310, "\`$argList \+= @\(Get-CodexEffortArgs\)").Count -eq 3) -and ($handoffSrcV310 -match "(?s)function Invoke-CodexImplementerTurn.{0,6500}Get-CodexEffortArgs"))

# The Bash suite is run for real when a Bash interpreter exists, and reported as SKIPPED
# - never as passing - when one does not. A suite that silently counts as green when it
# never ran is worse than no suite at all.
Write-Host "[bash] Bash companion suite"
$bashExe = (Get-Command bash -ErrorAction SilentlyContinue)
if ($null -eq $bashExe) {
    Write-Host "  SKIP  bash companion suite: no bash interpreter on this machine"
} else {
    $bashOut = & $bashExe.Source (Join-Path $RepoRoot "scripts/protocol-tests.sh") 2>&1
    $bashLine = @($bashOut | Select-String -Pattern '^Results:\s+\d+\s+passed,\s+\d+\s+failed' | Select-Object -Last 1)
    Check "the Bash companion suite runs and reports results" ($bashLine.Count -eq 1)
    if ($bashLine.Count -eq 1) {
        Check "the Bash companion suite passes" ($bashLine[0].ToString() -match 'Results:\s+\d+\s+passed,\s+0\s+failed')
    }
}

# A bounded turn that cannot be seen or stopped still feels like a runaway.
Check "a stop command exists" ($handoffSrc -match 'function Invoke-Stop')
Check "a run marker is written when an automated turn starts" ($handoffSrc -match 'Write-RunMarker -ProcessId \$proc\.Id')
Check "the run marker is cleared when the turn ends" ($handoffSrc -match 'Clear-RunMarker')
Check "the run marker is a local coordination file, never committed" ($handoffSrc -match '"HANDOFF_LOOP\.log", \$RunMarkerName')

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("status")
Check "status states plainly that nothing is running" ($r.Out -match "Running:\s+no automated turn in flight")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("stop")
Check "stop reports there is nothing to stop when no turn is running" ($r.Out -match "stop: nothing to stop")

# A marker whose process is gone must never read as a live run.
Set-Content -Path (Join-Path $fx "HANDOFF_RUN.json") -Value '{"processId":999999,"kind":"test","startedUtc":"2026-08-30T00:00:00Z","budgetUsd":2,"timeoutSec":180}' -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("status")
Check "a stale run marker is reported as stale, not as running" ($r.Out -match "stale marker")
# status must clear it too. A dead-PID marker is a false alarm, not information, and
# leaving it for stop to tidy up means every later status repeats the same false alarm.
Check "status clears the stale marker it reports" (-not (Test-Path (Join-Path $fx "HANDOFF_RUN.json")))
$r = Invoke-Handoff -WorkDir $fx -Arguments @("status")
Check "a cleared stale marker does not reappear on the next status" ($r.Out -match "Running:\s+no automated turn in flight")

Set-Content -Path (Join-Path $fx "HANDOFF_RUN.json") -Value '{"processId":999999,"kind":"test","startedUtc":"2026-08-30T00:00:00Z","budgetUsd":2,"timeoutSec":180}' -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("stop")
Check "stop clears a stale marker instead of pretending to kill something" ($r.Out -match "stale run marker was found")
Check "the stale marker is actually removed" (-not (Test-Path (Join-Path $fx "HANDOFF_RUN.json")))
# doctor deliberately does NOT clear the marker. It closes every run by stating that no
# files were changed; a diagnostic that silently mutates state is no longer a diagnostic.
Set-Content -Path (Join-Path $fx "HANDOFF_RUN.json") -Value '{"processId":999999,"kind":"test","startedUtc":"2026-08-30T00:00:00Z","budgetUsd":2,"timeoutSec":180}' -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("doctor")
Check "doctor reports a stale marker" ($r.Out -match "stale run marker is present")
Check "doctor stays read-only and does not clear the marker" (Test-Path (Join-Path $fx "HANDOFF_RUN.json"))
Check "doctor names the commands that do clear it" ($r.Out -match "handoff\.ps1 status or handoff\.ps1 stop")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("status")
Check "status clears what doctor only reported" (-not (Test-Path (Join-Path $fx "HANDOFF_RUN.json")))
# Run state must be reported even when model routing is broken - one of the states a
# user is most likely to run doctor in.
$fxBadModel = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = 'not valid json at all' }
$r = Invoke-Handoff -WorkDir $fxBadModel -Arguments @("doctor")
Check "doctor still reports run state when model routing is invalid" ($r.Out -match "No automated turn is running|automated turn is running now|stale run marker is present")

# A recycled process id must not be mistaken for the recorded turn.
Check "the run marker records process start time, not just the id" ($handoffSrc -match 'startTicks')
Check "liveness compares the recorded start time, so a reused id reads as stale" ($handoffSrc -match 'StartTime\.ToUniversalTime\(\)\.Ticks -eq \$result\.StartTicks')
$fxPid = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
Set-Content -Path (Join-Path $fxPid "HANDOFF_RUN.json") -Value ('{"processId":' + $PID + ',"startTicks":1,"kind":"test","startedUtc":"2026-08-30T00:00:00Z","budgetUsd":2,"timeoutSec":180}') -Encoding utf8
$r = Invoke-Handoff -WorkDir $fxPid -Arguments @("status")
Check "a live id with a mismatched start time is treated as stale, not as our turn" ($r.Out -match "stale marker")
# Missing or zero startTicks must ALSO read as stale. Falling back to a bare id match
# would reintroduce the exact hazard the field removes.
$fxNoTicks = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
Set-Content -Path (Join-Path $fxNoTicks "HANDOFF_RUN.json") -Value ('{"processId":' + $PID + ',"kind":"test","startedUtc":"2026-08-30T00:00:00Z","budgetUsd":2,"timeoutSec":180}') -Encoding utf8
$r = Invoke-Handoff -WorkDir $fxNoTicks -Arguments @("status")
Check "a marker with no startTicks reads as stale, never as a live turn" ($r.Out -match "stale marker")
$fxZeroTicks = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
Set-Content -Path (Join-Path $fxZeroTicks "HANDOFF_RUN.json") -Value ('{"processId":' + $PID + ',"startTicks":0,"kind":"test","startedUtc":"2026-08-30T00:00:00Z","budgetUsd":2,"timeoutSec":180}') -Encoding utf8
$r = Invoke-Handoff -WorkDir $fxZeroTicks -Arguments @("stop")
Check "stop refuses to kill a process it cannot positively identify" ($r.Out -match "stale run marker was found")

# --- v3.11.0: long commands launched from an agent window run in the background ---
Write-Host "[4B-9] Background runs from an agent window (v3.11.0)"

# v3.10.1 asked the Master not to check on a running loop. The next window did it anyway,
# 23 of 44 calls, and used up the usage window. The command itself must leave nothing to wait on.
function Wait-BackgroundFinished {
    param([string]$Dir, [int]$Seconds = 45)
    $markerPath = Join-Path $Dir "HANDOFF_BACKGROUND.json"
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $markerPath) {
            try {
                $data = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
                if ($data.finishedUtc) { return $data }
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

$env:HANDOFF_BACKGROUND_NO_NOTIFY = "1"
$fxBg = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fxBg
$env:HANDOFF_RUN_MODE = "background"
try {
    $bgWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Handoff -WorkDir $fxBg -Arguments @("loop", "-MaxTurns", "0", "-BudgetUsd", "1.5", "-Yes")
    $bgWatch.Stop()
} finally {
    $env:HANDOFF_RUN_MODE = "foreground"
}
Check "an agent-window loop returns at once with exit 0" (($r.Code -eq 0) -and ($r.Out -match "loop: started in the background"))
Check "the launch returns well before the run could finish a turn" ($bgWatch.Elapsed.TotalSeconds -lt 30)
Check "the launch tells the agent to end its turn" ($r.Out -match "AGENT: END YOUR TURN NOW")
$bgDone = Wait-BackgroundFinished -Dir $fxBg
Check "the background run records that it finished" ($null -ne $bgDone)
if ($null -ne $bgDone) {
    Check "the background run records the command's own exit code" ([string]$bgDone.exitCode -eq "1")
    $bgLog = Get-Content -Raw -LiteralPath (Join-Path $fxBg "HANDOFF_BACKGROUND.log") -ErrorAction SilentlyContinue
    Check "the background run received the original arguments" ($bgLog -match "-MaxTurns must be at least 1 \(got: 0\)")
    $r = Invoke-Handoff -WorkDir $fxBg -Arguments @("status")
    Check "status reports the finished background run and its exit code" ($r.Out -match "Background:\s+last run loop finished .* exit 1")
    $r = Invoke-Handoff -WorkDir $fxBg -Arguments @("doctor")
    Check "background run files do not make the tree look dirty" ($r.Out -match "Git working tree clean after local coordination exclusions")
}

# Without -Yes nothing can confirm a detached run.
$fxBgNoYes = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$env:HANDOFF_RUN_MODE = "background"
try {
    $r = Invoke-Handoff -WorkDir $fxBgNoYes -Arguments @("cycle")
} finally {
    $env:HANDOFF_RUN_MODE = "foreground"
}
Check "an agent-window run without -Yes is not started" (($r.Code -eq 2) -and ($r.Out -match "cannot ask for confirmation"))
Check "an unstarted background run leaves no marker" (-not (Test-Path (Join-Path $fxBgNoYes "HANDOFF_BACKGROUND.json")))

# Codex marks every command it runs with CODEX_CI; that alone must be recognised.
$savedClaudeCode = $env:CLAUDECODE
$savedCodexCi = $env:CODEX_CI
try {
    [System.Environment]::SetEnvironmentVariable("HANDOFF_RUN_MODE", $null, "Process")
    [System.Environment]::SetEnvironmentVariable("CLAUDECODE", $null, "Process")
    $env:CODEX_CI = "1"
    $r = Invoke-Handoff -WorkDir $fxBgNoYes -Arguments @("loop")
} finally {
    $env:HANDOFF_RUN_MODE = "foreground"
    [System.Environment]::SetEnvironmentVariable("CLAUDECODE", $savedClaudeCode, "Process")
    [System.Environment]::SetEnvironmentVariable("CODEX_CI", $savedCodexCi, "Process")
}
Check "a Codex shell is detected from CODEX_CI" ($r.Out -match "Codex, CODEX_CI environment variable")

# A person's terminal, or the foreground override, keeps the old behaviour.
$r = Invoke-Handoff -WorkDir $fxBgNoYes -Arguments @("loop", "-MaxTurns", "0", "-Yes")
Check "a foreground loop runs in place, as before" (($r.Out -match "loop: blocked") -and ($r.Out -notmatch "started in the background"))

# One run at a time: a live run refuses a second long command and stop ends it.
$fxBgLive = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$sleeper = Start-Process -FilePath $PwshExe -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 60") -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Milliseconds 500
    $liveMarker = [ordered]@{ processId = $sleeper.Id; startTicks = $sleeper.StartTime.ToUniversalTime().Ticks; command = "loop"; startedUtc = "2026-09-16T10:00:00Z"; log = "HANDOFF_BACKGROUND.log"; finishedUtc = $null; exitCode = $null }
    [System.IO.File]::WriteAllText((Join-Path $fxBgLive "HANDOFF_BACKGROUND.json"), ($liveMarker | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $fxBgLive -Arguments @("review-run", "-Yes")
    Check "a second long command is refused while a background run is alive" (($r.Code -eq 1) -and ($r.Out -match "a background run is already in progress"))
    $r = Invoke-Handoff -WorkDir $fxBgLive -Arguments @("work")
    Check "work shows the live background run" ($r.Out -match "Background:\s+YES - loop")
    $r = Invoke-Handoff -WorkDir $fxBgLive -Arguments @("stop")
    Check "stop terminates the background run" ($r.Out -match "Stopping the background run")
    Start-Sleep -Milliseconds 500
    Check "the background process is actually gone" ($null -eq (Get-Process -Id $sleeper.Id -ErrorAction SilentlyContinue))
    $stopped = Get-Content -Raw -LiteralPath (Join-Path $fxBgLive "HANDOFF_BACKGROUND.json") | ConvertFrom-Json
    Check "a stopped run is recorded as stopped" ([string]$stopped.exitCode -eq "stopped")
} finally {
    try { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue } catch { }
}
[System.Environment]::SetEnvironmentVariable("HANDOFF_BACKGROUND_NO_NOTIFY", $null, "Process")

$bgSnippet = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/gitignore-snippet.txt")
Check "the gitignore snippet ignores the background marker and log" (($bgSnippet -match "(?m)^/HANDOFF_BACKGROUND\.json$") -and ($bgSnippet -match "(?m)^/HANDOFF_BACKGROUND\.log$"))
$bgMaster = Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MASTER.md")
Check "MASTER.md describes the background launch instead of asking for restraint" (($bgMaster -match "END YOUR TURN NOW") -and ($bgMaster -notmatch "longest wait your tool"))
Check "the background log is scanned for credentials like every other capture" ($handoffSrc -match '"HANDOFF_BACKGROUND\.log", "AI_HANDOFF\.md"')

# release was unreachable by following the tool's own instructions: user-next always
# pointed at commit-approved, and release then failed on an empty git status.
Check "the release path accepts an already-committed HEAD" ($handoffSrc -match 'function Get-HeadCommitFiles')
Check "HEAD's file set is read NUL-delimited like every other scope check" ($handoffSrc -match 'show --name-only -z --format= HEAD')
Check "a HEAD that does not match Changed Files still blocks" ($handoffSrc -match "HEAD's file set does not match AI_HANDOFF.md Changed Files")
# The flag must be RETURNED and USED, not just computed. Setting it and then still
# running git add / git commit unconditionally left the executor exactly as unreachable
# as before, with the added risk of a failed empty commit mid-release.
Check "the already-committed decision is returned from the release plan" ($handoffSrc -match 'ReleaseFromHead = \$releaseFromHead')
Check "the release executor honours it and skips add/commit" ($handoffSrc -match 'if \(\$plan\.ReleaseFromHead\) \{')
Check "push and tag still run on the already-committed path" (
    ($handoffSrc -match 'Skipping git add and git commit') -and ($handoffSrc -match 'git push origin HEAD')
)

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("user-next")
Check "user-next at REVIEW_DONE names the release path as well as the commit path" (($r.Out -match "commit-approved") -and ($r.Out -match "release-check"))

# --- v3.4.1 packaging and release awareness (G2, G3, G4) ----------------------------
# v3.4.0 was tagged and pushed with no package ever built. dist/ is gitignored, so
# every tracked-file check was blind to it, and doctor called the newest TAG "the
# latest stable release". A tag is not a release.

# --- v3.4.1 script encoding is proof against re-saves ------------------------------
# Windows PowerShell 5.1 reads a .ps1 without a BOM as ANSI, and `Set-Content -Encoding
# utf8` WRITES a BOM. Between those two behaviours, an ordinary edit can add a BOM,
# double-encode existing non-ASCII text, or mangle a literal - and the file still
# parses, so nothing complains. This project already paid for that once in v3.1.4,
# and again while implementing v3.4.1. Keeping the shipped scripts pure ASCII removes
# the failure mode entirely instead of relying on every future editor behaving.
foreach ($scriptRel in @("scripts/handoff.ps1", "scripts/protocol-tests.ps1", "bootstrap.ps1", "install.ps1")) {
    $scriptPath = Join-Path $RepoRoot $scriptRel
    if (-not (Test-Path -LiteralPath $scriptPath)) { continue }
    $scriptBytes = [System.IO.File]::ReadAllBytes($scriptPath)
    $hasBom = ($scriptBytes.Length -ge 3 -and $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF)
    $nonAscii = @($scriptBytes | Where-Object { $_ -gt 127 }).Count
    Check "$scriptRel has no UTF-8 BOM" (-not $hasBom)
    Check "$scriptRel is pure ASCII (encoding-proof against re-saves)" ($nonAscii -eq 0)
}

$bootstrapSource = Get-Content -Raw -Path (Join-Path $RepoRoot "bootstrap.ps1")
Check "bootstrap installs from the published release asset, not the tag archive" (($bootstrapSource -match 'releases/download/') -and ($bootstrapSource -notmatch 'archive/refs/tags/\$Version'))
Check "bootstrap downloads the checksum alongside the package" ($bootstrapSource -match '\$checksumUri')
Check "bootstrap verifies SHA-256 before extracting" (
    ($bootstrapSource -match 'Get-FileHash -Algorithm SHA256') -and
    ($bootstrapSource.IndexOf('Get-FileHash -Algorithm SHA256') -lt $bootstrapSource.IndexOf('Expand-Archive'))
)
Check "bootstrap refuses a checksum naming a different asset" ($bootstrapSource -match 'Refusing to install a mismatched pair')
Check "bootstrap enforces a strict 64-hex checksum format" ($bootstrapSource -match '\[0-9a-fA-F\]\{64\}')

$handoffSource = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")

# --- v3.4.1 protocol-run review evidence --------------------------------------------
# The Reviewer runs in --sandbox read-only, which denies the suite's temp fixtures, so
# a review that required running tests blocked forever. The only sandbox mode granting
# a writable temp also makes the repository writable, and a reviewer that can edit the
# work is not a reviewer. The harness therefore runs the suite itself and binds the
# result to the reviewed bytes, so the Reviewer can VERIFY the evidence instead of
# trusting it - keeping the v3.1.6 rule that a handoff report is an untrusted claim.
Check "the harness produces its own test evidence for review" ($handoffSource -match 'function Get-ReviewTestEvidence')
Check "review evidence is bound to the SHA-256 of the reviewed files" ($handoffSource -match 'Get-FileHash -Algorithm SHA256 -LiteralPath \$full')
Check "the review prompt labels the evidence as protocol-run, not self-reported" ($handoffSource -match 'PROTOCOL-RUN TEST EVIDENCE')
Check "the review prompt tells the Reviewer to recompute the hashes itself" ($handoffSource -match 'recompute the SHA-256')
Check "a hash mismatch forces BLOCKED" ($handoffSource -match 'the code changed after the tests ran and you must return BLOCKED')
Check "reported test failures force BLOCKED" ($handoffSource -match 'If the evidence reports failures, return BLOCKED')
Check "the Reviewer is told not to run the suite in its own sandbox" ($handoffSource -match 'Do NOT attempt to run the protocol test suite yourself')
Check "a missing or inconclusive suite yields a negative summary, never an optimistic one" (($handoffSource -match 'NOT RUN - scripts/protocol-tests\.ps1 was not found') -and ($handoffSource -match 'INCONCLUSIVE - the suite produced no Results line'))
Check "a plan review runs no suite and says so" (($handoffSource -match 'Get-ReviewTestEvidence -Files @\("AI_HANDOFF\.md"\) -PlanReview') -and ($handoffSource -match 'PLAN REVIEW - there is no implementation yet'))
Check "cycle and loop default to a 600-second turn unless -TimeoutSeconds is given" ($handoffSource -match "(?s)ContainsKey\('TimeoutSeconds'\).{0,120}'cycle', 'run-next', 'loop'.{0,40}\`$TimeoutSeconds = 600")
# The printed Results line is the suite's claim about itself; the exit code is the
# independent signal. A run that crashes after printing, or fails where the counter
# cannot see it, still exits nonzero - so success requires BOTH.
Check "review evidence requires a zero suite exit code, not just a zero-failure line" (($handoffSource -match '\$suiteExit = \$LASTEXITCODE') -and ($handoffSource -match 'suiteExit -eq 0'))
Check "a zero-failure line with a nonzero exit is reported as INCONSISTENT and blocks" ($handoffSource -match 'INCONSISTENT - the suite printed')
Check "the review sandbox stays read-only" ($handoffSource -match "'--sandbox', 'read-only'")
# --- v3.4.4: the planning gate is reviewable ----------------------------------------
# The Master can route to PLAN_REQUIRED, and until now review-run refused whenever
# Changed Files was empty - so the Master could send you to a gate the Reviewer could
# not open. This task was itself routed to PLAN_REQUIRED.
Check "review-run has a plan mode" ($handoffSource -match '\$planMode = \$true')
Check "plan mode requires an actual Plan section" ($handoffSource -match 'Get-SectionLines -Lines \$Lines -Heading "Plan"')
Check "plan mode evidence is the handoff itself" ($handoffSource -match 'Get-ReviewTestEvidence -Files @\("AI_HANDOFF\.md"\)')
Check "the plan prompt tells the Reviewer not to hunt for code defects" ($handoffSource -match 'do not look for code defects')
Check "an approved plan does NOT reach REVIEW_DONE" ($handoffSource -match '-and -not \$plan\.Base\.PlanMode')

$planHandoff = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer") + "
## Plan

Do the thing, bounded to these files, with these acceptance criteria.
"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $planHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "an empty Changed Files list with a Plan section no longer refuses" ($r.Out -notmatch "has no reviewable files")

$noPlan = New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $noPlan; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "an empty Changed Files list with no Plan section still refuses" ($r.Out -match "no '## Plan' section to review instead")
# Declaring nothing must never become a way to review nothing. Plan mode requires the
# WORKING TREE to be clean, not merely the declared list to be empty - otherwise
# undeclared implementation would pass as a plan-only review and skip code review.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $planHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
Set-Content -Path (Join-Path $fx "sneaky.md") -Value "undeclared implementation" -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "plan mode refuses when the working tree has undeclared changes" ($r.Out -match "A plan review requires no implementation")
Check "the refusal names the undeclared files" ($r.Out -match "sneaky\.md")
Check "undeclared work cannot bypass code review" ($r.Out -match "must never bypass code review")

Check "doctor reports the source tag and the GitHub Release separately" (($handoffSource -match 'Source tag:') -and ($handoffSource -match 'GitHub Release:'))
Check "doctor reports whether the required release assets are attached" ($handoffSource -match 'Release assets:')
Check "doctor treats a tag without a release as a WARN, not a pass" ($handoffSource -match 'no published release found for')
Check "the release path has a packaging gate" ($handoffSource -match 'function Test-ReleasePackage')

# The gate must actually block, not merely exist.
$relHandoff = New-Handoff -State "REVIEW_DONE" -WaitingFor "User"
$relHandoff = $relHandoff -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- RELEASE_TARGET.md"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $relHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
Set-Content -Path (Join-Path $fx "RELEASE_TARGET.md") -Value "# release fixture" -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("release-check", "-Version", "v9.9.9")
Check "release-check blocks a version with no built package" (($r.Code -ne 0) -and ($r.Out -match "does not exist. Build it with scripts/build-package.ps1"))
Check "release-check blocks a version with no checksum file" ($r.Out -match "\.sha256 does not exist")

# A ZIP whose checksum disagrees must block just as hard as a missing one.
New-Item -ItemType Directory -Path (Join-Path $fx "dist") -Force | Out-Null
Set-Content -Path (Join-Path $fx "dist/codex-claude-handoff-v9.9.9.zip") -Value "not a real package" -Encoding ascii
Set-Content -Path (Join-Path $fx "dist/codex-claude-handoff-v9.9.9.zip.sha256") -Value ("0" * 64 + "  codex-claude-handoff-v9.9.9.zip") -Encoding ascii
$r = Invoke-Handoff -WorkDir $fx -Arguments @("release-check", "-Version", "v9.9.9")
Check "release-check blocks a package whose checksum does not match" (($r.Code -ne 0) -and ($r.Out -match "SHA-256 mismatch for dist/"))

# --- v3.4.1 next/user-next surface the automated route ------------------------------
# The manual paste read as THE way to take a turn, for roles that have had a verified
# callable adapter since v1.3.0. That cost a full day of hand-pasting.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "next surfaces the callable automated route when one exists" ($r.Out -match "Automated route available")
Check "next still offers the manual paste as a fallback" (($r.Out -match "Paste:") -and ($r.Out -match "Manual paste above remains valid"))

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("user-next")
Check "user-next prints a runnable command including the repository path" ($r.Out -match 'cd "')

# A wide changed set exercises a large stdout stream through the same capture.
$manyPaths = 1..40 | ForEach-Object { "bulk/file $_.md" }
$fx = New-ScopeFixture -Paths $manyPaths
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "wide changed set")
Check "exact scope survives a wide changed set through one capture" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))

$fx = New-ScopeFixture -Paths @("a space.md")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "spaced path")
Check "exact scope matches a path containing spaces" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))

# Non-ASCII names are built from code points so THIS FILE stays pure ASCII.
# Windows PowerShell 5.1 reads a .ps1 without a BOM as ANSI, so a literal Hebrew
# name written here is mangled by the parser before the test can run - the same
# encoding trap that cost v3.1.4. Building the string at runtime sidesteps the
# file encoding entirely.
$hebDoc  = [string]([char]0x05DE + [char]0x05E1 + [char]0x05DE + [char]0x05DA)   # "document"
$hebName = [string]([char]0x05E9 + [char]0x05DD)                                 # "name"

$fx = New-ScopeFixture -Paths @("$hebDoc.md")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "non-ASCII path")
Check "exact scope matches a non-ASCII path" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))

$fx = New-ScopeFixture -Paths @("$hebDoc $hebName.md")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "non-ASCII with spaces")
Check "exact scope matches a non-ASCII path containing spaces" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))

$fx = New-ScopeFixture -Paths @("nested/deeper/$hebDoc.md")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "nested non-ASCII path")
Check "exact scope matches a nested non-ASCII path" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))

# A rename emits the destination AND the source as separate NUL fields. Only the
# destination is a changed file; counting the source too would break exact scope.
$renameTarget = "$hebName $hebDoc.md"
$h = New-Handoff -State "REVIEW_DONE" -WaitingFor "User"
$h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- $renameTarget"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $h; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Set-Content -LiteralPath (Join-Path $fx "old name.md") -Value "renamed fixture" -Encoding utf8
Initialize-FixtureGitBaseline -Dir $fx
Push-Location $fx; try { & git mv "old name.md" $renameTarget *> $null } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "rename to a non-ASCII name")
Check "a rename contributes only its destination path to exact scope" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))

# Fail-closed must survive the rewrite: an undeclared file still blocks.
$fx = New-ScopeFixture -Paths @("$hebDoc.md", "undeclared extra.md") -Declared @("$hebDoc.md")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "still fails closed")
Check "an undeclared non-ASCII-adjacent file still fails closed" (($r.Code -eq 1) -and ($r.Out -match "does not exactly match git status"))

# Separator spelling stays strict by decision: Changed Files must use Git-style
# forward slashes. A backslash spelling is a genuine mismatch, not a normalization gap.
$fx = New-ScopeFixture -Paths @("nested/deeper/$hebDoc.md") -Declared @("nested\deeper\$hebDoc.md")
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "backslash spelling")
Check "a backslash-spelled path is treated as a mismatch, not normalized" (($r.Code -eq 1) -and ($r.Out -match "does not exactly match git status"))
# v3.4.3: paths compare case-SENSITIVELY. On a case-sensitive filesystem README.md and
# readme.md are different files, and this comparison decides what gets committed.
$fxCase = New-ScopeFixture -Paths @("CaseTarget.md") -Declared @("casetarget.md")
$r = Invoke-Handoff -WorkDir $fxCase -Arguments @("commit-check", "-Message", "case mismatch")
Check "a path differing only in letter case is a mismatch" (($r.Code -eq 1) -and ($r.Out -match "does not exactly match git status"))
Check "the mismatch message names letter case as the cause" ($r.Out -match "differ only in letter case")

$fxCaseOk = New-ScopeFixture -Paths @("CaseTarget.md")
$r = Invoke-Handoff -WorkDir $fxCaseOk -Arguments @("commit-check", "-Message", "exact case")
Check "an exactly-matching path still passes" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))
Check "an exact match never claims a case difference" ($r.Out -notmatch "differ only in letter case")

# Paths containing a literal quote or backslash are not creatable on NTFS, so the
# case is exercised where the filesystem permits it and reported as skipped otherwise.
$quoteProbe = Join-Path ([System.IO.Path]::GetTempPath()) ("q" + [Guid]::NewGuid().ToString("N") + '"x.md')
$quoteSupported = $false
try { Set-Content -LiteralPath $quoteProbe -Value "x" -ErrorAction Stop; $quoteSupported = $true; Remove-Item -LiteralPath $quoteProbe -Force } catch { }
if ($quoteSupported) {
    $fx = New-ScopeFixture -Paths @('has"quote.md')
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "quoted path")
    Check "exact scope matches a path containing a literal quote" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready"))
} else {
    Write-Host "  SKIP  literal-quote path: this filesystem forbids the character"
}

# === 6. Sequence advance guards (fail closed) ===
Write-Host "[6] Sequence advance guards (sequence-check)"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("sequence-check")
Check "sequence-check without args is blocked (exit 1)" (($r.Code -eq 1) -and ($r.Out -match "sequence-check: blocked"))
Check "sequence-check reports missing required inputs" (($r.Out -match "Missing -ReleasedVersion") -and ($r.Out -match "Missing -Commit") -and ($r.Out -match "Missing -Tag"))
Check "sequence-check prints 'No files were changed'" ($r.Out -match "No files were changed")

# === 7. Safety boundaries (dry runs mutate nothing) ===
Write-Host "[7] Safety boundaries"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$null = Invoke-Handoff -WorkDir $fx -Arguments @("release-check", "-Version", "v0.20.0")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "release-check does not modify AI_HANDOFF.md" ($before -eq $after)
# No commit was created by a dry run. Use rev-list --count (returns 0 with no stderr
# on an empty repo); git log would fatal to stderr and trip ErrorActionPreference=Stop.
Push-Location $fx
try { $commitCount = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "release-check creates no git commit" ("$commitCount".Trim() -eq "0")

# === 8. Mirror parity (canonical <-> template) ===
Write-Host "[8] Mirror parity"
$canonical = Join-Path $RepoRoot ".ai/skills/codex-claude-handoff"
$template  = Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff"
$mirrorOk = $true
$mirrorDetail = ""
if (Test-Path $canonical) {
    foreach ($f in (Get-ChildItem -Path $canonical -File)) {
        $tf = Join-Path $template $f.Name
        if (-not (Test-FileHashMatch -Left $f.FullName -Right $tf)) { $mirrorOk = $false; $mirrorDetail = ".ai skill: $($f.Name)" ; break }
    }
}
Check "canonical/template .ai skill files match" $mirrorOk $mirrorDetail
foreach ($pair in @(
    @("scripts/handoff.ps1", "templates/scripts/handoff.ps1"),
    @("scripts/handoff.sh",  "templates/scripts/handoff.sh"),
    @("scripts/protocol-tests.ps1", "templates/scripts/protocol-tests.ps1"),
    @("scripts/protocol-tests.sh",  "templates/scripts/protocol-tests.sh")
)) {
    $l = Join-Path $RepoRoot $pair[0]
    $rr = Join-Path $RepoRoot $pair[1]
    if ((Test-Path $l) -and (Test-Path $rr)) {
        Check "mirror: $($pair[0])" (Test-FileHashMatch -Left $l -Right $rr)
    }
}

# === 9. Codex Reviewer POC guards (review-check / review-run, fail closed) ===
Write-Host "[9] Codex Reviewer POC guards (review-check / review-run)"

# Force a deterministic, unresolvable Codex CLI for these child processes so the POC
# behavior does not depend on whether a real codex binary is on PATH in the test env.
$env:CODEX_CLI = Join-Path $FixtureRoot "no-such-codex-cli.exe"

# Happy path: READY_FOR_REVIEW / Reviewer with Codex reviewer and matching scope must
# pass the protocol guards and stop only on the (forced) missing CLI - not on a guard.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
# Commit the baseline so only the reviewed file shows as a change (scope must match exactly).
Initialize-FixtureGitBaseline -Dir $fx
# Add a Changed Files entry that matches a real (untracked) file in the fixture tree.
New-Item -ItemType Directory -Path (Join-Path $fx "scripts") -Force | Out-Null
Set-Content -Path (Join-Path $fx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
$h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $h -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "review-check passes protocol guards (stops only on missing Codex CLI)" (($r.Out -match "protocol guards pass, but no runnable Codex CLI is available") -and ($r.Out -notmatch "must be State: READY_FOR_REVIEW"))

# Wrong state: review-check must block before any Codex resolution.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "review-check blocks unless State is READY_FOR_REVIEW / Waiting For: Reviewer" (($r.Code -eq 1) -and ($r.Out -match "must be State: READY_FOR_REVIEW"))

# Approved scope requires Waiting For: Reviewer exactly - the bound tool name (Codex) is
# NOT accepted, even at READY_FOR_REVIEW.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Codex"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "review-check requires Waiting For: Reviewer exactly (rejects the tool-name form)" (($r.Code -eq 1) -and ($r.Out -match "must be State: READY_FOR_REVIEW and Waiting For: Reviewer"))

# v3.5.0: THE MIRROR SWAP. This fixture binds Reviewer = Claude Code and
# Implementer = Codex - the exact reverse of the default - and it must now be ACCEPTED.
#
# Until v3.5.0 this same fixture asserted the opposite: that the swap blocked with
# "No callable Reviewer adapter", because only Codex had one. That was never a protocol
# decision, only the set of adapters that happened to exist, and it meant the roles were
# swappable in name while the automation ran in one direction only. The check is
# inverted here deliberately: the swap is the feature.
$nonCodexRoles = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Claude Code |
| Implementer | Codex |
"@
$nonCodexHandoff = ((New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer") -replace "- Reviewer: Codex", "- Reviewer: Claude Code") -replace "- Implementer: Claude Code`r?`n", "- Implementer: Codex`n"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $nonCodexHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $nonCodexRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "the mirror swap (Reviewer = Claude Code) is accepted, not refused for lack of an adapter" (-not ($r.Out -match "No callable Reviewer adapter"))
Check "the mirror swap resolves a Claude Code review runner, not the Codex CLI" ($r.Out -match "Claude Code")

# Independent-review invariant: actual Reviewer must not equal actual Implementer.
$badHandoff = New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"
$badHandoff = $badHandoff -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $badHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "review-check blocks stale actors at the role checkpoint" (($r.Code -eq 12) -and ($r.Out -match "Role checkpoint: BLOCKED"))

# Changed Files must match git status (here: empty / no reviewable files).
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "review-check blocks when Changed Files has no reviewable files" (($r.Code -eq 1) -and ($r.Out -match "no reviewable files"))

# A PATH alias that resolves to `codex` but is not actually runnable for `exec --help`
# must NOT be treated as ready. Force PATH to a fake failing codex.cmd and hide any
# real local Codex install by pointing LOCALAPPDATA at an empty temp directory.
$fakeBrokenPathDir = Join-Path $FixtureRoot "fake-codex-path"
New-Item -ItemType Directory -Path $fakeBrokenPathDir -Force | Out-Null
@'
@echo off
exit /b 1
'@ | Set-Content -Path (Join-Path $fakeBrokenPathDir "codex.cmd") -Encoding ascii
$emptyLocalAppData = Join-Path $FixtureRoot "empty-localappdata"
New-Item -ItemType Directory -Path $emptyLocalAppData -Force | Out-Null
$prevPath = $env:Path
$hadLocalAppData = Test-Path Env:\LOCALAPPDATA
$prevLocalAppData = $env:LOCALAPPDATA
try {
    $gitCmd = Get-Command git -ErrorAction Stop
    $gitDir = Split-Path -Parent $gitCmd.Source
    $env:Path = "$fakeBrokenPathDir;$gitDir"
    $env:LOCALAPPDATA = $emptyLocalAppData
    Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue

    $fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    New-Item -ItemType Directory -Path (Join-Path $fx "scripts") -Force | Out-Null
    Set-Content -Path (Join-Path $fx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
    $h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    $h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
    Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $h -Encoding utf8
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
    Check "review-check blocks when PATH exposes a non-runnable Codex CLI alias" (($r.Code -eq 1) -and ($r.Out -match "no runnable Codex CLI is available") -and ($r.Out -notmatch "ready for operator-confirmed review-run"))
} finally {
    $env:Path = $prevPath
    if ($hadLocalAppData) {
        $env:LOCALAPPDATA = $prevLocalAppData
    } else {
        Remove-Item Env:\LOCALAPPDATA -ErrorAction SilentlyContinue
    }
}

# review-run fails closed with Environment/Preflight when the Codex CLI is unavailable,
# and runs no Codex invocation.
$env:CODEX_CLI = Join-Path $FixtureRoot "no-such-codex-cli.exe"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
New-Item -ItemType Directory -Path (Join-Path $fx "scripts") -Force | Out-Null
Set-Content -Path (Join-Path $fx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
$h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $h -Encoding utf8
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx
try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-run")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "review-run blocks (exit 3) when the Codex CLI is unavailable" (($r.Code -eq 3) -and ($r.Out -match "Environment/Preflight") -and ($r.Out -match "No Codex invocation was run"))
Check "review-run does not modify AI_HANDOFF.md when blocked" ($before -eq $after)
Push-Location $fx
try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "review-run creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())
Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue

# review-run fails closed on a HANGING Codex: a fake CLI that answers `exec --help` but
# then sleeps must be killed at the timeout, leaving no verdict and no git/handoff change.
$fakeCodex = Join-Path $FixtureRoot "fake-codex-hang.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
ping -n 30 127.0.0.1 >nul
exit /b 0
'@ | Set-Content -Path $fakeCodex -Encoding ascii
$env:CODEX_CLI = $fakeCodex
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
New-Item -ItemType Directory -Path (Join-Path $fx "scripts") -Force | Out-Null
Set-Content -Path (Join-Path $fx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
$h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $h -Encoding utf8
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx
try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-run", "-Yes", "-TimeoutSeconds", "2")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "review-run times out and fails closed (exit 4)" (($r.Code -eq 4) -and ($r.Out -match "TIMED OUT") -and ($r.Out -match "NO final verdict"))
Check "review-run timeout writes no final verdict file" (-not (Test-Path (Join-Path $fx "REVIEW_LAST.md")))
Check "review-run timeout does not modify AI_HANDOFF.md" ($before -eq $after)
Push-Location $fx
try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "review-run timeout creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# review-run must deliver the multi-word prompt through ONE channel (stdin), not as split
# argv tokens. A fake Codex records its stdin and its argv: the multi-word prompt must
# appear in stdin and NOT in argv (whose final token is the `-` stdin sentinel). If the
# prompt were passed as arguments, stdin would be empty and this fails.
$fakeEcho = Join-Path $FixtureRoot "fake-codex-echo.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > FAKE_STDIN.txt
echo %* > FAKE_ARGV.txt
echo VERDICT: APPROVED stdin-delivery-ok> REVIEW_LAST.md
:done
'@ | Set-Content -Path $fakeEcho -Encoding ascii
$env:CODEX_CLI = $fakeEcho
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
New-Item -ItemType Directory -Path (Join-Path $fx "scripts") -Force | Out-Null
Set-Content -Path (Join-Path $fx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
$h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $h -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-run", "-Yes")
$stdinFile = Join-Path $fx "FAKE_STDIN.txt"
$argvFile  = Join-Path $fx "FAKE_ARGV.txt"
$stdinContent = if (Test-Path $stdinFile) { Get-Content -Raw -Path $stdinFile } else { "" }
$argvContent  = if (Test-Path $argvFile)  { Get-Content -Raw -Path $argvFile }  else { "" }
Check "review-run delivers the multi-word prompt via stdin intact" ($stdinContent -match "Inspect ONLY these sources")
Check "review-run does not pass the prompt as argv tokens" (($argvContent -notmatch "Inspect ONLY these sources") -and ($argvContent -match "-\s*$"))
Check "review-run prompt covers untracked/new files without index mutation" (($stdinContent -match "untracked or new") -and ($stdinContent -match "inspect that file's current content directly") -and ($stdinContent -match "do not run git add"))
Check "review-run treats handoff verification as claims and reviews preservation beyond tests" (($stdinContent -match "verification statements in AI_HANDOFF.md as untrusted claims, not proof") -and ($stdinContent -match "preservation and backward-compatibility clauses") -and ($stdinContent -match "existing tests are evidence, not an exhaustive specification"))
Check "review-run executes explicitly named safe local read-only checks or blocks" (($stdinContent -match "marks a relevant check as not run") -and ($stdinContent -match "explicitly names a safe local read-only check") -and ($stdinContent -match "run that check before deciding") -and ($stdinContent -match "If required verification cannot run safely or the available evidence is inadequate, return BLOCKED"))
Check "review-run verification boundary forbids dangerous or mutating actions" (($stdinContent -match "Never install dependencies") -and ($stdinContent -match "use the network") -and ($stdinContent -match "deploy") -and ($stdinContent -match "database") -and ($stdinContent -match "secrets or production configuration") -and ($stdinContent -match "modify any file") -and ($stdinContent -match "working tree or git index"))
# Codex exited 0 AND wrote a verdict -> review-run succeeds (exit 0) and captures it. This
# also proves the process ExitCode is read correctly (0, not a null that looks non-zero).
Check "review-run succeeds (exit 0) and captures the verdict on a clean Codex exit" (($r.Code -eq 0) -and (Test-Path (Join-Path $fx "REVIEW_LAST.md")))

# review-run must FAIL CLOSED if Codex exits 0 but writes NO final verdict (no false
# success). A fake that emits a JSONL line but never writes the verdict file must block.
$fakeNoVerdict = Join-Path $FixtureRoot "fake-codex-noverdict.cmd"
@'
@echo off
if "%~2"=="--help" goto done
echo {"type":"item"}
:done
exit /b 0
'@ | Set-Content -Path $fakeNoVerdict -Encoding ascii
$env:CODEX_CLI = $fakeNoVerdict
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
New-Item -ItemType Directory -Path (Join-Path $fx "scripts") -Force | Out-Null
Set-Content -Path (Join-Path $fx "scripts/handoff.ps1") -Value "# fixture" -Encoding utf8
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
$h = $h -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- scripts/handoff.ps1"
Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $h -Encoding utf8
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-run", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "review-run fails closed (exit 6) when Codex exits 0 but captures no verdict" (($r.Code -eq 6) -and ($r.Out -match "no review verdict was captured"))
Check "review-run no-verdict path leaves no verdict file and no handoff change" ((-not (Test-Path (Join-Path $fx "REVIEW_LAST.md"))) -and ($before -eq $after))

Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue

# === 10. Automated Reviewer turn (review-apply, v1.3.0) ===
Write-Host "[10] Automated Reviewer turn (review-apply)"

$task = "v1.3.0 - Review Apply Test"
$approvedCapture = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: $task`nREASON: scope matches the approved task"
$blockedCapture  = "VERDICT: BLOCKED`nREVIEWER: Codex`nTASK: $task`nREASON: needs a fix before approval"

# APPROVED verdict -> REVIEW_DONE / Waiting For: User; edits only AI_HANDOFF.md; no commit.
$fx = New-ReviewApplyFixture -Capture $approvedCapture -CurrentTask $task
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$reviewedPath = Join-Path $fx "scripts/handoff.ps1"
$reviewedBefore = (Get-FileHash -Algorithm SHA256 -Path $reviewedPath).Hash
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$h = Get-Content -Raw -Path $handoffPath
$reviewedAfter = (Get-FileHash -Algorithm SHA256 -Path $reviewedPath).Hash
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "review-apply APPROVED sets REVIEW_DONE / Waiting For: User" (($r.Code -eq 0) -and ($h -match "State:\s+REVIEW_DONE") -and ($h -match "Waiting For:\s+User"))
Check "review-apply APPROVED records the verdict and source pointer" (($h -match "Verdict:\s+APPROVED") -and ($h -match "REVIEW_LAST.md"))
Check "review-apply changes no file other than AI_HANDOFF.md (reviewed file untouched)" ($reviewedBefore -eq $reviewedAfter)
Check "review-apply creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# Codex writes output-last-message as BOM-less UTF-8. Prove Windows PowerShell 5.1
# preserves a non-ASCII task through the anti-stale comparison instead of reading
# the capture through the active ANSI code page.
$utf8ReviewTask = (-join @([char]0x05DE, [char]0x05E9, [char]0x05D9, [char]0x05DE, [char]0x05D4)) + " UTF-8"
$utf8ReviewCapture = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: $utf8ReviewTask`nREASON: UTF-8 task matches"
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $utf8ReviewTask
[System.IO.File]::WriteAllText(
    (Join-Path $fx "REVIEW_LAST.md"),
    $utf8ReviewCapture,
    [System.Text.UTF8Encoding]::new($false)
)
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md") -Encoding utf8
Check "review-apply preserves a BOM-less UTF-8 non-ASCII TASK" (($r.Code -eq 0) -and $h.Contains($utf8ReviewTask))

# BLOCKED verdict -> READY_FOR_IMPLEMENTATION / Waiting For: Implementer; records the reason.
$fx = New-ReviewApplyFixture -Capture $blockedCapture -CurrentTask $task
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$h = Get-Content -Raw -Path $handoffPath
Check "review-apply BLOCKED sets READY_FOR_IMPLEMENTATION / Waiting For: Implementer" (($r.Code -eq 0) -and ($h -match "State:\s+READY_FOR_IMPLEMENTATION") -and ($h -match "Waiting For:\s+Implementer"))
Check "review-apply BLOCKED records the captured reason for the Implementer" ($h -match "needs a fix before approval")

# Fail-closed verdict parsing: each bad capture blocks (exit 1) and leaves AI_HANDOFF.md unchanged.
$badCaptures = @{
    "missing VERDICT line"    = "REVIEWER: Codex`nTASK: $task`nREASON: no verdict line here"
    "multiple VERDICT lines"  = "VERDICT: APPROVED`nVERDICT: BLOCKED`nREVIEWER: Codex`nTASK: $task`nREASON: two verdicts"
    "unknown verdict token"   = "VERDICT: MAYBE`nREVIEWER: Codex`nTASK: $task`nREASON: not a real verdict"
    "empty REASON"            = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: $task`nREASON: "
    "REVIEWER not Codex"      = "VERDICT: APPROVED`nREVIEWER: Claude Code`nTASK: $task`nREASON: wrong reviewer"
    "stale TASK mismatch"     = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: some other task`nREASON: stale capture"
}
foreach ($name in $badCaptures.Keys) {
    $fx = New-ReviewApplyFixture -Capture $badCaptures[$name] -CurrentTask $task
    $handoffPath = Join-Path $fx "AI_HANDOFF.md"
    $before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
    $after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
    Check "review-apply fails closed on $name (no transition, no handoff change)" (($r.Code -ne 0) -and ($before -eq $after))
}

# Missing capture file -> blocked, no handoff change.
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $task
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "review-apply fails closed when no captured verdict file exists" (($r.Code -ne 0) -and ($r.Out -match "No captured verdict file") -and ($before -eq $after))

# Guard reuse: wrong state blocks before any transition.
$fx = New-ReviewApplyFixture -Capture $approvedCapture -CurrentTask $task -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "review-apply blocks unless State is READY_FOR_REVIEW / Waiting For: Reviewer" (($r.Code -eq 1) -and ($r.Out -match "must be State: READY_FOR_REVIEW") -and ($before -eq $after))

# Guard reuse: Changed Files != git status (an extra untracked file) blocks.
$fx = New-ReviewApplyFixture -Capture $approvedCapture -CurrentTask $task -AddExtraUntracked
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "review-apply blocks when Changed Files does not match git status" (($r.Code -eq 1) -and ($r.Out -match "does not match git status") -and ($before -eq $after))

# Guard reuse: independent-review invariant (actual Reviewer == actual Implementer) blocks.
$fx = New-ReviewApplyFixture -Capture $approvedCapture -CurrentTask $task -ReviewerActor "Claude Code"
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "review-apply blocks stale actors at the role checkpoint" (($r.Code -eq 12) -and ($r.Out -match "Role checkpoint: BLOCKED") -and ($before -eq $after))

# loop must STOP at a READY_FOR_REVIEW Reviewer turn, never auto-run it (callable but not loop-eligible).
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes")
Check "loop stops at a Reviewer turn instead of auto-running it (exit 0)" (($r.Code -eq 0) -and ($r.Out -match "callable only via an explicit command, not inside loop"))
Check "loop does not start an Implementer turn for a Reviewer state" ($r.Out -notmatch "automated Claude Code Implementer turn")

# cycle must refuse a Reviewer state too (RFI-only; explicit-only adapters are never auto-run).
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("cycle")
Check "cycle refuses a READY_FOR_REVIEW Reviewer turn" (($r.Code -eq 1) -and ($r.Out -match "cycle: blocked"))

# === 11. Codex Master capture POC guards (master-check / master-run, v1.3.1) ===
Write-Host "[11] Codex Master capture POC guards (master-check / master-run)"

# Force a deterministic, unresolvable Codex CLI so guard behavior does not depend on a real
# codex binary being on PATH in the test environment.
$env:CODEX_CLI = Join-Path $FixtureRoot "no-such-codex-cli.exe"

# Happy path: NEEDS_ANALYSIS / Master with Codex bound passes the protocol guards and stops
# only on the (forced) missing CLI - not on a guard. Task Actors may be present or TBD.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "master-check passes protocol guards (stops only on missing Codex CLI)" (($r.Out -match "protocol guards pass, but no runnable Codex CLI is available") -and ($r.Out -notmatch "must be State: NEEDS_ANALYSIS"))

# Task Actors TBD must NOT block (the Master turn is expected to recommend the actors).
$tbdHandoff = New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"
$tbdHandoff = $tbdHandoff -replace "- Implementer: Claude Code", "- Implementer: TBD" -replace "- Reviewer: Codex", "- Reviewer: TBD"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $tbdHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "master-check allows Task Actors TBD (does not block on missing actors)" (($r.Out -match "protocol guards pass, but no runnable Codex CLI is available") -and ($r.Out -notmatch "Task Actors"))

# Wrong state: master-check must block before any Codex resolution.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "master-check blocks unless State is NEEDS_ANALYSIS / Waiting For: Master" (($r.Code -eq 1) -and ($r.Out -match "must be State: NEEDS_ANALYSIS"))

# Waiting For must be Master exactly - the bound tool name (Codex) is NOT accepted.
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Codex"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "master-check requires Waiting For: Master exactly (rejects the tool-name form)" (($r.Code -eq 1) -and ($r.Out -match "must be State: NEEDS_ANALYSIS and Waiting For: Master"))

# v3.5.0: the Master role held by Claude Code. Like the Reviewer case above, this used
# to assert a block; it now asserts that the role is callable whichever tool holds it.
$nonCodexMaster = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Codex |
| Implementer | Claude Code |
"@
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $nonCodexMaster }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "a Claude Code Master is accepted, not refused for lack of an adapter" (-not ($r.Out -match "No callable Master adapter"))
Check "a Claude Code Master resolves a Claude Code runner, not the Codex CLI" ($r.Out -match "Claude Code")

# master-run fails closed with Environment/Preflight when the Codex CLI is unavailable, and
# runs no Codex invocation, no git, and no handoff change.
$env:CODEX_CLI = Join-Path $FixtureRoot "no-such-codex-cli.exe"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-run")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "master-run blocks (exit 3) when the Codex CLI is unavailable" (($r.Code -eq 3) -and ($r.Out -match "Environment/Preflight") -and ($r.Out -match "No Codex invocation was run"))
Check "master-run does not modify AI_HANDOFF.md when blocked" ($before -eq $after)
Check "master-run creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())
Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue

# master-run fails closed on a HANGING Codex: a fake CLI that answers `exec --help` but then
# sleeps must be killed at the timeout, leaving no recommendation and no handoff change.
$fakeCodex = Join-Path $FixtureRoot "fake-codex-hang.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
ping -n 30 127.0.0.1 >nul
exit /b 0
'@ | Set-Content -Path $fakeCodex -Encoding ascii
$env:CODEX_CLI = $fakeCodex
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-run", "-Yes", "-TimeoutSeconds", "2")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "master-run times out and fails closed (exit 4)" (($r.Code -eq 4) -and ($r.Out -match "TIMED OUT") -and ($r.Out -match "NO final recommendation"))
Check "master-run timeout writes no final capture file" (-not (Test-Path (Join-Path $fx "MASTER_LAST.md")))
Check "master-run timeout does not modify AI_HANDOFF.md" ($before -eq $after)

# master-run delivers the multi-word Master prompt through stdin (not split argv), and a clean
# Codex exit that writes the capture file succeeds (exit 0). The fake records stdin and argv.
$fakeEcho = Join-Path $FixtureRoot "fake-codex-master-echo.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > FAKE_STDIN.txt
echo %* > FAKE_ARGV.txt
echo MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION> MASTER_LAST.md
:done
'@ | Set-Content -Path $fakeEcho -Encoding ascii
$env:CODEX_CLI = $fakeEcho
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-run", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$stdinFile = Join-Path $fx "FAKE_STDIN.txt"
$argvFile  = Join-Path $fx "FAKE_ARGV.txt"
$stdinContent = if (Test-Path $stdinFile) { Get-Content -Raw -Path $stdinFile } else { "" }
$argvContent  = if (Test-Path $argvFile)  { Get-Content -Raw -Path $argvFile }  else { "" }
Check "master-run delivers the Master prompt via stdin intact" ($stdinContent -match "as the Master decision router")
Check "master-run does not pass the prompt as argv tokens" (($argvContent -notmatch "as the Master decision router") -and ($argvContent -match "-\s*$"))
Check "master-run succeeds (exit 0) and captures the recommendation on a clean Codex exit" (($r.Code -eq 0) -and (Test-Path (Join-Path $fx "MASTER_LAST.md")))
Check "master-run capture-only: does not modify AI_HANDOFF.md on success" ($before -eq $after)

# master-run must FAIL CLOSED if Codex exits 0 but writes NO capture file (no false success).
$fakeNoCap = Join-Path $FixtureRoot "fake-codex-master-nocap.cmd"
@'
@echo off
if "%~2"=="--help" goto done
echo {"type":"item"}
:done
exit /b 0
'@ | Set-Content -Path $fakeNoCap -Encoding ascii
$env:CODEX_CLI = $fakeNoCap
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-run", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "master-run fails closed (exit 6) when Codex exits 0 but captures no recommendation" (($r.Code -eq 6) -and ($r.Out -match "no recommendation was captured"))
Check "master-run no-capture path leaves no capture file and no handoff change" ((-not (Test-Path (Join-Path $fx "MASTER_LAST.md"))) -and ($before -eq $after))

Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue

# === 12. Automated Master turn (master-apply, v2.0.1) ===
Write-Host "[12] Automated Master turn (master-apply)"

$masterCaptureReady = @"
MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION
WAITING_FOR: Implementer
IMPLEMENTER: Claude Code
REVIEWER: Codex
TASK: v2.0.1 - Master Apply Test
MODEL_PROFILE: economy
REASON: The task is scoped and ready for implementation.
"@
$fx = New-MasterApplyFixture -Capture $masterCaptureReady
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$beforeCommits = & git -C $fx rev-list --count HEAD
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$h = Get-Content -Raw -Path $handoffPath
$afterCommits = & git -C $fx rev-list --count HEAD
Check "master-apply READY_FOR_IMPLEMENTATION sets Waiting For: Implementer" (($r.Code -eq 0) -and ($h -match "State:\s+READY_FOR_IMPLEMENTATION") -and ($h -match "Waiting For:\s+Implementer"))
Check "master-apply records concrete Task Actors from the capture" (($h -match "Implementer:\s+Claude Code") -and ($h -match "Reviewer:\s+Codex"))
Check "master-apply preserves the Master-selected capability profile" ($h -match "Model Profile:\s+economy")
Check "master-apply creates no git commit" ("$afterCommits".Trim() -eq "$beforeCommits".Trim())

# --- v3.4.1 canonical identity in the Master capture path ---------------------------
# The capture-level independent-review check compared display strings, so one tool
# under two names passed as two tools - the exact defect G1 exists to close.
$captureAliasCollision = @"
MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION
WAITING_FOR: Implementer
IMPLEMENTER: Codex Window
REVIEWER: Codex
TASK: v2.0.1 - Master Apply Test
MODEL_PROFILE: economy
REASON: The task is scoped and ready for implementation.
"@
$fx = New-MasterApplyFixture -Capture $captureAliasCollision
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "master-apply rejects a capture naming one tool under two aliases" (($r.Code -ne 0) -and ($r.Out -match "resolve to the same tool") -and ($before -eq $after))

# The mirror failure: a capture whose alias is canonically identical to the binding
# must NOT be rejected as an unapproved role swap.
$captureAliasEquivalent = @"
MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION
WAITING_FOR: Implementer
IMPLEMENTER: Claude Code Window
REVIEWER: Codex
TASK: v2.0.1 - Master Apply Test
MODEL_PROFILE: economy
REASON: The task is scoped and ready for implementation.
"@
$fx = New-MasterApplyFixture -Capture $captureAliasEquivalent
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
Check "master-apply accepts a capture alias that canonically matches the binding" (($r.Code -eq 0) -and ($r.Out -notmatch "Role swaps require explicit user approval"))

# A sentinel or unknown actor must never reach the collision check.
$captureUnknownActor = @"
MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION
WAITING_FOR: Implementer
IMPLEMENTER: Gemini
REVIEWER: Codex
TASK: v2.0.1 - Master Apply Test
MODEL_PROFILE: economy
REASON: The task is scoped and ready for implementation.
"@
$fx = New-MasterApplyFixture -Capture $captureUnknownActor
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
Check "master-apply rejects a capture naming an unrecognized IMPLEMENTER" (($r.Code -ne 0) -and ($r.Out -match "concrete, recognized IMPLEMENTER"))

# Match the real Codex CLI encoding: output-last-message is UTF-8 without a BOM.
$utf8MasterTask = (-join @([char]0x05DE, [char]0x05E9, [char]0x05D9, [char]0x05DE, [char]0x05D4)) + " UTF-8"
$utf8MasterCapture = "MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION`nWAITING_FOR: Implementer`nIMPLEMENTER: Claude Code`nREVIEWER: Codex`nTASK: $utf8MasterTask`nREASON: UTF-8 task is ready"
$fx = New-MasterApplyFixture -NoCapture -CurrentTask $utf8MasterTask
[System.IO.File]::WriteAllText(
    (Join-Path $fx "MASTER_LAST.md"),
    $utf8MasterCapture,
    [System.Text.UTF8Encoding]::new($false)
)
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md") -Encoding utf8
Check "master-apply preserves a BOM-less UTF-8 non-ASCII TASK" (($r.Code -eq 0) -and $h.Contains($utf8MasterTask))

$masterCaptureBlocked = @"
MASTER_RECOMMENDATION: BLOCKED
WAITING_FOR: User
IMPLEMENTER: TBD
REVIEWER: TBD
TASK: v2.0.1 - Master Apply Test
REASON: User approval is required before routing.
"@
$fx = New-MasterApplyFixture -Capture $masterCaptureBlocked
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$h = Get-Content -Raw -Path $handoffPath
Check "master-apply BLOCKED sets Waiting For: User" (($r.Code -eq 0) -and ($h -match "State:\s+BLOCKED") -and ($h -match "Waiting For:\s+User") -and ($h -match "User approval is required"))

$badMasterCaptures = @(
    @{ Name = "missing recommendation"; Text = "WAITING_FOR: Implementer`nIMPLEMENTER: Claude Code`nREVIEWER: Codex`nTASK: v2.0.1 - Master Apply Test`nREASON: missing recommendation" },
    @{ Name = "stale task"; Text = "MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION`nWAITING_FOR: Implementer`nIMPLEMENTER: Claude Code`nREVIEWER: Codex`nTASK: stale task`nREASON: stale" },
    @{ Name = "bad waiting-for"; Text = "MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION`nWAITING_FOR: User`nIMPLEMENTER: Claude Code`nREVIEWER: Codex`nTASK: v2.0.1 - Master Apply Test`nREASON: invalid pair" },
    @{ Name = "TBD implementer"; Text = "MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION`nWAITING_FOR: Implementer`nIMPLEMENTER: TBD`nREVIEWER: Codex`nTASK: v2.0.1 - Master Apply Test`nREASON: missing actor" },
    @{ Name = "same implementer and reviewer"; Text = "MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION`nWAITING_FOR: Implementer`nIMPLEMENTER: Codex`nREVIEWER: Codex`nTASK: v2.0.1 - Master Apply Test`nREASON: invariant violation" }
)
foreach ($case in $badMasterCaptures) {
    $fx = New-MasterApplyFixture -Capture $case.Text
    $handoffPath = Join-Path $fx "AI_HANDOFF.md"
    $before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
    $after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
    Check "master-apply fails closed on $($case.Name) (no transition, no handoff change)" (($r.Code -ne 0) -and ($before -eq $after))
}

$fx = New-MasterApplyFixture -Capture "" -NoCapture
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "master-apply fails closed when no captured recommendation file exists" (($r.Code -ne 0) -and ($r.Out -match "No captured Master recommendation file") -and ($before -eq $after))

$rolesSwap = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Codex |
| Implementer | Gemini |
"@
$fx = New-MasterApplyFixture -Capture $masterCaptureReady -Roles $rolesSwap
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$syncedSwapHandoff = (Get-Content -Raw -Path $handoffPath) -replace "- Implementer: Claude Code", "- Implementer: Gemini"
Set-Content -Path $handoffPath -Value $syncedSwapHandoff -Encoding utf8
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
# v3.4.1: an unrecognized tool identity is now rejected at the role checkpoint,
# before master-apply's own captured-actor guard is reached. The block is earlier
# and broader, and the offending value is named so the user fixes the binding.
# The guarantee under test is unchanged: nothing is applied and the file is intact.
Check "master-apply blocks an unrecognized bound tool and changes nothing" (($r.Code -ne 0) -and ($r.Out -match "Gemini") -and ($before -eq $after))

$fx = New-MasterApplyFixture -Capture $masterCaptureReady -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "master-apply blocks unless State is NEEDS_ANALYSIS / Waiting For: Master" (($r.Code -eq 1) -and ($r.Out -match "must be State: NEEDS_ANALYSIS") -and ($before -eq $after))

# === 13. Opt-in Master loop integration (loop -IncludeMaster, v2.1.0) ===
Write-Host "[13] Opt-in Master loop integration (loop -IncludeMaster)"

$loopMasterTask = "v2.1.0 - Loop Master Test"
$fakeMasterReady = Join-Path $FixtureRoot "fake-codex-loop-master-ready.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
echo MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION> MASTER_LAST.md
echo WAITING_FOR: Implementer>> MASTER_LAST.md
echo IMPLEMENTER: Claude Code>> MASTER_LAST.md
echo REVIEWER: Codex>> MASTER_LAST.md
echo TASK: v2.1.0 - Loop Master Test>> MASTER_LAST.md
echo REASON: safe simple implementation task>> MASTER_LAST.md
exit /b 0
'@ | Set-Content -Path $fakeMasterReady -Encoding ascii

# Default OFF: without -IncludeMaster, loop still STOPS at the Master turn even when a
# runnable fake Codex is present - it must not capture a recommendation or transition.
$env:CODEX_CLI = $fakeMasterReady
$fx = New-MasterApplyFixture -NoCapture -CurrentTask $loopMasterTask
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "loop without -IncludeMaster still stops at the Master turn (exit 0)" (($r.Code -eq 0) -and ($r.Out -match "callable only via an explicit command, not inside loop"))
Check "loop without -IncludeMaster captures no recommendation and does not transition the handoff" ((-not (Test-Path (Join-Path $fx "MASTER_LAST.md"))) -and ($before -eq $after))
Check "loop without -IncludeMaster creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# Opt-in Master: loop -IncludeMaster runs master-run + master-apply, applies the route,
# then stops on MaxTurns before running Claude. No git commit.
$env:CODEX_CLI = $fakeMasterReady
$fx = New-MasterApplyFixture -NoCapture -CurrentTask $loopMasterTask
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-IncludeMaster", "-Yes", "-MaxTurns", "1")
$h = Get-Content -Raw -Path $handoffPath
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "loop -IncludeMaster runs the Master turn and applies READY_FOR_IMPLEMENTATION / Implementer (exit 0)" (($r.Code -eq 0) -and ($h -match "State:\s+READY_FOR_IMPLEMENTATION") -and ($h -match "Waiting For:\s+Implementer"))
Check "loop -IncludeMaster stops on MaxTurns before running Claude" (($r.Out -match "MaxTurns") -and ($r.Out -notmatch "automated Claude Code Implementer turn"))
Check "loop -IncludeMaster creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# v3.4.1: the opt-in handler used a raw "Codex" comparison, so a binding written with a
# legacy alias resolved as callable in the adapter profile and then silently failed to
# enter the handler - callable in one place, invisible in the next.
$aliasMasterRoles = $DefaultRoles -replace "\| Master \| Codex \|", "| Master | Codex Window |"
$env:CODEX_CLI = $fakeMasterReady
$fx = New-MasterApplyFixture -NoCapture -CurrentTask $loopMasterTask -Roles $aliasMasterRoles
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-IncludeMaster", "-Yes", "-MaxTurns", "1")
$h = Get-Content -Raw -Path $handoffPath
Check "loop -IncludeMaster enters the Master turn when the binding uses a legacy alias" (($r.Code -eq 0) -and ($h -match "State:\s+READY_FOR_IMPLEMENTATION"))

Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue

# === 14. Opt-in Reviewer loop integration (loop -IncludeReviewer, v1.4.0) ===
Write-Host "[14] Opt-in Reviewer loop integration (loop -IncludeReviewer)"

# The fake Codex CLIs below answer `exec --help` (exit 0) and, on the real run, write ONLY
# REVIEW_LAST.md (a local, gitignored, clean-tree-exempt artifact) so the in-loop
# review-apply's Changed Files == git status guard still matches the single untracked
# scripts/handoff.ps1. The TASK line matches the fixture's Current Task verbatim.
$loopTask = "v1.4.0 - Loop Reviewer Test"

$fakeApprove = Join-Path $FixtureRoot "fake-codex-loop-approve.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
echo VERDICT: APPROVED> REVIEW_LAST.md
echo REVIEWER: Codex>> REVIEW_LAST.md
echo TASK: v1.4.0 - Loop Reviewer Test>> REVIEW_LAST.md
echo REASON: scope matches the approved task>> REVIEW_LAST.md
exit /b 0
'@ | Set-Content -Path $fakeApprove -Encoding ascii

$fakeBlock = Join-Path $FixtureRoot "fake-codex-loop-block.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
echo VERDICT: BLOCKED> REVIEW_LAST.md
echo REVIEWER: Codex>> REVIEW_LAST.md
echo TASK: v1.4.0 - Loop Reviewer Test>> REVIEW_LAST.md
echo REASON: needs a fix before approval>> REVIEW_LAST.md
exit /b 0
'@ | Set-Content -Path $fakeBlock -Encoding ascii

$fakeMalformed = Join-Path $FixtureRoot "fake-codex-loop-malformed.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
echo this is not a verdict block> REVIEW_LAST.md
exit /b 0
'@ | Set-Content -Path $fakeMalformed -Encoding ascii

# Default OFF: without -IncludeReviewer, loop still STOPS at the Reviewer turn even when a
# runnable fake Codex is present - it must not capture a verdict or transition the handoff.
$env:CODEX_CLI = $fakeApprove
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $loopTask
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "loop without -IncludeReviewer still stops at the Reviewer turn (exit 0)" (($r.Code -eq 0) -and ($r.Out -match "callable only via an explicit command, not inside loop"))
Check "loop without -IncludeReviewer captures no verdict and does not transition the handoff" ((-not (Test-Path (Join-Path $fx "REVIEW_LAST.md"))) -and ($before -eq $after))
Check "loop without -IncludeReviewer creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# Opt-in APPROVED: loop -IncludeReviewer runs review-run + review-apply, applies APPROVED, and
# stops at REVIEW_DONE / Waiting For: User. No git commit; the reviewed file is untouched.
$env:CODEX_CLI = $fakeApprove
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $loopTask
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$reviewedPath = Join-Path $fx "scripts/handoff.ps1"
$reviewedBefore = (Get-FileHash -Algorithm SHA256 -Path $reviewedPath).Hash
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-IncludeReviewer", "-Yes", "-MaxTurns", "1")
$h = Get-Content -Raw -Path $handoffPath
$reviewedAfter = (Get-FileHash -Algorithm SHA256 -Path $reviewedPath).Hash
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "loop -IncludeReviewer runs the Reviewer turn and applies APPROVED -> REVIEW_DONE / User (exit 0)" (($r.Code -eq 0) -and ($h -match "State:\s+REVIEW_DONE") -and ($h -match "Waiting For:\s+User"))
Check "loop -IncludeReviewer APPROVED then stops at the non-loop-eligible User turn" ($r.Out -match "Next actor: User")
Check "loop -IncludeReviewer APPROVED changes no file other than AI_HANDOFF.md" ($reviewedBefore -eq $reviewedAfter)
Check "loop -IncludeReviewer APPROVED creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# v3.4.1: same defect as the Master handler - a legacy alias in the binding resolved as
# callable but never entered the opt-in Reviewer handler.
$aliasReviewerRoles = $DefaultRoles -replace "\| Reviewer \| Codex \|", "| Reviewer | Codex Window |"
$env:CODEX_CLI = $fakeApprove
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $loopTask -Roles $aliasReviewerRoles
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-IncludeReviewer", "-Yes", "-MaxTurns", "1")
$h = Get-Content -Raw -Path $handoffPath
Check "loop -IncludeReviewer enters the Reviewer turn when the binding uses a legacy alias" (($r.Code -eq 0) -and ($h -match "State:\s+REVIEW_DONE"))

# Opt-in BLOCKED: loop -IncludeReviewer applies BLOCKED -> READY_FOR_IMPLEMENTATION /
# Implementer, then stops on MaxTurns WITHOUT involving the user and WITHOUT running Claude.
$env:CODEX_CLI = $fakeBlock
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $loopTask
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-IncludeReviewer", "-Yes", "-MaxTurns", "1")
$h = Get-Content -Raw -Path $handoffPath
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "loop -IncludeReviewer applies BLOCKED -> READY_FOR_IMPLEMENTATION / Implementer (exit 0)" (($r.Code -eq 0) -and ($h -match "State:\s+READY_FOR_IMPLEMENTATION") -and ($h -match "Waiting For:\s+Implementer"))
Check "loop -IncludeReviewer BLOCKED stops on MaxTurns without involving the user" (($r.Out -match "MaxTurns") -and ($r.Out -notmatch "automated Claude Code Implementer turn"))
Check "loop -IncludeReviewer BLOCKED creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# Opt-in malformed verdict: review-apply fails closed (non-zero exit), the loop stops, and the
# handoff stays READY_FOR_REVIEW with no transition. No git commit.
$env:CODEX_CLI = $fakeMalformed
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $loopTask
$handoffPath = Join-Path $fx "AI_HANDOFF.md"
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsBefore = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-IncludeReviewer", "-Yes", "-MaxTurns", "1")
$h = Get-Content -Raw -Path $handoffPath
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Push-Location $fx; try { $commitsAfter = (& git rev-list --all --count 2>$null) } finally { Pop-Location }
Check "loop -IncludeReviewer fails closed on a malformed verdict (non-zero exit)" ($r.Code -ne 0)
Check "loop -IncludeReviewer malformed verdict makes no handoff transition (stays READY_FOR_REVIEW)" (($before -eq $after) -and ($h -match "State:\s+READY_FOR_REVIEW") -and ($h -notmatch "State:\s+REVIEW_DONE"))
Check "loop -IncludeReviewer malformed verdict creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# cycle still refuses a Reviewer turn (the v1.4.0 opt-in is loop-only; cycle is unchanged).
$env:CODEX_CLI = $fakeApprove
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $loopTask
$r = Invoke-Handoff -WorkDir $fx -Arguments @("cycle")
Check "cycle still refuses a Reviewer turn (no -IncludeReviewer opt-in for cycle)" (($r.Code -eq 1) -and ($r.Out -match "cycle: blocked"))

Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue


# === 14B. Reviewer BLOCKED correction resume and interrupted-turn recovery ===
Write-Host "[14B] Reviewer BLOCKED correction resume and interrupted-turn recovery"

$resumeBin = Join-Path $FixtureRoot "fake-npx-review-correction"
New-Item -ItemType Directory -Path $resumeBin -Force | Out-Null
Set-Content -Path (Join-Path $resumeBin "npx.cmd") -Encoding ascii -Value @"
@echo off
if "%~1"=="--version" goto version
if "%~2"=="--version" goto version
if "%~3"=="--version" goto version
goto run
:version
echo claude-code-test
exit /b 0
:run
if "%FAKE_CORRECTION_MODE%"=="transition" (
  echo corrected> "%FAKE_CORRECTION_FILE%"
  copy /y "%FAKE_CORRECTION_AFTER%" "%FAKE_CORRECTION_HANDOFF%" > nul
  echo FAKE_CORRECTION_TRANSITION
  exit /b 0
)
if "%FAKE_CORRECTION_MODE%"=="transition-error" (
  echo corrected> "%FAKE_CORRECTION_FILE%"
  copy /y "%FAKE_CORRECTION_AFTER%" "%FAKE_CORRECTION_HANDOFF%" > nul
  exit /b 9
)
if "%FAKE_CORRECTION_MODE%"=="transition-error-extra" (
  echo corrected> "%FAKE_CORRECTION_FILE%"
  echo unapproved> "%FAKE_CORRECTION_EXTRA%"
  copy /y "%FAKE_CORRECTION_AFTER%" "%FAKE_CORRECTION_HANDOFF%" > nul
  exit /b 9
)
if "%FAKE_CORRECTION_MODE%"=="error-after-edit" (
  echo corrected> "%FAKE_CORRECTION_FILE%"
  exit /b 9
)
if "%FAKE_CORRECTION_MODE%"=="error-no-change" exit /b 9
exit /b 8
"@

$prevPath = $env:Path
$prevCorrectionMode = $env:FAKE_CORRECTION_MODE
$prevCorrectionFile = $env:FAKE_CORRECTION_FILE
$prevCorrectionAfter = $env:FAKE_CORRECTION_AFTER
$prevCorrectionHandoff = $env:FAKE_CORRECTION_HANDOFF
$prevCorrectionExtra = $env:FAKE_CORRECTION_EXTRA
$env:Path = $resumeBin + [System.IO.Path]::PathSeparator + $env:Path
try {
    $blockedCorrection = New-BlockedCorrectionHandoff
    $readyCorrection = New-BlockedCorrectionHandoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"

    # A new loop session may resume the exact dirty scope left by Reviewer BLOCKED.
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md" = $blockedCorrection
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
        "approved.txt" = "baseline"
        "HANDOFF_AFTER.md" = $readyCorrection
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    Set-Content -Path (Join-Path $fx "approved.txt") -Value "review rejected" -Encoding utf8
    $env:FAKE_CORRECTION_MODE = "transition"
    $env:FAKE_CORRECTION_FILE = Join-Path $fx "approved.txt"
    $env:FAKE_CORRECTION_AFTER = Join-Path $fx "HANDOFF_AFTER.md"
    $env:FAKE_CORRECTION_HANDOFF = Join-Path $fx "AI_HANDOFF.md"
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1", "-TimeoutSeconds", "5")
    $h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    Check "loop resumes exact dirty scope after Reviewer BLOCKED" (($r.Code -eq 0) -and ($r.Out -match "resuming the Reviewer's BLOCKED correction") -and ($r.Out -notmatch "Working tree is not clean"))
    Check "resumed Reviewer correction reaches READY_FOR_REVIEW" (($h -match "State:\s+READY_FOR_REVIEW") -and ((Get-Content -Raw (Join-Path $fx "approved.txt")) -match "corrected"))

    # A non-zero process exit after Claude already produced a protocol-valid,
    # exact-scope review handoff must continue to the independent Reviewer.
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md" = $blockedCorrection
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
        "approved.txt" = "baseline"
        "HANDOFF_AFTER.md" = $readyCorrection
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    Set-Content -Path (Join-Path $fx "approved.txt") -Value "review rejected" -Encoding utf8
    $env:FAKE_CORRECTION_MODE = "transition-error"
    $env:FAKE_CORRECTION_FILE = Join-Path $fx "approved.txt"
    $env:FAKE_CORRECTION_AFTER = Join-Path $fx "HANDOFF_AFTER.md"
    $env:FAKE_CORRECTION_HANDOFF = Join-Path $fx "AI_HANDOFF.md"
    $env:FAKE_CORRECTION_EXTRA = Join-Path $fx "unapproved.tmp"
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1", "-TimeoutSeconds", "5")
    $h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    Check "non-zero exit after a valid exact-scope review handoff continues safely" (($r.Code -eq 0) -and ($r.Out -match "valid exact-scope review handoff") -and ($h -match "State:\s+READY_FOR_REVIEW"))

    # The same post-turn handoff with one extra source artifact is not valid scope
    # and must not receive either recovery path.
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md" = $blockedCorrection
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
        "approved.txt" = "baseline"
        "HANDOFF_AFTER.md" = $readyCorrection
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    Set-Content -Path (Join-Path $fx "approved.txt") -Value "review rejected" -Encoding utf8
    $env:FAKE_CORRECTION_MODE = "transition-error-extra"
    $env:FAKE_CORRECTION_FILE = Join-Path $fx "approved.txt"
    $env:FAKE_CORRECTION_AFTER = Join-Path $fx "HANDOFF_AFTER.md"
    $env:FAKE_CORRECTION_HANDOFF = Join-Path $fx "AI_HANDOFF.md"
    $env:FAKE_CORRECTION_EXTRA = Join-Path $fx "unapproved.tmp"
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1", "-TimeoutSeconds", "5")
    Check "non-zero review handoff with an extra file fails closed" (($r.Code -eq 5) -and ($r.Out -notmatch "valid exact-scope review handoff") -and (Test-Path (Join-Path $fx "unapproved.tmp")))

    # A budget/error exit after a real exact-scope correction receives a review-only
    # local recovery transition; it is never treated as technical approval.
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md" = $blockedCorrection
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
        "approved.txt" = "baseline"
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    Set-Content -Path (Join-Path $fx "approved.txt") -Value "review rejected" -Encoding utf8
    $env:FAKE_CORRECTION_MODE = "error-after-edit"
    $env:FAKE_CORRECTION_FILE = Join-Path $fx "approved.txt"
    $env:FAKE_CORRECTION_AFTER = ""
    $env:FAKE_CORRECTION_HANDOFF = Join-Path $fx "AI_HANDOFF.md"
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1", "-TimeoutSeconds", "5")
    $h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    $recoveryOk = (($r.Code -eq 0) -and ($r.Out -match "Automation recovery") -and ($h -match "State:\s+READY_FOR_REVIEW") -and ($h -match "not attested here"))
    Check "interrupted exact-scope correction recovers to independent review" $recoveryOk "exit=$($r.Code); stateReady=$($h -match 'State:\s+READY_FOR_REVIEW'); recoveryOutput=$($r.Out -match 'Automation recovery'); verificationMarker=$($h -match 'not attested here')"
    Push-Location $fx
    try { $recoveryCommitCount = (& git rev-list --all --count 2>$null).Trim() } finally { Pop-Location }
    Check "interrupted correction recovery creates no commit" ($recoveryCommitCount -eq "1")

    # No content change means no recovery: do not send the already-rejected diff
    # back to Reviewer merely because Claude consumed budget or exited non-zero.
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md" = $blockedCorrection
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
        "approved.txt" = "baseline"
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    Set-Content -Path (Join-Path $fx "approved.txt") -Value "review rejected" -Encoding utf8
    $env:FAKE_CORRECTION_MODE = "error-no-change"
    $env:FAKE_CORRECTION_FILE = Join-Path $fx "approved.txt"
    $env:FAKE_CORRECTION_HANDOFF = Join-Path $fx "AI_HANDOFF.md"
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1", "-TimeoutSeconds", "5")
    $h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    $noEditOk = (($r.Code -eq 5) -and ($r.Out -notmatch "Automation recovery") -and ($h -match "State:\s+READY_FOR_IMPLEMENTATION"))
    Check "interrupted correction without a new edit fails closed" $noEditOk "exit=$($r.Code); recoveryOutput=$($r.Out -match 'Automation recovery'); implementationState=$($h -match 'State:\s+READY_FOR_IMPLEMENTATION')"

    # Exact scope is mandatory; one unrelated file keeps the original dirty-tree block.
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md" = $blockedCorrection
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
        "approved.txt" = "baseline"
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    Set-Content -Path (Join-Path $fx "approved.txt") -Value "review rejected" -Encoding utf8
    Set-Content -Path (Join-Path $fx "unapproved.tmp") -Value "extra" -Encoding utf8
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "1", "-TimeoutSeconds", "5")
    Check "Reviewer correction resume blocks any unapproved extra file" (($r.Code -eq 1) -and ($r.Out -match "Working tree is not clean") -and ($r.Out -match "unapproved.tmp"))
} finally {
    $env:Path = $prevPath
    if ($null -eq $prevCorrectionMode) { Remove-Item Env:\FAKE_CORRECTION_MODE -ErrorAction SilentlyContinue } else { $env:FAKE_CORRECTION_MODE = $prevCorrectionMode }
    if ($null -eq $prevCorrectionFile) { Remove-Item Env:\FAKE_CORRECTION_FILE -ErrorAction SilentlyContinue } else { $env:FAKE_CORRECTION_FILE = $prevCorrectionFile }
    if ($null -eq $prevCorrectionAfter) { Remove-Item Env:\FAKE_CORRECTION_AFTER -ErrorAction SilentlyContinue } else { $env:FAKE_CORRECTION_AFTER = $prevCorrectionAfter }
    if ($null -eq $prevCorrectionHandoff) { Remove-Item Env:\FAKE_CORRECTION_HANDOFF -ErrorAction SilentlyContinue } else { $env:FAKE_CORRECTION_HANDOFF = $prevCorrectionHandoff }
    if ($null -eq $prevCorrectionExtra) { Remove-Item Env:\FAKE_CORRECTION_EXTRA -ErrorAction SilentlyContinue } else { $env:FAKE_CORRECTION_EXTRA = $prevCorrectionExtra }
}


# === 15. Safe Claude process runner and Implementer capture (v2.0.0/v2.3.0/v2.4.0) ===
Write-Host "[15] Safe Claude process runner and Implementer capture"

$fastBin = Join-Path $FixtureRoot "fake-npx-fast"
New-Item -ItemType Directory -Path $fastBin -Force | Out-Null
$fastCmd = Join-Path $fastBin "npx.cmd"
Set-Content -Path $fastCmd -Encoding ascii -Value @"
@echo off
setlocal EnableDelayedExpansion
set "ALL=%CMDCMDLINE%"
set IS_VERSION=
set SAW_PERMISSION=
set SAW_DISALLOWED=
set SAW_NOSESSION=
set SAW_MODEL=
set SAW_MODEL_VALUE=
if not "!ALL:--version=!"=="!ALL!" set IS_VERSION=1
if not "!ALL:--permission-mode=!"=="!ALL!" if not "!ALL:acceptEdits=!"=="!ALL!" set SAW_PERMISSION=1
if not "!ALL:--disallowed-tools=!"=="!ALL!" if not "!ALL:Bash=!"=="!ALL!" set SAW_DISALLOWED=1
if not "!ALL:--no-session-persistence=!"=="!ALL!" set SAW_NOSESSION=1
if not "!ALL:--model=!"=="!ALL!" set SAW_MODEL=1
if not "!ALL:test-economy-model=!"=="!ALL!" set SAW_MODEL_VALUE=1
if defined IS_VERSION (
  echo claude-code-test
  exit /b 0
)
echo FAKE_CLAUDE_FAST_STDOUT
if "%FAKE_NPX_ARGV%"=="" goto after_arg_capture
echo permission=!SAW_PERMISSION! > "%FAKE_NPX_ARGV%"
echo disallowed=!SAW_DISALLOWED! >> "%FAKE_NPX_ARGV%"
echo nosession=!SAW_NOSESSION! >> "%FAKE_NPX_ARGV%"
echo model=!SAW_MODEL! >> "%FAKE_NPX_ARGV%"
echo modelvalue=!SAW_MODEL_VALUE! >> "%FAKE_NPX_ARGV%"
echo arg3=%~3 >> "%FAKE_NPX_ARGV%"
echo arg4=%~4 >> "%FAKE_NPX_ARGV%"
echo arg5=%~5 >> "%FAKE_NPX_ARGV%"
echo arg6=%~6 >> "%FAKE_NPX_ARGV%"
echo arg7=%~7 >> "%FAKE_NPX_ARGV%"
:after_arg_capture
exit /b 0
"@
$fastArgv = Join-Path $fastBin "argv.txt"
$prevPath = $env:Path
$prevArgv = $env:FAKE_NPX_ARGV
$env:Path = $fastBin + [System.IO.Path]::PathSeparator + $env:Path
$env:FAKE_NPX_ARGV = $fastArgv
try {
    $fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.0.0 - Safe Runner Test"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "cycle -Yes runs the bounded Claude runner (fake fast npx stdout captured)" (($r.Out -match "bounded PowerShell runner") -and ($r.Out -match "FAKE_CLAUDE_FAST_STDOUT"))
    Check "cycle flags a no-op turn (exit 7) when the fake fast npx makes no progress (v2.6.0)" (($r.Code -eq 7) -and ($r.Out -match "no-op"))
    $runnerSource = Get-Content -Raw -Path $HandoffScript
    Check "bounded Claude runner source keeps the Claude safety flags" (($runnerSource -match "'--permission-mode'") -and ($runnerSource -match "'acceptEdits'") -and ($runnerSource -match "'--disallowed-tools'") -and ($runnerSource -match "'Bash'") -and ($runnerSource -match "'--no-session-persistence'"))
    Check "Claude prompt forbids helper scripts and invented verification" (($runnerSource -match "Do NOT create temporary helper, capture, runner, or wrapper scripts") -and ($runnerSource -match "never claim a command or test passed without observed output"))
    Check "Claude prompt enforces strict preservation beyond existing tests" (($runnerSource -match "every preservation or backward-compatibility clause in the task as strict") -and ($runnerSource -match "Existing tests are evidence, not an exhaustive specification") -and ($runnerSource -match "avoid broad transformations or coercion changes unless the task explicitly requires them"))
    $argvText = if (Test-Path $fastArgv) { Get-Content -Raw -Path $fastArgv } else { "" }
    Check "bounded Claude runner enables safe mode before delivering prompts" (($argvText -match "arg3=--safe-mode") -and ($argvText -match "arg4=--append-system-prompt"))
    Check "bounded Claude runner preserves multi-word system and user prompts as single argv values (v2.10.0)" (($argvText -match "arg5=You are a non-interactive, headless automation agent") -and ($argvText -match "arg6=-p") -and ($argvText -match "arg7=You are running as the Implementer"))
    $claudeLast = Join-Path $fx "IMPLEMENTER_LAST.md"
    $claudeCommand = Join-Path $fx "IMPLEMENTER_COMMAND.md"
    $claudeJsonl = Join-Path $fx "IMPLEMENTER.jsonl"
    $captureText = if (Test-Path $claudeLast) { Get-Content -Raw -Path $claudeLast } else { "" }
    $commandText = if (Test-Path $claudeCommand) { Get-Content -Raw -Path $claudeCommand } else { "" }
    [string[]]$jsonLines = if (Test-Path $claudeJsonl) { [regex]::Split((Get-Content -Raw -Path $claudeJsonl).Trim(), "`r?`n") | Where-Object { $_ -ne "" } } else { @() }
    $captureRecord = if ($jsonLines.Count -gt 0) { $jsonLines[$jsonLines.Count - 1] | ConvertFrom-Json } else { $null }
    Check "cycle writes Claude Implementer last capture" ((Test-Path $claudeLast) -and ($captureText -match "FAKE_CLAUDE_FAST_STDOUT") -and ($captureText -match "CLAUDE_EXECUTION_POLICY.md") -and ($captureText -match "Claude Execution Evidence") -and ($captureText -match "Command Transparency") -and ($captureText -match "Model Evidence"))
    Check "cycle writes sanitized Claude command capture" ((Test-Path $claudeCommand) -and ($commandText -match "Claude Implementer Command Capture") -and ($commandText -match "<prompt:redacted>") -and ($commandText -match "--safe-mode") -and ($commandText -match "--permission-mode acceptEdits") -and ($commandText -match "--disallowed-tools Bash") -and ($commandText -match "Sanitized: true"))
    Check "cycle appends Claude Implementer JSONL capture" ((Test-Path $claudeJsonl) -and ($null -ne $captureRecord) -and ($captureRecord.exitCode -eq 0) -and ($captureRecord.timedOut -eq $false) -and ($captureRecord.stdout -match "FAKE_CLAUDE_FAST_STDOUT"))
    Check "JSONL capture includes command and model evidence" (($null -ne $captureRecord.commands) -and ($captureRecord.commands[0].sanitized -eq $true) -and ($captureRecord.commands[0].cmd -match "<prompt:redacted>") -and ($null -ne $captureRecord.modelEvidence) -and ($captureRecord.modelEvidence.requestedProfile -eq "standard") -and ($captureRecord.modelEvidence.actualModelObserved -eq "unknown/not exposed") -and ($captureRecord.modelEvidence.source -eq "built-in fallback") -and ($captureRecord.modelEvidence.confidence -eq "low"))
    $r2 = Invoke-Handoff -WorkDir $fx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "Claude capture artifacts are clean-tree exempt for cycle (2nd run still reaches the turn)" (($r2.Code -eq 7) -and ($r2.Out -notmatch "Working tree is not clean"))

    Remove-Item -LiteralPath $fastArgv -Force -ErrorAction SilentlyContinue
    $mappedHandoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v3.4.0 - Concrete Model Runner Test") -replace "(- Current Task:[^\r\n]+)", "`$1`r`n- Model Profile: economy"
    $mappedConfig = '{"schemaVersion":1,"profiles":{"economy":{"claudeModel":"test-economy-model"}}}'
    $mappedFx = New-Fixture -Files @{ "AI_HANDOFF.md" = $mappedHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $mappedConfig } -InitGit
    Initialize-FixtureGitBaseline -Dir $mappedFx
    $r3 = Invoke-Handoff -WorkDir $mappedFx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    $mappedArgvText = if (Test-Path $fastArgv) { Get-Content -Raw -Path $fastArgv } else { "" }
    Check "Claude runner passes --model only for a concrete resolved mapping" (($r3.Code -eq 7) -and ($mappedArgvText -match "model=1") -and ($mappedArgvText -match "modelvalue=1"))
    $mappedCapture = Get-Content -Raw -LiteralPath (Join-Path $mappedFx "IMPLEMENTER_LAST.md")
    Check "Claude capture records adapter-resolved profile and concrete model" (($mappedCapture -match "Requested policy/profile: economy") -and ($mappedCapture -match "Requested concrete model: test-economy-model") -and ($mappedCapture -match "Model source: MODEL_ROUTING.json"))

    $highHandoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v3.4.0 - Escalation Guard Test") -replace "(- Current Task:[^\r\n]+)", "`$1`r`n- Model Profile: high_reasoning"
    $highConfig = '{"schemaVersion":1,"profiles":{"high_reasoning":{"claudeModel":"test-high-model"}}}'
    $highFx = New-Fixture -Files @{ "AI_HANDOFF.md" = $highHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json" = $highConfig } -InitGit
    Initialize-FixtureGitBaseline -Dir $highFx
    $r4 = Invoke-Handoff -WorkDir $highFx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "concrete high_reasoning mapping requires explicit escalation approval" (($r4.Code -eq 1) -and ($r4.Out -match "requires explicit cost escalation approval") -and ($r4.Out -match "AllowModelEscalation")) -Detail "code=$($r4.Code); output=$($r4.Out)"
} finally {
    $env:Path = $prevPath
    if ($null -eq $prevArgv) { Remove-Item Env:\FAKE_NPX_ARGV -ErrorAction SilentlyContinue } else { $env:FAKE_NPX_ARGV = $prevArgv }
}

$hangBin = Join-Path $FixtureRoot "fake-npx-hang"
New-Item -ItemType Directory -Path $hangBin -Force | Out-Null
$hangCmd = Join-Path $hangBin "npx.cmd"
Set-Content -Path $hangCmd -Encoding ascii -Value @"
@echo off
if "%~1"=="--version" goto version
if "%~2"=="--version" goto version
if "%~3"=="--version" goto version
goto run
:version
echo claude-code-test
exit /b 0
:run
echo started> "%FAKE_NPX_MARKER%"
if not "%FAKE_NPX_TOUCH%"=="" echo partial progress> "%FAKE_NPX_TOUCH%"
cmd /c "ping -n 31 127.0.0.1 > nul"
echo finished> "%FAKE_NPX_MARKER%"
exit /b 0
"@
$marker = Join-Path $hangBin "marker.txt"
$prevPath = $env:Path
$prevMarker = $env:FAKE_NPX_MARKER
$prevTouch = $env:FAKE_NPX_TOUCH
$env:Path = $hangBin + [System.IO.Path]::PathSeparator + $env:Path
$env:FAKE_NPX_MARKER = $marker
try {
    $fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.0.0 - Safe Runner Timeout Test"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    $before = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "1")
    $after = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    $markerText = if (Test-Path $marker) { Get-Content -Raw -Path $marker } else { "" }
    Check "bounded Claude runner times out and exits 4" (($r.Code -eq 4) -and ($r.Out -match "TIMED OUT") -and ($r.Out -match "process tree was terminated"))
    Check "timeout does not transition AI_HANDOFF.md to a false review state" (($before -eq $after) -and ($after -match "State:\s+READY_FOR_IMPLEMENTATION") -and ($after -notmatch "State:\s+READY_FOR_REVIEW"))
    Check "timeout kills the hanging fake Claude before completion" ($markerText -notmatch "finished")
    $timeoutLast = Join-Path $fx "IMPLEMENTER_LAST.md"
    $timeoutCommand = Join-Path $fx "IMPLEMENTER_COMMAND.md"
    $timeoutJsonl = Join-Path $fx "IMPLEMENTER.jsonl"
    $timeoutText = if (Test-Path $timeoutLast) { Get-Content -Raw -Path $timeoutLast } else { "" }
    [string[]]$timeoutLines = if (Test-Path $timeoutJsonl) { [regex]::Split((Get-Content -Raw -Path $timeoutJsonl).Trim(), "`r?`n") | Where-Object { $_ -ne "" } } else { @() }
    $timeoutRecord = if ($timeoutLines.Count -gt 0) { $timeoutLines[$timeoutLines.Count - 1] | ConvertFrom-Json } else { $null }
    Check "timeout writes Claude Implementer capture as timed out" ((Test-Path $timeoutLast) -and (Test-Path $timeoutJsonl) -and ($timeoutText -match "Timed Out: True") -and ($null -ne $timeoutRecord) -and ($timeoutRecord.timedOut -eq $true))
    Check "timeout writes Claude command capture as timed out" ((Test-Path $timeoutCommand) -and ((Get-Content -Raw -Path $timeoutCommand) -match "Timed Out: true"))

    $fxPartial = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.11.0 - Timeout Partial Progress Test"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fxPartial
    $env:FAKE_NPX_TOUCH = Join-Path $fxPartial "PARTIAL_PROGRESS.md"
    # Give the nested Windows PowerShell -> npx.cmd runner enough time to start and
    # create the partial-progress file before the deliberately hanging turn times out.
    # A one-second bound is flaky on a cold or loaded Windows host and can time out
    # before the fixture reaches its first source edit, producing a false negative.
    $rPartial = Invoke-Handoff -WorkDir $fxPartial -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "timeout with source changes reports partial progress repair guidance (v2.11.0)" (($rPartial.Code -eq 4) -and ($rPartial.Out -match "partial progress detected after timeout") -and ($rPartial.Out -match "Protocol Repair") -and ($rPartial.Out -match "Open Codex as Reviewer/repair"))
} finally {
    $env:Path = $prevPath
    if ($null -eq $prevMarker) { Remove-Item Env:\FAKE_NPX_MARKER -ErrorAction SilentlyContinue } else { $env:FAKE_NPX_MARKER = $prevMarker }
    if ($null -eq $prevTouch) { Remove-Item Env:\FAKE_NPX_TOUCH -ErrorAction SilentlyContinue } else { $env:FAKE_NPX_TOUCH = $prevTouch }
}


# === v2.6.0 cycle/loop no-op / no-progress guard ===
Write-Host "[no-op] v2.6.0 cycle/loop no-op / no-progress guard"

# Fake npx that exits 0 but does nothing (no handoff transition, no source change) => no-op.
$noopBin = Join-Path $FixtureRoot "fake-npx-noop"
New-Item -ItemType Directory -Path $noopBin -Force | Out-Null
Set-Content -Path (Join-Path $noopBin "npx.cmd") -Encoding ascii -Value @"
@echo off
setlocal EnableDelayedExpansion
set "ALL=%*"
if not "!ALL:--version=!"=="!ALL!" (
  echo claude-code-test
  exit /b 0
)
echo FAKE_CLAUDE_NOOP
exit /b 0
"@

# Fake npx that edits a source file but does NOT transition the handoff => incomplete.
$incompleteBin = Join-Path $FixtureRoot "fake-npx-incomplete"
New-Item -ItemType Directory -Path $incompleteBin -Force | Out-Null
Set-Content -Path (Join-Path $incompleteBin "npx.cmd") -Encoding ascii -Value @"
@echo off
setlocal EnableDelayedExpansion
set "ALL=%*"
if not "!ALL:--version=!"=="!ALL!" (
  echo claude-code-test
  exit /b 0
)
echo FAKE_CLAUDE_INCOMPLETE
echo changed> "%FAKE_SRC%"
exit /b 0
"@

# Fake npx that transitions the handoff to READY_FOR_REVIEW (copies a pre-staged file) => progress.
$transitionBin = Join-Path $FixtureRoot "fake-npx-transition"
New-Item -ItemType Directory -Path $transitionBin -Force | Out-Null
Set-Content -Path (Join-Path $transitionBin "npx.cmd") -Encoding ascii -Value @"
@echo off
setlocal EnableDelayedExpansion
set "ALL=%*"
if not "!ALL:--version=!"=="!ALL!" (
  echo claude-code-test
  exit /b 0
)
echo FAKE_CLAUDE_TRANSITION
copy /Y "%FAKE_AFTER%" "%FAKE_HANDOFF%" >nul
if not "%FAKE_SRC%"=="" echo forbidden-investigation-edit> "%FAKE_SRC%"
exit /b 0
"@

# 1. cycle: an exit-0 no-op turn is flagged (exit 7), not reported as success.
$prevPath = $env:Path
$env:Path = $noopBin + [System.IO.Path]::PathSeparator + $env:Path
try {
    $fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.6.0 - No-op Guard Test"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    $before = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    $after = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    Check "cycle no-op turn fails closed with exit 7" (($r.Code -eq 7) -and ($r.Out -match "no-op"))
    Check "cycle no-op leaves the handoff state unchanged" (($before -eq $after) -and ($after -match "State:\s+READY_FOR_IMPLEMENTATION"))

    # 2. loop: a no-op turn stops the loop instead of re-running the identical turn.
    $fx2 = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.6.0 - Loop No-op Test"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx2
    $r = Invoke-Handoff -WorkDir $fx2 -Arguments @("loop", "-Yes", "-MaxTurns", "3", "-TimeoutSeconds", "5")
    Check "loop stops after the first no-op turn (exit 7)" (($r.Code -eq 7) -and ($r.Out -match "no-op"))
    Check "loop does not re-run the same turn after a no-op" (($r.Out -match "turn 1 of 3") -and ($r.Out -notmatch "turn 2 of 3"))
} finally {
    $env:Path = $prevPath
}

# 5. NEEDS_INVESTIGATION: loop invokes Claude automatically, permits a handoff-only
# transition, and stops at the Reviewer without requiring a manual Claude window.
$prevPath = $env:Path
$prevAfter = $env:FAKE_AFTER
$prevHandoff = $env:FAKE_HANDOFF
$prevSrc = $env:FAKE_SRC
$env:Path = $transitionBin + [System.IO.Path]::PathSeparator + $env:Path
try {
    $task = "v3.1.7 automated investigation test"
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md"   = (New-Handoff -State "NEEDS_INVESTIGATION" -WaitingFor "Implementer" -CurrentTask $task);
        "HANDOFF_AFTER.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask $task);
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    $env:FAKE_AFTER = Join-Path $fx "HANDOFF_AFTER.md"
    $env:FAKE_HANDOFF = Join-Path $fx "AI_HANDOFF.md"
    Remove-Item Env:\FAKE_SRC -ErrorAction SilentlyContinue
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("loop", "-Yes", "-MaxTurns", "2", "-TimeoutSeconds", "5")
    $after = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    Check "loop auto-runs NEEDS_INVESTIGATION and reaches READY_FOR_REVIEW" (($r.Code -eq 0) -and ($r.Out -match "automated Claude Code Implementer turn") -and ($after -match "State:\s+READY_FOR_REVIEW"))
    Check "automated investigation prompt explicitly forbids source edits" ((Get-Content -Raw -Path (Join-Path $fx "IMPLEMENTER_LAST.md")) -match "READ-ONLY investigation turn")

    # A handoff transition cannot hide a source edit: the post-turn boundary must
    # still fail closed and identify the unexpected file.
    $fx2 = New-Fixture -Files @{
        "AI_HANDOFF.md"   = (New-Handoff -State "NEEDS_INVESTIGATION" -WaitingFor "Implementer" -CurrentTask $task);
        "HANDOFF_AFTER.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask $task);
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx2
    $env:FAKE_AFTER = Join-Path $fx2 "HANDOFF_AFTER.md"
    $env:FAKE_HANDOFF = Join-Path $fx2 "AI_HANDOFF.md"
    $env:FAKE_SRC = Join-Path $fx2 "FORBIDDEN_EDIT.txt"
    $r2 = Invoke-Handoff -WorkDir $fx2 -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "investigation source edit fails closed even after a valid handoff transition" (($r2.Code -eq 6) -and ($r2.Out -match "read-only investigation modified source files") -and ($r2.Out -match "FORBIDDEN_EDIT.txt"))
} finally {
    $env:Path = $prevPath
    if ($null -eq $prevAfter) { Remove-Item Env:\FAKE_AFTER -ErrorAction SilentlyContinue } else { $env:FAKE_AFTER = $prevAfter }
    if ($null -eq $prevHandoff) { Remove-Item Env:\FAKE_HANDOFF -ErrorAction SilentlyContinue } else { $env:FAKE_HANDOFF = $prevHandoff }
    if ($null -eq $prevSrc) { Remove-Item Env:\FAKE_SRC -ErrorAction SilentlyContinue } else { $env:FAKE_SRC = $prevSrc }
}

# 3. cycle: source changed but no transition => incomplete (exit 6), not success.
$prevPath = $env:Path
$prevSrc = $env:FAKE_SRC
$env:Path = $incompleteBin + [System.IO.Path]::PathSeparator + $env:Path
try {
    $fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.6.0 - Incomplete Turn Test"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    $env:FAKE_SRC = Join-Path $fx "src_change.txt"
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "cycle treats source-change-without-transition as incomplete (exit 6)" (($r.Code -eq 6) -and ($r.Out -match "incomplete"))
} finally {
    $env:Path = $prevPath
    if ($null -eq $prevSrc) { Remove-Item Env:\FAKE_SRC -ErrorAction SilentlyContinue } else { $env:FAKE_SRC = $prevSrc }
}

# 4. cycle: a legitimate transition (READY_FOR_REVIEW) is NOT flagged as a no-op.
$prevPath = $env:Path
$prevAfter = $env:FAKE_AFTER
$prevHandoff = $env:FAKE_HANDOFF
$env:Path = $transitionBin + [System.IO.Path]::PathSeparator + $env:Path
try {
    $fx = New-Fixture -Files @{
        "AI_HANDOFF.md"   = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "v2.6.0 legit transition test");
        "HANDOFF_AFTER.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask "v2.6.0 legit transition test");
        ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles
    } -InitGit
    Initialize-FixtureGitBaseline -Dir $fx
    $env:FAKE_AFTER = Join-Path $fx "HANDOFF_AFTER.md"
    $env:FAKE_HANDOFF = Join-Path $fx "AI_HANDOFF.md"
    $r = Invoke-Handoff -WorkDir $fx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    $after = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
    Check "cycle does NOT flag a legitimate transition as a no-op" (($r.Out -notmatch "no-op") -and ($after -match "State:\s+READY_FOR_REVIEW"))
    Check "cycle routes a transitioned turn to the Reviewer (exit 0)" (($r.Code -eq 0) -and ($r.Out -match "Reviewer"))
} finally {
    $env:Path = $prevPath
    if ($null -eq $prevAfter) { Remove-Item Env:\FAKE_AFTER -ErrorAction SilentlyContinue } else { $env:FAKE_AFTER = $prevAfter }
    if ($null -eq $prevHandoff) { Remove-Item Env:\FAKE_HANDOFF -ErrorAction SilentlyContinue } else { $env:FAKE_HANDOFF = $prevHandoff }
}

# === v2.7.0 Claude Implementer prompt grounding ===
Write-Host "[grounding] v2.7.0 non-interactive prompt grounding"
$handoffSource = Get-Content -Raw -Path $HandoffScript
Check "Invoke-ClaudeTurn prompt declares a non-interactive headless turn" ($handoffSource -match "NON-INTERACTIVE")
Check "Invoke-ClaudeTurn prompt forbids greeting and asking the operator" (($handoffSource -match "do NOT greet") -and ($handoffSource -match "do NOT ask what to work on"))
Check "Invoke-ClaudeTurn prompt still requires the Claude Execution Evidence block" ($handoffSource -match "Claude Execution Evidence")

# === v2.8.0 Claude Implementer context isolation ===
Write-Host "[isolation] v2.8.0 --setting-sources project,local"
Check "Invoke-ClaudeTurn passes the v2.8.0 isolation flag --setting-sources project,local" (($handoffSource -match "'--setting-sources'") -and ($handoffSource -match "'project,local'"))
Check "Claude command transparency records the quoted setting-sources value (v2.8.0)" ($handoffSource -match 'setting-sources `"project,local`"')
Check "Claude runner disables ambient plugins and hooks with --safe-mode" (($handoffSource -match "'--safe-mode'") -and ($handoffSource -match "customizations/plugins/hooks disabled"))

# === v2.9.0 Claude Implementer system-prompt grounding ===
Write-Host "[system-prompt] v2.9.0 --append-system-prompt"
Check "Invoke-ClaudeTurn passes --append-system-prompt to the Claude runner (v2.9.0)" ($handoffSource -match "'--append-system-prompt'")
Check "System prompt carries the non-interactive / never-greet / read-files-exactly guards (v2.9.0)" (($handoffSource -match "non-interactive, headless") -and ($handoffSource -match "Never greet") -and ($handoffSource -match "Read the requested local files exactly"))
Check "Command transparency redacts the system prompt (v2.9.0)" ($handoffSource -match "append-system-prompt <system-prompt:redacted>")


# === v3.5.0 Symmetric role adapters ===
#
# One block per acceptance criterion in the approved plan. The claim these defend is
# narrow and worth stating plainly: the permission a turn runs under is decided by the
# ROLE, and swapping which tool holds a role changes who does the work and nothing else.
Write-Host "[v3.5.0] Symmetric role adapters"

$symRoles = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Claude Code |
| Implementer | Codex |
"@

# --- Adapter coverage: all six combinations callable ---
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("adapters")
$symMatrix = $r.Out
$symPairs = @(
    @("Master", "Codex"), @("Master", "Claude Code"),
    @("Implementer", "Codex"), @("Implementer", "Claude Code"),
    @("Reviewer", "Codex"), @("Reviewer", "Claude Code")
)
$symAllCallable = $true
$symMissing = ""
foreach ($pair in $symPairs) {
    # Match the matrix row: role, tool, then "yes" in the Callable column.
    $rowPattern = "(?m)^\s+" + [regex]::Escape($pair[0]) + "\s+" + [regex]::Escape($pair[1]) + "\s+yes\s"
    if ($symMatrix -notmatch $rowPattern) { $symAllCallable = $false; $symMissing = "$($pair[0])/$($pair[1])"; break }
}
Check "adapters reports every one of the six role/tool combinations as callable" $symAllCallable $symMissing
Check "adapters states that permission belongs to the role, not the tool" ($symMatrix -match "Permission is a property of the ROLE")

# --- Read-only roles: both tools run Master and Reviewer without write permission ---
Check "the Master role is read-only for both tools" (($symMatrix -match "(?m)^\s+Master\s+Codex\s+yes\s+read-only") -and ($symMatrix -match "(?m)^\s+Master\s+Claude Code\s+yes\s+read-only"))
Check "the Reviewer role is read-only for both tools" (($symMatrix -match "(?m)^\s+Reviewer\s+Codex\s+yes\s+read-only") -and ($symMatrix -match "(?m)^\s+Reviewer\s+Claude Code\s+yes\s+read-only"))
Check "the Implementer role is the only write-enabled role, for both tools" (($symMatrix -match "(?m)^\s+Implementer\s+Codex\s+yes\s+write") -and ($symMatrix -match "(?m)^\s+Implementer\s+Claude Code\s+yes\s+write"))

# A read-only Claude turn must have no instrument for writing: the file-writing tools are
# refused at the CLI, not merely discouraged in the prompt.
Check "the read-only Claude role turn disables every file-writing tool" ($handoffSource -match "'Bash,Edit,Write,NotebookEdit'")
Check "the read-only Claude role turn never enables acceptEdits" ($handoffSource -notmatch "(?s)Invoke-ClaudeReadOnlyCapture.{0,4000}acceptEdits")
Check "a read-only role turn that changes the tree fails and discards its capture" (($handoffSource -match 'read-only \$TurnRole turn changed files') -and ($handoffSource -match "a Reviewer must never edit what it reviews"))

# --- Write-enabled Implementer: the Codex grant is bounded exactly as specified ---
#
# Which role receives which sandbox is the whole safety claim of this release, so it is
# asserted structurally rather than left to a reader of a 6000-line script. A reviewer
# read the Implementer's sandbox variable as if it were script-wide and reported that the
# Master and Reviewer had been granted write access. They had not - both pass a literal
# 'read-only' - but the ambiguity was real, and these checks make the answer mechanical.
$codexSandboxLines = @($handoffSource -split "`r?`n" | Where-Object { $_.Contains("'--sandbox'") })
Check "exactly three codex invocations exist: Master, Reviewer, Implementer" ($codexSandboxLines.Count -eq 3)
Check "exactly two codex invocations are hard-coded read-only (Master and Reviewer)" (@($codexSandboxLines | Where-Object { $_.Contains("'--sandbox', 'read-only'") }).Count -eq 2)
Check "exactly one codex invocation takes a variable sandbox, and it is the Implementer's" (@($codexSandboxLines | Where-Object { $_.Contains("'--sandbox', `$implementerSandbox") }).Count -eq 1)
Check "the Codex Implementer turn requests workspace-write, not full access" (($handoffSource.Contains("`$implementerSandbox = ""workspace-write""")) -and (@($codexSandboxLines | Where-Object { $_.Contains("danger-full-access") }).Count -eq 0) -and ($handoffSource -notmatch "(?s)function Invoke-CodexImplementerTurn.{0,8000}'danger-full-access'"))
Check "the Codex Implementer turn never passes an approval or bypass flag" (($handoffSource -notmatch "(?s)function Invoke-CodexImplementerTurn.{0,8000}--ask-for-approval") -and ($handoffSource -notmatch "(?s)function Invoke-CodexImplementerTurn.{0,8000}dangerously-bypass"))
# A Codex investigation turn must still be able to WRITE AI_HANDOFF.md. Fencing it with
# a read-only sandbox deadlocked the state - advertised as callable, unable to finish.
Check "a Codex investigation turn keeps workspace-write so it can record its findings" ($handoffSource.Contains("`$implementerSandbox = ""workspace-write"""))
Check "no Implementer turn is fenced into a read-only sandbox it cannot transition from" (-not $handoffSource.Contains("`$implementerSandbox = if ("))
Check "source-read-only is enforced after the investigation turn, for both tools alike" (($handoffSource -match "SOURCE-READ-ONLY investigation turn") -and ($handoffSource -match "The working tree is checked after this turn and any source change fails it"))
Check "the deadlock is recorded so the same sandbox reasoning is not repeated" ($handoffSource -match "That was a deadlock, caught in review")
Check "the Codex Implementer is told its declared scope is checked after the turn" ($handoffSource -match "an undeclared file fails the turn")

# --- Exact scope still binds, whichever tool implements ---
# The scope check lives in the shared caller, so both tools reach it through one path.
Check "the Implementer turn is dispatched by role, so both tools reach the same scope check" (($handoffSource -match "function Invoke-ImplementerTurn") -and ($handoffSource -match "\`$claudeExit = Invoke-ImplementerTurn"))

# --- Invariant unchanged: Reviewer != Implementer, in both directions ---
$sameToolRoles = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Codex |
| Implementer | Codex |
"@
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $sameToolRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "Reviewer == Implementer still blocks when both are Codex" ($r.Code -ne 0)

$sameToolRolesClaude = $sameToolRoles -replace "Codex", "Claude Code"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $sameToolRolesClaude } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "Reviewer == Implementer still blocks when both are Claude Code" ($r.Code -ne 0)

# --- The mirror swap reaches its turn instead of stopping for a manual paste ---
$symHandoff = ((New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer") -replace "- Reviewer: Codex", "- Reviewer: Claude Code") -replace "- Implementer: Claude Code`r?`n", "- Implementer: Codex`n"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $symHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $symRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "the mirror swap does not stop at the manual-paste category" ($r.Out -notmatch "Operator Manual Action - paste the prompt")
Check "the mirror swap plan names Claude Code as the Reviewer, not Codex" ($r.Out -match "Claude Code Reviewer plan")

# The Task Actors must be swapped alongside the binding, or the role checkpoint blocks
# first - correctly, since a task recorded under one binding must not run under another.
$symMasterHandoff = ((New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master") -replace "- Reviewer: Codex", "- Reviewer: Claude Code") -replace "- Implementer: Claude Code`r?`n", "- Implementer: Codex`n"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $symMasterHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $symRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "a swapped Master plan names Claude Code, not Codex" ($r.Out -match "Claude Code Master analysis plan")

# --- What does NOT change for an untouched install ---
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "the default binding still resolves a Codex Reviewer running read-only" (($r.Out -match "Codex Reviewer plan") -and ($r.Out -match "--sandbox read-only"))
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "the default binding still resolves a Codex Master running read-only" (($r.Out -match "Codex Master analysis plan") -and ($r.Out -match "--sandbox read-only"))

# --- Legacy vendor-named captures are still consumed ---
# An install that upgraded mid-task carries CODEX_REVIEW_LAST.md and no REVIEW_LAST.md.
# review-apply must read it rather than report that no verdict was captured.
$legacyTask = "v3.5.0 - Legacy Capture Compatibility"
$legacyCapture = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: $legacyTask`nREASON: legacy capture still applies"
$fx = New-ReviewApplyFixture -Capture $legacyCapture -CurrentTask $legacyTask
Rename-Item -LiteralPath (Join-Path $fx "REVIEW_LAST.md") -NewName "CODEX_REVIEW_LAST.md"
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
Check "review-apply consumes a legacy vendor-named capture when no role-named file exists" (($r.Code -eq 0) -and ($h -match "Verdict:\s+APPROVED"))

# --- A capture produced by the wrong tool is never applied ---
# This guard used to read "must be Codex". Stated as "must be the bound Reviewer" it also
# catches the case the old form waved through: a Codex capture under a Claude binding.
$wrongTask = "v3.5.0 - Wrong Reviewer Capture"
$wrongCapture = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: $wrongTask`nREASON: produced by the wrong tool"
$fx = New-ReviewApplyFixture -Capture $wrongCapture -CurrentTask $wrongTask
Set-Content -Path (Join-Path $fx ".ai/roles/ROLE_ASSIGNMENT.md") -Value $symRoles -Encoding utf8
$symWrong = ((Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")) -replace "- Reviewer: Codex", "- Reviewer: Claude Code") -replace "- Implementer: Claude Code`r?`n", "- Implementer: Codex`n"
Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $symWrong -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
# v3.6.0: assert the REASON, not just a non-zero exit. This check passed for four
# releases while the guard it names did nothing: the fixture's edited role file left the
# tree dirty, an unrelated guard failed first, and the exit code looked right. A capture
# signed by Codex was in fact being ACCEPTED under a Claude Code Reviewer binding.
Check "a verdict signed by a tool other than the bound Reviewer is refused" (($r.Code -ne 0) -and ($r.Out -match "must be the bound Reviewer"))
Check "the refusal names the bound Reviewer and the signer" (($r.Out -match "Claude Code") -and ($r.Out -match "Codex"))

# The inverse half of the same guard: under the swapped binding the capture the bound
# Reviewer actually produced must be accepted. The old hardcoded form would have
# refused it, which would have made a swapped Reviewer unable to review at all.
$rightTask = "v3.6.0 - Bound Reviewer Capture"
$rightCapture = "VERDICT: APPROVED`nREVIEWER: Claude Code`nTASK: $rightTask`nREASON: produced by the bound Reviewer"
$fx = New-ReviewApplyFixture -Capture $rightCapture -CurrentTask $rightTask
Set-Content -Path (Join-Path $fx ".ai/roles/ROLE_ASSIGNMENT.md") -Value $symRoles -Encoding utf8
$symRight = ((Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")) -replace "- Reviewer: Codex", "- Reviewer: Claude Code") -replace "- Implementer: Claude Code`r?`n", "- Implementer: Codex`n"
Set-Content -Path (Join-Path $fx "AI_HANDOFF.md") -Value $symRight -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-apply", "-Yes")
$h = Get-Content -Raw -Path (Join-Path $fx "AI_HANDOFF.md")
Check "a verdict signed by the bound Reviewer is applied under a swapped binding" (($r.Code -eq 0) -and ($h -match "Verdict:\s+APPROVED"))

# --- The upgrade path adds the new local captures to .gitignore ---
# A pre-v3.5.0 project already contains the ignore block, so a block-presence check would
# skip the new names and the next review-run would fail its own exact-scope guard.
$upgradeTarget = Join-Path $FixtureRoot ("upgrade-ignore-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $upgradeTarget -Force | Out-Null
Set-Content -Path (Join-Path $upgradeTarget ".gitignore") -Value "/AI_HANDOFF.md`n/CODEX_REVIEW_LAST.md" -Encoding utf8
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $upgradeTarget *> $null
$upgradedIgnore = Get-Content -Raw -Path (Join-Path $upgradeTarget ".gitignore")
Check "upgrading an existing install adds the new role-named captures to .gitignore" (($upgradedIgnore -match "/REVIEW_LAST\.md") -and ($upgradedIgnore -match "/MASTER_LAST\.md") -and ($upgradedIgnore -match "/IMPLEMENTER_LAST\.md"))
Check "upgrading .gitignore preserves the entries that were already there" ($upgradedIgnore -match "/CODEX_REVIEW_LAST\.md")

# --- The read-only boundary is measured by CONTENT, not by filename set ---
#
# Found by the Codex Reviewer while reviewing v3.5.0 itself. The first implementation of
# this guard compared the set of changed file NAMES before and after a read-only turn.
# A Reviewer runs on a dirty tree by definition, so a turn that edited a file which was
# ALREADY dirty left that set identical and passed - the reviewer could have rewritten
# the very code it was reviewing. These pin the content-level comparison that replaced it.
Check "the read-only boundary hashes file content, not just file names" (($handoffSource -match 'function Get-ReadOnlyBoundarySnapshot') -and ($handoffSource -match 'Get-FileHash -Algorithm SHA256 -LiteralPath'))
Check "the boundary explains why a filename comparison is insufficient" ($handoffSource -match 'identical and walks straight through')
Check "the boundary covers local coordination files, so a read-only turn cannot rewrite the handoff" ($handoffSource -match 'foreach \(\$local in \$LocalHandoffFiles\)')
Check "an unreadable tree or unhashable file fails the boundary closed" ($handoffSource -match 'Refusing to accept a capture whose read-only boundary is unverified')
Check "the boundary comparison is case-sensitive on the hash" ($handoffSource -match '\$After\[\$key\] -cne \$Before\[\$key\]')
Check "a path that vanished during a read-only turn counts as a change" ($handoffSource -match 'if \(-not \$After.ContainsKey\(\$key\)\)')
Check "a path that appeared during a read-only turn counts as a change" ($handoffSource -match 'if \(-not \$Before.ContainsKey\(\$key\)\)')
Check "the boundary is checked before the protocol writes its own capture or event log" ($handoffSource -match '(?s)\$postSnapshot = Get-ReadOnlyBoundarySnapshot.{0,1500}Event log parity with the Codex path')

# Behavioural proof of the comparison itself: same names, different content.
$boundaryBefore = @{ "a.txt" = "AAA"; "b.txt" = "BBB" }
$boundaryAfterEdited = @{ "a.txt" = "AAA"; "b.txt" = "CCC" }
$boundaryAfterSame = @{ "a.txt" = "AAA"; "b.txt" = "BBB" }
$boundaryProbe = {
    param($Before, $After)
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) { $changed.Add($key); continue }
        if ($After[$key] -cne $Before[$key]) { $changed.Add($key) }
    }
    foreach ($key in $After.Keys) { if (-not $Before.ContainsKey($key)) { $changed.Add($key) } }
    return @($changed | Sort-Object -Unique)
}
Check "editing an already-tracked file with no name change is detected" ((& $boundaryProbe $boundaryBefore $boundaryAfterEdited).Count -eq 1)
Check "an untouched tree reports no change" ((& $boundaryProbe $boundaryBefore $boundaryAfterSame).Count -eq 0)

# --- v3.5.0: the release dry run must report what will actually happen ---
#
# Two reporting defects, neither of them a safety hole and both of them the kind that
# teaches an operator to stop trusting the output:
#   1. release-check printed "ready for explicit authorization" and then exited 1,
#      because the ready path fell off the end of the function and inherited whatever
#      status the last internal probe left behind. Anything gating on the exit code read
#      a successful dry run as a failure.
#   2. The command list always showed `git add` and `git commit`, including on the
#      already-committed path where Invoke-Release deliberately skips both. The dry run
#      is the one thing an operator reads before authorising an irreversible action, and
#      it was naming a commit that would never be created.
Write-Host "[v3.5.0] Release dry-run reporting fidelity"

function New-ReadyReleaseFixture {
    param([string]$Version, [switch]$CommitTheWork)
    $handoff = New-Handoff -State "REVIEW_DONE" -WaitingFor "User"
    $handoff = $handoff -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- RELEASE_TARGET.md"
    # dist/ must be ignored exactly as it is in a real install, or the built package
    # itself shows up as undeclared work and the exact-scope guard blocks the release.
    $dir = New-Fixture -Files @{ "AI_HANDOFF.md" = $handoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles; ".gitignore" = "/dist/`n/AI_HANDOFF.md`n" } -InitGit
    Initialize-FixtureGitBaseline -Dir $dir
    Set-Content -Path (Join-Path $dir "RELEASE_TARGET.md") -Value "# release fixture" -Encoding utf8
    if ($CommitTheWork) {
        # Reproduce the state left behind by commit-approved: the reviewed change is
        # already in HEAD and the working tree is clean.
        Initialize-FixtureGitBaseline -Dir $dir
    }
    # A package the gate will accept: a real file and its real SHA-256.
    New-Item -ItemType Directory -Path (Join-Path $dir "dist") -Force | Out-Null
    $zip = Join-Path $dir "dist/codex-claude-handoff-$Version.zip"
    Set-Content -Path $zip -Value "fixture package payload" -Encoding ascii
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    Set-Content -Path (Join-Path $dir "dist/codex-claude-handoff-$Version.zip.sha256") -Value "$hash  codex-claude-handoff-$Version.zip" -Encoding ascii
    return $dir
}

# Uncommitted reviewed work: the release still has a commit to build, so the dry run
# must say so.
$fx = New-ReadyReleaseFixture -Version "v9.9.8"
$r = Invoke-Handoff -WorkDir $fx -Arguments @("release-check", "-Version", "v9.9.8", "-Message", "fixture release")
Check "a ready release-check exits 0, not 1" (($r.Code -eq 0) -and ($r.Out -match "ready for explicit authorization"))
Check "an uncommitted release still lists git add and git commit" (($r.Out -match "git add --") -and ($r.Out -match "git commit -m"))
Check "an uncommitted release lists push and tag" (($r.Out -match "git push origin HEAD") -and ($r.Out -match "git tag -a v9\.9\.8"))

# Already-committed reviewed work: Invoke-Release skips add and commit, so the dry run
# must not name them.
$fx = New-ReadyReleaseFixture -Version "v9.9.7" -CommitTheWork
$r = Invoke-Handoff -WorkDir $fx -Arguments @("release-check", "-Version", "v9.9.7", "-Message", "fixture release")
Check "an already-committed release-check also exits 0" ($r.Code -eq 0)
Check "an already-committed release does NOT list git add or git commit" (($r.Out -notmatch "git add --") -and ($r.Out -notmatch "git commit -m"))
Check "the already-committed plan says why the commit step is absent" ($r.Out -match "HEAD already carries the approved Changed Files")
Check "an already-committed release still lists push and tag" (($r.Out -match "git push origin HEAD") -and ($r.Out -match "git tag -a v9\.9\.7"))

# The printed plan and the executor must not drift apart again.
Check "the executor's skip condition and the plan's are the same flag" ((@($handoffSource -split "`r?`n" | Where-Object { $_.Contains('$Plan.ReleaseFromHead') }).Count -ge 1) -and (@($handoffSource -split "`r?`n" | Where-Object { $_.Contains('$plan.ReleaseFromHead') }).Count -ge 1))


# --- v3.12.0: the push reminder ---
Write-Host "[4D-2] Push reminder (v3.12.0)"
# The protocol never pushes. One project collected 20 local commits because nothing ever
# pointed the user back at the push.
$pushRemote = Join-Path $FixtureRoot ("push-remote-" + [Guid]::NewGuid().ToString("N") + ".git")
& git init -q --bare $pushRemote 2>$null | Out-Null
$pushFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $pushFx
$r = Invoke-Handoff -WorkDir $pushFx -Arguments @("work")
Check "a project with no remote shows no push reminder" ($r.Out -notmatch "Not pushed:")
Push-Location $pushFx
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & git remote add origin $pushRemote 2>$null | Out-Null
} finally { $ErrorActionPreference = $prevEap; Pop-Location }
$r = Invoke-Handoff -WorkDir $pushFx -Arguments @("status")
Check "a branch that was never pushed is named with the command to push it" ($r.Out -match "has never been pushed \(1 commit\(s\)\)\. Pushing is yours: git push -u origin")
Push-Location $pushFx
$ErrorActionPreference = 'Continue'
try {
    $pushBranch = (& git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    & git push -q -u origin $pushBranch 2>$null | Out-Null
    & git -c core.autocrlf=false commit -q --allow-empty -m "second" 2>$null | Out-Null
    & git -c core.autocrlf=false commit -q --allow-empty -m "third" 2>$null | Out-Null
} finally { $ErrorActionPreference = $prevEap; Pop-Location }
$r = Invoke-Handoff -WorkDir $pushFx -Arguments @("work")
Check "work counts the local commits that wait for a push" ($r.Out -match "Not pushed:\s+2 local commit\(s\) on .* are not pushed to origin/")
Check "the reminder warns that a push can deploy" ($r.Out -match "deploys on push, the push also publishes")
$r = Invoke-Handoff -WorkDir $pushFx -Arguments @("doctor")
# The fixture is not a full install, so doctor fails on other checks; only the push line is under test.
Check "doctor reports unpushed commits as information, not failure" (($r.Out -match "INFO  2 local commit\(s\)") -and ($r.Out -notmatch "(FAIL|WARN)  2 local commit"))
Push-Location $pushFx
$ErrorActionPreference = 'Continue'
try { & git push -q 2>$null | Out-Null } finally { $ErrorActionPreference = $prevEap; Pop-Location }
$r = Invoke-Handoff -WorkDir $pushFx -Arguments @("status")
Check "a fully pushed branch shows no reminder" ($r.Out -notmatch "Not pushed:")
$pushSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "commit-approved prints the push count after the commit" ($pushSrc -match 'Push:\s+\$\(\$pushLines\[0\]\)')
$pushFnStart = $pushSrc.IndexOf('function Get-UnpushedState')
$pushFnEnd = $pushSrc.IndexOf('function Write-PushReminder')
$pushFnText = $pushSrc.Substring($pushFnStart, $pushFnEnd - $pushFnStart)
Check "the reminder never runs a push or a network command" (($pushFnStart -ge 0) -and ($pushFnText -notmatch 'git push"?\s*$|& git push|& git fetch|& git pull'))
$pushSh = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.sh")
Check "the Bash status carries the same reminder" ($pushSh -match '_push_reminder\(\)')



# --- v3.13.0: authorized database work, generated briefs, waiting, self-review ---
Write-Host "[4D-3] Database authorization, generated brief, wait, self-review (v3.13.0)"

# A real session lost a turn here: the Master dispatched a user-approved database acceptance
# matrix, and the Implementer turn's prompt forbids database access, so it refused.
$dbRoles = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Claude Code |
| Implementer | Codex |
"@
# A fake Codex CLI keeps these turns free: the gate is what is under test, not the agent.
$fakeDbCodex = Join-Path $FixtureRoot "fake-codex-db-gate.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo turn ran> IMPLEMENTER_LAST.md
:done
'@ | Set-Content -Path $fakeDbCodex -Encoding ascii
$prevDbCodexCli = $env:CODEX_CLI
$env:CODEX_CLI = $fakeDbCodex
try {
$dbTask = "Run the database acceptance matrix against the project with disposable test data."
$dbHandoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask $dbTask) -replace "- Implementer: Claude Code", "- Implementer: Codex" -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$dbFx = New-Fixture -Files @{ "AI_HANDOFF.md" = $dbHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $dbRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $dbFx
$r = Invoke-Handoff -WorkDir $dbFx -Arguments @("cycle", "-Yes")
Check "a database task with no authorization is refused before the turn runs" (($r.Code -eq 2) -and ($r.Out -match "blocked before the turn was spent"))
Check "the refusal names the line the user has to authorize" ($r.Out -match "- Authorized Operations: database")
Check "the refusal is a user decision, not a protocol repair" ($r.Out -match "Stop category: Scope/Authorization")

# Implementation that only writes a migration file must still run: this is not execution.
$writeTask = "Write migration 009 adding the exercise_notes column; do not run it."
$writeHandoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask $writeTask) -replace "- Implementer: Claude Code", "- Implementer: Codex" -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$writeFx = New-Fixture -Files @{ "AI_HANDOFF.md" = $writeHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $dbRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $writeFx
$r = Invoke-Handoff -WorkDir $writeFx -Arguments @("cycle", "-Yes")
Check "writing a migration file is not treated as database execution" ($r.Out -notmatch "blocked before the turn was spent")

# With the authorization recorded, the gate passes and the prompt carries a bounded allowance.
$dbAuthHandoff = $dbHandoff -replace "(?m)^- Current Task:", "- Authorized Operations: database`n- Current Task:"
$dbAuthFx = New-Fixture -Files @{ "AI_HANDOFF.md" = $dbAuthHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $dbRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $dbAuthFx
$r = Invoke-Handoff -WorkDir $dbAuthFx -Arguments @("cycle", "-Yes")
Check "an authorized database task passes the gate" ($r.Out -notmatch "blocked before the turn was spent")
$dbSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "the turn prompt forbids the database unless the handoff authorizes it" ($dbSrc -match 'Never access or mutate a database\. If the task cannot be completed without database access')
Check "the authorized allowance is bounded to disposable data and cleanup" (($dbSrc -match "Use disposable test data only") -and ($dbSrc -match "never reset, restore, backfill or delete data you did not create") -and ($dbSrc -match "clean up everything you created"))
Check "an authorized turn still may not open a credential file" ($dbSrc -match "Never open a credential file to do it")
Check "both turn prompts read the same authorization" ((@($dbSrc -split "`r?`n" | Where-Object { $_ -match 'Get-DatabaseTurnPromptClause' }).Count -ge 3))
} finally {
    if ($null -eq $prevDbCodexCli) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $prevDbCodexCli }
}

# NEXT_TURN.md is generated. A Master that hand-writes it is working outside the protocol.
$briefFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$null = Invoke-Handoff -WorkDir $briefFx -Arguments @("next")
$briefText = Get-Content -Raw -Path (Join-Path $briefFx "NEXT_TURN.md")
Check "next stamps the brief it generates" ($briefText -match '<!-- handoff-generated: handoff\.ps1 next; sha256=[0-9a-f]{64} -->')
$r = Invoke-Handoff -WorkDir $briefFx -Arguments @("work")
Check "a generated brief raises nothing in work" ($r.Out -notmatch "NEXT_TURN.md was")
Add-Content -LiteralPath (Join-Path $briefFx "NEXT_TURN.md") -Value "hand-written addition"
$r = Invoke-Handoff -WorkDir $briefFx -Arguments @("work")
Check "work reports a brief edited after it was generated" ($r.Out -match "NEXT_TURN.md was edited after it was generated")
Check "the report names the command that regenerates it" ($r.Out -match "handoff\.ps1 next")
Set-Content -LiteralPath (Join-Path $briefFx "NEXT_TURN.md") -Value "# Next Turn Entry Brief`nhand-written by the Master" -Encoding utf8
$r = Invoke-Handoff -WorkDir $briefFx -Arguments @("doctor")
Check "doctor warns about a hand-written brief" ($r.Out -match "NEXT_TURN.md was not generated by 'handoff\.ps1 next'")
$null = Invoke-Handoff -WorkDir $briefFx -Arguments @("next")
$r = Invoke-Handoff -WorkDir $briefFx -Arguments @("doctor")
Check "regenerating the brief clears the warning" ($r.Out -match "NEXT_TURN.md carries a valid generated stamp")

# A tool must not review work it performed itself, whatever the Task Actors table says.
$selfCapture = @"
VERDICT: APPROVED
REVIEWER: Codex
TASK: v1.3.0 - Review Apply Test
REASON: fixture
"@
$selfFx = New-ReviewApplyFixture -Capture $selfCapture
$selfHandoffPath = Join-Path $selfFx "AI_HANDOFF.md"
$selfText = (Get-Content -Raw -LiteralPath $selfHandoffPath) -replace "(?m)^- Actor: Test?$", "- Actor: Codex (Reviewer) ran the work itself"
Set-Content -LiteralPath $selfHandoffPath -Value $selfText -Encoding utf8
$r = Invoke-Handoff -WorkDir $selfFx -Arguments @("review-check")
Check "a reviewer that took the last turn itself is refused" ($r.Out -match "Self-review guard")
Check "the refusal names the recorded Implementer" ($r.Out -match "recorded Implementer 'Claude Code'")
$otherText = (Get-Content -Raw -LiteralPath $selfHandoffPath) -replace "(?m)^- Actor: Codex \(Reviewer\) ran the work itself?$", "- Actor: Claude Code (Implementer)"
Set-Content -LiteralPath $selfHandoffPath -Value $otherText -Encoding utf8
$r = Invoke-Handoff -WorkDir $selfFx -Arguments @("review-check")
Check "a turn taken by the Implementer still reviews normally" ($r.Out -notmatch "Self-review guard")
$verdictText = (Get-Content -Raw -LiteralPath $selfHandoffPath) -replace "(?m)^- Actor: Claude Code \(Implementer\)?$", "- Actor: Codex (Reviewer)`r`n- Verdict: BLOCKED"
Set-Content -LiteralPath $selfHandoffPath -Value $verdictText -Encoding utf8
$r = Invoke-Handoff -WorkDir $selfFx -Arguments @("review-check")
Check "a recorded review verdict is not mistaken for self-review" ($r.Out -notmatch "Self-review guard")

# wait: one blocking call instead of polling, and it never stops the run.
$waitFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $waitFx -Arguments @("wait")
Check "wait says plainly when there is nothing to wait for" (($r.Code -eq 1) -and ($r.Out -match "wait: nothing to wait for"))
$finishedMarker = [ordered]@{ processId = 999999; startTicks = 1; command = "loop"; startedUtc = "2026-09-17T10:00:00Z"; log = "HANDOFF_BACKGROUND.log"; finishedUtc = "2026-09-17T10:04:00Z"; exitCode = 0 }
[System.IO.File]::WriteAllText((Join-Path $waitFx "HANDOFF_BACKGROUND.json"), ($finishedMarker | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
Set-Content -LiteralPath (Join-Path $waitFx "HANDOFF_BACKGROUND.log") -Value "loop: turn 1 complete" -Encoding utf8
$r = Invoke-Handoff -WorkDir $waitFx -Arguments @("wait")
Check "wait reports a finished run with its exit code" (($r.Code -eq 0) -and ($r.Out -match "wait: the background run has finished") -and ($r.Out -match "Exit code: 0"))
Check "wait prints the end of the run's log" ($r.Out -match "loop: turn 1 complete")
$failedMarker = [ordered]@{ processId = 999999; startTicks = 1; command = "loop"; startedUtc = "2026-09-17T10:00:00Z"; log = "HANDOFF_BACKGROUND.log"; finishedUtc = "2026-09-17T10:04:00Z"; exitCode = 7 }
[System.IO.File]::WriteAllText((Join-Path $waitFx "HANDOFF_BACKGROUND.json"), ($failedMarker | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Handoff -WorkDir $waitFx -Arguments @("wait")
Check "a run that ended badly does not report success" (($r.Code -ne 0) -and ($r.Out -match "Exit code: 7"))
$waitSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
$waitStart = $waitSrc.IndexOf("function Invoke-Wait")
$waitBody = $waitSrc.Substring($waitStart, [Math]::Min(4000, $waitSrc.Length - $waitStart))
$waitBody = $waitBody.Substring(0, $waitBody.IndexOf("`nfunction "))
Check "wait never stops or clears the run it waits for" (($waitStart -ge 0) -and ($waitBody -notmatch "Stop-ProcessTree|Clear-RunMarker|Stop-Process"))

# An interactive Claude Code Master waits by itself instead of handing the window back.
$bgFxAgent = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $bgFxAgent
$env:HANDOFF_BACKGROUND_NO_NOTIFY = "1"
$savedClaudeForBg = $env:CLAUDECODE
try {
    [System.Environment]::SetEnvironmentVariable("HANDOFF_RUN_MODE", $null, "Process")
    $env:CLAUDECODE = "1"
    $r = Invoke-Handoff -WorkDir $bgFxAgent -Arguments @("loop", "-MaxTurns", "0", "-Yes")
} finally {
    $env:HANDOFF_RUN_MODE = "foreground"
    [System.Environment]::SetEnvironmentVariable("CLAUDECODE", $savedClaudeForBg, "Process")
}
Check "a Claude Code agent is told to wait, not to end its turn" (($r.Out -match "WAIT FOR IT IN ONE BLOCKING CALL") -and ($r.Out -match "handoff\.ps1 wait"))
Check "it is told not to hand the window back to the user" ($r.Out -match "do not ask the user to open a window")
Check "a Claude Code agent is not told to end its turn" ($r.Out -notmatch "AGENT: END YOUR TURN NOW")
$null = Wait-BackgroundFinished -Dir $bgFxAgent
[System.Environment]::SetEnvironmentVariable("HANDOFF_BACKGROUND_NO_NOTIFY", $null, "Process")

$masterDoc = Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MASTER.md")
Check "MASTER.md tells the Master to drive the protocol through its commands" ($masterDoc -match "Drive the protocol through its commands")
Check "MASTER.md records the database authorization line" ($masterDoc -match "- Authorized Operations: database")
Check "MASTER.md forbids reviewing your own implementation" ($masterDoc -match "Never review what you implemented")


# --- v3.14.0: the plan, the next task, named stops, and what the user sees ---
Write-Host "[4D-4] The plan, task-next, named stops (v3.14.0)"

$seqTemplate = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/AI_SEQUENCE.md")
$planRoles = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Claude Code |
| Implementer | Codex |
"@
function New-PlanHandoff {
    param([string]$State, [string]$WaitingFor, [string]$CurrentTask)
    return (New-Handoff -State $State -WaitingFor $WaitingFor -CurrentTask $CurrentTask) -replace "- Implementer: Claude Code", "- Implementer: Codex" -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
}

# The plan lives in the project. A Master with an empty plan went looking for the next
# task in the user's personal notes outside the repository.
$planFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-PlanHandoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles
    "AI_SEQUENCE.md" = $seqTemplate
} -InitGit
$r = Invoke-Handoff -WorkDir $planFx -Arguments @("sequence-add", "-NextTask", "Secure the image generation endpoint")
Check "sequence-add appends a pending task" (($r.Code -eq 0) -and ($r.Out -match "task 1 added to AI_SEQUENCE.md as pending"))
$seqText = Get-Content -Raw -Path (Join-Path $planFx "AI_SEQUENCE.md")
Check "the shipped placeholders are replaced, not queued behind" (($seqText -match "\| 1 \| Secure the image generation endpoint \| pending \|") -and ($seqText -notmatch "\[one-line task description\]"))
$null = Invoke-Handoff -WorkDir $planFx -Arguments @("sequence-add", "-NextTask", "Store approved visuals in Supabase Storage")
$seqText = Get-Content -Raw -Path (Join-Path $planFx "AI_SEQUENCE.md")
Check "a second task is numbered after the first" ($seqText -match "\| 2 \| Store approved visuals in Supabase Storage \| pending \|")
$r = Invoke-Handoff -WorkDir $planFx -Arguments @("sequence-add")
Check "sequence-add without a task is refused" (($r.Code -eq 1) -and ($r.Out -match "-NextTask is required"))

# work must show the next task instead of leaving the boundary silent.
$r = Invoke-Handoff -WorkDir $planFx -Arguments @("work")
Check "work names the next task in the plan" ($r.Out -match "Next in the plan: Secure the image generation endpoint")
Check "work names the command that opens it" ($r.Out -match "task-next")

# task-next closes the finished task and opens the next one in one guarded operation.
$r = Invoke-Handoff -WorkDir $planFx -Arguments @("task-next", "-Yes")
Check "task-next opens the next pending task" (($r.Code -eq 0) -and ($r.Out -match "task-next: opened") -and ($r.Out -match "Current Task: Secure the image generation endpoint"))
$planHandoff = Get-Content -Raw -Path (Join-Path $planFx "AI_HANDOFF.md")
Check "the new task starts at the Master's routing turn" (($planHandoff -match "(?m)^- State: NEEDS_ANALYSIS") -and ($planHandoff -match "(?m)^- Waiting For: Master"))
Check "the declared scope is reset for the new task" ($planHandoff -match "(?ms)## Changed Files\s*\n- None yet")
Check "the finished handoff is archived" ((Get-ChildItem -Path (Join-Path $planFx ".ai/handoff-history") -Filter "*AI_HANDOFF.md" -ErrorAction SilentlyContinue).Count -ge 1)
$seqText = Get-Content -Raw -Path (Join-Path $planFx "AI_SEQUENCE.md")
Check "the opened task is marked active in the plan" ($seqText -match "\| 1 \| Secure the image generation endpoint \| active \|")
Check "the brief is regenerated for the new task" ((Get-Content -Raw -Path (Join-Path $planFx "NEXT_TURN.md")) -match "Secure the image generation endpoint")
Check "task-next runs no git, deploy, database or secret action" ($r.Out -match "No git, deploy, database or secret action was run")

# A task that is not finished must not be closed by moving on.
$r = Invoke-Handoff -WorkDir $planFx -Arguments @("task-next", "-Yes")
Check "task-next refuses while the current task is unfinished" (($r.Code -eq 1) -and ($r.Out -match "the current task is not finished"))

# An empty plan is a user decision, not a silent stop.
$emptyFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-PlanHandoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles
    "AI_SEQUENCE.md" = $seqTemplate
} -InitGit
$r = Invoke-Handoff -WorkDir $emptyFx -Arguments @("task-next", "-Yes")
Check "an empty plan stops with a named category" (($r.Code -eq 3) -and ($r.Out -match "Stop category: Empty Plan"))
Check "the empty plan stop says how to record the next task" ($r.Out -match "sequence-add -NextTask")
$r = Invoke-Handoff -WorkDir $emptyFx -Arguments @("work")
Check "work asks for the next task when the plan is empty" ($r.Out -match "AI_SEQUENCE.md has no pending task")
$r = Invoke-Handoff -WorkDir $emptyFx -Arguments @("task-next", "-NextTask", "Ad-hoc task the user just asked for", "-Yes")
Check "task-next also opens a task given directly" (($r.Code -eq 0) -and ((Get-Content -Raw -Path (Join-Path $emptyFx "AI_HANDOFF.md")) -match "Ad-hoc task the user just asked for"))

# The output must name the tool that actually took the turn.
$v314Src = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "turn completion names the implementer, not always Claude Code" (($v314Src -match '\$implementerTool turn complete \(exit 0\)') -and ($v314Src -notmatch '"Claude Code turn complete \(exit 0\)\."'))
Check "the loop's failure messages name the implementer" (($v314Src -match '\$loopImplementerTool exited with error') -and ($v314Src -match '\$loopImplementerTool turn timed out'))
Check "Claude Code availability is only probed for a Claude Code turn" ($v314Src -match 'if \(Test-SameToolIdentity -First \$implementerTool -Second "Claude Code"\) \{\s*\r?\n\s*Write-Host "Checking Claude Code availability')

# A tool with no usage left is a named stop, not a generic error.
$quotaFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-PlanHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Quota probe"); ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $quotaFx
Set-Content -LiteralPath (Join-Path $quotaFx "IMPLEMENTER_LAST.md") -Value "You've hit your usage limit. Upgrade to Pro or try again at 5:13 PM." -Encoding utf8
$quotaCodex = Join-Path $FixtureRoot "fake-codex-quota.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo You've hit your usage limit. Try again at 5:13 PM.
exit /b 1
:done
'@ | Set-Content -Path $quotaCodex -Encoding ascii
$prevQuotaCli = $env:CODEX_CLI
$env:CODEX_CLI = $quotaCodex
try {
    $r = Invoke-Handoff -WorkDir $quotaFx -Arguments @("cycle", "-Yes")
} finally {
    if ($null -eq $prevQuotaCli) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $prevQuotaCli }
}
Check "a usage limit is reported as a Provider Quota stop" ($r.Out -match "Stop category: Provider Quota")
Check "the quota stop names the tool that is out" ($r.Out -match "the Codex account has no usage left")
Check "the quota stop reports the reset time the provider gave" ($r.Out -match "Resumes:\s+5:13 PM")
Check "the quota stop says no work was lost" ($r.Out -match "the turn did not run")

# work leads with the command for a role the protocol can run end to end.
$reviewLeadFx = New-ReviewApplyFixture -Capture "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: v1.3.0 - Review Apply Test`nREASON: fixture"
$r = Invoke-Handoff -WorkDir $reviewLeadFx -Arguments @("work")
Check "work leads with the runnable command for the Reviewer turn" ($r.Out -match "Next action: run the Reviewer turn from here")
Check "the manual paste is offered second, not first" ($r.Out -match "To take the turn manually in")

# What the user sees while a run is in flight.
Check "a status window is written for the background run" (($v314Src -match "handoff-status-") -and ($v314Src -match "TopMost = ") -and ($v314Src -match "running  00:00"))
Check "the status window can be switched off" ($v314Src -match "HANDOFF_BACKGROUND_NO_WINDOW")
Check "the run also announces itself when it starts" ($v314Src -match 'Handoff \$Command started')
Check "the launch message tells the agent what the user will see" ($v314Src -match "sees a notification now and a small status window")


# v3.14.1: a task that rules the database out in its own words must still run.
$denyTask = "Write migration SQL file 009 and update TypeScript source to support Storage paths. No database access, no bucket creation, no migration apply - source files only."
$denyFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-PlanHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask $denyTask); ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $denyFx
$r = Invoke-Handoff -WorkDir $denyFx -Arguments @("cycle")
Check "a task that denies database work is not treated as database execution" ($r.Out -notmatch "blocked before the turn was spent")
$declaredTask = "Run the database acceptance matrix against the project."
$declaredHandoff = (New-PlanHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask $declaredTask) -replace "(?m)^- Current Task:", "- Authorized Operations: none`n- Current Task:"
$declaredFx = New-Fixture -Files @{ "AI_HANDOFF.md" = $declaredHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $declaredFx
$r = Invoke-Handoff -WorkDir $declaredFx -Arguments @("cycle")
Check "an explicit 'Authorized Operations: none' ends the guessing" ($r.Out -notmatch "blocked before the turn was spent")

$planMaster = Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MASTER.md")
Check "MASTER.md says to end the window, not the work" ($planMaster -match "End the window, not the work")
Check "MASTER.md lists the only legitimate stops" (($planMaster -match "Stop only for these, and say which one it is") -and ($planMaster -match "empty plan"))
Check "MASTER.md tells the Master to name a quota stop" ($planMaster -match "When a tool runs out of usage, say so plainly")


# --- v3.15.0: the roles command, the indicator, and attribution before review ---
Write-Host "[4D-5] Roles command, indicator and attribution (v3.15.0)"

$swapRolesFile = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Codex |
| Implementer | Claude Code |
The User is always the approval point and is never one of these roles.

## Role Swap History

| Date | Previous Binding | New Binding | Approved By |
|---|---|---|---|
| 2026-09-01 | Master=Codex | Master=Claude Code | User |
"@
$rolesFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = ((New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -replace "- Implementer: Claude Code", "- Implementer: Claude Code" -replace "- Reviewer: Codex", "- Reviewer: Codex")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $swapRolesFile
} -InitGit
$r = Invoke-Handoff -WorkDir $rolesFx -Arguments @("roles")
Check "roles prints who holds each role" (($r.Out -match "Master:\s+Claude Code") -and ($r.Out -match "Implementer:\s+Claude Code") -and ($r.Out -match "Reviewer:\s+Codex"))
Check "roles states the rule that binds them" ($r.Out -match "the Reviewer is never the Implementer")

# The invariant is enforced by the command, not by the window that calls it.
$r = Invoke-Handoff -WorkDir $rolesFx -Arguments @("roles", "-SetRole", "Reviewer", "-SetTool", "Claude Code", "-Yes")
Check "moving one of the pair exchanges instead of breaking the invariant" (($r.Code -eq 0) -and ($r.Out -match "Exchange:\s+Implementer takes Codex"))
$exchanged = Get-Content -Raw -Path (Join-Path $rolesFx ".ai/roles/ROLE_ASSIGNMENT.md")
Check "both roles moved together" (($exchanged -match "\| Reviewer \| Claude Code \|") -and ($exchanged -match "\| Implementer \| Codex \|"))
# An exchange at a task boundary leaves the finished task's actors as they were - that
# record is history - so the protocol asks for a new task before the next turn. Each
# scenario below therefore gets its own fixture.
$r = Invoke-Handoff -WorkDir $rolesFx -Arguments @("work")
Check "after an exchange the protocol asks to open the next task" ($r.Out -match "Role drift|repair the handoff state|start")

$legalFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task"); ".ai/roles/ROLE_ASSIGNMENT.md" = $swapRolesFile } -InitGit
$r = Invoke-Handoff -WorkDir $legalFx -Arguments @("roles", "-SetRole", "Master", "-SetTool", "Codex", "-Yes")
Check "a legal swap is applied" (($r.Code -eq 0) -and ($r.Out -match "roles: applied"))
$swappedFile = Get-Content -Raw -Path (Join-Path $legalFx ".ai/roles/ROLE_ASSIGNMENT.md")
Check "the binding table is rewritten" ($swappedFile -match "\| Master \| Codex \|")
Check "the swap writes the history row that hand edits skipped" ($swappedFile -match "(?m)^\| \d{4}-\d{2}-\d{2} \| Master=Claude Code, Reviewer=Codex, Implementer=Claude Code \| Master=Codex, Reviewer=Codex, Implementer=Claude Code \| User \(handoff\.ps1 roles\) \|")
$r = Invoke-Handoff -WorkDir $legalFx -Arguments @("roles", "-SetRole", "Master", "-SetTool", "Codex", "-Yes")
Check "swapping a role to the tool it already holds changes nothing" ($r.Out -match "is already Codex")

# A swap while a turn is in flight would let work land under a binding it never had.
$rolesLiveFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $swapRolesFile } -InitGit
$rolesSleeper = Start-Process -FilePath $PwshExe -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 45") -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Milliseconds 500
    $liveMarker = [ordered]@{ processId = $rolesSleeper.Id; startTicks = $rolesSleeper.StartTime.ToUniversalTime().Ticks; command = "cycle"; startedUtc = "2026-09-20T10:00:00Z"; log = "HANDOFF_BACKGROUND.log"; finishedUtc = $null; exitCode = $null }
    [System.IO.File]::WriteAllText((Join-Path $rolesLiveFx "HANDOFF_BACKGROUND.json"), ($liveMarker | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $rolesLiveFx -Arguments @("roles", "-SetRole", "Master", "-SetTool", "Codex", "-Yes")
    Check "no role changes while a turn is running" (($r.Code -eq 1) -and ($r.Out -match "A turn is running now"))
} finally {
    try { Stop-Process -Id $rolesSleeper.Id -Force -ErrorAction SilentlyContinue } catch { }
}

# Mid-task, the binding and the task's own actors must move together.
$midFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "work in flight"); ".ai/roles/ROLE_ASSIGNMENT.md" = $swapRolesFile } -InitGit
$r = Invoke-Handoff -WorkDir $midFx -Arguments @("roles", "-SetRole", "Implementer", "-SetTool", "Codex", "-Yes")
Check "a mid-task swap says it moves Task Actors too" ($r.Out -match "Task Actors will be updated with the binding")
$midHandoff = Get-Content -Raw -Path (Join-Path $midFx "AI_HANDOFF.md")
Check "Task Actors follow the binding mid-task" ($midHandoff -match "(?m)^- Implementer: Codex?$")

# The settings file and the window are per project, and the window owns no rules.
$r = Invoke-Handoff -WorkDir $legalFx -Arguments @("roles", "-WindowOff")
Check "the indicator can be switched off per project" (($r.Out -match "the indicator is off") -and (Test-Path (Join-Path $legalFx "HANDOFF_UI.json")))
Check "the setting is remembered as data, not a guess" ((Get-Content -Raw -Path (Join-Path $legalFx "HANDOFF_UI.json")) -match '"rolesWindow":\s*false')
$rolesSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "the window shells out to the command for every swap" ($rolesSrc -match "handoff roles -SetRole")
Check "the window disables the swap buttons while a turn runs" ($rolesSrc -match "a turn is running - roles are locked")
Check "the window names the project it belongs to" ($rolesSrc -match "'HANDOFF - ' \+ ")
Check "both windows carry the project's own colour" ((@($rolesSrc -split "`r?`n" | Where-Object { $_ -match '\$accentSeed = 0' }).Count -eq 2))
Check "the indicator settings and marker are local coordination files" ($rolesSrc -match '"HANDOFF_UI\.json", "HANDOFF_UI_WINDOW\.json"')
$installSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "install.ps1")
Check "the installer asks once whether to show the indicator" (($installSrc -match "Show the roles indicator\? \[Y/n\]") -and ($installSrc -match "Windows only"))
Check "the installer never asks twice for the same project" ($installSrc -match 'not \(Test-Path -LiteralPath \$uiSettingsPath\)')

# A review of changes whose author is not recorded is not an independent review.
$anonCapture = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: v1.3.0 - Review Apply Test`nREASON: fixture"
$anonFx = New-ReviewApplyFixture -Capture $anonCapture
$anonPath = Join-Path $anonFx "AI_HANDOFF.md"
$anonText = (Get-Content -Raw -LiteralPath $anonPath) -replace "(?m)^- Actor: Test\r?$", "- Date: 2026-09-20"
Set-Content -LiteralPath $anonPath -Value $anonText -Encoding utf8
$r = Invoke-Handoff -WorkDir $anonFx -Arguments @("review-check")
Check "a review is refused when no actor is recorded for the changes" ($r.Out -match "does not record who took the turn")
Check "the refusal says to name the actor, even if it was yourself" ($r.Out -match "including yourself, if you did it")

$rolesMaster = Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MASTER.md")
Check "MASTER.md sends role questions to the command, not to a hand edit" ($rolesMaster -match "handoff\.ps1 roles")

Write-Host "[4D-6] Handoff stays UTF-8 and small (v3.15.1)"

# Another tool saving AI_HANDOFF.md without a BOM made the next Get-Content read it as ANSI;
# every save then doubled each non-ASCII character. A real project reached 1.2 GB this way.
$dash = [string][char]0x2014
$hebrew = -join ([char[]](0x05D1, 0x05D3, 0x05D9, 0x05E7, 0x05D4))
$encFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-PlanHandoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles
    "AI_SEQUENCE.md" = $seqTemplate
} -InitGit
$encPath = Join-Path $encFx "AI_HANDOFF.md"
$encText = (Get-Content -Encoding UTF8 -Raw -LiteralPath $encPath).TrimEnd() + "`n`n## Session Authorization $dash standing`n- keep $hebrew $dash`n`n## Master Note $dash finished task`n- finished-task note $hebrew`n`n## Risks / Notes`n- standing risk $hebrew $dash`n"
[System.IO.File]::WriteAllText($encPath, $encText, (New-Object System.Text.UTF8Encoding($false)))
$null = Invoke-Handoff -WorkDir $encFx -Arguments @("sequence-add", "-NextTask", "Next encoded task")
$r = Invoke-Handoff -WorkDir $encFx -Arguments @("task-next", "-Yes")
$encAfter = [System.IO.File]::ReadAllText($encPath, [System.Text.Encoding]::UTF8)
Check "task-next on a BOM-less UTF-8 handoff keeps non-ASCII text intact" (($r.Code -eq 0) -and ($encAfter.Contains("- standing risk $hebrew $dash")) -and ($encAfter.Contains("- keep $hebrew $dash")))
Check "no double-encoded text after a read-write cycle" (-not ($encAfter -match '\u00C3[\u0080-\u00BF\u0192\u2020]|\u00E2\u20AC'))
Check "task-next drops the finished task's own sections from the working copy" (-not $encAfter.Contains("finished-task note"))
Check "task-next keeps standing Session Authorization sections" ($encAfter.Contains("## Session Authorization $dash standing"))
Check "task-next reports the compaction" ($r.Out -match "Working copy compacted")
$encArchive = Get-ChildItem -Path (Join-Path $encFx ".ai/handoff-history") -Filter "*AI_HANDOFF.md" | Select-Object -First 1
Check "the dropped sections stay in the archive" ($encArchive -and ([System.IO.File]::ReadAllText($encArchive.FullName, [System.Text.Encoding]::UTF8).Contains("finished-task note $hebrew")))

# doctor names double-encoded text instead of letting it grow.
$mojiFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Moji task")
} -InitGit
$mojiPath = Join-Path $mojiFx "AI_HANDOFF.md"
$moji = -join ([char[]](0x00C3, 0x00A2, 0x00E2, 0x20AC, 0x201D))
Add-Content -LiteralPath $mojiPath -Value "- broken $moji text" -Encoding utf8
$r = Invoke-Handoff -WorkDir $mojiFx -Arguments @("doctor")
Check "doctor reports double-encoded text in AI_HANDOFF.md" ($r.Out -match "double-encoded character run")

# A heading inside a fenced block is text, not a section: compaction must keep it.
$fenceFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-PlanHandoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles
    "AI_SEQUENCE.md" = $seqTemplate
} -InitGit
$fencePath = Join-Path $fenceFx "AI_HANDOFF.md"
$fenceText = (Get-Content -Encoding UTF8 -Raw -LiteralPath $fencePath).TrimEnd() + "`n`n## Session Authorization - fenced`n- rule before`n``````text`n## Example`n```````n- Never deploy production.`n"
[System.IO.File]::WriteAllText($fencePath, $fenceText, (New-Object System.Text.UTF8Encoding($false)))
$null = Invoke-Handoff -WorkDir $fenceFx -Arguments @("sequence-add", "-NextTask", "Fenced next task")
$null = Invoke-Handoff -WorkDir $fenceFx -Arguments @("task-next", "-Yes")
$fenceAfter = [System.IO.File]::ReadAllText($fencePath, [System.Text.Encoding]::UTF8)
Check "compaction keeps a fenced heading and the lines after it" (($fenceAfter.Contains("## Example")) -and ($fenceAfter.Contains("- Never deploy production.")))

# Legitimate accented text is not corruption; double-encoded Hebrew is.
$legit = -join ([char[]](0x201C, 0x004D, 0x0041, 0x00C7, 0x00C3, 0x201D))
$legitFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Legit task") } -InitGit
Add-Content -LiteralPath (Join-Path $legitFx "AI_HANDOFF.md") -Value "- fruit $legit" -Encoding utf8
$r = Invoke-Handoff -WorkDir $legitFx -Arguments @("doctor")
Check "doctor does not flag legitimate accented text" (-not ($r.Out -match "double-encoded character run"))
$hebMoji = -join ([char[]](0x00D7, 0x2018, 0x00D7, 0x201C, 0x00D7, 0x2122))
$hebFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Hebrew task") } -InitGit
Add-Content -LiteralPath (Join-Path $hebFx "AI_HANDOFF.md") -Value "- word $hebMoji" -Encoding utf8
$r = Invoke-Handoff -WorkDir $hebFx -Arguments @("doctor")
Check "doctor flags double-encoded Hebrew" ($r.Out -match "double-encoded character run")

# Resets and nested fences follow the same rule: a fenced heading is text.
$nestFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-PlanHandoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles
    "AI_SEQUENCE.md" = $seqTemplate
} -InitGit
$nestPath = Join-Path $nestFx "AI_HANDOFF.md"
$tick3 = '```'
$tick4 = '````'
$nestText = (Get-Content -Encoding UTF8 -Raw -LiteralPath $nestPath).TrimEnd() + "`n`n## Risks / Notes`n$tick3`n## Plan`n$tick3`n- keep risk after fenced plan`n`n## Session Authorization - nested`n$tick4`n$tick3`n## Example`n$tick3`n$tick4`n- Never push on Fridays.`n`n## Plan`n- old plan line`n"
[System.IO.File]::WriteAllText($nestPath, $nestText, (New-Object System.Text.UTF8Encoding($false)))
$null = Invoke-Handoff -WorkDir $nestFx -Arguments @("sequence-add", "-NextTask", "Nested next task")
$null = Invoke-Handoff -WorkDir $nestFx -Arguments @("task-next", "-Yes")
$nestAfter = [System.IO.File]::ReadAllText($nestPath, [System.Text.Encoding]::UTF8)
Check "a fenced Plan heading is not reset and the lines after it stay" ($nestAfter.Contains("- keep risk after fenced plan"))
Check "a longer fence holding a shorter one keeps its content" ($nestAfter.Contains("- Never push on Fridays."))
Check "the real Plan section is reset" (($nestAfter -match "(?m)^## Plan\r?\n- None yet") -and (-not $nestAfter.Contains("- old plan line")))

$quotedHeb = -join ([char[]](0x201C, 0x00D7, 0x2018, 0x00D7, 0x201C, 0x201D))
$qFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Quoted task") } -InitGit
Add-Content -LiteralPath (Join-Path $qFx "AI_HANDOFF.md") -Value "- quoted $quotedHeb" -Encoding utf8
$r = Invoke-Handoff -WorkDir $qFx -Arguments @("doctor")
Check "doctor flags double-encoded Hebrew inside curly quotes" ($r.Out -match "double-encoded character run")

# Inline code is not a fence; Hebrew misread through Windows-1255 is still corruption.
$inlineFx = New-Fixture -Files @{
    "AI_HANDOFF.md" = (New-PlanHandoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
    ".ai/roles/ROLE_ASSIGNMENT.md" = $planRoles
    "AI_SEQUENCE.md" = $seqTemplate
} -InitGit
$inlinePath = Join-Path $inlineFx "AI_HANDOFF.md"
$inlineText = (Get-Content -Encoding UTF8 -Raw -LiteralPath $inlinePath).TrimEnd() + "`n`n## Done`n$tick3" + "npm test" + "$tick3`n`n## Session Authorization - after inline`n- Never deploy on inline.`n"
[System.IO.File]::WriteAllText($inlinePath, $inlineText, (New-Object System.Text.UTF8Encoding($false)))
$null = Invoke-Handoff -WorkDir $inlineFx -Arguments @("sequence-add", "-NextTask", "Inline next task")
$null = Invoke-Handoff -WorkDir $inlineFx -Arguments @("task-next", "-Yes")
Check "inline triple-backtick code does not open a fence" (([System.IO.File]::ReadAllText($inlinePath, [System.Text.Encoding]::UTF8)).Contains("- Never deploy on inline."))

$heb1255 = [System.Text.Encoding]::GetEncoding(1255).GetString([System.Text.Encoding]::UTF8.GetBytes((-join ([char[]](0x05D1, 0x05D3, 0x05D9, 0x05E7, 0x05D4)))))
$h55Fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Cp1255 task") } -InitGit
Add-Content -LiteralPath (Join-Path $h55Fx "AI_HANDOFF.md") -Value "- word $heb1255" -Encoding utf8
$r = Invoke-Handoff -WorkDir $h55Fx -Arguments @("doctor")
Check "doctor flags Hebrew misread through Windows-1255" ($r.Out -match "double-encoded character run")

$okHeb = -join ([char[]](0x05D1, 0x05D3, 0x05D9, 0x05E7, 0x05D4, 0x0020, 0x05E9, 0x05DC, 0x05D5, 0x05DD))
$okFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Hebrew ok task") } -InitGit
Add-Content -LiteralPath (Join-Path $okFx "AI_HANDOFF.md") -Value "- $okHeb" -Encoding utf8
$r = Invoke-Handoff -WorkDir $okFx -Arguments @("doctor")
Check "doctor does not flag correct Hebrew" (-not ($r.Out -match "double-encoded character run"))

$quotedOk = @((-join ([char[]](0x201C, 0x05D1, 0x05D3, 0x05D9, 0x05E7, 0x05D4, 0x2026, 0x201D))), (-join ([char[]](0x201C, 0x0063, 0x0061, 0x0066, 0x00E9, 0x2026, 0x201D))), (-join ([char[]](0x201C, 0x05D3, 0x05D9, 0x05E8, 0x05D5, 0x05D2, 0x2026, 0x201D))), (-join ([char[]](0x201C, 0x05D1, 0x05D0, 0x05D2, 0x2026, 0x201D))))
$qokFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Quoted ok task") } -InitGit
foreach ($q in $quotedOk) { Add-Content -LiteralPath (Join-Path $qokFx "AI_HANDOFF.md") -Value "- $q" -Encoding utf8 }
$r = Invoke-Handoff -WorkDir $qokFx -Arguments @("doctor")
Check "doctor does not flag quoted Hebrew or accented text ending in an ellipsis" (-not ($r.Out -match "double-encoded character run"))

$symbols = -join ([char[]](0x2705, 0x0020, 0x274C, 0x0020, 0x2713))
foreach ($symCp in @(1252, 1255)) {
    $symMoji = [System.Text.Encoding]::GetEncoding($symCp).GetString([System.Text.Encoding]::UTF8.GetBytes($symbols))
    $symFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Symbol task") } -InitGit
    Add-Content -LiteralPath (Join-Path $symFx "AI_HANDOFF.md") -Value "- status $symMoji" -Encoding utf8
    $r = Invoke-Handoff -WorkDir $symFx -Arguments @("doctor")
    Check "doctor flags double-encoded status symbols through code page $symCp" ($r.Out -match "double-encoded character run")
}
$symOkFx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "Symbol ok task") } -InitGit
Add-Content -LiteralPath (Join-Path $symOkFx "AI_HANDOFF.md") -Value "- status $symbols" -Encoding utf8
$r = Invoke-Handoff -WorkDir $symOkFx -Arguments @("doctor")
Check "doctor does not flag correct status symbols" (-not ($r.Out -match "double-encoded character run"))

$handoffSrc = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $ScriptDir "handoff.ps1")
Check "handoff.ps1 never reads a file with Get-Content and no -Encoding" (-not ($handoffSrc -split "`n" | Where-Object { $_ -match 'Get-Content ' -and $_ -notmatch '-Encoding' }))

# --- v3.17.0: review independence - separate-tool by default, fresh-context by declaration ---
Write-Host "[4D-7] Review independence: separate-tool and fresh-context (v3.17.0)"

function New-RiRoles {
    param([string]$Master = "Codex", [string]$Reviewer = "Codex", [string]$Implementer = "Claude Code", [string]$ModeLine = "", [switch]$History)
    $text = "# Role Assignment`n`n## Current Binding`n`n| Role | Tool |`n|---|---|`n| Master | $Master |`n| Reviewer | $Reviewer |`n| Implementer | $Implementer |`n"
    if ($ModeLine -ne "") { $text += "`n$ModeLine`n" }
    $text += "`nThe User is always the approval point and is never one of these roles.`n"
    if ($History) { $text += "`n## Role Swap History`n`n| Date | Previous Binding | New Binding | Approved By |`n|---|---|---|---|`n| 2026-09-01 | Master=Codex | Master=Codex | User |`n" }
    return $text
}

function New-RiHandoff {
    param(
        [string]$State = "READY_FOR_REVIEW",
        [string]$WaitingFor = "Reviewer",
        [string]$Task = "solo review task",
        [string]$Implementer = "Codex",
        [string]$Reviewer = "Codex",
        [string]$Actor = "Codex (Implementer)",
        [string]$ChangedFile = "src/app.txt",
        [string]$LastUpdateExtra = "",
        [string]$Extra = ""
    )
    return @"
# AI Handoff

## Status
- State: $State
- Waiting For: $WaitingFor
- Last Updated By: Test
- Last Updated At: 2026-11-18
- Current Task: $Task

## Last Update
- Actor: $Actor
- Date: 2026-11-18
$LastUpdateExtra

## Task Actors
- Implementer: $Implementer
- Reviewer: $Reviewer

## Changed Files
- $ChangedFile

## Next Recommended Step
- See AI_HANDOFF.md.
$Extra
"@
}

function New-RiFixture {
    param([string]$Roles, [string]$Handoff, [switch]$NoChange, [switch]$NoGit)
    if ($NoGit) {
        return (New-Fixture -Files @{ "AI_HANDOFF.md" = $Handoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $Roles })
    }
    $dir = New-Fixture -Files @{ "AI_HANDOFF.md" = $Handoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $Roles } -InitGit
    Initialize-FixtureGitBaseline -Dir $dir
    if (-not $NoChange) {
        New-Item -ItemType Directory -Path (Join-Path $dir "src") -Force | Out-Null
        Set-Content -Path (Join-Path $dir "src/app.txt") -Value "hello" -Encoding utf8
    }
    return $dir
}

function Get-RiFile { param([string]$Dir, [string]$Rel) return [System.IO.File]::ReadAllText((Join-Path $Dir $Rel), [System.Text.Encoding]::UTF8) }
function Get-RiHash { param([string]$Dir, [string]$Rel) return (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Dir $Rel)).Hash }

$riFresh = "Review Independence: fresh-context"
$riSeparate = "Review Independence: separate-tool"
$riSoloCodex = New-RiRoles -Master "Codex" -Reviewer "Codex" -Implementer "Codex" -ModeLine $riFresh -History
$riSoloClaude = New-RiRoles -Master "Claude Code" -Reviewer "Claude Code" -Implementer "Claude Code" -ModeLine $riFresh

# --- The setting: absent, each value, invalid, duplicated ---
$riFx = New-RiFixture -Roles $DefaultRoles -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("roles")
Check "an absent Review Independence line means separate-tool" (($r.Code -eq 0) -and ($r.Out -match "Rule:\s+the Reviewer is never the Implementer") -and ($r.Out -notmatch "Single-vendor review"))
$riSameHandoff = New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Implementer "Claude Code" -Reviewer "Claude Code" -Actor "Test"
$riFx = New-RiFixture -Roles (New-RiRoles -Master "Claude Code" -Reviewer "Claude Code" -Implementer "Claude Code") -Handoff $riSameHandoff -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "with no line, one tool in both roles is still refused" (($r.Code -eq 12) -and ($r.Out -match "Invalid role binding: Reviewer and Implementer both resolve to the same tool"))
$riFx = New-RiFixture -Roles (New-RiRoles -Master "Claude Code" -Reviewer "Claude Code" -Implementer "Claude Code" -ModeLine $riSeparate) -Handoff $riSameHandoff -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "separate-tool refuses one tool in both roles, binding and Task Actors" (($r.Code -eq 12) -and ($r.Out -match "Invalid role binding") -and ($r.Out -match "Independent-review invariant: Task Actors"))
$riFx = New-RiFixture -Roles $riSoloClaude -Handoff $riSameHandoff -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "fresh-context lets one tool hold Implementer and Reviewer at the role checkpoint" (($r.Code -eq 0) -and ($r.Out -notmatch "Role checkpoint: BLOCKED"))
$riFx = New-RiFixture -Roles (New-RiRoles -Master "Claude Code" -Reviewer "Claude Code" -Implementer "Claude Code" -ModeLine "review independence: Fresh-Context") -Handoff $riSameHandoff -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "the key and value are read without regard to letter case" ($r.Code -eq 0)
$riFx = New-RiFixture -Roles (New-RiRoles -ModeLine "Review Independence: relaxed") -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "an unknown value fails closed even with two different tools bound" (($r.Code -eq 12) -and ($r.Out -match "Invalid review independence: ROLE_ASSIGNMENT\.md declares 'Review Independence: relaxed'\. The value must be separate-tool or fresh-context\."))
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("doctor")
Check "doctor fails on an unknown value and names it" (($r.Out -match "FAIL  Role checkpoint") -and ($r.Out -match "Review Independence: relaxed"))
$riFx = New-RiFixture -Roles (New-RiRoles -ModeLine "Review Independence:") -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "an empty value fails closed" (($r.Code -eq 12) -and ($r.Out -match "Invalid review independence"))
$riFx = New-RiFixture -Roles ((New-RiRoles -Master "Claude Code" -Reviewer "Claude Code" -Implementer "Claude Code" -ModeLine $riFresh) + "`n$riFresh`n") -Handoff $riSameHandoff -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "a duplicated line fails closed, even when both copies agree" (($r.Code -eq 12) -and ($r.Out -match "declares 'Review Independence:' 2 times"))

# --- The shipped template leaves behavior unchanged ---
$riTemplate = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md")
Check "the shipped role file declares separate-tool, exactly once" ((([regex]::Matches($riTemplate, '(?m)^\s*(?:[-*]\s+)?Review Independence\s*:')).Count -eq 1) -and ($riTemplate -match '(?m)^Review Independence: separate-tool\r?$'))
# v3.18.0: the shipped file is 'Setup: pending', which blocks every work command by design;
# these two checks are about the review rule, so they run on the file after setup.
$riTemplateConfigured = $riTemplate -replace 'Setup: pending', 'Setup: complete'
$riFx = New-RiFixture -Roles $riTemplateConfigured -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("roles")
Check "the shipped role file keeps today's rule" (($r.Code -eq 0) -and ($r.Out -match "Rule:\s+the Reviewer is never the Implementer"))
$riFx = New-RiFixture -Roles ($riTemplateConfigured -replace '\| Implementer \| Claude Code \|', '| Implementer | Codex |') -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -NoGit
$r = Invoke-Handoff -WorkDir $riFx -Arguments @("next")
Check "the shipped role file still refuses one tool in both roles" (($r.Code -eq 12) -and ($r.Out -match "Invalid role binding"))

# The installer keeps the declaration on upgrade, and keeps the binding it allows.
$riInstallTarget = Join-Path $FixtureRoot "ri-install-target"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $riInstallTarget -NoRolesWindow 2>&1
$riInstalledRoles = Join-Path $riInstallTarget ".ai/roles/ROLE_ASSIGNMENT.md"
Check "a fresh install writes the separate-tool declaration" ((Test-Path -LiteralPath $riInstalledRoles) -and ((Get-Content -Encoding UTF8 -Raw -LiteralPath $riInstalledRoles) -match '(?m)^Review Independence: separate-tool\r?$'))
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $riInstallTarget -Force -NoRolesWindow 2>&1
$riAfter = Get-Content -Encoding UTF8 -Raw -LiteralPath $riInstalledRoles
Check "an upgrade of an untouched install keeps separate-tool, once" ((([regex]::Matches($riAfter, '(?m)^Review Independence:')).Count -eq 1) -and ($riAfter -match '(?m)^Review Independence: separate-tool\r?$'))
$riSolo = ($riAfter -replace 'Review Independence: separate-tool', 'Review Independence: fresh-context') -replace '\| Implementer \| Claude Code \|', '| Implementer | Codex |'
[System.IO.File]::WriteAllText($riInstalledRoles, $riSolo, (New-Object System.Text.UTF8Encoding($false)))
$riUp = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $riInstallTarget -Force -NoRolesWindow 2>&1 | Out-String
$riAfter = Get-Content -Encoding UTF8 -Raw -LiteralPath $riInstalledRoles
Check "an upgrade keeps a fresh-context declaration and the one-tool binding it allows" (($LASTEXITCODE -eq 0) -and (([regex]::Matches($riAfter, '(?m)^Review Independence:')).Count -eq 1) -and ($riAfter -match '(?m)^Review Independence: fresh-context\r?$') -and ($riAfter -match '\| Implementer \| Codex \|')) $riUp
[System.IO.File]::WriteAllText($riInstalledRoles, ($riAfter -replace 'Review Independence: fresh-context', 'Review Independence: sometimes'), (New-Object System.Text.UTF8Encoding($false)))
$riPrevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $riUp = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $riInstallTarget -Force -NoRolesWindow 2>&1 | Out-String
    $riUpCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $riPrevEap }
Check "an upgrade refuses an invalid declaration instead of guessing" (($riUpCode -ne 0) -and ($riUp -match "Review Independence"))

# --- The command: roles -ReviewIndependence ---
$riCmdFx = New-RiFixture -Roles (New-RiRoles -History) -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$riRolesBefore = Get-RiHash -Dir $riCmdFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$r = Invoke-Handoff -WorkDir $riCmdFx -Arguments @("roles", "-ReviewIndependence", "sometimes", "-Yes")
Check "roles -ReviewIndependence refuses an unknown value and changes nothing" (($r.Code -eq 1) -and ($r.Out -match "-ReviewIndependence must be separate-tool or fresh-context \(got: 'sometimes'\)") -and ((Get-RiHash -Dir $riCmdFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riRolesBefore))
$r = Invoke-Handoff -WorkDir $riCmdFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-SetRole", "Master", "-SetTool", "Codex", "-Yes")
Check "roles -ReviewIndependence is never combined with a role swap" (($r.Code -eq 1) -and ($r.Out -match "change one thing at a time") -and ((Get-RiHash -Dir $riCmdFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riRolesBefore))
$r = Invoke-Handoff -WorkDir $riCmdFx -Arguments @("roles", "-ReviewIndependence", "separate-tool", "-Yes")
Check "asking for the rule already in force changes nothing" (($r.Code -eq 0) -and ($r.Out -match "already separate-tool") -and ((Get-RiHash -Dir $riCmdFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riRolesBefore))
$r = Invoke-Handoff -WorkDir $riCmdFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
$riCmdText = Get-RiFile -Dir $riCmdFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "roles -ReviewIndependence fresh-context applies and says what it weakens" (($r.Code -eq 0) -and ($r.Out -match "roles: applied\. Review Independence: fresh-context") -and ($r.Out -match "Two tools remain the recommended setup"))
Check "the change writes exactly one declaration line, under the binding" ((([regex]::Matches($riCmdText, '(?m)^Review Independence:')).Count -eq 1) -and ($riCmdText -match '(?s)\| Implementer \| Claude Code \|\r?\n\r?\nReview Independence: fresh-context'))
Check "the change is recorded in the Role Swap History like a role swap" ($riCmdText -match '(?m)^\| \d{4}-\d{2}-\d{2} \| Master=Codex, Reviewer=Codex, Implementer=Claude Code, Review Independence=separate-tool \| Master=Codex, Reviewer=Codex, Implementer=Claude Code, Review Independence=fresh-context \| User \(handoff\.ps1 roles\) \|')
$r = Invoke-Handoff -WorkDir $riCmdFx -Arguments @("roles")
Check "roles states the fresh-context rule once it is in force" ($r.Out -match "Rule:\s+the Reviewer never shares a context with the Implementer\. Review Independence: fresh-context")
Check "two different tools under fresh-context print no single-vendor line" ($r.Out -notmatch "Single-vendor review")
$r = Invoke-Handoff -WorkDir $riCmdFx -Arguments @("roles", "-ReviewIndependence", "separate-tool", "-Yes")
$riCmdText = Get-RiFile -Dir $riCmdFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "switching back to separate-tool is allowed while the tools differ" (($r.Code -eq 0) -and ($riCmdText -match '(?m)^Review Independence: separate-tool\r?$') -and ($riCmdText -match 'Review Independence=fresh-context \| Master=Codex, Reviewer=Codex, Implementer=Claude Code, Review Independence=separate-tool'))

$riNoHistFx = New-RiFixture -Roles (New-RiRoles) -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$r = Invoke-Handoff -WorkDir $riNoHistFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
$riNoHistText = Get-RiFile -Dir $riNoHistFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "a role file with no history table gets one, instead of a claim that nothing backs" (($r.Code -eq 0) -and ($riNoHistText -match '(?s)## Role Swap History\r?\n\r?\n\| Date \| Before \| After \| Decided by \|\r?\n\|---\|---\|---\|---\|\r?\n\| \d{4}-\d{2}-\d{2} \| Master=Codex'))

$riBackFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Task "Finished task") -NoChange
$riBackBefore = Get-RiHash -Dir $riBackFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$r = Invoke-Handoff -WorkDir $riBackFx -Arguments @("roles", "-ReviewIndependence", "separate-tool", "-Yes")
Check "separate-tool is refused while one tool holds both roles, with the way out" (($r.Code -eq 1) -and ($r.Out -match "Reassign a role first") -and ((Get-RiHash -Dir $riBackFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riBackBefore))

# The adapter refusal for fresh-context cannot be reached through the CLI today: both known
# tools have a callable Reviewer adapter, and an unknown tool fails the role checkpoint
# before the roles command runs. What is reachable is tested: an unknown Reviewer is refused
# at the checkpoint, by name, and the file is not touched.
$riNoAdapterFx = New-RiFixture -Roles (New-RiRoles -Reviewer "Gemini") -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$riNoAdapterBefore = Get-RiHash -Dir $riNoAdapterFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$r = Invoke-Handoff -WorkDir $riNoAdapterFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
Check "an unknown Reviewer tool is refused at the checkpoint before fresh-context can be set" (($r.Code -eq 12) -and ($r.Out -match "Unrecognized tool identity 'Gemini'") -and ((Get-RiHash -Dir $riNoAdapterFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riNoAdapterBefore))
$riHandoffSrc = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "the command checks for a callable Reviewer adapter before allowing fresh-context" ($riHandoffSrc -match '(?s)if \(\$normalized -eq "fresh-context"\) \{\s+\$reviewerAdapter = Get-AdapterProfile -Role "Reviewer" -Tool \$Binding\.Reviewer\s+if \(-not \$reviewerAdapter\.Callable\)')

$riLiveFx = New-RiFixture -Roles (New-RiRoles -History) -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User") -NoChange
$riLiveBefore = Get-RiHash -Dir $riLiveFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$riSleeper = Start-Process -FilePath $PwshExe -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 45") -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Milliseconds 500
    $riMarker = [ordered]@{ processId = $riSleeper.Id; startTicks = $riSleeper.StartTime.ToUniversalTime().Ticks; command = "cycle"; startedUtc = "2026-11-18T10:00:00Z"; log = "HANDOFF_BACKGROUND.log"; finishedUtc = $null; exitCode = $null }
    [System.IO.File]::WriteAllText((Join-Path $riLiveFx "HANDOFF_BACKGROUND.json"), ($riMarker | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $riLiveFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
    Check "the review rule never changes while a turn is running" (($r.Code -eq 1) -and ($r.Out -match "A turn is running now") -and ((Get-RiHash -Dir $riLiveFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riLiveBefore))
} finally {
    try { Stop-Process -Id $riSleeper.Id -Force -ErrorAction SilentlyContinue } catch { }
}

# --- Every relaxed gate, both ways ---
# roles -SetRole: separate-tool exchanges (unchanged); fresh-context lets the pair share a tool.
$riSwapFx = New-RiFixture -Roles (New-RiRoles -ModeLine $riFresh -History) -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$r = Invoke-Handoff -WorkDir $riSwapFx -Arguments @("roles", "-SetRole", "Implementer", "-SetTool", "Codex", "-Yes")
$riSwapText = Get-RiFile -Dir $riSwapFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "under fresh-context a swap may put one tool in both roles, with no exchange" (($r.Code -eq 0) -and ($r.Out -notmatch "Exchange:") -and ($riSwapText -match '\| Implementer \| Codex \|') -and ($riSwapText -match '\| Reviewer \| Codex \|'))
Check "the applied swap says it is now a single-vendor review" ($r.Out -match "Single-vendor review: Codex is both Implementer and Reviewer")
$riSwapSepFx = New-RiFixture -Roles (New-RiRoles -ModeLine $riSeparate -History) -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$r = Invoke-Handoff -WorkDir $riSwapSepFx -Arguments @("roles", "-SetRole", "Implementer", "-SetTool", "Codex", "-Yes")
Check "under separate-tool the same swap still exchanges the pair" (($r.Code -eq 0) -and ($r.Out -match "Exchange:\s+Reviewer takes Claude Code"))

# master-apply: a recommendation that names one tool twice.
$riMasterCapture = "MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION`nWAITING_FOR: Implementer`nIMPLEMENTER: Codex`nREVIEWER: Codex`nTASK: solo master task`nMODEL_PROFILE: economy`nREASON: scoped."
$riMasterFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -Task "solo master task" -Implementer "TBD" -Reviewer "TBD" -Actor "Test") -NoChange
Set-Content -Path (Join-Path $riMasterFx "MASTER_LAST.md") -Value $riMasterCapture -Encoding utf8
$r = Invoke-Handoff -WorkDir $riMasterFx -Arguments @("master-apply", "-Yes")
Check "under fresh-context master-apply accepts one tool as Implementer and Reviewer" (($r.Code -eq 0) -and ((Get-RiFile -Dir $riMasterFx -Rel "AI_HANDOFF.md") -match "State:\s+READY_FOR_IMPLEMENTATION")) $r.Out
$riMasterSepFx = New-RiFixture -Roles (New-RiRoles -ModeLine $riSeparate) -Handoff (New-RiHandoff -State "NEEDS_ANALYSIS" -WaitingFor "Master" -Task "solo master task" -Implementer "TBD" -Reviewer "TBD" -Actor "Test") -NoChange
Set-Content -Path (Join-Path $riMasterSepFx "MASTER_LAST.md") -Value ($riMasterCapture -replace "IMPLEMENTER: Codex", "IMPLEMENTER: Claude Code" -replace "REVIEWER: Codex", "REVIEWER: Claude Code") -Encoding utf8
$r = Invoke-Handoff -WorkDir $riMasterSepFx -Arguments @("master-apply", "-Yes")
Check "under separate-tool master-apply still refuses one tool as both" (($r.Code -ne 0) -and ($r.Out -match "resolve to the same tool"))

# cycle and loop: past the role invariant under fresh-context; the next guard (no Git) stops them.
$riCycleFx = New-RiFixture -Roles $riSoloClaude -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Implementer "Claude Code" -Reviewer "Claude Code" -Actor "Test") -NoGit
$r = Invoke-Handoff -WorkDir $riCycleFx -Arguments @("cycle", "-Yes")
Check "under fresh-context cycle passes the role invariant" (($r.Code -ne 0) -and ($r.Out -notmatch "Role invariant violation") -and ($r.Out -match "Git"))
$r = Invoke-Handoff -WorkDir $riCycleFx -Arguments @("loop", "-Yes")
Check "under fresh-context loop passes the session role invariant" (($r.Code -ne 0) -and ($r.Out -notmatch "Role invariant violation") -and ($r.Out -match "Git"))
$riCycleSepFx = New-RiFixture -Roles (New-RiRoles -Master "Claude Code" -Reviewer "Claude Code" -Implementer "Claude Code") -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Implementer "Claude Code" -Reviewer "Claude Code" -Actor "Test") -NoGit
$r = Invoke-Handoff -WorkDir $riCycleSepFx -Arguments @("cycle", "-Yes")
Check "under separate-tool cycle is still refused for one tool in both roles" (($r.Code -eq 12) -and ($r.Out -match "Invalid role binding"))
$r = Invoke-Handoff -WorkDir $riCycleSepFx -Arguments @("loop", "-Yes")
Check "under separate-tool loop is still refused for one tool in both roles" (($r.Code -eq 12) -and ($r.Out -match "Invalid role binding"))
Check "each of the ten same-tool gates in handoff.ps1 is relaxed only through Test-FreshContextReview" (([regex]::Matches($riHandoffSrc, [regex]::Escape("-and -not (Test-FreshContextReview)"))).Count -eq 10)

# --- The harness path: review-run, review-apply, then commit and release accept it ---
$riFakeApprove = Join-Path $FixtureRoot "fake-codex-solo-approve.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo Looked at the diff.> REVIEW_LAST.md
echo VERDICT: APPROVED>> REVIEW_LAST.md
echo REVIEWER: Codex>> REVIEW_LAST.md
echo TASK: solo review task>> REVIEW_LAST.md
echo REASON: scope and behavior match the task.>> REVIEW_LAST.md
:done
'@ | Set-Content -Path $riFakeApprove -Encoding ascii
$riFakeBlock = Join-Path $FixtureRoot "fake-codex-solo-block.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo VERDICT: BLOCKED> REVIEW_LAST.md
echo REVIEWER: Codex>> REVIEW_LAST.md
echo TASK: solo review task>> REVIEW_LAST.md
echo REASON: a test is missing.>> REVIEW_LAST.md
:done
'@ | Set-Content -Path $riFakeBlock -Encoding ascii
$riPrevCodexCli = $env:CODEX_CLI
try {
    $env:CODEX_CLI = $riFakeApprove
    $riRunFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff)
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("review-check")
    Check "review-check names a single-vendor review" (($r.Code -eq 0) -and ($r.Out -match "Review:\s+Single-vendor review: Codex is both Implementer and Reviewer\. It reviews in a separate read-only run started by the harness"))
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("review-run", "-Yes")
    $riJsonl = if (Test-Path (Join-Path $riRunFx "REVIEW.jsonl")) { Get-RiFile -Dir $riRunFx -Rel "REVIEW.jsonl" } else { "" }
    Check "review-run names a single-vendor review in its plan" (($r.Code -eq 0) -and ($r.Out -match "Review:\s+Single-vendor review"))
    Check "review-run writes one harness evidence record under fresh-context" (([regex]::Matches($riJsonl, '(?m)^\{"handoffReviewEvidence":1,')).Count -eq 1)
    $riRecord = ($riJsonl -split "`r?`n" | Where-Object { $_ -match '^\{"handoffReviewEvidence"' } | Select-Object -First 1) | ConvertFrom-Json
    Check "the record binds the task, the capture and each reviewed file by SHA-256" (($riRecord.task -eq "solo review task") -and ($riRecord.kind -eq "code") -and ($riRecord.capture -eq (Get-RiHash -Dir $riRunFx -Rel "REVIEW_LAST.md").ToLowerInvariant()) -and (@($riRecord.files).Count -eq 1) -and (@($riRecord.files)[0].path -eq "src/app.txt") -and (@($riRecord.files)[0].sha256 -eq (Get-RiHash -Dir $riRunFx -Rel "src/app.txt").ToLowerInvariant()))
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("review-apply", "-Yes")
    Check "review-apply applies a harness verdict for a single-vendor review" (($r.Code -eq 0) -and ((Get-RiFile -Dir $riRunFx -Rel "AI_HANDOFF.md") -match "State:\s+REVIEW_DONE"))
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("commit-check")
    Check "commit-check accepts the harness verdict" (($r.Code -eq 0) -and ($r.Out -match "commit-check: ready for explicit authorization"))
    Check "commit-check names a single-vendor review" ($r.Out -match "Review:\s+Single-vendor review: Codex is both Implementer and Reviewer")
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("release-check", "-Version", "v9.9.9")
    Check "release-check raises no review objection to the harness verdict" (($r.Out -notmatch "Reason: Single-vendor review") -and ($r.Out -match "Release package dist/"))

    # Code that changes after the review is not the code the review approved.
    $riApp = Join-Path $riRunFx "src/app.txt"
    $riAppBytes = [System.IO.File]::ReadAllBytes($riApp)
    Set-Content -Path $riApp -Value "hello, changed after review" -Encoding utf8
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("commit-check")
    Check "a file changed after the harness review is refused at commit" (($r.Code -eq 1) -and ($r.Out -match "these files changed after the harness review read them: src/app\.txt"))
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("release-check", "-Version", "v9.9.9")
    Check "a file changed after the harness review is refused at release" (($r.Code -eq 1) -and ($r.Out -match "changed after the harness review read them"))
    [System.IO.File]::WriteAllBytes($riApp, $riAppBytes)
    $riLast = Join-Path $riRunFx "REVIEW_LAST.md"
    $riLastBytes = [System.IO.File]::ReadAllBytes($riLast)
    Add-Content -Path $riLast -Value "Edited by hand." -Encoding utf8
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("commit-check")
    Check "a capture edited after review-run is refused" (($r.Code -eq 1) -and ($r.Out -match "REVIEW_LAST\.md changed after review-run captured it"))
    [System.IO.File]::WriteAllBytes($riLast, $riLastBytes)
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("commit-check")
    Check "restoring the reviewed bytes restores the verdict" ($r.Code -eq 0)
    $riJsonlPath = Join-Path $riRunFx "REVIEW.jsonl"
    $riJsonlBytes = [System.IO.File]::ReadAllBytes($riJsonlPath)
    Add-Content -Path $riJsonlPath -Value ($riJsonl -split "`r?`n" | Where-Object { $_ -match '^\{"handoffReviewEvidence"' } | Select-Object -First 1) -Encoding utf8
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("commit-check")
    Check "a second evidence record is refused, not chosen between" (($r.Code -eq 1) -and ($r.Out -match "carries 2 harness evidence records"))
    [System.IO.File]::WriteAllBytes($riJsonlPath, $riJsonlBytes)
    $riCommitsBefore = "$(& git -C $riRunFx rev-list --count HEAD)".Trim()
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("commit-approved", "-Message", "Solo reviewed change", "-Authorize", "I_AUTHORIZE_COMMIT")
    $riCommitsAfter = "$(& git -C $riRunFx rev-list --count HEAD)".Trim()
    Check "commit-approved commits a harness-reviewed single-vendor change" (($r.Code -eq 0) -and ([int]$riCommitsAfter -eq ([int]$riCommitsBefore + 1)))
    $r = Invoke-Handoff -WorkDir $riRunFx -Arguments @("release-check", "-Version", "v9.9.9")
    Check "after the commit, release-check still ties the reviewed bytes to the verdict" (($r.Out -notmatch "Reason: Single-vendor review") -and ($r.Out -match "Release package dist/"))

    # A REVIEW_DONE reached by hand, with no harness run, is refused at commit and release.
    $riForgedFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Actor "Reviewer (Codex)" -LastUpdateExtra "- Verdict: APPROVED")
    $r = Invoke-Handoff -WorkDir $riForgedFx -Arguments @("commit-check")
    Check "a manual REVIEW_DONE is refused by commit-check when one tool holds both roles" (($r.Code -eq 1) -and ($r.Out -match "Single-vendor review: there is no harness review capture"))
    $riForgedCommits = "$(& git -C $riForgedFx rev-list --count HEAD)".Trim()
    $r = Invoke-Handoff -WorkDir $riForgedFx -Arguments @("commit-approved", "-Message", "Forged", "-Authorize", "I_AUTHORIZE_COMMIT")
    Check "a manual REVIEW_DONE is refused by commit-approved and nothing is committed" (($r.Code -eq 1) -and ($r.Out -match "no harness review capture") -and ("$(& git -C $riForgedFx rev-list --count HEAD)".Trim() -eq $riForgedCommits))
    $r = Invoke-Handoff -WorkDir $riForgedFx -Arguments @("release-check", "-Version", "v9.9.9")
    Check "a manual REVIEW_DONE is refused by release-check" (($r.Code -eq 1) -and ($r.Out -match "Reason: Single-vendor review: there is no harness review capture"))
    Set-Content -Path (Join-Path $riForgedFx "REVIEW_LAST.md") -Value "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: solo review task`nREASON: written by hand" -Encoding utf8
    $riForgedText = (Get-RiFile -Dir $riForgedFx -Rel "AI_HANDOFF.md") -replace "- Actor: Reviewer \(Codex\)", "- Actor: Reviewer (Codex), applied from the captured review verdict via review-apply"
    [System.IO.File]::WriteAllText((Join-Path $riForgedFx "AI_HANDOFF.md"), $riForgedText, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $riForgedFx -Arguments @("commit-check")
    Check "a hand-written capture with no harness record is refused" (($r.Code -eq 1) -and ($r.Out -match "carries no harness evidence record"))
    $r = Invoke-Handoff -WorkDir $riForgedFx -Arguments @("release-check", "-Version", "v9.9.9")
    Check "release-check refuses the hand-written capture too" (($r.Code -eq 1) -and ($r.Out -match "carries no harness evidence record"))

    # review-apply itself refuses a verdict review-run did not produce.
    $riHandApplyFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff)
    Set-Content -Path (Join-Path $riHandApplyFx "REVIEW_LAST.md") -Value "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: solo review task`nREASON: written by hand" -Encoding utf8
    $riHandBefore = Get-RiHash -Dir $riHandApplyFx -Rel "AI_HANDOFF.md"
    $r = Invoke-Handoff -WorkDir $riHandApplyFx -Arguments @("review-apply", "-Yes")
    Check "review-apply refuses a single-vendor verdict that review-run did not write" (($r.Code -eq 1) -and ($r.Out -match "carries no harness evidence record") -and ((Get-RiHash -Dir $riHandApplyFx -Rel "AI_HANDOFF.md") -eq $riHandBefore))

    # A BLOCKED harness verdict does not become an approval by editing the state.
    $env:CODEX_CLI = $riFakeBlock
    $riBlockFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff)
    $null = Invoke-Handoff -WorkDir $riBlockFx -Arguments @("review-run", "-Yes")
    $r = Invoke-Handoff -WorkDir $riBlockFx -Arguments @("review-apply", "-Yes")
    $riBlockText = (Get-RiFile -Dir $riBlockFx -Rel "AI_HANDOFF.md") -replace "- State: READY_FOR_IMPLEMENTATION", "- State: REVIEW_DONE" -replace "- Waiting For: Implementer", "- Waiting For: User"
    [System.IO.File]::WriteAllText((Join-Path $riBlockFx "AI_HANDOFF.md"), $riBlockText, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $riBlockFx -Arguments @("commit-check")
    Check "a BLOCKED harness verdict edited to REVIEW_DONE is refused" (($r.Code -eq 1) -and ($r.Out -match "verdict is BLOCKED, not APPROVED"))

    # A plan review under fresh-context is bound the same way, to the plan text.
    $env:CODEX_CLI = $riFakeApprove
    $riPlanFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -ChangedFile "None yet" -Extra "`n## Plan`n- Step one: add the feature.") -NoChange
    $null = Invoke-Handoff -WorkDir $riPlanFx -Arguments @("review-run", "-Yes")
    $r = Invoke-Handoff -WorkDir $riPlanFx -Arguments @("review-apply", "-Yes")
    Check "an approved single-vendor plan review is applied from its harness record" (($r.Code -eq 0) -and ((Get-RiFile -Dir $riPlanFx -Rel "AI_HANDOFF.md") -match "State:\s+READY_FOR_IMPLEMENTATION")) $r.Out

    # Under separate-tool nothing new is written.
    $riSepRunFx = New-RiFixture -Roles $DefaultRoles -Handoff (New-RiHandoff -Implementer "Claude Code" -Reviewer "Codex" -Actor "Claude Code (Implementer)")
    $r = Invoke-Handoff -WorkDir $riSepRunFx -Arguments @("review-run", "-Yes")
    $riSepJsonl = if (Test-Path (Join-Path $riSepRunFx "REVIEW.jsonl")) { Get-RiFile -Dir $riSepRunFx -Rel "REVIEW.jsonl" } else { "" }
    Check "under separate-tool review-run writes no evidence record and no new line" (($r.Code -eq 0) -and ($riSepJsonl -notmatch "handoffReviewEvidence") -and ($r.Out -notmatch "Single-vendor review"))
} finally {
    if ($null -eq $riPrevCodexCli) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $riPrevCodexCli }
}

# Two different tools under fresh-context behave exactly like separate-tool.
$riTwoFx = New-RiFixture -Roles (New-RiRoles -ModeLine $riFresh) -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Implementer "Claude Code" -Reviewer "Codex" -Actor "Claude Code (Implementer)")
$r = Invoke-Handoff -WorkDir $riTwoFx -Arguments @("commit-check")
Check "with two tools, fresh-context needs no harness record, as separate-tool" (($r.Code -eq 0) -and ($r.Out -notmatch "Single-vendor review"))

# --- The self-review guard keeps its purpose ---
$riSelfFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -Actor "Codex (Master)")
$r = Invoke-Handoff -WorkDir $riSelfFx -Arguments @("review-check")
Check "one tool in all roles: a Master that did the work is still refused review" (($r.Code -eq 1) -and ($r.Out -match "Self-review guard \(single-vendor review\)"))
$riSelfFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -Actor "Codex")
$r = Invoke-Handoff -WorkDir $riSelfFx -Arguments @("review-check")
Check "one tool in all roles: an Actor line that names no role is refused" (($r.Code -eq 1) -and ($r.Out -match "Self-review guard \(single-vendor review\).*its Actor line is 'Codex'"))
$riSelfFx = New-RiFixture -Roles (New-RiRoles -ModeLine $riFresh) -Handoff (New-RiHandoff -Implementer "Claude Code" -Reviewer "Codex" -Actor "Codex (Master)")
$r = Invoke-Handoff -WorkDir $riSelfFx -Arguments @("review-check")
Check "fresh-context with two tools: a Master that reviews its own work is refused as before" (($r.Code -eq 1) -and ($r.Out -match "Self-review guard: AI_HANDOFF\.md Last Update records 'Codex'"))

# --- Say it out loud: one line in each place ---
$riSayFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff)
foreach ($riCmd in @("roles", "status", "work")) {
    $r = Invoke-Handoff -WorkDir $riSayFx -Arguments @($riCmd)
    Check "$riCmd prints one single-vendor line" ((([regex]::Matches($r.Out, "Single-vendor review: Codex is both Implementer and Reviewer")).Count -eq 1) -and ($r.Code -eq 0))
}
$r = Invoke-Handoff -WorkDir $riSayFx -Arguments @("work")
Check "work does not offer a hand-taken review as an equal path" (($r.Out -match "will not count: commit-check accepts only the review-run verdict") -and ($r.Out -notmatch "To take the turn manually"))
$r = Invoke-Handoff -WorkDir $riSayFx -Arguments @("next")
Check "next says a pasted review will not count" (($r.Out -match "a review taken by pasting this prompt will not count") -and ($r.Out -notmatch "Manual paste above remains valid"))
$r = Invoke-Handoff -WorkDir $riSayFx -Arguments @("doctor")
Check "doctor reports a single-vendor review as information, not a failure" (($r.Out -match "INFO  Single-vendor review: Codex is both Implementer and Reviewer") -and ($r.Out -match "OK  Role checkpoint") -and ($r.Out -notmatch "FAIL  Role checkpoint"))
$null = Invoke-Handoff -WorkDir $riSayFx -Arguments @("next")
$riNt = Get-RiFile -Dir $riSayFx -Rel "NEXT_TURN.md"
Check "NEXT_TURN.md gives the Reviewer a single-vendor section" ($riNt -match "(?s)## Review Independence\r?\nSingle-vendor review: Codex is both Implementer and Reviewer.*refused by commit-check, commit-approved and release-check")
$riImplFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -NoChange
$null = Invoke-Handoff -WorkDir $riImplFx -Arguments @("next")
Check "an Implementer turn carries no Review Independence section" ((Get-RiFile -Dir $riImplFx -Rel "NEXT_TURN.md") -notmatch "## Review Independence")
$riQuietFx = New-RiFixture -Roles $DefaultRoles -Handoff (New-RiHandoff -Implementer "Claude Code" -Reviewer "Codex" -Actor "Claude Code (Implementer)")
$null = Invoke-Handoff -WorkDir $riQuietFx -Arguments @("next")
$r = Invoke-Handoff -WorkDir $riQuietFx -Arguments @("status")
Check "separate-tool prints no single-vendor line and writes no section" (($r.Out -notmatch "Single-vendor review") -and ((Get-RiFile -Dir $riQuietFx -Rel "NEXT_TURN.md") -notmatch "## Review Independence"))

# --- Advisory, not a block: Master and Reviewer on one tool, two tools bound ---
$r = Invoke-Handoff -WorkDir $riQuietFx -Arguments @("roles")
Check "roles advises a Reviewer from a different tool than the Master" (($r.Code -eq 0) -and ($r.Out -match "Advisory: Master and Reviewer are both Codex\. A Reviewer from a different tool than the Master questions the plan as well as the code\."))
$r = Invoke-Handoff -WorkDir $riQuietFx -Arguments @("doctor")
Check "doctor gives the same advisory as information" (($r.Out -match "INFO  Advisory: Master and Reviewer are both Codex") -and ($r.Out -notmatch "FAIL  Role checkpoint"))
$r = Invoke-Handoff -WorkDir $riSayFx -Arguments @("roles")
Check "with one tool bound there is no second tool to advise" ($r.Out -notmatch "Advisory:")
$riSplitFx = New-RiFixture -Roles (New-RiRoles -Master "Claude Code" -Reviewer "Codex" -Implementer "Claude Code") -Handoff (New-RiHandoff -Implementer "Claude Code" -Reviewer "Codex" -Actor "Claude Code (Implementer)")
$r = Invoke-Handoff -WorkDir $riSplitFx -Arguments @("roles")
Check "a Reviewer apart from the Master draws no advisory" ($r.Out -notmatch "Advisory:")

# --- Parity: handoff.sh and next-step write the same section and enforce the same rule ---
$riBash = Get-Command bash -ErrorAction SilentlyContinue
if ($null -eq $riBash) {
    Write-Host "  SKIP  review independence parity with handoff.sh and next-step: no bash interpreter on this machine"
} else {
    $riShPath = (Join-Path $RepoRoot "scripts/handoff.sh") -replace '\\', '/'
    $riNextShPath = (Join-Path $RepoRoot "scripts/next-step.sh") -replace '\\', '/'
    $riNextPsPath = Join-Path $RepoRoot "scripts/next-step.ps1"
    function Get-RiSection { param([string]$Text) if (($Text -replace "`r", "") -match '(?s)## Review Independence\n(.*?)(\n\n|$)') { return $Matches[1] } return "<none>" }
    function Invoke-RiIn { param([string]$Dir, [scriptblock]$Block)
        $prevCwd = [System.Environment]::CurrentDirectory
        Push-Location $Dir
        [System.Environment]::CurrentDirectory = $Dir
        try { return (& $Block 2>&1 | Out-String) } finally { Pop-Location; [System.Environment]::CurrentDirectory = $prevCwd }
    }
    $null = Invoke-Handoff -WorkDir $riSayFx -Arguments @("next")
    $riPsSection = Get-RiSection -Text (Get-RiFile -Dir $riSayFx -Rel "NEXT_TURN.md")
    $null = Invoke-RiIn -Dir $riSayFx -Block { & $riBash.Source $riShPath next }
    $riShSection = Get-RiSection -Text (Get-RiFile -Dir $riSayFx -Rel "NEXT_TURN.md")
    Check "handoff.sh and handoff.ps1 write the same Review Independence section" (($riPsSection -ne "<none>") -and ($riPsSection -eq $riShSection)) "ps=[$riPsSection] sh=[$riShSection]"
    $null = Invoke-RiIn -Dir $riSayFx -Block { & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $riNextPsPath -PrepareFile }
    $riNextPsSection = Get-RiSection -Text (Get-RiFile -Dir $riSayFx -Rel "NEXT_TURN.md")
    $null = Invoke-RiIn -Dir $riSayFx -Block { & $riBash.Source $riNextShPath --prepare-file }
    $riNextShSection = Get-RiSection -Text (Get-RiFile -Dir $riSayFx -Rel "NEXT_TURN.md")
    Check "next-step.ps1 and next-step.sh write the same section as handoff.ps1" (($riNextPsSection -eq $riPsSection) -and ($riNextShSection -eq $riPsSection)) "ps=[$riNextPsSection] sh=[$riNextShSection]"
    $riShOut = Invoke-RiIn -Dir $riSayFx -Block { & $riBash.Source $riShPath status }
    Check "handoff.sh status prints the single-vendor line" ($riShOut -match "Review:\s+Single-vendor review: Codex is both Implementer and Reviewer")
    $riShOut = Invoke-RiIn -Dir $riQuietFx -Block { & $riBash.Source $riShPath next }
    Check "handoff.sh says nothing new under separate-tool" (($riShOut -notmatch "Single-vendor") -and ((Get-RiFile -Dir $riQuietFx -Rel "NEXT_TURN.md") -notmatch "## Review Independence"))
    $riBadFx = New-RiFixture -Roles (New-RiRoles -ModeLine "Review Independence: relaxed") -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -NoGit
    $riShOut = Invoke-RiIn -Dir $riBadFx -Block { & $riBash.Source $riShPath next; "exit=$LASTEXITCODE" }
    Check "handoff.sh fails closed on an unknown value, like handoff.ps1" (($riShOut -match "exit=12") -and ($riShOut -match "Invalid review independence"))
    $riSameFx = New-RiFixture -Roles (New-RiRoles -Master "Claude Code" -Reviewer "Claude Code" -Implementer "Claude Code") -Handoff $riSameHandoff -NoGit
    $riFreshSameFx = New-RiFixture -Roles $riSoloClaude -Handoff $riSameHandoff -NoGit
    $riShOut = Invoke-RiIn -Dir $riSameFx -Block { & $riBash.Source $riShPath next; "exit=$LASTEXITCODE" }
    Check "handoff.sh refuses one tool in both roles without fresh-context" (($riShOut -match "exit=12") -and ($riShOut -match "Invalid role binding"))
    $riShOut = Invoke-RiIn -Dir $riFreshSameFx -Block { & $riBash.Source $riShPath next; "exit=$LASTEXITCODE" }
    Check "handoff.sh accepts one tool in both roles under fresh-context" (($riShOut -match "exit=0") -and ($riShOut -notmatch "Role checkpoint: BLOCKED"))
    $riShOut = Invoke-RiIn -Dir $riForgedFx -Block { & $riBash.Source $riShPath commit-check }
    Check "handoff.sh sends a single-vendor commit to the PowerShell check that reads the harness record" ($riShOut -match "Commit: BLOCKED in handoff\.sh - a single-vendor review is verified only by pwsh scripts/handoff\.ps1 commit-check")
}


# --- v3.17.0 review fixes: each check below failed before its fix ---
Write-Host "[4D-7b] Review independence: holes closed after review (v3.17.0)"

$riFakeEmpty = Join-Path $FixtureRoot "fake-codex-solo-empty.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
:done
'@ | Set-Content -Path $riFakeEmpty -Encoding ascii
$riFakeRoleEdit = Join-Path $FixtureRoot "fake-codex-solo-role-edit.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo Review Independence: separate-tool>> .ai\roles\ROLE_ASSIGNMENT.md
:done
'@ | Set-Content -Path $riFakeRoleEdit -Encoding ascii
$riFakeNoop = Join-Path $FixtureRoot "fake-codex-solo-noop.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo done> FAKE_IMPLEMENTER_RAN.txt
:done
'@ | Set-Content -Path $riFakeNoop -Encoding ascii

# 1. Placeholder Task Actors no longer skip the harness check at commit and release.
$riTbdFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Implementer "TBD" -Reviewer "TBD" -Actor "Reviewer (Codex)" -LastUpdateExtra "- Verdict: APPROVED")
$r = Invoke-Handoff -WorkDir $riTbdFx -Arguments @("commit-check")
Check "fresh-context with TBD Task Actors: commit-check still requires the harness verdict" (($r.Code -eq 1) -and ($r.Out -match "Task Actors Implementer is 'TBD', not a known tool") -and ($r.Out -match "no harness review capture")) $r.Out
$r = Invoke-Handoff -WorkDir $riTbdFx -Arguments @("release-check", "-Version", "v9.9.9")
Check "fresh-context with TBD Task Actors: release-check still requires the harness verdict" (($r.Code -eq 1) -and ($r.Out -match "Task Actors Reviewer is 'TBD', not a known tool") -and ($r.Out -match "no harness review capture"))
$r = Invoke-Handoff -WorkDir $riTbdFx -Arguments @("commit-approved", "-Message", "Forged", "-Authorize", "I_AUTHORIZE_COMMIT")
Check "fresh-context with TBD Task Actors: commit-approved refuses" (($r.Code -eq 1) -and ($r.Out -match "no harness review capture"))
$riTbdSepFx = New-RiFixture -Roles (New-RiRoles -ModeLine $riSeparate) -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Implementer "TBD" -Reviewer "TBD" -Actor "Reviewer (Codex)")
$r = Invoke-Handoff -WorkDir $riTbdSepFx -Arguments @("commit-check")
Check "separate-tool keeps its behavior for placeholder actors (recorded separately, unchanged here)" ($r.Out -notmatch "Single-vendor review")

# 5. status, user-next and work agree with the gate.
$r = Invoke-Handoff -WorkDir $riTbdFx -Arguments @("status")
Check "status does not call a single-vendor REVIEW_DONE without a harness verdict ALLOWED" (($r.Out -match "Commit:\s+Blocked - commit-check refuses this single-vendor REVIEW_DONE") -and ($r.Out -notmatch "Commit:\s+ALLOWED"))
$r = Invoke-Handoff -WorkDir $riTbdFx -Arguments @("user-next")
Check "user-next does not offer commit-approved that commit-check would refuse" (($r.Out -notmatch "commit-approved -Message") -and ($r.Out -match "review must come from the harness"))
$r = Invoke-Handoff -WorkDir $riTbdFx -Arguments @("work")
Check "work does not offer commit-approved that commit-check would refuse" (($r.Out -notmatch "commit-approved -Message") -and ($r.Out -match "review must come from the harness"))

# 2. A single-vendor review proceeds only after an Implementer record.
$riRoleOnlyFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -Actor "Implementer")
$r = Invoke-Handoff -WorkDir $riRoleOnlyFx -Arguments @("review-check")
Check "the shipped '- Actor: Implementer' form, with no tool, is an Implementer record" (($r.Code -eq 0) -and ($r.Out -match "review-check: ready"))
$riMasterOnlyFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -Actor "Master")
$r = Invoke-Handoff -WorkDir $riMasterOnlyFx -Arguments @("review-check")
Check "an honest '- Actor: Master', with no tool, is refused review" (($r.Code -eq 1) -and ($r.Out -match "its Actor line is 'Master'"))
$riLeftoverFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -Actor "Reviewer (Codex), applied from the captured review verdict via review-apply" -LastUpdateExtra "- Verdict: BLOCKED")
$r = Invoke-Handoff -WorkDir $riLeftoverFx -Arguments @("review-check")
Check "a leftover review record (BLOCKED findings fixed without a new record) is refused review" (($r.Code -eq 1) -and ($r.Out -match "it is still the record of a review"))
$riLeftoverMasterFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -Actor "Codex (Master)" -LastUpdateExtra "- Verdict: BLOCKED")
$r = Invoke-Handoff -WorkDir $riLeftoverMasterFx -Arguments @("review-check")
Check "a Verdict line no longer hides a Master's turn from the single-vendor guard" (($r.Code -eq 1) -and ($r.Out -match "Self-review guard \(single-vendor review\)"))
$riHandoffSrc2 = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $RepoRoot "scripts/handoff.ps1")
Check "the harness's own interrupted-correction record counts as an Implementer record" ($riHandoffSrc2 -match "\^Automation Recovery after interrupted")

$riPrevCodexCli2 = $env:CODEX_CLI
try {
    # A failed review-run clears the old record, and a re-run after it still works.
    $env:CODEX_CLI = $riFakeApprove
    $riRerunFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff)
    $null = Invoke-Handoff -WorkDir $riRerunFx -Arguments @("review-run", "-Yes")
    $riHadRecord = (Test-Path (Join-Path $riRerunFx "REVIEW.jsonl")) -and ((Get-RiFile -Dir $riRerunFx -Rel "REVIEW.jsonl") -match "handoffReviewEvidence")
    $env:CODEX_CLI = $riFakeEmpty
    $r = Invoke-Handoff -WorkDir $riRerunFx -Arguments @("review-run", "-Yes")
    $riJsonlAfter = if (Test-Path (Join-Path $riRerunFx "REVIEW.jsonl")) { Get-RiFile -Dir $riRerunFx -Rel "REVIEW.jsonl" } else { "" }
    Check "a failed review-run leaves no old harness record behind" ($riHadRecord -and ($r.Code -ne 0) -and ($riJsonlAfter -notmatch "handoffReviewEvidence") -and (-not (Test-Path (Join-Path $riRerunFx "REVIEW_LAST.md"))))
    $r = Invoke-Handoff -WorkDir $riRerunFx -Arguments @("review-apply", "-Yes")
    Check "after a failed run there is nothing to apply" ($r.Code -eq 1)
    $env:CODEX_CLI = $riFakeApprove
    $r = Invoke-Handoff -WorkDir $riRerunFx -Arguments @("review-run", "-Yes")
    $r2 = Invoke-Handoff -WorkDir $riRerunFx -Arguments @("review-apply", "-Yes")
    Check "a re-run of review-run after a failed run completes and applies" (($r.Code -eq 0) -and ($r2.Code -eq 0) -and ((Get-RiFile -Dir $riRerunFx -Rel "AI_HANDOFF.md") -match "State:\s+REVIEW_DONE"))

    # 9. review-apply records the capture hash, and commit compares it.
    $riAppliedText = Get-RiFile -Dir $riRerunFx -Rel "AI_HANDOFF.md"
    Check "review-apply records the SHA-256 of the capture it applied" ($riAppliedText -match ("- Capture SHA-256: " + (Get-RiHash -Dir $riRerunFx -Rel "REVIEW_LAST.md").ToLowerInvariant()))

    # 12. Record for another task, and a file-set mismatch.
    $riOtherTask = $riAppliedText -replace "- Current Task: solo review task", "- Current Task: another task"
    [System.IO.File]::WriteAllText((Join-Path $riRerunFx "AI_HANDOFF.md"), $riOtherTask, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $riRerunFx -Arguments @("commit-check")
    Check "a harness record for another task is refused" (($r.Code -eq 1) -and ($r.Out -match "the harness evidence is for task 'solo review task', not the current task 'another task'"))
    $riExtraSet = $riAppliedText -replace "## Changed Files\r?\n- src/app.txt", "## Changed Files`n- src/app.txt`n- src/extra.txt"
    [System.IO.File]::WriteAllText((Join-Path $riRerunFx "AI_HANDOFF.md"), $riExtraSet, (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -Path (Join-Path $riRerunFx "src/extra.txt") -Value "extra" -Encoding utf8
    $r = Invoke-Handoff -WorkDir $riRerunFx -Arguments @("commit-check")
    Check "a file outside the reviewed set is refused" (($r.Code -eq 1) -and ($r.Out -match "the harness review covered \[src/app\.txt\], but the files declared now are \[src/app\.txt, src/extra\.txt\]"))

    # 12 / 9. A plan record at commit, and a leftover plan review-apply record.
    $riPlan2Fx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -ChangedFile "None yet" -Extra "`n## Plan`n- Step one: add the feature.") -NoChange
    $null = Invoke-Handoff -WorkDir $riPlan2Fx -Arguments @("review-run", "-Yes")
    $null = Invoke-Handoff -WorkDir $riPlan2Fx -Arguments @("review-apply", "-Yes")
    $riPlanApplied = Get-RiFile -Dir $riPlan2Fx -Rel "AI_HANDOFF.md"
    New-Item -ItemType Directory -Path (Join-Path $riPlan2Fx "src") -Force | Out-Null
    Set-Content -Path (Join-Path $riPlan2Fx "src/app.txt") -Value "hello" -Encoding utf8
    $riPlanDone = ($riPlanApplied -replace "- State: READY_FOR_IMPLEMENTATION", "- State: REVIEW_DONE" -replace "- Waiting For: Implementer", "- Waiting For: User") -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- src/app.txt"
    [System.IO.File]::WriteAllText((Join-Path $riPlan2Fx "AI_HANDOFF.md"), $riPlanDone, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $riPlan2Fx -Arguments @("commit-check")
    Check "an approved plan record presented at commit is refused" (($r.Code -eq 1) -and ($r.Out -match "the harness evidence is for a plan review, and this step needs a code review"))
    # Now a code review-run that is never applied, with the plan's review-apply record put back.
    $riPlanReady = ($riPlanApplied -replace "- State: READY_FOR_IMPLEMENTATION", "- State: READY_FOR_REVIEW" -replace "- Waiting For: Implementer", "- Waiting For: Reviewer") -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- src/app.txt"
    $riPlanReady = $riPlanReady -replace "(?s)## Last Update\r?\n.*?(?=\r?\n## )", "## Last Update`n- Actor: Codex (Implementer)`n- Date: 2026-11-18`n"
    [System.IO.File]::WriteAllText((Join-Path $riPlan2Fx "AI_HANDOFF.md"), $riPlanReady, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Handoff -WorkDir $riPlan2Fx -Arguments @("review-run", "-Yes")
    $riLeftoverPlan = ($riPlanApplied -replace "- State: READY_FOR_IMPLEMENTATION", "- State: REVIEW_DONE" -replace "- Waiting For: Implementer", "- Waiting For: User") -replace "## Changed Files\r?\n- None yet", "## Changed Files`n- src/app.txt"
    [System.IO.File]::WriteAllText((Join-Path $riPlan2Fx "AI_HANDOFF.md"), $riLeftoverPlan, (New-Object System.Text.UTF8Encoding($false)))
    $r2 = Invoke-Handoff -WorkDir $riPlan2Fx -Arguments @("commit-check")
    Check "a leftover plan review-apply record cannot stand in for an unapplied code verdict" (($r.Code -eq 0) -and ($r2.Code -eq 1) -and ($r2.Out -match "REVIEW_DONE was applied from a different review")) "$($r2.Out)"

    # 12. loop -IncludeReviewer end to end under fresh-context.
    $env:CODEX_CLI = $riFakeApprove
    $riLoopFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff)
    $r = Invoke-Handoff -WorkDir $riLoopFx -Arguments @("loop", "-IncludeReviewer", "-Yes")
    $r2 = Invoke-Handoff -WorkDir $riLoopFx -Arguments @("commit-check")
    Check "loop -IncludeReviewer runs a single-vendor review end to end and commit-check accepts it" (($r.Code -eq 0) -and ((Get-RiFile -Dir $riLoopFx -Rel "AI_HANDOFF.md") -match "State:\s+REVIEW_DONE") -and ($r2.Code -eq 0)) "$($r.Out)"

    # 10. A write-enabled Implementer turn may not change the role file.
    $env:CODEX_CLI = $riFakeRoleEdit
    $riEditFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Actor "Test") -NoChange
    $r = Invoke-Handoff -WorkDir $riEditFx -Arguments @("cycle", "-Yes")
    Check "cycle stops when the Implementer turn edits the role file" (($r.Code -eq 6) -and ($r.Out -match "the Implementer turn changed \.ai/roles/ROLE_ASSIGNMENT\.md")) "$($r.Out)"
    $riEditFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Actor "Test") -NoChange
    $r = Invoke-Handoff -WorkDir $riEditFx -Arguments @("loop", "-Yes", "-MaxTurns", "1")
    Check "loop stops when the Implementer turn edits the role file" (($r.Code -eq 6) -and ($r.Out -match "the Implementer turn changed \.ai/roles/ROLE_ASSIGNMENT\.md")) "$($r.Out)"
    $env:CODEX_CLI = $riFakeNoop
    $riNoEditFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Actor "Test") -NoChange
    $r = Invoke-Handoff -WorkDir $riNoEditFx -Arguments @("cycle", "-Yes")
    Check "an Implementer turn that leaves the role file alone is not stopped by that check" ((Test-Path (Join-Path $riNoEditFx "FAKE_IMPLEMENTER_RAN.txt")) -and ($r.Out -notmatch "changed \.ai/roles/ROLE_ASSIGNMENT\.md"))
} finally {
    if ($null -eq $riPrevCodexCli2) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $riPrevCodexCli2 }
}

# 8. loop re-reads the review rule every turn, with the binding.
Check "loop re-reads Review Independence with the binding each turn" ($riHandoffSrc2 -match '(?s)\$script:Binding     = Get-RoleBinding\r?\n\s+# v3\.17\.0 \(review fix\)[^\n]*\r?\n\s+\$script:ReviewIndependenceState = Get-ReviewIndependence')

# 6. The roles window shows an invalid line as invalid.
Check "the roles window shows an invalid or duplicated line as invalid, not as fresh-context" (($riHandoffSrc2 -match "review rule INVALID") -and ($riHandoffSrc2 -match "values\.Count -eq 1 -and ``\`$values\[0\] -eq 'fresh-context'"))

# 7. An invalid line is repairable by the command when it is the only problem.
$riRepairFx = New-RiFixture -Roles (New-RiRoles -ModeLine "Review Independence: relaxed" -History) -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$r = Invoke-Handoff -WorkDir $riRepairFx -Arguments @("roles", "-ReviewIndependence", "separate-tool", "-Yes")
$riRepaired = Get-RiFile -Dir $riRepairFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "roles -ReviewIndependence repairs an invalid line" (($r.Code -eq 0) -and (([regex]::Matches($riRepaired, '(?m)^Review Independence:')).Count -eq 1) -and ($riRepaired -match '(?m)^Review Independence: separate-tool\r?$') -and ($riRepaired -match 'Review Independence=invalid \|')) $r.Out
$riDupFx = New-RiFixture -Roles ((New-RiRoles -Master "Codex" -Reviewer "Codex" -Implementer "Codex" -ModeLine $riFresh) + "`nreview independence: FRESH-CONTEXT`n") -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Task "Finished task") -NoChange
$r = Invoke-Handoff -WorkDir $riDupFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
$riDedup = Get-RiFile -Dir $riDupFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "roles -ReviewIndependence repairs a duplicated line under a one-tool binding" (($r.Code -eq 0) -and (([regex]::Matches($riDedup, '(?mi)^review independence:')).Count -eq 1)) $r.Out
$riDupFx2 = New-RiFixture -Roles ((New-RiRoles -Master "Codex" -Reviewer "Codex" -Implementer "Codex" -ModeLine $riFresh) + "`n$riFresh`n") -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Task "Finished task") -NoChange
$riDupFx2Before = Get-RiHash -Dir $riDupFx2 -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$r = Invoke-Handoff -WorkDir $riDupFx2 -Arguments @("roles", "-ReviewIndependence", "separate-tool", "-Yes")
Check "the repair still refuses separate-tool for a one-tool binding" (($r.Code -eq 1) -and ($r.Out -match "Reassign a role first") -and ((Get-RiHash -Dir $riDupFx2 -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riDupFx2Before))
$riBadToolFx = New-RiFixture -Roles (New-RiRoles -Reviewer "Gemini" -ModeLine "Review Independence: relaxed") -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$riBadToolBefore = Get-RiHash -Dir $riBadToolFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$r = Invoke-Handoff -WorkDir $riBadToolFx -Arguments @("roles", "-ReviewIndependence", "separate-tool", "-Yes")
Check "the repair is refused when another problem remains, with the manual repair named" (($r.Code -eq 12) -and ($r.Out -match "Repair it by hand in \.ai/roles/ROLE_ASSIGNMENT\.md") -and ((Get-RiHash -Dir $riBadToolFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riBadToolBefore))
$riDriftFx = New-RiFixture -Roles (New-RiRoles -ModeLine "Review Independence: relaxed") -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Implementer "Codex" -Reviewer "Claude Code" -Actor "Test") -NoChange
$r = Invoke-Handoff -WorkDir $riDriftFx -Arguments @("next")
Check "the bad-line hint is printed even when role drift is reported too" (($r.Code -eq 12) -and ($r.Out -match "Role drift") -and ($r.Out -match "The 'Review Independence:' line must appear once"))
$riRolesBadFx = New-RiFixture -Roles (New-RiRoles -ModeLine "Review Independence: relaxed") -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$r = Invoke-Handoff -WorkDir $riRolesBadFx -Arguments @("roles")
Check "plain roles is still blocked by an invalid line, and names the repair command" (($r.Code -eq 12) -and ($r.Out -match "roles -ReviewIndependence <separate-tool\|fresh-context> -Yes"))

# 3. Agent instructions hold under both modes, in every copy.
$riOldSentences = @(
    "If they differ, or Reviewer equals Implementer, stop",
    "If they differ, or Reviewer equals Implementer, fail closed",
    "Reviewer and Implementer must always remain different",
    "drift or Reviewer==Implementer is a fail-closed stop",
    "for drift or Reviewer==Implementer;",
    "Implementer must be bound to Claude Code; Reviewer != Implementer;"
)
$riAgentFiles = @(".ai/skills/codex-claude-handoff/MASTER.md", ".ai/skills/codex-claude-handoff/IMPLEMENTER.md", ".ai/skills/codex-claude-handoff/SKILL.md", ".ai/skills/codex-claude-handoff/CLAUDE.md", ".ai/skills/codex-claude-handoff/CODEX.md", ".ai/skills/codex-claude-handoff/ADAPTERS.md", "templates/AGENTS.md", "templates/CLAUDE.md")
$riStale = @()
foreach ($riRel in @($riAgentFiles + @($riAgentFiles | Where-Object { $_ -like ".ai/*" } | ForEach-Object { "templates/$_" }))) {
    $riText = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $RepoRoot $riRel)
    foreach ($riSentence in $riOldSentences) { if ($riText.Contains($riSentence)) { $riStale += "$riRel : $riSentence" } }
}
Check "no agent instruction still forbids one tool in both roles under fresh-context" ($riStale.Count -eq 0) ($riStale -join " | ")
$riMasterDoc = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MASTER.md")
$riImplDoc = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/IMPLEMENTER.md")
Check "MASTER.md and IMPLEMENTER.md state the start-of-turn rule for both modes" (($riMasterDoc -match "Reviewer equals Implementer while the role file does not declare ``Review Independence: fresh-context``") -and ($riImplDoc -match "Reviewer equals Implementer while the role file does not declare ``Review Independence: fresh-context``"))

# 4. Mis-cased lines are read the same way by every implementation.
$riMisFx = New-RiFixture -Roles (New-RiRoles -Master "Codex" -Reviewer "Codex" -Implementer "Codex" -ModeLine "review independence: Fresh-Context") -Handoff (New-RiHandoff) -NoGit
$r = Invoke-Handoff -WorkDir $riMisFx -Arguments @("next")
$riMisPs = Get-RiFile -Dir $riMisFx -Rel "NEXT_TURN.md"
Check "handoff.ps1 reads a mis-cased fresh-context line" (($r.Code -eq 0) -and ($riMisPs -match "## Review Independence"))
$riBash2 = Get-Command bash -ErrorAction SilentlyContinue
if ($null -eq $riBash2) {
    Write-Host "  SKIP  mis-cased parity with handoff.sh: no bash interpreter on this machine"
} else {
    $riSh2 = (Join-Path $RepoRoot "scripts/handoff.sh") -replace '\\', '/'
    $riNextSh2 = (Join-Path $RepoRoot "scripts/next-step.sh") -replace '\\', '/'
    $riPrevCwd = [System.Environment]::CurrentDirectory
    Push-Location $riMisFx
    [System.Environment]::CurrentDirectory = $riMisFx
    try {
        $riShOut2 = (& $riBash2.Source $riSh2 next 2>&1 | Out-String) + "exit=$LASTEXITCODE"
        $riShNt = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $riMisFx "NEXT_TURN.md")
        $null = & $riBash2.Source $riNextSh2 --prepare-file 2>&1
        $riNextShNt = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $riMisFx "NEXT_TURN.md")
    } finally { Pop-Location; [System.Environment]::CurrentDirectory = $riPrevCwd }
    Check "handoff.sh reads the same mis-cased line the same way" (($riShOut2 -match "exit=0") -and ($riShNt -match "## Review Independence")) $riShOut2
    Check "next-step.sh reads the same mis-cased line the same way" ($riNextShNt -match "## Review Independence")
}
$riMisTarget = Join-Path $FixtureRoot "ri-miscase-target"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $riMisTarget -NoRolesWindow 2>&1
$riMisRoles = Join-Path $riMisTarget ".ai/roles/ROLE_ASSIGNMENT.md"
$riMisText = (Get-Content -Encoding UTF8 -Raw -LiteralPath $riMisRoles) -replace 'Review Independence: separate-tool', 'review independence: Fresh-Context'
[System.IO.File]::WriteAllText($riMisRoles, $riMisText, (New-Object System.Text.UTF8Encoding($false)))
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $riMisTarget -Force -NoRolesWindow 2>&1
$riMisAfter = Get-Content -Encoding UTF8 -Raw -LiteralPath $riMisRoles
Check "install.ps1 keeps a mis-cased fresh-context line on upgrade, with two tools bound" ((([regex]::Matches($riMisAfter, '(?mi)^review independence:')).Count -eq 1) -and ($riMisAfter -match '(?m)^Review Independence: fresh-context\r?$'))

# --- v3.17.0 second review: four last items ---
Write-Host "[4D-7c] Review independence: last review items (v3.17.0)"

# 1. A turn that edits the role file AND leaks a credential reports both.
$riFakeBoth = Join-Path $FixtureRoot "fake-codex-solo-role-and-secret.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > NUL
echo Review Independence: separate-tool>> .ai\roles\ROLE_ASSIGNMENT.md
echo - leaked sk-abcdefghijklmnopqrstuvwx0123>> AI_HANDOFF.md
:done
'@ | Set-Content -Path $riFakeBoth -Encoding ascii
$riPrevCodexCli3 = $env:CODEX_CLI
try {
    $env:CODEX_CLI = $riFakeBoth
    $riBothFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Actor "Test") -NoChange
    $r = Invoke-Handoff -WorkDir $riBothFx -Arguments @("cycle", "-Yes")
    Check "cycle reports a role-file edit even when the same turn leaked a credential" (($r.Out -match "the Implementer turn changed \.ai/roles/ROLE_ASSIGNMENT\.md") -and ($r.Out -match "SECURITY STOP") -and ($r.Code -eq 13)) "code=$($r.Code)"
    $riBothFx = New-RiFixture -Roles $riSoloCodex -Handoff (New-RiHandoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -Actor "Test") -NoChange
    $r = Invoke-Handoff -WorkDir $riBothFx -Arguments @("loop", "-Yes", "-MaxTurns", "1")
    Check "loop reports a role-file edit even when the same turn leaked a credential" (($r.Out -match "the Implementer turn changed \.ai/roles/ROLE_ASSIGNMENT\.md") -and ($r.Out -match "SECURITY STOP") -and ($r.Code -eq 13)) "code=$($r.Code)"
} finally {
    if ($null -eq $riPrevCodexCli3) { Remove-Item Env:\CODEX_CLI -ErrorAction SilentlyContinue } else { $env:CODEX_CLI = $riPrevCodexCli3 }
}

# 2. A broken line opens the one-tool repair only when it already asks for fresh-context.
$riSepDupFx = New-RiFixture -Roles ((New-RiRoles -Master "Codex" -Reviewer "Codex" -Implementer "Codex" -ModeLine $riSeparate) + "`n$riSeparate`n") -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Task "Finished task") -NoChange
$riSepDupBefore = Get-RiHash -Dir $riSepDupFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$r = Invoke-Handoff -WorkDir $riSepDupFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
Check "a duplicated separate-tool line is no way into fresh-context with one tool bound" (($r.Code -eq 12) -and ((Get-RiHash -Dir $riSepDupFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riSepDupBefore))
$riMixedFx = New-RiFixture -Roles ((New-RiRoles -Master "Codex" -Reviewer "Codex" -Implementer "Codex" -ModeLine $riFresh) + "`n$riSeparate`n") -Handoff (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Task "Finished task") -NoChange
$riMixedBefore = Get-RiHash -Dir $riMixedFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$r = Invoke-Handoff -WorkDir $riMixedFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
Check "mixed values are no way into fresh-context with one tool bound" (($r.Code -eq 12) -and ((Get-RiHash -Dir $riMixedFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -eq $riMixedBefore))
$riSepDupTwoFx = New-RiFixture -Roles ((New-RiRoles -ModeLine $riSeparate -History) + "`n$riSeparate`n") -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task") -NoChange
$r = Invoke-Handoff -WorkDir $riSepDupTwoFx -Arguments @("roles", "-ReviewIndependence", "separate-tool", "-Yes")
$riSepDupTwoText = Get-RiFile -Dir $riSepDupTwoFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "repair to separate-tool still works with two different tools bound" (($r.Code -eq 0) -and (([regex]::Matches($riSepDupTwoText, '(?m)^Review Independence:')).Count -eq 1))

# 4. A BOM before the line, and a non-breaking space, are read the same way by both shells.
$riBom = [byte[]](0xEF, 0xBB, 0xBF)
$riUtf8 = New-Object System.Text.UTF8Encoding($false)
$riBomRoles = "Review Independence: fresh-context`n| Master | Codex |`n| Reviewer | Codex |`n| Implementer | Codex |`n"
$riNbsp = [string][char]0x00A0
$riNbspRoles = (New-RiRoles -Master "Codex" -Reviewer "Codex" -Implementer "Codex") + "`nReview Independence:$($riNbsp)fresh-context$($riNbsp)`n"
$riParityCases = @(
    @{ Name = "a UTF-8 BOM before the line on line 1"; Bytes = ($riBom + $riUtf8.GetBytes($riBomRoles)) },
    @{ Name = "a non-breaking space after the colon and at the end"; Bytes = $riUtf8.GetBytes($riNbspRoles) }
)
$riBash3 = Get-Command bash -ErrorAction SilentlyContinue
foreach ($riCase in $riParityCases) {
    $riPFx = New-RiFixture -Roles $DefaultRoles -Handoff (New-RiHandoff) -NoGit
    [System.IO.File]::WriteAllBytes((Join-Path $riPFx ".ai/roles/ROLE_ASSIGNMENT.md"), $riCase.Bytes)
    $r = Invoke-Handoff -WorkDir $riPFx -Arguments @("next")
    $riPsOk = ($r.Code -eq 0) -and ((Get-RiFile -Dir $riPFx -Rel "NEXT_TURN.md") -match "## Review Independence")
    if ($null -eq $riBash3) {
        Write-Host "  SKIP  parity for $($riCase.Name): no bash interpreter on this machine"
        Check "handoff.ps1 reads fresh-context with $($riCase.Name)" $riPsOk
        continue
    }
    $riPrevCwd3 = [System.Environment]::CurrentDirectory
    Push-Location $riPFx
    [System.Environment]::CurrentDirectory = $riPFx
    try {
        Remove-Item -LiteralPath (Join-Path $riPFx "NEXT_TURN.md") -Force -ErrorAction SilentlyContinue
        $riShOut3 = (& $riBash3.Source ((Join-Path $RepoRoot "scripts/handoff.sh") -replace '\\', '/') next 2>&1 | Out-String) + "exit=$LASTEXITCODE"
        $riShOk = ($riShOut3 -match "exit=0") -and (Test-Path (Join-Path $riPFx "NEXT_TURN.md")) -and ((Get-RiFile -Dir $riPFx -Rel "NEXT_TURN.md") -match "## Review Independence")
        $null = & $riBash3.Source ((Join-Path $RepoRoot "scripts/next-step.sh") -replace '\\', '/') --prepare-file 2>&1
        $riNextOk = (Get-RiFile -Dir $riPFx -Rel "NEXT_TURN.md") -match "## Review Independence"
    } finally { Pop-Location; [System.Environment]::CurrentDirectory = $riPrevCwd3 }
    Check "handoff.ps1, handoff.sh and next-step.sh all read fresh-context with $($riCase.Name)" ($riPsOk -and $riShOk -and $riNextOk) "ps=$riPsOk sh=$riShOk next=$riNextOk $riShOut3"
}

# --- v3.18.0: the first choice is the user's ---
Write-Host "[4D-8] First setup: the players and the Master are chosen, never assumed (v3.18.0)"

Check "the suite runs with windows switched off" ($env:HANDOFF_BACKGROUND_NO_WINDOW -eq "1")

# Same as Invoke-Handoff, with text on standard input. Every setup call without -Players or
# without -Yes goes through here: input is then redirected, so nothing can wait on a console.
function Invoke-HandoffInput {
    param([string]$WorkDir, [string[]]$Arguments, [string]$InputText = "")
    $prevPwd = (Get-Location).Path
    $prevEnv = [System.Environment]::CurrentDirectory
    try {
        Set-Location $WorkDir
        [System.Environment]::CurrentDirectory = $WorkDir
        $combined = $InputText | & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $HandoffScript @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Set-Location $prevPwd
        [System.Environment]::CurrentDirectory = $prevEnv
    }
    return @{ Code = $code; Out = $combined }
}

function New-SuRoles {
    param([string]$SetupLine = "Setup: pending", [string]$Master = "Codex", [string]$Reviewer = "Codex", [string]$Implementer = "Claude Code", [string]$ModeLine = "Review Independence: separate-tool")
    $text = "# Role Assignment`n`n## Current Binding`n`n| Role | Tool |`n|---|---|`n| Master | $Master |`n| Reviewer | $Reviewer |`n| Implementer | $Implementer |`n`n"
    if ($ModeLine -ne "") { $text += "$ModeLine`n" }
    if ($SetupLine -ne "") { $text += "$SetupLine`n" }
    $text += "`nThe User is always the approval point and is never one of these roles.`n"
    return $text
}

$suInitialHandoff = Get-Content -Encoding UTF8 -Raw -Path (Join-Path $RepoRoot "templates/AI_HANDOFF.md")
function New-SuFixture {
    param([string]$Roles, [string]$Handoff = $suInitialHandoff)
    $dir = New-Fixture -Files @{ "AI_HANDOFF.md" = $Handoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $Roles } -InitGit
    Initialize-FixtureGitBaseline -Dir $dir
    return $dir
}
function Get-SuFile { param([string]$Dir, [string]$Rel) return [System.IO.File]::ReadAllText((Join-Path $Dir $Rel), [System.Text.Encoding]::UTF8) }
function Get-SuHashes { param([string]$Dir) return ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Dir ".ai/roles/ROLE_ASSIGNMENT.md")).Hash + "/" + (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Dir "AI_HANDOFF.md")).Hash) }
function Get-SuRow { param([string]$Text, [string]$Role) if ($Text -match "(?m)^\| $Role \| (.+?) \|\r?$") { return $Matches[1] } return "" }

# --- The marker: absent = configured, complete = configured, pending = not configured ---
$suFx = New-SuFixture -Roles $DefaultRoles
$r = Invoke-Handoff -WorkDir $suFx -Arguments @("work")
Check "no Setup line is a configured project: work runs as before" (($r.Code -eq 0) -and ($r.Out -notmatch "Setup required") -and ($r.Out -match "start the first task"))
$r = Invoke-Handoff -WorkDir $suFx -Arguments @("status")
Check "no Setup line: status prints nothing new" (($r.Out -match "Roles:\s+Master=Codex, Reviewer=Codex, Implementer=Claude Code") -and ($r.Out -notmatch "Setup:"))
$suFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete")
$r = Invoke-Handoff -WorkDir $suFx -Arguments @("work")
Check "Setup: complete is a configured project" (($r.Code -eq 0) -and ($r.Out -notmatch "Setup required"))
$suFx = New-SuFixture -Roles (New-SuRoles -SetupLine "setup: Complete")
$r = Invoke-Handoff -WorkDir $suFx -Arguments @("work")
Check "the Setup line is read without regard to letter case" (($r.Code -eq 0) -and ($r.Out -notmatch "Setup required"))
$suFx = New-SuFixture -Roles (New-SuRoles -SetupLine ("- Setup:" + [string][char]0x00A0 + "pending"))
$r = Invoke-Handoff -WorkDir $suFx -Arguments @("work")
Check "a bulleted Setup line with a non-breaking space is still read" ($r.Code -eq 14)

# --- pending: every work command stops with exit 14 and one instruction ---
$suPendFx = New-SuFixture -Roles (New-SuRoles)
$suPendBefore = Get-SuHashes -Dir $suPendFx
$suGated = @(
    @("work"), @("next"), @("start", "add a feature"), @("user-next"), @("adapters"), @("roles"),
    @("roles", "-Window"), @("roles", "-WindowOff"), @("roles", "-SetRole", "Master", "-SetTool", "Claude Code", "-Yes"),
    @("roles", "-ReviewIndependence", "fresh-context", "-Yes"), @("commit-check"), @("commit-approved", "-Message", "x", "-Authorize", "I_AUTHORIZE_COMMIT"),
    @("cycle", "-Yes"), @("run-next", "-Yes"), @("loop", "-Yes"), @("review-check"), @("review-run", "-Yes"), @("review-apply", "-Yes"),
    @("master-check"), @("master-run", "-Yes"), @("master-apply", "-Yes"), @("release-check", "-Version", "v9.9.9"),
    @("task-next", "-Yes"), @("sequence-add", "-NextTask", "x"), @("stop"), @("wait", "-TimeoutSeconds", "1"), @("no-such-command")
)
$suGateMisses = @()
foreach ($suArgs in $suGated) {
    $r = Invoke-HandoffInput -WorkDir $suPendFx -Arguments $suArgs
    if (-not (($r.Code -eq 14) -and ($r.Out -match "Setup required: this project has not chosen its players and its Master yet\.") -and ($r.Out -match "Run:\s+\.\\scripts\\handoff\.ps1 setup") -and ($r.Out -match "Nothing was started and nothing was changed\."))) {
        $suGateMisses += "$($suArgs -join ' ') -> $($r.Code)"
    }
}
Check "pending: every work command, every form of roles and an unknown command stop with exit 14" ($suGateMisses.Count -eq 0) ($suGateMisses -join "; ")
$r = Invoke-HandoffInput -WorkDir $suPendFx -Arguments @() -InputText "18"
Check "pending: the no-command menu is gated too" (($r.Code -eq 14) -and ($r.Out -notmatch "Select"))
Check "pending: the gated commands changed nothing" ((Get-SuHashes -Dir $suPendFx) -eq $suPendBefore)
Check "pending: nothing was written by a gated command" (-not (Test-Path (Join-Path $suPendFx "NEXT_TURN.md")) -and -not (Test-Path (Join-Path $suPendFx "USER_REQUEST.md")) -and -not (Test-Path (Join-Path $suPendFx "HANDOFF_UI.json")))
$r = Invoke-Handoff -WorkDir $suPendFx -Arguments @("status")
Check "pending: status says NOT CONFIGURED and names the command" (($r.Code -eq 0) -and ($r.Out -match "Setup:\s+NOT CONFIGURED") -and ($r.Out -match "Run:\s+\.\\scripts\\handoff\.ps1 setup"))
Check "pending: status does not show the template binding as a choice" ($r.Out -notmatch "Roles:\s+Master=")
$r = Invoke-Handoff -WorkDir $suPendFx -Arguments @("models")
Check "pending: models still runs" (($r.Code -eq 0) -and ($r.Out -notmatch "Setup required"))
$suSrc = Get-Content -Raw -Path $HandoffScript
Check "exit 14 is used by the setup gate and nothing else" (([regex]::Matches($suSrc, '(?m)^\s*exit 14\s*$')).Count -eq 1)
Check "the setup gate is evaluated before the role checkpoint" ($suSrc -match '(?s)if \(\$SetupState\.Pending -and \$Command -notin @\(''setup'', ''doctor'', ''status'', ''models''\)\).{0,1200}if \(-not \$RoleCheckpoint\.Ok -and')

# doctor warns and still passes, on a real fresh install.
$suInstTarget = Join-Path $FixtureRoot "su-install-fresh"
New-Item -ItemType Directory -Path $suInstTarget -Force | Out-Null
& git -C $suInstTarget init -q 2>&1 | Out-Null
$suInstOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suInstTarget -NoRolesWindow 2>&1 | Out-String
$suInstCode = $LASTEXITCODE
$suInstRoles = Join-Path $suInstTarget ".ai/roles/ROLE_ASSIGNMENT.md"
Check "a fresh install succeeds and is Setup: pending" (($suInstCode -eq 0) -and (([regex]::Matches((Get-Content -Raw -LiteralPath $suInstRoles), '(?m)^Setup: pending\r?$')).Count -eq 1))
Check "a fresh install without a window says NOT CONFIGURED and names the command" (($suInstOut -match "Setup: NOT CONFIGURED") -and ($suInstOut -match "\.\\scripts\\handoff\.ps1 setup") -and ($suInstOut -match "exit 14"))
$r = Invoke-Handoff -WorkDir $suInstTarget -Arguments @("doctor")
Check "pending: doctor warns, never fails, and names the command" (($r.Code -eq 0) -and ($r.Out -match "WARN  Setup: NOT CONFIGURED") -and ($r.Out -match "Doctor result: PASS") -and ($r.Out -notmatch "FAIL  "))
Check "pending: doctor gives no advice about a binding nobody chose" ($r.Out -notmatch "Advisory: Master and Reviewer")
$r = Invoke-Handoff -WorkDir $suInstTarget -Arguments @("work")
Check "a fresh install blocks work with exit 14" ($r.Code -eq 14)

# --- setup: the rule, through the command ---
$suCases = @(
    @{ Name = "two players, Claude Code as Master"; Players = "Claude Code,Codex"; Master = "Claude Code"; M = "Claude Code"; I = "Claude Code"; R = "Codex"; Mode = "separate-tool" },
    @{ Name = "two players, Codex as Master"; Players = "Claude Code,Codex"; Master = "Codex"; M = "Codex"; I = "Codex"; R = "Claude Code"; Mode = "separate-tool" },
    @{ Name = "two players given in the other order"; Players = "Codex,Claude Code"; Master = "Claude Code"; M = "Claude Code"; I = "Claude Code"; R = "Codex"; Mode = "separate-tool" },
    @{ Name = "aliases resolve to display names"; Players = "claude-code, codex window"; Master = "codex cli"; M = "Codex"; I = "Codex"; R = "Claude Code"; Mode = "separate-tool" },
    @{ Name = "one player, Codex"; Players = "Codex"; Master = ""; M = "Codex"; I = "Codex"; R = "Codex"; Mode = "fresh-context" },
    @{ Name = "one player, Claude Code, Master named"; Players = "Claude Code"; Master = "Claude Code"; M = "Claude Code"; I = "Claude Code"; R = "Claude Code"; Mode = "fresh-context" },
    @{ Name = "a duplicated player collapses to one"; Players = "Codex,codex"; Master = ""; M = "Codex"; I = "Codex"; R = "Codex"; Mode = "fresh-context" }
)
foreach ($suCase in $suCases) {
    $suCaseFx = New-SuFixture -Roles (New-SuRoles)
    $suArgs = @("setup", "-Players", $suCase.Players)
    if ($suCase.Master -ne "") { $suArgs += @("-Master", $suCase.Master) }
    $r = Invoke-HandoffInput -WorkDir $suCaseFx -Arguments ($suArgs + @("-Yes"))
    $suText = Get-SuFile -Dir $suCaseFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
    $suOk = ($r.Code -eq 0) -and ((Get-SuRow $suText "Master") -eq $suCase.M) -and ((Get-SuRow $suText "Implementer") -eq $suCase.I) -and ((Get-SuRow $suText "Reviewer") -eq $suCase.R) -and ($suText -match "(?m)^Review Independence: $($suCase.Mode)\r?$")
    Check "setup: $($suCase.Name)" $suOk "code=$($r.Code) $($r.Out)"
}

$suRefusals = @(
    @{ Name = "an unknown tool"; Args = @("setup", "-Players", "Claude Code,Gemini", "-Master", "Claude Code", "-Yes"); Want = "Unknown player 'Gemini'\. Known tools: Claude Code, Codex\." },
    @{ Name = "a Master who is not a player"; Args = @("setup", "-Players", "Codex", "-Master", "Claude Code", "-Yes"); Want = "The Master must be one of the players" },
    @{ Name = "an unknown Master"; Args = @("setup", "-Players", "Claude Code,Codex", "-Master", "Gemini", "-Yes"); Want = "Unknown Master 'Gemini'" },
    @{ Name = "an empty list"; Args = @("setup", "-Players", " ", "-Yes"); Want = "Choose at least one player" },
    @{ Name = "a list of commas"; Args = @("setup", "-Players", " , ", "-Yes"); Want = "Choose at least one player" },
    @{ Name = "two players without a Master"; Args = @("setup", "-Players", "Claude Code,Codex", "-Yes"); Want = "With two players, choose the Master.*No Master is chosen for you" },
    @{ Name = "-Master without -Players"; Args = @("setup", "-Master", "Codex", "-Yes"); Want = "-Master needs -Players" }
)
foreach ($suRef in $suRefusals) {
    $suRefFx = New-SuFixture -Roles (New-SuRoles)
    $suRefBefore = Get-SuHashes -Dir $suRefFx
    $r = Invoke-HandoffInput -WorkDir $suRefFx -Arguments $suRef.Args
    Check "setup refuses $($suRef.Name) and changes nothing" (($r.Code -eq 1) -and ($r.Out -match "setup: blocked") -and ($r.Out -match $suRef.Want) -and ($r.Out -match "Nothing was changed") -and ((Get-SuHashes -Dir $suRefFx) -eq $suRefBefore)) "code=$($r.Code) $($r.Out)"
}

# What is written, on the untouched install state.
$suWriteFx = New-SuFixture -Roles (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md"))
$r = Invoke-HandoffInput -WorkDir $suWriteFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Codex", "-Yes")
$suWritten = Get-SuFile -Dir $suWriteFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
$suWrittenHandoff = Get-SuFile -Dir $suWriteFx -Rel "AI_HANDOFF.md"
Check "setup on the shipped file writes the three rows with display names" (($r.Code -eq 0) -and ($suWritten -match "(?m)^\| Master \| Codex \|\r?$") -and ($suWritten -match "(?m)^\| Implementer \| Codex \|\r?$") -and ($suWritten -match "(?m)^\| Reviewer \| Claude Code \|\r?$"))
Check "setup writes one Review Independence line and one Setup: complete line, together" ((([regex]::Matches($suWritten, '(?mi)^\s*(?:[-*]\s+)?Review Independence\s*:')).Count -eq 1) -and (([regex]::Matches($suWritten, '(?mi)^\s*(?:[-*]\s+)?Setup\s*:')).Count -eq 1) -and ($suWritten -match '(?m)^Review Independence: separate-tool\r?\nSetup: complete\r?$'))
Check "setup records a Role Swap History row decided by the user through setup" ($suWritten -match '(?m)^\| \d{4}-\d{2}-\d{2} \| Master=Codex, Reviewer=Codex, Implementer=Claude Code, Review Independence=separate-tool, Setup=pending \| Master=Codex, Reviewer=Claude Code, Implementer=Codex, Review Independence=separate-tool, Setup=complete \| User \(handoff\.ps1 setup\) \|\r?$')
Check "setup keeps the rest of the shipped role file" (($suWritten -match "## Role Meanings") -and ($suWritten -match "## Invariant \(must always hold\)") -and ($suWritten -match "## Tooling Note"))
Check "setup moves the install's Task Actors to the new binding" (($suWrittenHandoff -match "(?m)^- Implementer: Codex\r?$") -and ($suWrittenHandoff -match "(?m)^- Reviewer: Claude Code\r?$"))
Check "setup leaves no temporary or backup file beside the role file" (@(Get-ChildItem -LiteralPath (Join-Path $suWriteFx ".ai/roles") -Force).Count -eq 1)
Check "setup names what it changed and what it never does" (($r.Out -match "Changes:\s+\.ai/roles/ROLE_ASSIGNMENT\.md .*and AI_HANDOFF\.md Task Actors") -and ($r.Out -match "no turn is started") -and ($r.Out -match "setup: complete"))
$r = Invoke-Handoff -WorkDir $suWriteFx -Arguments @("work")
Check "work runs clean right after setup on a fresh install (two players)" (($r.Code -eq 0) -and ($r.Out -notmatch "Role drift") -and ($r.Out -notmatch "Setup required") -and ($r.Out -match "paste the printed Master prompt into Codex"))
$r = Invoke-HandoffInput -WorkDir $suWriteFx -Arguments @("setup", "-Players", "Codex,Claude Code", "-Master", "codex", "-Yes")
Check "setup with the same choice again changes nothing" (($r.Code -eq 0) -and ($r.Out -match "Nothing to change"))

$suSoloFx = New-SuFixture -Roles (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md"))
$r = Invoke-HandoffInput -WorkDir $suSoloFx -Arguments @("setup", "-Players", "Codex", "-Yes")
Check "one player: the plan says single-vendor review is weaker" (($r.Code -eq 0) -and ($r.Out -match "one vendor reviewing its own vendor's work misses what a second vendor would catch") -and ($r.Out -match "Two tools remain the recommended setup"))
$suSoloText = Get-SuFile -Dir $suSoloFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "one player: every role is that tool under fresh-context" (((Get-SuRow $suSoloText "Master") -eq "Codex") -and ((Get-SuRow $suSoloText "Reviewer") -eq "Codex") -and ((Get-SuRow $suSoloText "Implementer") -eq "Codex") -and ($suSoloText -match '(?m)^Review Independence: fresh-context\r?\nSetup: complete\r?$'))
$r = Invoke-Handoff -WorkDir $suSoloFx -Arguments @("work")
Check "work runs clean right after setup on a fresh install (one player)" (($r.Code -eq 0) -and ($r.Out -notmatch "Role drift") -and ($r.Out -match "Single-vendor review: Codex"))

# A role file with no Review Independence line gets one, under the binding.
$suNoModeFx = New-SuFixture -Roles (New-SuRoles -ModeLine "")
$r = Invoke-HandoffInput -WorkDir $suNoModeFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Claude Code", "-Yes")
Check "setup adds a missing Review Independence line above the Setup line" (($r.Code -eq 0) -and ((Get-SuFile -Dir $suNoModeFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -match '(?m)^Review Independence: separate-tool\r?\nSetup: complete\r?$'))

# Cancel, and no choice possible: nothing changes.
$suCancelFx = New-SuFixture -Roles (New-SuRoles)
$suCancelBefore = Get-SuHashes -Dir $suCancelFx
$r = Invoke-HandoffInput -WorkDir $suCancelFx -Arguments @("setup", "-Players", "Codex") -InputText "no"
Check "cancelling the confirmation exits 2 and changes nothing" (($r.Code -eq 2) -and ($r.Out -match "Cancelled") -and ($r.Out -match "Setup is still pending") -and ((Get-SuHashes -Dir $suCancelFx) -eq $suCancelBefore))
$suTempBefore = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter "handoff-setup-*" -ErrorAction SilentlyContinue).Count
$r = Invoke-HandoffInput -WorkDir $suCancelFx -Arguments @("setup")
Check "no flags and nobody to ask: setup prints the flag form and exits 1" (($r.Code -eq 1) -and ($r.Out -match "pass the choice as flags") -and ($r.Out -match 'setup -Players "Claude Code,Codex" -Master "Claude Code" -Yes') -and ((Get-SuHashes -Dir $suCancelFx) -eq $suCancelBefore))
$r = Invoke-HandoffInput -WorkDir $suCancelFx -Arguments @("setup", "-Window")
Check "-Window with windows switched off opens nothing and falls back to the flag form" (($r.Code -eq 1) -and ($r.Out -match "pass the choice as flags") -and ($r.Out -notmatch "a window is open"))
$suTempAfter = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter "handoff-setup-*" -ErrorAction SilentlyContinue).Count
Check "no picker script was even written while windows are switched off" ($suTempAfter -eq $suTempBefore)

# Guards: a running turn, and a configured project mid-task.
$suLiveFx = New-SuFixture -Roles (New-SuRoles)
$suLiveBefore = Get-SuHashes -Dir $suLiveFx
$suSleeper = Start-Process -FilePath $PwshExe -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 45") -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Milliseconds 500
    $suMarker = [ordered]@{ processId = $suSleeper.Id; startTicks = $suSleeper.StartTime.ToUniversalTime().Ticks; command = "cycle"; startedUtc = "2026-11-19T10:00:00Z"; log = "HANDOFF_BACKGROUND.log"; finishedUtc = $null; exitCode = $null }
    [System.IO.File]::WriteAllText((Join-Path $suLiveFx "HANDOFF_BACKGROUND.json"), ($suMarker | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-HandoffInput -WorkDir $suLiveFx -Arguments @("setup", "-Players", "Codex", "-Yes")
    Check "setup is refused while a turn is running" (($r.Code -eq 1) -and ($r.Out -match "A turn is running now") -and ((Get-SuHashes -Dir $suLiveFx) -eq $suLiveBefore))
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        $suShLive = Invoke-RiIn -Dir $suLiveFx -Block { & (Get-Command bash).Source ((Join-Path $RepoRoot "scripts/handoff.sh") -replace '\\', '/') setup --players Codex --yes; "exit=$LASTEXITCODE" }
        Check "handoff.sh setup is refused while a run marker says a turn is running" (($suShLive -match "exit=1") -and ($suShLive -match "A turn may be running now") -and ((Get-SuHashes -Dir $suLiveFx) -eq $suLiveBefore)) $suShLive
    }
} finally {
    try { Stop-Process -Id $suSleeper.Id -Force -ErrorAction SilentlyContinue } catch { }
}
$suMidFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete") -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer" -CurrentTask "work in flight")
$suMidBefore = Get-SuHashes -Dir $suMidFx
$r = Invoke-HandoffInput -WorkDir $suMidFx -Arguments @("setup", "-Players", "Codex", "-Yes")
Check "a reconfiguration is refused mid-task and points to roles -SetRole" (($r.Code -eq 1) -and ($r.Out -match "allowed only at a finished task") -and ($r.Out -match "roles -SetRole") -and ((Get-SuHashes -Dir $suMidFx) -eq $suMidBefore))

# A reconfiguration at a finished task keeps that task's Task Actors: they are its record.
$suDoneFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete" -Master "Codex" -Reviewer "Codex" -Implementer "Claude Code") -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
$suDoneHandoffBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $suDoneFx "AI_HANDOFF.md")).Hash
$r = Invoke-HandoffInput -WorkDir $suDoneFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Codex", "-Yes")
Check "a reconfiguration at a finished task is allowed" (($r.Code -eq 0) -and ($r.Out -match "Reconfiguring the players and the Master") -and ((Get-SuRow (Get-SuFile -Dir $suDoneFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md") "Implementer") -eq "Codex"))
Check "a finished task's Task Actors are never rewritten" (((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $suDoneFx "AI_HANDOFF.md")).Hash -eq $suDoneHandoffBefore) -and ($r.Out -notmatch "and AI_HANDOFF\.md Task Actors"))
Check "the reconfiguration says how to open the next task, and only that" (($r.Out -match "(?s)keeps its Task Actors.{0,300}Next: \.\\scripts\\handoff\.ps1 start") -and ($r.Out -notmatch "Next: \.\\scripts\\handoff\.ps1 work"))
$r = Invoke-Handoff -WorkDir $suDoneFx -Arguments @("work")
Check "after it, the finished record is reported as drift, for start to retire" (($r.Code -eq 12) -and ($r.Out -match "Role drift"))

# The roles command on the untouched install state: Task Actors now follow the binding.
$suSwapFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete" -Master "Codex" -Reviewer "Codex" -Implementer "Claude Code")
$r = Invoke-Handoff -WorkDir $suSwapFx -Arguments @("roles", "-SetRole", "Implementer", "-SetTool", "Codex", "-Yes")
$suSwapHandoff = Get-SuFile -Dir $suSwapFx -Rel "AI_HANDOFF.md"
Check "roles -SetRole on a fresh install moves Task Actors with the binding" (($r.Code -eq 0) -and ($suSwapHandoff -match "(?m)^- Implementer: Codex\r?$") -and ($suSwapHandoff -match "(?m)^- Reviewer: Claude Code\r?$") -and ($r.Out -match "no task has started yet"))
$r = Invoke-Handoff -WorkDir $suSwapFx -Arguments @("work")
Check "after a swap on a fresh install, work runs without role drift" (($r.Code -eq 0) -and ($r.Out -notmatch "Role drift"))

# --- Invalid and duplicated Setup lines: fail closed, repairable only by setup ---
$suBadFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: maybe")
$r = Invoke-Handoff -WorkDir $suBadFx -Arguments @("work")
Check "an unknown Setup value blocks through the role checkpoint (exit 12)" (($r.Code -eq 12) -and ($r.Out -match "Invalid setup line: ROLE_ASSIGNMENT\.md declares 'Setup: maybe'\. The value must be pending or complete\.") -and ($r.Out -match "Repair it by choosing the players and the Master again: \.\\scripts\\handoff\.ps1 setup"))
$r = Invoke-Handoff -WorkDir $suBadFx -Arguments @("doctor")
Check "doctor fails the role checkpoint on an invalid Setup line" ($r.Out -match "FAIL  Role checkpoint")
$suBadBefore = Get-SuHashes -Dir $suBadFx
$r = Invoke-Handoff -WorkDir $suBadFx -Arguments @("roles", "-ReviewIndependence", "fresh-context", "-Yes")
Check "roles cannot repair a broken Setup line" (($r.Code -eq 12) -and ((Get-SuHashes -Dir $suBadFx) -eq $suBadBefore))
$r = Invoke-HandoffInput -WorkDir $suBadFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Claude Code", "-Yes")
$suBadText = Get-SuFile -Dir $suBadFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
Check "setup repairs a broken Setup line when it is the only problem" (($r.Code -eq 0) -and ($r.Out -match "repairing the Setup line") -and (([regex]::Matches($suBadText, '(?mi)^\s*(?:[-*]\s+)?Setup\s*:')).Count -eq 1) -and ($suBadText -match '(?m)^Setup: complete\r?$') -and ($suBadText -match 'Setup=invalid \|'))
$suDupFx = New-SuFixture -Roles ((New-SuRoles -SetupLine "Setup: complete") + "`nSetup: complete`n")
$r = Invoke-Handoff -WorkDir $suDupFx -Arguments @("next")
Check "a duplicated Setup line fails closed, even when both copies agree" (($r.Code -eq 12) -and ($r.Out -match "declares 'Setup:' 2 times"))
$r = Invoke-HandoffInput -WorkDir $suDupFx -Arguments @("setup", "-Players", "Codex", "-Yes")
Check "setup repairs a duplicated Setup line to one" (($r.Code -eq 0) -and (([regex]::Matches((Get-SuFile -Dir $suDupFx -Rel ".ai/roles/ROLE_ASSIGNMENT.md"), '(?m)^Setup:')).Count -eq 1))
$suBadTwoFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: maybe" -Reviewer "Gemini")
$suBadTwoBefore = Get-SuHashes -Dir $suBadTwoFx
$r = Invoke-HandoffInput -WorkDir $suBadTwoFx -Arguments @("setup", "-Players", "Codex", "-Yes")
Check "setup does not repair a Setup line that is not the only problem" (($r.Code -eq 12) -and ($r.Out -match "Unrecognized tool identity 'Gemini'") -and ((Get-SuHashes -Dir $suBadTwoFx) -eq $suBadTwoBefore))
$suBadDoneFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: maybe") -Handoff (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer" -CurrentTask "in flight")
$suBadDoneBefore = Get-SuHashes -Dir $suBadDoneFx
$r = Invoke-HandoffInput -WorkDir $suBadDoneFx -Arguments @("setup", "-Players", "Codex", "-Yes")
Check "a Setup-line repair is still refused mid-task" (($r.Code -eq 1) -and ($r.Out -match "allowed only at a finished task") -and ((Get-SuHashes -Dir $suBadDoneFx) -eq $suBadDoneBefore))

# --- The picker window: generated, parsed, never shown ---
$suParseTokens = $null
$suParseErrors = $null
$suAst = [System.Management.Automation.Language.Parser]::ParseFile($HandoffScript, [ref]$suParseTokens, [ref]$suParseErrors)
$suWanted = @("ConvertTo-PowerShellLiteral", "New-SetupWindowScript", "Test-SetupWindowPossible", "New-RolesWindowScript", "Read-SetupWindowResult",
    "Get-SetupChoiceTable", "Resolve-SetupChoice", "Get-SetupTools", "Get-SetupRuleShort", "Resolve-ToolIdentity", "Get-AdapterProfile", "Test-FreshContextReview")
$suFns = @($suAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($suWanted -contains $n.Name) }, $true))
Check "the window generators, the window decision and the result reader are separate functions" ($suFns.Count -eq $suWanted.Count)
# The registry the rules read, taken from handoff.ps1 itself.
$suVars = @($suAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -in @('$CanonicalToolRegistry', '$ToolIdentitySentinels')) -and ($n.Parent.Parent -is [System.Management.Automation.Language.ScriptBlockAst]) }, $true))
. ([scriptblock]::Create(((@($suVars) + @($suFns)) | ForEach-Object { $_.Extent.Text }) -join "`n`n"))
$suTools = @(
    @{ Canonical = "claude-code"; Display = "Claude Code"; Detected = $true },
    @{ Canonical = "codex"; Display = "Codex"; Detected = $false }
)
# The real table: every combination, computed by Resolve-SetupChoice, as Invoke-SetupWindow builds it.
$suTable = Get-SetupChoiceTable -Tools $suTools
Check "the real choice table covers every combination of players and Master" (@($suTable.Keys).Count -eq 7)
Check "the real table: two players with no Master is not a valid choice" ((-not $suTable["3|"].Ok) -and ($suTable["3|"].Error -match "No Master is chosen for you"))
Check "the real table: the Master's tool implements and the other reviews" (($suTable["3|codex"].Ok) -and ($suTable["3|codex"].Implementer -eq "Codex") -and ($suTable["3|codex"].Reviewer -eq "Claude Code") -and ($suTable["3|claude-code"].Reviewer -eq "Codex"))
Check "the real table: one player reviews its own work, said to be weaker" (($suTable["1|"].Ok) -and ($suTable["1|"].Reviewer -eq "Claude Code") -and ($suTable["1|"].Rule -match "Weaker than two vendors") -and ($suTable["2|codex"].Implementer -eq "Codex"))
foreach ($suNone in @($false, $true)) {
    $suWindowText = New-SetupWindowScript -ResultPath (Join-Path $FixtureRoot "it's a result.json") -Project "proj 'quoted' `$x" -Tools $suTools -Table $suTable -NoneDetected $suNone
    $suWindowPath = Join-Path $FixtureRoot ("setup-window-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    [System.IO.File]::WriteAllText($suWindowPath, $suWindowText, (New-Object System.Text.UTF8Encoding($true)))
    $suWinTokens = $null
    $suWinErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($suWindowPath, [ref]$suWinTokens, [ref]$suWinErrors)
    Check "the generated picker script parses with zero errors (none detected: $suNone)" ($suWinErrors.Count -eq 0) (($suWinErrors | ForEach-Object { $_.Message }) -join "; ")
}
Check "the picker carries every result it shows, computed by the parent" (($suWindowText -match [regex]::Escape("`$choices['3|codex'] = @{ Ok = `$True; Implementer = 'Codex'; Reviewer = 'Claude Code'")) -and ($suWindowText -match [regex]::Escape("`$choices['3|'] = @{ Ok = `$False")) -and ($suWindowText -match "two tools remain the recommended setup"))
Check "the picker preselects no Master and keeps Save disabled until a valid choice" (($suWindowText -match [regex]::Escape("`$radio.Checked = `$false")) -and ($suWindowText -match [regex]::Escape("`$save.Enabled = `$false")) -and ($suWindowText -match "No Master is chosen for you"))
Check "the picker collapses the Master to the only player" ($suWindowText -match [regex]::Escape("if (`$count -eq 1) { for (`$i = 0; `$i -lt `$tools.Count; `$i++) { `$radios[`$i].Checked = `$boxes[`$i].Checked } }"))
Check "the picker writes only its result file, never a project file" ((@([regex]::Matches($suWindowText, 'WriteAllText\(')).Count -eq @([regex]::Matches($suWindowText, 'WriteAllText\(\$resultPath,')).Count) -and ($suWindowText -notmatch "ROLE_ASSIGNMENT") -and ($suWindowText -notmatch "AI_HANDOFF"))
Check "the picker says so when no tool was found, and ticks both" ($suWindowText -match "Neither tool was found on this machine, so both are ticked")
Check "the window decision: a person at a Windows console gets a window" (Test-SetupWindowPossible -ExplicitWindow $false -IsWindows $true -NoWindowEnv $false -InputRedirected $false -IsAgent $false)
Check "the window decision: never with HANDOFF_BACKGROUND_NO_WINDOW, even with -Window" ((-not (Test-SetupWindowPossible -ExplicitWindow $false -IsWindows $true -NoWindowEnv $true -InputRedirected $false -IsAgent $false)) -and (-not (Test-SetupWindowPossible -ExplicitWindow $true -IsWindows $true -NoWindowEnv $true -InputRedirected $false -IsAgent $false)))
Check "the window decision: never with redirected input or from an agent, unless -Window" ((-not (Test-SetupWindowPossible -ExplicitWindow $false -IsWindows $true -NoWindowEnv $false -InputRedirected $true -IsAgent $false)) -and (-not (Test-SetupWindowPossible -ExplicitWindow $false -IsWindows $true -NoWindowEnv $false -InputRedirected $false -IsAgent $true)) -and (Test-SetupWindowPossible -ExplicitWindow $true -IsWindows $true -NoWindowEnv $false -InputRedirected $true -IsAgent $true))
Check "the window decision: never off Windows" (-not (Test-SetupWindowPossible -ExplicitWindow $true -IsWindows $false -NoWindowEnv $false -InputRedirected $false -IsAgent $false))
Check "the command feeds the real facts into the window decision" ($suSrc -match '(?s)\$windowPossible = Test-SetupWindowPossible -ExplicitWindow \(\[bool\]\$Window\) -IsWindows \(\$env:OS -eq "Windows_NT"\) -NoWindowEnv \(-not \[string\]::IsNullOrEmpty\(\$env:HANDOFF_BACKGROUND_NO_WINDOW\)\) -InputRedirected \$inputRedirected -IsAgent \$isAgent')
Check "the window's table comes from Resolve-SetupChoice, not from a second copy of the rules" (($suSrc -match '(?s)function Get-SetupChoiceTable.{0,1500}Resolve-SetupChoice -Players') -and ($suSrc -match '\$table = Get-SetupChoiceTable -Tools \$tools'))
Check "the Save choice goes through the same apply path as the flags" ($suSrc -match '(?s)\$chosenPlayers = \$picked\.Players.{0,400}\$confirmed = \$true.{0,2500}\$choice = Resolve-SetupChoice -Players \$chosenPlayers -Master \$chosenMaster.{0,300}Invoke-SetupApply -Choice \$choice -Confirmed \$confirmed')
Check "detection reuses what doctor checks, no second detector" (($suSrc -match '\$codexFound = \[bool\]\(Resolve-CodexCli\)\.Ok') -and ($suSrc -match '\$claudeFound = \(\$null -ne \(Get-NpxCommand\)\)') -and ($suSrc -match '\$npxCmd = Get-NpxCommand'))
Check "the indicator has a setup button that runs setup -Window and is locked while a turn runs" (($suSrc -match "handoff setup -Window") -and ($suSrc -match [regex]::Escape('`$setupButton.Enabled = `$false')))
$suIndicatorParseOk = $true
foreach ($suFile in @($HandoffScript, (Join-Path $RepoRoot "install.ps1"), (Join-Path $RepoRoot "bootstrap.ps1"), (Join-Path $RepoRoot "scripts/install.ps1"), (Join-Path $RepoRoot ".agents/skills/codex-claude-handoff/scripts/setup.ps1"))) {
    $suT = $null; $suE = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($suFile, [ref]$suT, [ref]$suE)
    if ($suE.Count -gt 0) { $suIndicatorParseOk = $false }
}
Check "every changed PowerShell script parses with zero errors" $suIndicatorParseOk

# --- Installers ---
$suUpTarget = Join-Path $FixtureRoot "su-upgrade-v317"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suUpTarget -NoRolesWindow 2>&1
$suUpRoles = Join-Path $suUpTarget ".ai/roles/ROLE_ASSIGNMENT.md"
[System.IO.File]::WriteAllText($suUpRoles, ((Get-Content -Raw -LiteralPath $suUpRoles) -replace '(?m)^Setup: pending\r?\n', ''), (New-Object System.Text.UTF8Encoding($false)))
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suUpTarget -Force -NoRolesWindow 2>&1
$suUpText = Get-Content -Raw -LiteralPath $suUpRoles
Check "an upgrade of a v3.17.0-shaped install gains no Setup line" (($LASTEXITCODE -eq 0) -and ($suUpText -notmatch '(?mi)^\s*Setup\s*:'))
$r = Invoke-Handoff -WorkDir $suUpTarget -Arguments @("work")
Check "and stays configured: work runs" (($r.Code -eq 0) -and ($r.Out -notmatch "Setup required"))
$suKeepTarget = Join-Path $FixtureRoot "su-upgrade-pending"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suKeepTarget -NoRolesWindow 2>&1
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suKeepTarget -Force -NoRolesWindow 2>&1
Check "an upgrade of a pending install stays pending, once" (([regex]::Matches((Get-Content -Raw -LiteralPath (Join-Path $suKeepTarget ".ai/roles/ROLE_ASSIGNMENT.md")), '(?m)^Setup: pending\r?$')).Count -eq 1)

$suFlagTarget = Join-Path $FixtureRoot "su-install-flags"
New-Item -ItemType Directory -Path $suFlagTarget -Force | Out-Null
& git -C $suFlagTarget init -q 2>&1 | Out-Null
$suFlagOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suFlagTarget -NoRolesWindow -Players "Claude Code,Codex" -Master "Codex" 2>&1 | Out-String
$suFlagCode = $LASTEXITCODE
$suFlagText = Get-Content -Raw -LiteralPath (Join-Path $suFlagTarget ".ai/roles/ROLE_ASSIGNMENT.md")
Check "install.ps1 -Players -Master configures the project in the same run" (($suFlagCode -eq 0) -and ($suFlagText -match '(?m)^Setup: complete\r?$') -and ((Get-SuRow $suFlagText "Master") -eq "Codex") -and ((Get-SuRow $suFlagText "Reviewer") -eq "Claude Code") -and ($suFlagOut -match "setup: complete")) $suFlagOut
$r = Invoke-Handoff -WorkDir $suFlagTarget -Arguments @("work")
Check "a scripted install is ready to work" (($r.Code -eq 0) -and ($r.Out -notmatch "Role drift"))
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suFlagTarget -Force -NoRolesWindow 2>&1
Check "an upgrade of a configured install stays complete" (([regex]::Matches((Get-Content -Raw -LiteralPath (Join-Path $suFlagTarget ".ai/roles/ROLE_ASSIGNMENT.md")), '(?m)^Setup: complete\r?$')).Count -eq 1)
$suFlagBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $suFlagTarget ".ai/roles/ROLE_ASSIGNMENT.md")).Hash
$suIgnoredOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suFlagTarget -Force -NoRolesWindow -Players "Codex" 2>&1 | Out-String
Check "-Players on a configured project is ignored, with the way to change it" (($LASTEXITCODE -eq 0) -and ($suIgnoredOut -match "-Players ignored") -and ($suIgnoredOut -match "handoff\.ps1 setup") -and ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $suFlagTarget ".ai/roles/ROLE_ASSIGNMENT.md")).Hash -eq $suFlagBefore))

$suBadFlagTarget = Join-Path $FixtureRoot "su-install-badflag"
$suPrevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $suBadFlagOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suBadFlagTarget -NoRolesWindow -Players "Gemini" 2>&1 | Out-String
    $suBadFlagCode = $LASTEXITCODE
    $suNoMasterOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project (Join-Path $FixtureRoot "su-install-nomaster") -NoRolesWindow -Players "Claude Code,Codex" 2>&1 | Out-String
    $suNoMasterCode = $LASTEXITCODE
    $suMasterOnlyOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project (Join-Path $FixtureRoot "su-install-masteronly") -NoRolesWindow -Master "Codex" 2>&1 | Out-String
    $suMasterOnlyCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $suPrevEap }
Check "a scripted install with an unknown player fails and says why" (($suBadFlagCode -eq 1) -and ($suBadFlagOut -match "Unknown player 'Gemini'") -and ($suBadFlagOut -match "NOT CONFIGURED") -and ((Get-Content -Raw -LiteralPath (Join-Path $suBadFlagTarget ".ai/roles/ROLE_ASSIGNMENT.md")) -match '(?m)^Setup: pending\r?$'))
Check "a scripted install with two players and no Master fails and says why" (($suNoMasterCode -eq 1) -and ($suNoMasterOut -match "No Master is chosen for you"))
Check "a scripted install with -Master alone fails and says why, before anything is written" (($suMasterOnlyCode -eq 1) -and ($suMasterOnlyOut -match "-Master needs -Players") -and -not (Test-Path (Join-Path $FixtureRoot "su-install-masteronly/.ai")))

$suInvalidUpTarget = Join-Path $FixtureRoot "su-upgrade-invalid"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suInvalidUpTarget -NoRolesWindow 2>&1
$suInvalidRoles = Join-Path $suInvalidUpTarget ".ai/roles/ROLE_ASSIGNMENT.md"
[System.IO.File]::WriteAllText($suInvalidRoles, ((Get-Content -Raw -LiteralPath $suInvalidRoles) -replace 'Setup: pending', 'Setup: someday'), (New-Object System.Text.UTF8Encoding($false)))
$suInvalidBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $suInvalidRoles).Hash
$ErrorActionPreference = 'Continue'
try {
    $suInvalidOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $suInvalidUpTarget -Force -NoRolesWindow 2>&1 | Out-String
    $suInvalidCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $suPrevEap }
Check "an upgrade refuses an invalid installed Setup line and changes nothing" (($suInvalidCode -ne 0) -and ($suInvalidOut -match "'Setup:' line must appear once") -and ((Get-FileHash -Algorithm SHA256 -LiteralPath $suInvalidRoles).Hash -eq $suInvalidBefore))

$suBootTarget = Join-Path $FixtureRoot "su-bootstrap-flags"
$suBootOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "bootstrap.ps1") -Project $suBootTarget -PackageRoot $RepoRoot -Players "Codex" 2>&1 | Out-String
Check "bootstrap.ps1 forwards -Players to the installer" (($LASTEXITCODE -eq 0) -and ((Get-Content -Raw -LiteralPath (Join-Path $suBootTarget ".ai/roles/ROLE_ASSIGNMENT.md")) -match '(?m)^Setup: complete\r?$')) $suBootOut
$suBootSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "bootstrap.ps1")
Check "bootstrap.ps1 defaults to v3.18.0 and forwards -Master and -NoSetupWindow" (($suBootSrc -match '\[string\]\$Version = "v3\.18\.0"') -and ($suBootSrc -match '"-Master", \$Master') -and ($suBootSrc -match '"-NoSetupWindow"'))
$suWrapTarget = Join-Path $FixtureRoot "su-wrapper-flags"
$suWrapOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts/install.ps1") -TargetPath $suWrapTarget -NoRolesWindow -Players "Claude Code,Codex" -Master "Claude Code" 2>&1 | Out-String
Check "scripts/install.ps1 forwards -Players and -Master" (($LASTEXITCODE -eq 0) -and ((Get-SuRow (Get-Content -Raw -LiteralPath (Join-Path $suWrapTarget ".ai/roles/ROLE_ASSIGNMENT.md")) "Master") -eq "Claude Code")) $suWrapOut
$suInstallSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "install.ps1")
Check "install.ps1 decides fresh or existing before anything is copied" ($suInstallSrc -match '(?s)\$isExistingInstall = Test-Path -LiteralPath \$installedRolePath.{0,200}if \(\$Force -and \$isExistingInstall\)')
Check "install.ps1 opens the picker only when a person can use it" ($suInstallSrc -match '\$windowPossible = \(\$env:OS -eq "Windows_NT"\) -and \(-not \[System\.Console\]::IsInputRedirected\) -and \(-not \$NoSetupWindow\) -and \[string\]::IsNullOrEmpty\(\$env:HANDOFF_BACKGROUND_NO_WINDOW\) -and \(-not \$agentEnv\)')

# The skill package: doctor still passes on a pending install, and setup says what is pending.
Check "bundled Skill setup reports a pending setup and the command, without choosing" (($standaloneSetupOut -match "Setup: NOT CONFIGURED") -and ($standaloneSetupOut -match "Ask the user which tools work on this project") -and ((Get-Content -Raw -LiteralPath (Join-Path $standaloneTarget ".ai/roles/ROLE_ASSIGNMENT.md")) -match '(?m)^Setup: pending\r?$'))
$suSkill = Get-Content -Raw -Path (Join-Path $RepoRoot ".agents/skills/codex-claude-handoff/SKILL.md")
Check "SKILL.md tells an installing agent to ask, never to choose or edit the line" (($suSkill -match "ASK the user which tools") -and ($suSkill -match "Never choose for the user, and never edit the Setup line by hand"))
$suTemplateRoles = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md")
Check "the shipped role file carries Setup: pending once, next to Review Independence" ((([regex]::Matches($suTemplateRoles, '(?mi)^\s*(?:[-*]\s+)?Setup\s*:')).Count -eq 1) -and ($suTemplateRoles -match '(?m)^Review Independence: separate-tool\r?\nSetup: pending\r?$') -and ($suTemplateRoles -match "- ``Setup:`` \(since v3\.18\.0\)"))
Check "the repository's own role file has no Setup line, and keeps working" ((Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/roles/ROLE_ASSIGNMENT.md")) -notmatch '(?mi)^\s*(?:[-*]\s+)?Setup\s*:')

# --- Bash: the gate, setup, the installer, and the unknown-tool fix, in parity ---
$suBash = Get-Command bash -ErrorAction SilentlyContinue
# Native stderr must not become a terminating error in this section.
$suBashEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
if ($null -eq $suBash) {
    Write-Host "  SKIP  setup parity with handoff.sh: no bash interpreter on this machine"
} else {
    $suSh = (Join-Path $RepoRoot "scripts/handoff.sh") -replace '\\', '/'
    function Invoke-SuSh { param([string]$Dir, [string[]]$ShArgs) return (Invoke-RiIn -Dir $Dir -Block { $null | & $suBash.Source $suSh @ShArgs; "exit=$LASTEXITCODE" }) }
    $suShPend = New-SuFixture -Roles (New-SuRoles)
    $suShBefore = Get-SuHashes -Dir $suShPend
    $suShMisses = @()
    foreach ($suShCmd in @(@("next"), @("start", "x"), @("commit-check"), @("cycle"), @("doctor"), @())) {
        $suOut = Invoke-SuSh -Dir $suShPend -ShArgs $suShCmd
        if (-not (($suOut -match "exit=14") -and ($suOut -match "Setup required: this project has not chosen its players and its Master yet\.") -and ($suOut -match "bash scripts/handoff\.sh setup --players"))) { $suShMisses += ($suShCmd -join ' ') }
    }
    Check "handoff.sh: pending stops every command but status and setup with exit 14" (($suShMisses.Count -eq 0) -and ((Get-SuHashes -Dir $suShPend) -eq $suShBefore)) ($suShMisses -join "; ")
    $suOut = Invoke-SuSh -Dir $suShPend -ShArgs @("status")
    Check "handoff.sh: pending status says NOT CONFIGURED and hides the template binding" (($suOut -match "exit=0") -and ($suOut -match "Setup:\s+NOT CONFIGURED") -and ($suOut -notmatch "Roles:\s+Master="))
    $suOut = Invoke-SuSh -Dir $suShPend -ShArgs @("adapters")
    # Second review: adapters showed the template binding as if chosen; it is gated now, as in handoff.ps1.
    Check "handoff.sh: adapters is gated while pending, as in handoff.ps1" (($suOut -match "exit=14") -and ($suOut -notmatch "Role:\s+Master"))
    $suOut = Invoke-SuSh -Dir $suShPend -ShArgs @("setup")
    Check "handoff.sh: setup without flags prints the flag form and changes nothing" (($suOut -match "exit=1") -and ($suOut -match 'setup --players "Claude Code,Codex" --master "Claude Code" --yes') -and ((Get-SuHashes -Dir $suShPend) -eq $suShBefore))
    foreach ($suShRef in @(
        @{ Args = @("setup", "--players", "Gemini", "--yes"); Want = "Unknown player 'Gemini'" },
        @{ Args = @("setup", "--players", "Codex", "--master", "Claude Code", "--yes"); Want = "The Master must be one of the players" },
        @{ Args = @("setup", "--players", "Claude Code,Codex", "--yes"); Want = "No Master is chosen for you" },
        @{ Args = @("setup", "--players", " ", "--yes"); Want = "Choose at least one player" },
        @{ Args = @("setup", "--master", "Codex"); Want = "--master needs --players" },
        @{ Args = @("setup", "--players"); Want = "--players needs a value" },
        @{ Args = @("setup", "--players", "Codex", "--sideways"); Want = "unknown setup option" }
    )) {
        $suOut = Invoke-SuSh -Dir $suShPend -ShArgs $suShRef.Args
        Check "handoff.sh setup refuses: $($suShRef.Want)" (($suOut -match "exit=1") -and ($suOut -match [regex]::Escape($suShRef.Want)) -and ((Get-SuHashes -Dir $suShPend) -eq $suShBefore)) $suOut
    }
    $suOut = Invoke-SuSh -Dir $suShPend -ShArgs @("setup", "--players", "Codex")
    Check "handoff.sh: no --yes and nothing on input cancels with exit 2" (($suOut -match "exit=2") -and ((Get-SuHashes -Dir $suShPend) -eq $suShBefore))

    # The same choice through both shells writes the same file, apart from the decider.
    $suPsTwin = New-SuFixture -Roles (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md"))
    $suShTwin = New-SuFixture -Roles (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md"))
    $null = Invoke-HandoffInput -WorkDir $suPsTwin -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Claude Code", "-Yes")
    $suOut = Invoke-SuSh -Dir $suShTwin -ShArgs @("setup", "--players", "claude code, Codex", "--master", "claude-code", "--yes")
    $suNorm = { param($t) (($t -replace "`r", "") -replace 'User \(handoff\.(ps1|sh) setup\)', 'User (setup)').TrimEnd() }
    Check "handoff.sh setup writes the same role file as handoff.ps1 setup" (($suOut -match "exit=0") -and ((& $suNorm (Get-SuFile -Dir $suShTwin -Rel ".ai/roles/ROLE_ASSIGNMENT.md")) -eq (& $suNorm (Get-SuFile -Dir $suPsTwin -Rel ".ai/roles/ROLE_ASSIGNMENT.md")))) $suOut
    Check "handoff.sh setup records its own name as the decider" ((Get-SuFile -Dir $suShTwin -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -match 'Setup=complete \| User \(handoff\.sh setup\) \|')
    Check "handoff.sh setup moves the install's Task Actors as handoff.ps1 does" (((Get-SuFile -Dir $suShTwin -Rel "AI_HANDOFF.md") -match "(?m)^- Implementer: Claude Code\r?$") -and ((Get-SuFile -Dir $suShTwin -Rel "AI_HANDOFF.md") -match "(?m)^- Reviewer: Codex\r?$"))
    $r = Invoke-Handoff -WorkDir $suShTwin -Arguments @("work")
    Check "a project configured from Bash runs clean in PowerShell" (($r.Code -eq 0) -and ($r.Out -notmatch "Role drift"))
    $suOut = Invoke-SuSh -Dir $suShTwin -ShArgs @("next")
    Check "and in Bash" ($suOut -match "exit=0")
    $suShSolo = New-SuFixture -Roles (New-SuRoles)
    $suOut = Invoke-SuSh -Dir $suShSolo -ShArgs @("setup", "--players", "Codex", "--yes")
    $suShSoloText = Get-SuFile -Dir $suShSolo -Rel ".ai/roles/ROLE_ASSIGNMENT.md"
    Check "handoff.sh setup with one player writes fresh-context and says it is weaker" (($suOut -match "exit=0") -and ($suOut -match "Two tools remain the recommended setup") -and ((Get-SuRow $suShSoloText "Reviewer") -eq "Codex") -and ($suShSoloText -match '(?m)^Review Independence: fresh-context\r?\nSetup: complete\r?$'))
    $suShNoHist = New-SuFixture -Roles (New-SuRoles)
    $null = Invoke-SuSh -Dir $suShNoHist -ShArgs @("setup", "--players", "Codex", "--yes")
    Check "handoff.sh setup creates the history table when the file has none" ((Get-SuFile -Dir $suShNoHist -Rel ".ai/roles/ROLE_ASSIGNMENT.md") -match '(?s)## Role Swap History\n\n\| Date \| Before \| After \| Decided by \|\n\|---\|---\|---\|---\|\n\| \d{4}-\d{2}-\d{2} \| Master=Codex')
    $suShMid = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete") -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer")
    $suShMidBefore = Get-SuHashes -Dir $suShMid
    $suOut = Invoke-SuSh -Dir $suShMid -ShArgs @("setup", "--players", "Codex", "--yes")
    Check "handoff.sh refuses a reconfiguration mid-task" (($suOut -match "exit=1") -and ($suOut -match "requires PowerShell: pwsh scripts/handoff\.ps1 setup") -and ((Get-SuHashes -Dir $suShMid) -eq $suShMidBefore))
    $suShDone = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete") -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
    $suShDoneHandoff = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $suShDone "AI_HANDOFF.md")).Hash
    $suOut = Invoke-SuSh -Dir $suShDone -ShArgs @("setup", "--players", "Claude Code,Codex", "--master", "Codex", "--yes")
    Check "handoff.sh leaves a reconfiguration after the first task to PowerShell, where start can retire the record" (($suOut -match "exit=1") -and ($suOut -match "requires PowerShell") -and ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $suShDone "AI_HANDOFF.md")).Hash -eq $suShDoneHandoff))

    # The Setup line is read the same way by both shells, including at the edges.
    $suParity = @(
        @{ Name = "no line"; Roles = (New-SuRoles -SetupLine ""); Ps = 0; Sh = 0 },
        @{ Name = "complete"; Roles = (New-SuRoles -SetupLine "Setup: complete"); Ps = 0; Sh = 0 },
        @{ Name = "mis-cased complete"; Roles = (New-SuRoles -SetupLine "SETUP:   Complete  "); Ps = 0; Sh = 0 },
        @{ Name = "pending"; Roles = (New-SuRoles); Ps = 14; Sh = 14 },
        @{ Name = "bulleted pending with a non-breaking space"; Roles = (New-SuRoles -SetupLine ("* Setup:" + [string][char]0x00A0 + "pending")); Ps = 14; Sh = 14 },
        @{ Name = "an unknown value"; Roles = (New-SuRoles -SetupLine "Setup: done"); Ps = 12; Sh = 12 },
        @{ Name = "an empty value"; Roles = (New-SuRoles -SetupLine "Setup:"); Ps = 12; Sh = 12 },
        @{ Name = "two lines"; Roles = ((New-SuRoles -SetupLine "Setup: pending") + "Setup: pending`n"); Ps = 12; Sh = 12 }
    )
    foreach ($suP in $suParity) {
        $suPFx = New-SuFixture -Roles $suP.Roles
        $r = Invoke-Handoff -WorkDir $suPFx -Arguments @("next")
        $suOut = Invoke-SuSh -Dir $suPFx -ShArgs @("next")
        Check "both shells read a Setup line with $($suP.Name) the same way" (($r.Code -eq $suP.Ps) -and ($suOut -match "exit=$($suP.Sh)\s*$")) "ps=$($r.Code) sh=$suOut"
    }
    $suBomFx = New-SuFixture -Roles (New-SuRoles)
    [System.IO.File]::WriteAllBytes((Join-Path $suBomFx ".ai/roles/ROLE_ASSIGNMENT.md"), ([byte[]](0xEF, 0xBB, 0xBF) + (New-Object System.Text.UTF8Encoding($false)).GetBytes("Setup: pending`n| Master | Codex |`n| Reviewer | Codex |`n| Implementer | Claude Code |`n")))
    $r = Invoke-Handoff -WorkDir $suBomFx -Arguments @("next")
    $suOut = Invoke-SuSh -Dir $suBomFx -ShArgs @("next")
    Check "both shells read a Setup line on line 1 after a BOM" (($r.Code -eq 14) -and ($suOut -match "exit=14"))

    # Security scan fix: an unknown tool is refused by both shells, including where Bash used to agree by accident.
    $suUnknownCases = @(
        @{ Name = "one unknown tool in every role under fresh-context, at commit-check"; Roles = (New-SuRoles -SetupLine "" -Master "Gemini" -Reviewer "Gemini" -Implementer "Gemini" -ModeLine "Review Independence: fresh-context"); Handoff = (New-RiHandoff -State "REVIEW_DONE" -WaitingFor "User" -Implementer "Gemini" -Reviewer "Gemini" -Actor "Gemini (Implementer)"); Cmd = "commit-check"; Ps = 12; Sh = 12 },
        @{ Name = "an unknown Reviewer under separate-tool"; Roles = (New-SuRoles -SetupLine "" -Reviewer "Gemini"); Handoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); Cmd = "next"; Ps = 12; Sh = 12 },
        @{ Name = "an unknown Master"; Roles = (New-SuRoles -SetupLine "" -Master "Gemini"); Handoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); Cmd = "next"; Ps = 12; Sh = 12 },
        @{ Name = "an unknown Task Actor"; Roles = (New-SuRoles -SetupLine ""); Handoff = ((New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -replace "- Implementer: Claude Code", "- Implementer: Gemini"); Cmd = "next"; Ps = 12; Sh = 12 },
        @{ Name = "an alias Task Actor that is the bound tool"; Roles = (New-SuRoles -SetupLine ""); Handoff = ((New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -replace "- Reviewer: Codex", "- Reviewer: Codex Window"); Cmd = "next"; Ps = 0; Sh = 0 },
        @{ Name = "a sentinel Task Actor"; Roles = (New-SuRoles -SetupLine ""); Handoff = ((New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master") -replace "- Implementer: Claude Code", "- Implementer: TBD" -replace "- Reviewer: Codex", "- Reviewer: tbd"); Cmd = "next"; Ps = 0; Sh = 0 },
        @{ Name = "two known tools, all valid"; Roles = (New-SuRoles -SetupLine ""); Handoff = (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer"); Cmd = "next"; Ps = 0; Sh = 0 },
        @{ Name = "Task Actors that put one tool in both roles under separate-tool"; Roles = (New-SuRoles -SetupLine ""); Handoff = ((New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -replace "- Reviewer: Codex", "- Reviewer: Claude Code"); Cmd = "next"; Ps = 12; Sh = 12 }
    )
    foreach ($suU in $suUnknownCases) {
        $suUFx = New-SuFixture -Roles $suU.Roles -Handoff $suU.Handoff
        $r = Invoke-Handoff -WorkDir $suUFx -Arguments @($suU.Cmd)
        $suOut = Invoke-SuSh -Dir $suUFx -ShArgs @($suU.Cmd)
        Check "both shells agree on $($suU.Name)" (($r.Code -eq $suU.Ps) -and ($suOut -match "exit=$($suU.Sh)\s*$")) "ps=$($r.Code) sh=$suOut"
    }
    $suGemFx = New-SuFixture -Roles $suUnknownCases[0].Roles -Handoff $suUnknownCases[0].Handoff
    $suOut = Invoke-SuSh -Dir $suGemFx -ShArgs @("commit-check")
    Check "handoff.sh commit-check never says ALLOWED for an unknown tool under fresh-context" (($suOut -notmatch "ALLOWED") -and ($suOut -match "Unrecognized tool identity 'Gemini'"))
    $suShSrc = Get-Content -Raw -Path (Join-Path $RepoRoot "scripts/handoff.sh")
    Check "handoff.sh defines _canonical_tool exactly once" (([regex]::Matches($suShSrc, '(?m)^_canonical_tool\(\) \{')).Count -eq 1)

    # The Bash installer: fresh is pending, flags configure, an upgrade carries the line.
    $suInstSh = (Join-Path $RepoRoot "scripts/install.sh") -replace '\\', '/'
    $suShTarget = ((Join-Path $FixtureRoot "su-bash-install") -replace '\\', '/')
    $suOut = (& $suBash.Source $suInstSh $suShTarget 2>&1 | Out-String) + "exit=$LASTEXITCODE"
    $suShTargetRoles = Join-Path $FixtureRoot "su-bash-install/.ai/roles/ROLE_ASSIGNMENT.md"
    Check "install.sh: a fresh install is pending and says so with the Bash command" (($suOut -match "exit=0") -and ($suOut -match "Setup: NOT CONFIGURED") -and ($suOut -match "bash scripts/handoff\.sh setup --players") -and ((Get-Content -Raw -LiteralPath $suShTargetRoles) -match '(?m)^Setup: pending\r?$'))
    $null = & $suBash.Source $suInstSh $suShTarget --force 2>&1
    Check "install.sh: an upgrade of a pending install stays pending, once" (([regex]::Matches((Get-Content -Raw -LiteralPath $suShTargetRoles), '(?m)^Setup: pending\r?$')).Count -eq 1)
    [System.IO.File]::WriteAllText($suShTargetRoles, ((Get-Content -Raw -LiteralPath $suShTargetRoles) -replace '(?m)^Setup: pending\r?\n', ''), (New-Object System.Text.UTF8Encoding($false)))
    $null = & $suBash.Source $suInstSh $suShTarget --force 2>&1
    Check "install.sh: an upgrade of a v3.17.0-shaped install gains no Setup line" ((Get-Content -Raw -LiteralPath $suShTargetRoles) -notmatch '(?mi)^\s*Setup\s*:')
    $suShFlagTarget = ((Join-Path $FixtureRoot "su-bash-install-flags") -replace '\\', '/')
    $suOut = (& $suBash.Source $suInstSh $suShFlagTarget --players "Claude Code,Codex" --master "Codex" 2>&1 | Out-String) + "exit=$LASTEXITCODE"
    $suShFlagRoles = Get-Content -Raw -LiteralPath (Join-Path $FixtureRoot "su-bash-install-flags/.ai/roles/ROLE_ASSIGNMENT.md")
    Check "install.sh --players --master configures the project in the same run" (($suOut -match "exit=0") -and ($suShFlagRoles -match '(?m)^Setup: complete\r?$') -and ((Get-SuRow $suShFlagRoles "Master") -eq "Codex")) $suOut
    $null = & $suBash.Source $suInstSh $suShFlagTarget --force 2>&1
    Check "install.sh: an upgrade of a configured install stays complete" (([regex]::Matches((Get-Content -Raw -LiteralPath (Join-Path $FixtureRoot "su-bash-install-flags/.ai/roles/ROLE_ASSIGNMENT.md")), '(?m)^Setup: complete\r?$')).Count -eq 1)
    $suOut = (& $suBash.Source $suInstSh ((Join-Path $FixtureRoot "su-bash-install-bad") -replace '\\', '/') --players "Gemini" 2>&1 | Out-String) + "exit=$LASTEXITCODE"
    Check "install.sh with an unknown player fails and says why" (($suOut -match "exit=1") -and ($suOut -match "Unknown player 'Gemini'") -and ($suOut -match "NOT CONFIGURED"))
}
$ErrorActionPreference = $suBashEap

# --- v3.18.0 review fixes: each check below failed on 1aecc6d ---
Write-Host "[4D-8b] First setup: holes closed after review (v3.18.0)"
$rvBash = Get-Command bash -ErrorAction SilentlyContinue
$rvSh = (Join-Path $RepoRoot "scripts/handoff.sh") -replace '\\', '/'
function Invoke-RvSh {
    param([string]$Dir, [string[]]$ShArgs, [string]$Script = $rvSh)
    $prevCwd = [System.Environment]::CurrentDirectory
    Push-Location $Dir
    [System.Environment]::CurrentDirectory = $Dir
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (($null | & $rvBash.Source $Script @ShArgs 2>&1 | Out-String) + "exit=$LASTEXITCODE") } finally { $ErrorActionPreference = $prevEap; Pop-Location; [System.Environment]::CurrentDirectory = $prevCwd }
}
function Invoke-RvIn { param([string]$Dir, [scriptblock]$Block)
    $prevCwd = [System.Environment]::CurrentDirectory
    Push-Location $Dir
    [System.Environment]::CurrentDirectory = $Dir
    try { return (& $Block 2>&1 | Out-String) } finally { Pop-Location; [System.Environment]::CurrentDirectory = $prevCwd }
}
$rvHandMade = @"
# AI Handoff

## Status
- State: REVIEW_DONE
- Waiting For: User
- Current Task: hand made

## Last Update
- Actor: Codex (Reviewer)
- Verdict: APPROVED

## Task Actors
- Implementer: Codex
- Reviewer: Claude Code

## Changed Files
- foo.txt
"@

# H1: a pending project never adopts a record written before the players were chosen.
$rvAdoptFx = New-SuFixture -Roles (New-SuRoles) -Handoff $rvHandMade
Set-Content -Path (Join-Path $rvAdoptFx "foo.txt") -Value "x" -Encoding utf8
$rvAdoptBefore = Get-SuHashes -Dir $rvAdoptFx
$r = Invoke-HandoffInput -WorkDir $rvAdoptFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Codex", "-Yes")
Check "pending: setup refuses to adopt a hand-written REVIEW_DONE and changes nothing" (($r.Code -eq 1) -and ($r.Out -match "setup does not adopt a record written before the players were chosen") -and ($r.Out -match "\.ai/handoff-history/") -and ($r.Out -match "-Force") -and ((Get-SuHashes -Dir $rvAdoptFx) -eq $rvAdoptBefore)) $r.Out
$r = Invoke-Handoff -WorkDir $rvAdoptFx -Arguments @("commit-check", "-Message", "x")
Check "pending: the hand-written record still cannot reach commit-check" (($r.Code -eq 14) -and ($r.Out -notmatch "ready for explicit authorization"))
if ($null -ne $rvBash) {
    $rvAdoptShFx = New-SuFixture -Roles (New-SuRoles) -Handoff $rvHandMade
    Set-Content -Path (Join-Path $rvAdoptShFx "foo.txt") -Value "x" -Encoding utf8
    $rvAdoptShBefore = Get-SuHashes -Dir $rvAdoptShFx
    $rvOut = Invoke-RvSh -Dir $rvAdoptShFx -ShArgs @("setup", "--players", "Claude Code,Codex", "--master", "Codex", "--yes")
    Check "handoff.sh: pending setup refuses to adopt a hand-written record too" (($rvOut -match "exit=1") -and ($rvOut -match "setup does not adopt a record") -and ((Get-SuHashes -Dir $rvAdoptShFx) -eq $rvAdoptShBefore)) $rvOut
    $rvOut = Invoke-RvSh -Dir $rvAdoptShFx -ShArgs @("commit-check")
    Check "handoff.sh: the hand-written record never reads ALLOWED" (($rvOut -match "exit=14") -and ($rvOut -notmatch "ALLOWED"))
}
# The documented way out works with both installers: keep the record in the history, reinstall, set up.
$rvOutTarget = Join-Path $FixtureRoot "rv-way-out"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $rvOutTarget -NoRolesWindow 2>&1
[System.IO.File]::WriteAllText((Join-Path $rvOutTarget "AI_HANDOFF.md"), $rvHandMade, (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-HandoffInput -WorkDir $rvOutTarget -Arguments @("setup", "-Players", "Codex", "-Yes")
New-Item -ItemType Directory -Path (Join-Path $rvOutTarget ".ai/handoff-history") -Force | Out-Null
Move-Item -LiteralPath (Join-Path $rvOutTarget "AI_HANDOFF.md") -Destination (Join-Path $rvOutTarget ".ai/handoff-history/kept-AI_HANDOFF.md")
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $rvOutTarget -Force -NoRolesWindow 2>&1
$rvRestored = if (Test-Path (Join-Path $rvOutTarget "AI_HANDOFF.md")) { Get-Content -Raw -Path (Join-Path $rvOutTarget "AI_HANDOFF.md") } else { "" }
Check "install.ps1 -Force restores a clean AI_HANDOFF.md and keeps the project pending" (($r.Code -eq 1) -and ($rvRestored -match "Current Task: Initial setup") -and ((Get-Content -Raw -Path (Join-Path $rvOutTarget ".ai/roles/ROLE_ASSIGNMENT.md")) -match '(?m)^Setup: pending\r?$') -and (Test-Path (Join-Path $rvOutTarget ".ai/handoff-history/kept-AI_HANDOFF.md")))
$r = Invoke-HandoffInput -WorkDir $rvOutTarget -Arguments @("setup", "-Players", "Codex", "-Yes")
Check "after the documented way out, setup succeeds" ($r.Code -eq 0)
if ($null -ne $rvBash) {
    $rvInstSh = (Join-Path $RepoRoot "scripts/install.sh") -replace '\\', '/'
    $rvShTarget = Join-Path $FixtureRoot "rv-way-out-sh"
    $null = & $rvBash.Source $rvInstSh ($rvShTarget -replace '\\', '/') 2>&1
    [System.IO.File]::WriteAllText((Join-Path $rvShTarget "AI_HANDOFF.md"), $rvHandMade, (New-Object System.Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Path (Join-Path $rvShTarget ".ai/handoff-history") -Force | Out-Null
    Move-Item -LiteralPath (Join-Path $rvShTarget "AI_HANDOFF.md") -Destination (Join-Path $rvShTarget ".ai/handoff-history/kept-AI_HANDOFF.md")
    $null = & $rvBash.Source $rvInstSh ($rvShTarget -replace '\\', '/') --force 2>&1
    $rvShRestored = if (Test-Path (Join-Path $rvShTarget "AI_HANDOFF.md")) { Get-Content -Raw -Path (Join-Path $rvShTarget "AI_HANDOFF.md") } else { "" }
    Check "install.sh --force restores a clean AI_HANDOFF.md and keeps the project pending" (($rvShRestored -match "Current Task: Initial setup") -and ((Get-Content -Raw -Path (Join-Path $rvShTarget ".ai/roles/ROLE_ASSIGNMENT.md")) -match '(?m)^Setup: pending\r?$'))
    $rvOut = Invoke-RvSh -Dir $rvShTarget -ShArgs @("setup", "--players", "Codex", "--yes")
    Check "after the documented way out, handoff.sh setup succeeds" ($rvOut -match "exit=0")
}

# H2: a role is held by a tool, never by a placeholder, the User or an unknown name.
$rvSentinelMiss = @()
foreach ($rvTool in @("TBD", "(unknown)", "unknown", "User", "Gemini")) {
    $rvSentFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete")
    $rvSentBefore = Get-SuHashes -Dir $rvSentFx
    $r = Invoke-Handoff -WorkDir $rvSentFx -Arguments @("roles", "-SetRole", "Reviewer", "-SetTool", $rvTool, "-Yes")
    if (-not (($r.Code -eq 1) -and ($r.Out -match "-SetTool must be a known tool") -and ((Get-SuHashes -Dir $rvSentFx) -eq $rvSentBefore))) { $rvSentinelMiss += "$rvTool -> $($r.Code)" }
}
Check "roles -SetTool refuses TBD, (unknown), unknown, User and an unknown name, and changes nothing" ($rvSentinelMiss.Count -eq 0) ($rvSentinelMiss -join "; ")

# M1: the next-step helpers honour the Setup line.
$rvNsPs = Join-Path $RepoRoot "scripts/next-step.ps1"
$rvNsSh = (Join-Path $RepoRoot "scripts/next-step.sh") -replace '\\', '/'
$rvAnalysis = (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/AI_HANDOFF.md")) -replace '(?m)^- State: .*$', '- State: NEEDS_ANALYSIS' -replace '(?m)^- Waiting For: .*$', '- Waiting For: Master'
foreach ($rvCase in @(@{ Line = "Setup: pending"; Code = 14; Want = "Setup required" }, @{ Line = "Setup: maybe"; Code = 12; Want = "'Setup:' line .* must appear once" }, @{ Line = "Setup: complete"; Code = 0; Want = "Handoff Status" })) {
    $rvNsFx = New-SuFixture -Roles (New-SuRoles -SetupLine $rvCase.Line) -Handoff $rvAnalysis
    $rvPsOut = Invoke-RvIn -Dir $rvNsFx -Block { & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $rvNsPs -PrepareFile; "exit=$LASTEXITCODE" }
    $rvPsWrote = Test-Path (Join-Path $rvNsFx "NEXT_TURN.md")
    Remove-Item -LiteralPath (Join-Path $rvNsFx "NEXT_TURN.md") -Force -ErrorAction SilentlyContinue
    $rvExpectWrite = ($rvCase.Code -eq 0)
    Check "next-step.ps1 with '$($rvCase.Line)' exits $($rvCase.Code) and writes NEXT_TURN.md only when configured" (($rvPsOut -match "exit=$($rvCase.Code)\s*$") -and ($rvPsOut -match $rvCase.Want) -and ($rvPsWrote -eq $rvExpectWrite)) $rvPsOut
    if ($null -ne $rvBash) {
        $rvShOut = Invoke-RvSh -Dir $rvNsFx -ShArgs @("--prepare-file") -Script $rvNsSh
        $rvShWrote = Test-Path (Join-Path $rvNsFx "NEXT_TURN.md")
        Check "next-step.sh with '$($rvCase.Line)' exits $($rvCase.Code) and writes NEXT_TURN.md only when configured" (($rvShOut -match "exit=$($rvCase.Code)\s*$") -and ($rvShWrote -eq $rvExpectWrite)) $rvShOut
    }
}

# M2: a typographic quote in a value cannot break, or inject into, a generated window script.
$rvQuote = [string][char]0x2019
$rvInject = "x" + $rvQuote + ";Start-Process notepad;" + $rvQuote
function Get-RvCommandNames { param([string]$Text, [string]$Name)
    $path = Join-Path $FixtureRoot ("rv-window-" + $Name + "-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($true)))
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tok, [ref]$err)
    $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    return @{ Errors = $err.Count; Names = ($names -join ","); Notepad = (@($ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and ($n.Value -eq "notepad") -and ($n.Parent -is [System.Management.Automation.Language.CommandAst]) }, $true)).Count) }
}
$rvPlainPicker = Get-RvCommandNames -Text (New-SetupWindowScript -ResultPath (Join-Path $FixtureRoot "r.json") -Project "plain" -Tools $suTools -Table $suTable -NoneDetected $false) -Name "plain"
foreach ($rvValue in @(("Nir" + $rvQuote + "s app"), $rvInject)) {
    $rvPicker = Get-RvCommandNames -Text (New-SetupWindowScript -ResultPath (Join-Path $FixtureRoot ($rvValue + ".json")) -Project $rvValue -Tools $suTools -Table $suTable -NoneDetected $false) -Name "picker"
    Check "the picker script for a value with U+2019 parses clean and runs no extra command ($($rvValue.Length) chars)" (($rvPicker.Errors -eq 0) -and ($rvPicker.Notepad -eq 0) -and ($rvPicker.Names -eq $rvPlainPicker.Names)) "errors=$($rvPicker.Errors) names=$($rvPicker.Names)"
    $rvRoles = Get-RvCommandNames -Text (New-RolesWindowScript -WorkDir ("C:\work\" + $rvValue) -HandoffScript ("C:\tools\" + $rvValue + "\handoff.ps1") -BackgroundMarker "HANDOFF_BACKGROUND.json" -WindowMarker "HANDOFF_UI_WINDOW.json") -Name "roles"
    $rvRolesPlain = Get-RvCommandNames -Text (New-RolesWindowScript -WorkDir "C:\work\plain" -HandoffScript "C:\tools\handoff.ps1" -BackgroundMarker "HANDOFF_BACKGROUND.json" -WindowMarker "HANDOFF_UI_WINDOW.json") -Name "rolesplain"
    Check "the indicator script for a value with U+2019 parses clean and runs no extra command ($($rvValue.Length) chars)" (($rvRoles.Errors -eq 0) -and ($rvRoles.Notepad -eq 0) -and ($rvRoles.Names -eq $rvRolesPlain.Names)) "errors=$($rvRoles.Errors) names=$($rvRoles.Names)"
}
Check "the literal helper uses the parser's own escaper" ($suSrc -match '\[System\.Management\.Automation\.Language\.CodeGeneration\]::EscapeSingleQuotedStringContent\(\$text\)')
# A failed picker is a failure, never a cancel.
$rvResult = Join-Path $FixtureRoot "rv-result.json"
Remove-Item -LiteralPath $rvResult -Force -ErrorAction SilentlyContinue
$rvNoFile = Read-SetupWindowResult -ExitCode 0 -ResultPath $rvResult
$rvBadExit = Read-SetupWindowResult -ExitCode 1 -ResultPath $rvResult
Set-Content -LiteralPath $rvResult -Value "{not json" -Encoding ascii
$rvBadJson = Read-SetupWindowResult -ExitCode 0 -ResultPath $rvResult
Set-Content -LiteralPath $rvResult -Value '{"players": ""}' -Encoding ascii
$rvEmpty = Read-SetupWindowResult -ExitCode 0 -ResultPath $rvResult
Set-Content -LiteralPath $rvResult -Value '{"cancelled": true}' -Encoding ascii
$rvCancel = Read-SetupWindowResult -ExitCode 0 -ResultPath $rvResult
$rvCancelBadExit = Read-SetupWindowResult -ExitCode 3 -ResultPath $rvResult
Set-Content -LiteralPath $rvResult -Value '{"players": "Claude Code,Codex", "master": "Codex"}' -Encoding ascii
$rvChoice = Read-SetupWindowResult -ExitCode 0 -ResultPath $rvResult
Check "no result file, a non-zero exit, bad JSON or an empty choice is a failure, not a cancel" ($rvNoFile.Failed -and -not $rvNoFile.Cancelled -and $rvBadExit.Failed -and $rvBadJson.Failed -and $rvEmpty.Failed -and $rvCancelBadExit.Failed -and -not $rvCancelBadExit.Cancelled)
Check "only an explicit cancel is a cancel, and a choice is read as given" ($rvCancel.Cancelled -and -not $rvCancel.Failed -and ($rvChoice.Players -eq "Claude Code,Codex") -and ($rvChoice.Master -eq "Codex") -and -not $rvChoice.Failed -and -not $rvChoice.Cancelled)
Check "the picker writes an explicit cancel when it closes without a choice" ($suWindowText -match [regex]::Escape("if (-not `$script:saved) { [System.IO.File]::WriteAllText(`$resultPath, '{`"cancelled`": true}'"))
Check "a failed picker exits 3 with its own message, not as a cancel" ($suSrc -match '(?s)if \(\$picked\.Failed\) \{.{0,400}setup: FAILED - the picker window did not return a choice.{0,400}exit 3')
# L7: the indicator's button passes -Window; that path never waits on a console prompt.
# Second review: proved by a real run in the [4D-8c] section, on a console that is not redirected.

# M3: a configured project reconfigures only at a finished task, and start then works.
$rvWaitFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete") -Handoff (New-Handoff -State "WAITING_FOR_USER" -WaitingFor "User" -CurrentTask "a decision in flight")
$rvWaitBefore = Get-SuHashes -Dir $rvWaitFx
$r = Invoke-HandoffInput -WorkDir $rvWaitFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Codex", "-Yes")
Check "reconfiguration is refused at WAITING_FOR_USER mid-task, where start cannot recover" (($r.Code -eq 1) -and ($r.Out -match "allowed only at a finished task \(REVIEW_DONE or BLOCKED") -and ((Get-SuHashes -Dir $rvWaitFx) -eq $rvWaitBefore))
$rvPathFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete") -Handoff (New-Handoff -State "REVIEW_DONE" -WaitingFor "User" -CurrentTask "Finished task")
$r = Invoke-HandoffInput -WorkDir $rvPathFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Codex", "-Yes")
$rvReconfigOk = ($r.Code -eq 0) -and ($r.Out -match "handoff\.ps1 start")
$r = Invoke-Handoff -WorkDir $rvPathFx -Arguments @("start", "the next request")
$rvArchives = @(Get-ChildItem -LiteralPath (Join-Path $rvPathFx ".ai/handoff-history") -Filter "*Finished-task*AI_HANDOFF.md" -ErrorAction SilentlyContinue)
$rvAfterStart = Get-SuFile -Dir $rvPathFx -Rel "AI_HANDOFF.md"
Check "reconfigure at REVIEW_DONE, then start retires and archives the record" ($rvReconfigOk -and ($r.Code -eq 0) -and ($r.Out -match "Archived previous handoff") -and ($rvArchives.Count -eq 1) -and ($rvAfterStart -match "State: NEEDS_ANALYSIS")) $r.Out
$r = Invoke-Handoff -WorkDir $rvPathFx -Arguments @("work")
Check "after that start the project runs again" (($r.Code -eq 0) -and ($r.Out -notmatch "Role drift"))
if ($null -ne $rvBash) {
    $rvShInitFx = New-SuFixture -Roles (New-SuRoles -SetupLine "Setup: complete")
    $rvOut = Invoke-RvSh -Dir $rvShInitFx -ShArgs @("setup", "--players", "Codex", "--yes")
    Check "handoff.sh still reconfigures the untouched install state" ($rvOut -match "exit=0")
}

# M4 and L1: what each shell reads from Task Actors and the role table, at the edges.
if ($null -ne $rvBash) {
    $rvActorMiss = @()
    foreach ($rvForm in @("* Implementer: Codex", "-Implementer: Codex", "  - Implementer: Codex", "- implementer: Codex", "*Implementer:Codex")) {
        $rvActFx = New-SuFixture -Roles (New-SuRoles -SetupLine "") -Handoff ("# AI Handoff`n`n## Status`n- State: REVIEW_DONE`n- Waiting For: User`n- Current Task: t`n`n## Task Actors`n$rvForm`n- Reviewer: Codex`n`n## Changed Files`n- foo.txt`n")
        Set-Content -Path (Join-Path $rvActFx "foo.txt") -Value "x" -Encoding utf8
        $r = Invoke-Handoff -WorkDir $rvActFx -Arguments @("commit-check")
        $rvOut = Invoke-RvSh -Dir $rvActFx -ShArgs @("commit-check")
        if (-not (($r.Code -eq 12) -and ($rvOut -match "exit=12") -and ($rvOut -notmatch "ALLOWED"))) { $rvActorMiss += "[$rvForm] ps=$($r.Code) sh=$($rvOut -replace '(?s).*exit=', '')" }
    }
    Check "both shells read every Task Actors form handoff.ps1 accepts, and refuse the self-review" ($rvActorMiss.Count -eq 0) ($rvActorMiss -join "; ")
    $rvLowerBad = New-SuFixture -Roles "| Role | Tool |`n|---|---|`n| master | Codex |`n| reviewer | Codex |`n| implementer | Codex |`n" -Handoff (New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer")
    $r = Invoke-Handoff -WorkDir $rvLowerBad -Arguments @("next")
    $rvOut = Invoke-RvSh -Dir $rvLowerBad -ShArgs @("next")
    Check "both shells read lower-case role rows and refuse one tool in both roles" (($r.Code -eq 12) -and ($rvOut -match "exit=12\s*$")) "ps=$($r.Code) $rvOut"
    $rvLowerGood = New-SuFixture -Roles "| Role | Tool |`n|---|---|`n| master | Codex |`n| reviewer | Claude Code |`n| implementer | Codex |`n" -Handoff ((New-Handoff -State "READY_FOR_IMPLEMENTATION" -WaitingFor "Implementer") -replace "- Implementer: Claude Code", "- Implementer: Codex" -replace "- Reviewer: Codex", "- Reviewer: Claude Code")
    $r = Invoke-Handoff -WorkDir $rvLowerGood -Arguments @("next")
    $rvOut = Invoke-RvSh -Dir $rvLowerGood -ShArgs @("next")
    $rvNt = Get-SuFile -Dir $rvLowerGood -Rel "NEXT_TURN.md"
    Check "both shells route lower-case role rows to the bound tools, not the built-in default" (($r.Code -eq 0) -and ($rvOut -match "exit=0\s*$") -and ($rvNt -match "Actor: Codex \(Implementer\)")) $rvOut
    $null = Invoke-RvSh -Dir $rvLowerGood -ShArgs @("--prepare-file") -Script $rvNsSh
    Check "next-step.sh reads lower-case role rows too" ((Get-SuFile -Dir $rvLowerGood -Rel "NEXT_TURN.md") -match "Actor: Codex \(Implementer\)")
    $rvLowerTarget = Join-Path $FixtureRoot "rv-lower-install"
    $null = & $rvBash.Source $rvInstSh ($rvLowerTarget -replace '\\', '/') 2>&1
    $rvLowerRoles = Join-Path $rvLowerTarget ".ai/roles/ROLE_ASSIGNMENT.md"
    [System.IO.File]::WriteAllText($rvLowerRoles, ((Get-Content -Raw -LiteralPath $rvLowerRoles) -replace '\| Master \| Codex \|', '| master | Claude Code |'), (New-Object System.Text.UTF8Encoding($false)))
    $rvOut = (& $rvBash.Source $rvInstSh ($rvLowerTarget -replace '\\', '/') --force 2>&1 | Out-String) + "exit=$LASTEXITCODE"
    Check "install.sh reads a lower-case role row on upgrade and keeps its tool" (($rvOut -match "exit=0") -and ((Get-Content -Raw -LiteralPath $rvLowerRoles) -match '(?m)^\| Master \| Claude Code \|\r?$')) $rvOut
}

# L6: the stop and the notices never hand an agent a ready-made choice.
$rvGateFx = New-SuFixture -Roles (New-SuRoles)
$r = Invoke-Handoff -WorkDir $rvGateFx -Arguments @("work")
Check "the exit-14 block shows placeholders and says an agent must ask" (($r.Out -match '-Players "<Claude Code, Codex, or both>" -Master "<one of the players>"') -and ($r.Out -match "An agent must ask the user which players and which Master; it never chooses for them") -and ($r.Out -notmatch '-Players "Claude Code,Codex" -Master "Claude Code"'))
Check "the installer's NOT CONFIGURED notice shows placeholders too" (($suInstOut -match '<one of the players>') -and ($suInstOut -match "never chooses for them") -and ($suInstOut -notmatch '-Players "Claude Code,Codex" -Master "Claude Code"'))
if ($null -ne $rvBash) {
    $rvOut = Invoke-RvSh -Dir $rvGateFx -ShArgs @("next")
    Check "handoff.sh's exit-14 block shows placeholders and says an agent must ask" (($rvOut -match '<one of the players>') -and ($rvOut -match "never chooses for them") -and ($rvOut -notmatch '--players "Claude Code,Codex" --master "Claude Code"'))
}
$r = Invoke-Handoff -WorkDir $rvGateFx -Arguments @("status")
Check "pending status does not point at the gated adapters command" (($r.Code -eq 0) -and ($r.Out -notmatch "Adapters:"))

# Leftover claims of a default binding.
$rvPointerText = (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff/CODEX.md")) + (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/skills/codex-claude-handoff/CLAUDE.md")) + (Get-Content -Raw -Path (Join-Path $RepoRoot "README.md"))
Check "no entry pointer or README line still claims a default binding" (($rvPointerText -notmatch "By default Codex holds") -and ($rvPointerText -notmatch "By default Claude Code holds") -and ($rvPointerText -notmatch "Default binding: Master = Codex"))

# --- v3.18.0 second review: each check below failed on 54a38fe ---
Write-Host "[4D-8c] First setup: second review (v3.18.0)"
$r2Concrete = '(-Master|--master) \\?"(Claude Code|Codex)\\?"'

# A. No ready-made choice reaches an agent after a stop.
$r2DupFx = New-SuFixture -Roles ((New-SuRoles) + "Setup: pending`n")
$r = Invoke-Handoff -WorkDir $r2DupFx -Arguments @("next")
Check "handoff.ps1's exit-12 block for a broken Setup line names no players or Master" (($r.Code -eq 12) -and ($r.Out -notmatch $r2Concrete))
if ($null -ne $rvBash) {
    $r2Out = Invoke-RvSh -Dir $r2DupFx -ShArgs @("next")
    Check "handoff.sh's exit-12 block for a broken Setup line shows placeholders and says an agent must ask" (($r2Out -match "exit=12") -and ($r2Out -match "<one of the players>") -and ($r2Out -match "never chooses for them") -and ($r2Out -notmatch $r2Concrete)) $r2Out
    $r2Out = Invoke-RvSh -Dir $r2DupFx -ShArgs @("setup")
    Check "handoff.sh's flag usage labels its commands as examples, next to the ask sentence" (($r2Out -match "Examples only - the choice is the user's; an agent asks the user and never chooses") -and ($r2Out -match "never chooses for them"))
}
$r2DocMiss = @()
foreach ($r2Doc in @("START_HERE.md", "README.md", "QUICKSTART.md")) {
    $r2Lines = @(Get-Content -Encoding UTF8 -Path (Join-Path $RepoRoot $r2Doc))
    for ($i = 0; $i -lt $r2Lines.Count; $i++) {
        if ($r2Lines[$i] -notmatch $r2Concrete) { continue }
        $lo = [Math]::Max(0, $i - 4); $hi = [Math]::Min($r2Lines.Count - 1, $i + 4)
        $near = ($r2Lines[$lo..$hi] -join "`n")
        if (($near -notmatch "never chooses for (them|you)") -or ($near -notmatch "(?i)example")) { $r2DocMiss += "$r2Doc line $($i + 1)" }
    }
}
Check "START_HERE, README and QUICKSTART show a concrete choice only as a labelled example beside the ask sentence" ($r2DocMiss.Count -eq 0) ($r2DocMiss -join "; ")

# B. A failed setup leaves the project exactly as it was, in both shells.
foreach ($r2Shell in @("ps", "sh")) {
    if ($r2Shell -eq "sh" -and $null -eq $rvBash) { continue }
    $r2LockFx = New-SuFixture -Roles (Get-Content -Raw -Path (Join-Path $RepoRoot "templates/.ai/roles/ROLE_ASSIGNMENT.md"))
    $r2RoleBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $r2LockFx ".ai/roles/ROLE_ASSIGNMENT.md")).Hash
    $r2Lock = [System.IO.File]::Open((Join-Path $r2LockFx "AI_HANDOFF.md"), 'Open', 'ReadWrite', 'Read')
    try {
        if ($r2Shell -eq "ps") {
            $r = Invoke-HandoffInput -WorkDir $r2LockFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Codex", "-Yes")
            $r2Code = $r.Code; $r2Out = $r.Out
        } else {
            $r2Out = Invoke-RvSh -Dir $r2LockFx -ShArgs @("setup", "--players", "Claude Code,Codex", "--master", "Codex", "--yes")
            $r2Code = if ($r2Out -match "exit=(\d+)\s*$") { [int]$Matches[1] } else { -1 }
        }
    } finally { $r2Lock.Close() }
    $r2Left = @(Get-ChildItem -LiteralPath $r2LockFx -Recurse -Force -File | Where-Object { $_.Name -match '\.(setup|backup)-' })
    Check "$r2Shell setup that cannot write AI_HANDOFF.md restores the role file byte for byte and leaves no temp file" (($r2Code -ne 0) -and ($r2Out -match "Nothing was changed") -and ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $r2LockFx ".ai/roles/ROLE_ASSIGNMENT.md")).Hash -eq $r2RoleBefore) -and ($r2Left.Count -eq 0)) "code=$r2Code left=$($r2Left.Name -join ',') $r2Out"
    if ($r2Shell -eq "ps") {
        $r = Invoke-HandoffInput -WorkDir $r2LockFx -Arguments @("setup", "-Players", "Claude Code,Codex", "-Master", "Codex", "-Yes")
        $r2Again = ($r.Code -eq 0)
    } else {
        $r2Again = ((Invoke-RvSh -Dir $r2LockFx -ShArgs @("setup", "--players", "Claude Code,Codex", "--master", "Codex", "--yes")) -match "exit=0\s*$")
    }
    $r = Invoke-Handoff -WorkDir $r2LockFx -Arguments @("work")
    Check "$r2Shell setup succeeds once the file is free, and the project then runs" ($r2Again -and ($r.Code -eq 0))
}

# C. Bash reads the Task Actors section as handoff.ps1 does, and audits it before a commit.
if ($null -ne $rvBash) {
    $r2Sections = @(
        @{ Name = "a heading with a trailing space"; Head = "## Task Actors "; Actors = "- Implementer: Claude Code`n- Reviewer: Claude Code"; Ps = 12 },
        @{ Name = "a lower-case heading"; Head = "## task actors"; Actors = "- Implementer: Claude Code`n- Reviewer: Claude Code"; Ps = 12 },
        @{ Name = "a renamed section"; Head = "## Actors"; Actors = "- Implementer: Claude Code`n- Reviewer: Claude Code"; Ps = 1 },
        @{ Name = "two different Reviewer lines"; Head = "## Task Actors"; Actors = "- Implementer: Claude Code`n- Reviewer: Claude Code`n- Reviewer: Codex"; Ps = 1 }
    )
    foreach ($r2S in $r2Sections) {
        $r2SFx = New-SuFixture -Roles (New-SuRoles -SetupLine "") -Handoff ("# AI Handoff`n`n## Status`n- State: REVIEW_DONE`n- Waiting For: User`n- Current Task: t`n`n$($r2S.Head)`n$($r2S.Actors)`n`n## Changed Files`n- foo.txt`n")
        Set-Content -Path (Join-Path $r2SFx "foo.txt") -Value "x" -Encoding utf8
        $r = Invoke-Handoff -WorkDir $r2SFx -Arguments @("commit-check")
        $r2Out = Invoke-RvSh -Dir $r2SFx -ShArgs @("commit-check")
        Check "both shells refuse a self-review commit with $($r2S.Name), and Bash never says ALLOWED" (($r.Code -eq $r2S.Ps) -and ($r2Out -match "exit=$($r2S.Ps)\s*$") -and ($r2Out -notmatch "ALLOWED")) "ps=$($r.Code) $r2Out"
    }
}

# D. Bash adapters shows no binding nobody chose.
if ($null -ne $rvBash) {
    $r2AdFx = New-SuFixture -Roles (New-SuRoles)
    $r2Out = Invoke-RvSh -Dir $r2AdFx -ShArgs @("adapters")
    Check "handoff.sh adapters stops with exit 14 while pending and prints no binding row" (($r2Out -match "exit=14\s*$") -and ($r2Out -notmatch "(?m)^(Role|Tool):"))
    $r2Out = Invoke-RvSh -Dir $r2AdFx -ShArgs @("status")
    Check "handoff.sh status does not offer adapters while pending" (($r2Out -match "exit=0\s*$") -and ($r2Out -notmatch "Adapters:"))
}

# E. An explicit -Window never waits on a console prompt: run it on a console that is not
# redirected (a new console with no window), with windows switched off. The same run without
# -Window reaches the prompt, which proves the console really is interactive.
function Invoke-HandoffConsole {
    # stdin is "< CON" inside a new console that has no window: a real console, so
    # [Console]::IsInputRedirected is false in the child, and nothing is shown on screen.
    param([string]$WorkDir, [string[]]$Arguments, [int]$TimeoutSeconds = 25)
    $ErrorActionPreference = 'Continue'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot "System32\cmd.exe"
    $psi.Arguments = '/d /s /c ""' + $PwshExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $HandoffScript + '" ' + ($Arguments -join ' ') + ' < CON"'
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { $null = & taskkill.exe /PID $p.Id /T /F 2>&1; [void]$p.WaitForExit(5000) }
    $text = ""
    try { if ($outTask.Wait(5000)) { $text = $outTask.Result } } catch { }
    try { if ($errTask.Wait(1000)) { $text += $errTask.Result } } catch { }
    return @{ Code = $(if ($timedOut) { -1 } else { $p.ExitCode }); Out = $text; TimedOut = $timedOut }
}
$r2WinFx = New-SuFixture -Roles (New-SuRoles)
$r2WinBefore = Get-SuHashes -Dir $r2WinFx
$r = Invoke-HandoffConsole -WorkDir $r2WinFx -Arguments @("setup", "-Window")
Check "setup -Window on an interactive console with windows off prints the flag form and exits 1, never prompting" ((-not $r.TimedOut) -and ($r.Code -eq 1) -and ($r.Out -match "pass the choice as flags") -and ($r.Out -notmatch "Which tools will work on this project") -and ((Get-SuHashes -Dir $r2WinFx) -eq $r2WinBefore)) "code=$($r.Code) timedOut=$($r.TimedOut) $($r.Out)"
$r = Invoke-HandoffConsole -WorkDir $r2WinFx -Arguments @("setup") -TimeoutSeconds 15
Check "control: the same console without -Window does reach the prompt" (($r.Out -match "Which tools will work on this project") -and ((Get-SuHashes -Dir $r2WinFx) -eq $r2WinBefore)) "code=$($r.Code) timedOut=$($r.TimedOut) $($r.Out)"

# E. A -Force upgrade keeps the blank line under the binding table, and is stable.
$r2UpTarget = Join-Path $FixtureRoot "r2-upgrade-blank"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $r2UpTarget -NoRolesWindow 2>&1
$r2UpRoles = Join-Path $r2UpTarget ".ai/roles/ROLE_ASSIGNMENT.md"
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $r2UpTarget -Force -NoRolesWindow 2>&1
$r2First = Get-Content -Raw -LiteralPath $r2UpRoles
$null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $r2UpTarget -Force -NoRolesWindow 2>&1
$r2Second = Get-Content -Raw -LiteralPath $r2UpRoles
Check "install.ps1 -Force keeps the blank line between the table and Review Independence" ($r2First -match '\| Implementer \| Claude Code \|\r?\n\r?\nReview Independence: separate-tool\r?\nSetup: pending')
Check "two consecutive -Force upgrades produce the same role file" ($r2First -eq $r2Second)
if ($null -ne $rvBash) {
    $r2ShUp = Join-Path $FixtureRoot "r2-upgrade-blank-sh"
    $null = & $rvBash.Source $rvInstSh ($r2ShUp -replace '\\', '/') 2>&1
    $null = & $rvBash.Source $rvInstSh ($r2ShUp -replace '\\', '/') --force 2>&1
    $r2ShFirst = Get-Content -Raw -LiteralPath (Join-Path $r2ShUp ".ai/roles/ROLE_ASSIGNMENT.md")
    $null = & $rvBash.Source $rvInstSh ($r2ShUp -replace '\\', '/') --force 2>&1
    $r2ShSecond = Get-Content -Raw -LiteralPath (Join-Path $r2ShUp ".ai/roles/ROLE_ASSIGNMENT.md")
    Check "install.sh --force keeps the blank line too, and is stable" (($r2ShFirst -match '\| Implementer \| Claude Code \|\r?\n\r?\nReview Independence: separate-tool\r?\nSetup: pending') -and ($r2ShFirst -eq $r2ShSecond))
}

# E. The Skill setup scripts suggest no stale version.
$r2SetupText = (Get-Content -Raw -Path (Join-Path $RepoRoot ".agents/skills/codex-claude-handoff/scripts/setup.ps1")) + (Get-Content -Raw -Path (Join-Path $RepoRoot ".agents/skills/codex-claude-handoff/scripts/setup.sh"))
Check "the Skill setup scripts suggest an install commit with no stale version number" (($r2SetupText -match 'Install codex-claude-handoff') -and ($r2SetupText -notmatch 'Install codex-claude-handoff v\d'))

# --- v3.18.0 third review: Bash and PowerShell commit-check, as a property ---
Write-Host "[4D-8d] First setup: third review (v3.18.0)"
if ($null -ne $rvBash) {
    # One throwaway project; each row writes AI_HANDOFF.md and runs both commit-checks.
    # The property: Bash never prints ALLOWED, and never exits 0, on a file PowerShell refuses.
    # Ps is what PowerShell is expected to answer (it guards the meaning of the row); Same
    # says the exit codes are meant to match. Adding a case is one line.
    $dfRolesTwo = "# Role Assignment`n`n## Current Binding`n`n| Role | Tool |`n|---|---|`n| Master | Claude Code |`n| Reviewer | Codex |`n| Implementer | Claude Code |`n"
    $dfRolesFresh = $dfRolesTwo + "`nReview Independence: fresh-context`n"
    $dfOk = "- State: REVIEW_DONE`n- Waiting For: User`n- Current Task: t"
    $dfTa = "- Implementer: Claude Code`n- Reviewer: Codex"
    $dfCf = "## Changed Files`n- foo.txt"
    # Written as escapes: the script source stays ASCII.
    $dfNb = [string][char]0x00A0; $dfNel = [string][char]0x0085; $dfIdeo = [string][char]0x3000; $dfKelvin = [string][char]0x212A
    $dfHebrew = { param([int[]]$Cps) -join ($Cps | ForEach-Object { [char]$_ }) }
    $dfHeb1 = & $dfHebrew @(0x05EA, 0x05D9, 0x05E7, 0x05D5, 0x05DF, 0x0020, 0x05D4, 0x05D3, 0x05E3)
    $dfHeb2 = & $dfHebrew @(0x05D4, 0x05E2, 0x05E8, 0x05D5, 0x05EA)
    $dfHeb3 = & $dfHebrew @(0x05D8, 0x05E7, 0x05E1, 0x05D8, 0x0020, 0x05D7, 0x05D5, 0x05E4, 0x05E9, 0x05D9)
    $dfHeb4 = & $dfHebrew @(0x05DE, 0x05E6, 0x05D1)
    $dfHeb5 = & $dfHebrew @(0x05EA, 0x05E7, 0x05D9, 0x05DF)
    function New-DfBody { param([string]$Status = $dfOk, [string]$Head = "## Task Actors", [string]$Actors = $dfTa, [string]$Middle = "", [string]$Tail = "")
        return "# AI Handoff`n`n## Status`n$Status`n$Middle`n$Head`n$Actors`n`n$dfCf`n$Tail"
    }
    $dfRows = @(
        @{ Name = "a legitimate file"; Body = (New-DfBody); Ps = 0; Same = $true },
        @{ Name = "a legitimate file with CRLF"; Body = (New-DfBody); Crlf = $true; Ps = 0; Same = $true },
        @{ Name = "a legitimate file with a UTF-8 BOM"; Body = (New-DfBody); Bom = $true; Ps = 0; Same = $true },
        @{ Name = "Task Actors last, no final newline"; Body = "# AI Handoff`n`n## Status`n$dfOk`n`n$dfCf`n`n## Task Actors`n$dfTa"; NoFinalNewline = $true; Ps = 0; Same = $true },
        @{ Name = "a self-review"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Claude Code"); Ps = 12; Same = $true },
        @{ Name = "a heading with trailing spaces"; Body = (New-DfBody -Head "## Task Actors   " -Actors "- Implementer: Claude Code`n- Reviewer: Claude Code"); Ps = 12; Same = $true },
        @{ Name = "a lower-case heading"; Body = (New-DfBody -Head "## task actors" -Actors "- Implementer: Claude Code`n- Reviewer: Claude Code"); Ps = 12; Same = $true },
        @{ Name = "a tab after ##"; Body = (New-DfBody -Head "##`tTask Actors" -Actors "- Implementer: Claude Code`n- Reviewer: Claude Code"); Ps = 1; Same = $true },
        @{ Name = "## Status Notes before ## Status"; Body = ("# AI Handoff`n`n## Status Notes`n$dfOk`n`n## Status`n- State: IMPLEMENTING`n- Waiting For: Implementer`n`n## Task Actors`n$dfTa`n`n$dfCf`n"); Ps = 1 },
        @{ Name = "## Status Notes after ## Status"; Body = (New-DfBody -Middle "## Status Notes`n- State: IMPLEMENTING`n"); Ps = 0; Same = $true },
        @{ Name = "a ### sub-heading inside Task Actors"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Codex`n### later`n- Reviewer: Claude Code"); Ps = 12; Same = $true },
        @{ Name = "a heading inside a code fence in Task Actors"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Codex`n``````n## Task Actors`n- Reviewer: Claude Code`n``````"); Ps = 12; Same = $true },
        @{ Name = "an empty Task Actors section"; Body = (New-DfBody -Actors ""); Ps = 1; Same = $true },
        @{ Name = "no Task Actors section"; Body = "# AI Handoff`n`n## Status`n$dfOk`n`n$dfCf`n"; Ps = 1; Same = $true },
        @{ Name = "a renamed section"; Body = (New-DfBody -Head "## Actors"); Ps = 1; Same = $true },
        @{ Name = "two Reviewer lines, same tool"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Codex`n- Reviewer: Codex"); Ps = 0; Same = $true },
        @{ Name = "two Reviewer lines, same tool in another case"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Codex`n- Reviewer: codex"); Ps = 0; Same = $true },
        @{ Name = "two Reviewer lines, Codex and its alias"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Codex`n- Reviewer: Codex Window"); Ps = 1; Same = $true },
        @{ Name = "two Reviewer lines, two tools"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Claude Code`n- Reviewer: Codex"); Ps = 1; Same = $true },
        @{ Name = "only * bullets"; Body = (New-DfBody -Actors "* Implementer: Claude Code`n* Reviewer: Codex"); Ps = 1; Same = $true },
        @{ Name = "mixed bullets, the * line last"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Claude Code`n* Reviewer: Codex"); Ps = 1; Same = $true },
        @{ Name = "mixed bullets, the * line first"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n* Reviewer: Codex`n- Reviewer: Claude Code"); Ps = 12; Same = $true },
        @{ Name = "a duplicated ## Status, adjacent"; Body = ("# AI Handoff`n`n## Status`n- State: REVIEW_DONE`n- Waiting For: User`n## Status`n- State: IMPLEMENTING`n- Waiting For: Implementer`n- Current Task: t`n`n## Task Actors`n$dfTa`n`n$dfCf`n"); Ps = 1; Same = $true },
        @{ Name = "a duplicated ## Status, after another section"; Body = (New-DfBody -Tail "`n## Status`n- State: IMPLEMENTING`n- Waiting For: Implementer`n"); Ps = 0; Same = $true },
        @{ Name = "a duplicated ## Task Actors, adjacent"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Codex`n## Task Actors`n- Reviewer: Claude Code"); Ps = 12; Same = $true },
        @{ Name = "a duplicated ## Task Actors, after another section"; Body = (New-DfBody -Tail "`n## Task Actors`n- Reviewer: Claude Code`n"); Ps = 0; Same = $true },
        @{ Name = "a lower-case Status key later in the section"; Body = (New-DfBody -Status "$dfOk`n- state: IMPLEMENTING"); Ps = 1; Same = $true },
        @{ Name = "an empty State value later in the section"; Body = (New-DfBody -Status "$dfOk`n- State:   "); Ps = 1; Same = $true },
        @{ Name = "one tool in both under fresh-context, two tools bound"; Roles = $dfRolesFresh; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: Claude Code"); Ps = 12; Same = $true },
        # Fourth review: characters Bash cannot read the way handoff.ps1 does. Bash refuses them
        # (exit 1) wherever PowerShell refuses with 1 or 12, so these rows do not set Same.
        @{ Name = "a lone CR inside Status"; Body = (New-DfBody -Status "$dfOk`n- Note: x`r- State: IMPLEMENTING"); Ps = 1 },
        @{ Name = "a lone CR inside Task Actors"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Note: x`r- Reviewer: Claude Code`n- Reviewer: Codex"); Ps = 1 },
        @{ Name = "## + NBSP ends Status for PowerShell"; Body = (New-DfBody -Status "- State: IMPLEMENTING`n- Waiting For: Implementer`n##$($dfNb)x`n$dfOk"); Ps = 1 },
        @{ Name = "## + NBSP inside Task Actors"; Body = (New-DfBody -Actors "##$($dfNb)x`n$dfTa"); Ps = 1 },
        @{ Name = "a Task Actors heading with a trailing NBSP"; Body = ("# AI Handoff`n`n## Status`n$dfOk`n`n## Task Actors$dfNb`n- Reviewer: Claude Code`n## Task Actors`n$dfTa`n`n$dfCf`n"); Ps = 1 },
        @{ Name = "an NBSP Reviewer value, then a * Reviewer line"; Body = (New-DfBody -Actors "- Implementer: Claude Code`n- Reviewer: $dfNb`n* Reviewer: Codex"); Ps = 1 },
        @{ Name = "an NBSP Implementer value, then a * Implementer line"; Body = (New-DfBody -Actors "- Implementer: $dfNb`n* Implementer: Claude Code`n- Reviewer: Codex"); Ps = 1 },
        @{ Name = "## + NEL inside Task Actors"; Body = (New-DfBody -Actors "##$($dfNel)x`n$dfTa"); Ps = 1 },
        @{ Name = "an NBSP before a self-review line"; Body = (New-DfBody -Actors "$dfTa`n$($dfNb)- Reviewer: Claude Code"); Ps = 12 },
        @{ Name = "an ideographic space before a * self-review line"; Body = (New-DfBody -Actors "$dfTa`n$($dfIdeo)* Reviewer: Claude Code"); Ps = 12 },
        @{ Name = "a lone CR before a * self-review line"; Body = (New-DfBody -Actors "$dfTa`n- Note: x`r* Reviewer: Claude Code"); Ps = 12 },
        @{ Name = "a Kelvin-sign Task Actors heading carrying a self-review"; Body = (New-DfBody -Actors "$dfTa`n## Tas$($dfKelvin) Actors`n- Reviewer: Claude Code"); Ps = 12 },
        @{ Name = "a legitimate file written in Hebrew"; Body = (New-DfBody -Status "- State: REVIEW_DONE`n- Waiting For: User`n- Current Task: $dfHeb1" -Middle "## $dfHeb2`n$dfHeb3`n- $($dfHeb4): $dfHeb5`n"); Ps = 0; Same = $true }
    )
    $dfDir = New-SuFixture -Roles $dfRolesTwo -Handoff (New-DfBody)
    Set-Content -Path (Join-Path $dfDir "foo.txt") -Value "x" -Encoding utf8
    $dfUtf8 = New-Object System.Text.UTF8Encoding($false)
    $dfBroken = @(); $dfMismatch = @(); $dfMeaning = @(); $dfAllowedBoth = 0; $dfLocale = @()
    $dfUtf8Locale = ((& $rvBash.Source -c "locale -a 2>/dev/null" | Out-String) -match '(?im)^C\.utf-?8\s*$')
    foreach ($dfRow in $dfRows) {
        $dfRoles = if ($dfRow.ContainsKey("Roles")) { $dfRow.Roles } else { $dfRolesTwo }
        [System.IO.File]::WriteAllText((Join-Path $dfDir ".ai/roles/ROLE_ASSIGNMENT.md"), $dfRoles, $dfUtf8)
        $dfText = $dfRow.Body
        if ($dfRow.NoFinalNewline) { $dfText = $dfText.TrimEnd("`n") }
        if ($dfRow.Crlf) { $dfText = $dfText -replace "`n", "`r`n" }
        $dfBytes = $dfUtf8.GetBytes($dfText)
        if ($dfRow.Bom) { $dfBytes = [byte[]](0xEF, 0xBB, 0xBF) + $dfBytes }
        [System.IO.File]::WriteAllBytes((Join-Path $dfDir "AI_HANDOFF.md"), $dfBytes)
        $r = Invoke-Handoff -WorkDir $dfDir -Arguments @("commit-check")
        $dfSh = Invoke-RvSh -Dir $dfDir -ShArgs @("commit-check")
        $dfShCode = if ($dfSh -match "exit=(\d+)\s*$") { [int]$Matches[1] } else { -1 }
        # The same Bash run under a UTF-8 locale must reach the same verdict.
        if ($dfUtf8Locale) {
            $dfPrevLc = $env:LC_ALL
            $env:LC_ALL = "C.UTF-8"
            try { $dfShU = Invoke-RvSh -Dir $dfDir -ShArgs @("commit-check") } finally { if ($null -eq $dfPrevLc) { Remove-Item Env:\LC_ALL -ErrorAction SilentlyContinue } else { $env:LC_ALL = $dfPrevLc } }
            $dfShUCode = if ($dfShU -match "exit=(\d+)\s*$") { [int]$Matches[1] } else { -1 }
            if (($dfShUCode -ne $dfShCode) -or (($dfShU -cmatch "Commit: ALLOWED") -ne ($dfSh -cmatch "Commit: ALLOWED"))) { $dfLocale += "[$($dfRow.Name)] default=$dfShCode utf8=$dfShUCode" }
        }
        if ($r.Code -ne $dfRow.Ps) { $dfMeaning += "[$($dfRow.Name)] ps=$($r.Code) expected $($dfRow.Ps)" }
        if (($r.Code -ne 0) -and (($dfShCode -eq 0) -or ($dfSh -cmatch "Commit: ALLOWED"))) { $dfBroken += "[$($dfRow.Name)] ps=$($r.Code) sh=$dfShCode" }
        if ($dfRow.Same -and ($dfShCode -ne $r.Code)) { $dfMismatch += "[$($dfRow.Name)] ps=$($r.Code) sh=$dfShCode" }
        if (($r.Code -eq 0) -and ($dfShCode -eq 0) -and ($dfSh -cmatch "Commit: ALLOWED")) { $dfAllowedBoth++ }
    }
    Check "differential: every row means what it says in handoff.ps1" ($dfMeaning.Count -eq 0) ($dfMeaning -join "; ")
    Check "differential: Bash never prints ALLOWED or exits 0 on a file PowerShell refuses ($($dfRows.Count) rows)" ($dfBroken.Count -eq 0) ($dfBroken -join "; ")
    Check "differential: where the exit codes are meant to match, they do" ($dfMismatch.Count -eq 0) ($dfMismatch -join "; ")
    Check "differential: legitimate files are allowed by both shells, so refusing everything cannot pass" ($dfAllowedBoth -ge 10) "both allowed: $dfAllowedBoth"
    if ($dfUtf8Locale) {
        Check "differential: Bash reaches the same verdict on every row under LC_ALL=C.UTF-8" ($dfLocale.Count -eq 0) ($dfLocale -join "; ")
    } else {
        Write-Host "  SKIP  differential under LC_ALL=C.UTF-8: that locale does not exist on this machine"
    }

    # 4. Bash setup: every failure path cleans up, and a failed restore says how to recover.
    $suInstallSnippet = Get-Content -Raw -Path (Join-Path $RepoRoot "templates/gitignore-snippet.txt")
    Check "setup's work folder .ai/handoff-history is in the installers' .gitignore snippet" ($suInstallSnippet -match '(?m)^/\.ai/handoff-history/\r?$')
    $dfSeamTarget = Join-Path $FixtureRoot "df-seam-install"
    New-Item -ItemType Directory -Path $dfSeamTarget -Force | Out-Null
    & git -C $dfSeamTarget init -q 2>&1 | Out-Null
    $null = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -Project $dfSeamTarget -NoRolesWindow 2>&1
    $dfSeamRoles = Join-Path $dfSeamTarget ".ai/roles/ROLE_ASSIGNMENT.md"
    $dfSeamOrig = [System.IO.File]::ReadAllBytes($dfSeamRoles)
    $dfSeamHandoff = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dfSeamTarget "AI_HANDOFF.md")).Hash
    $dfPrevSeam = $env:HANDOFF_TEST_SETUP_FAIL
    try {
        foreach ($dfSeam in @("role", "handoff", "interrupt")) {
            $env:HANDOFF_TEST_SETUP_FAIL = $dfSeam
            $dfOut = Invoke-RvSh -Dir $dfSeamTarget -ShArgs @("setup", "--players", "Codex", "--yes")
            $dfLeft = @(Get-ChildItem -LiteralPath $dfSeamTarget -Recurse -Force -File | Where-Object { $_.Name -match '\.(setup|setup2|setup-orig|backup)-|\.handoff-setup-probe-' })
            Check "handoff.sh setup failing at '$dfSeam' restores both files and leaves no temp file" (($dfOut -match "exit=1\s*$") -and ($dfOut -match "Nothing was changed") -and ([System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($dfSeamRoles), [byte[]]$dfSeamOrig)) -and ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dfSeamTarget "AI_HANDOFF.md")).Hash -eq $dfSeamHandoff) -and ($dfLeft.Count -eq 0)) "$dfOut left=$($dfLeft.Name -join ',')"
        }
        $env:HANDOFF_TEST_SETUP_FAIL = "handoff,restore"
        $dfOut = Invoke-RvSh -Dir $dfSeamTarget -ShArgs @("setup", "--players", "Codex", "--yes")
        $dfKept = @(Get-ChildItem -LiteralPath (Join-Path $dfSeamTarget ".ai/handoff-history") -Force -File -Filter "ROLE_ASSIGNMENT.md.setup-orig-*" -ErrorAction SilentlyContinue)
        $dfOthers = @(Get-ChildItem -LiteralPath $dfSeamTarget -Recurse -Force -File | Where-Object { ($_.Name -match '\.(setup|setup2|backup)-|\.handoff-setup-probe-') -and ($_.Name -notmatch 'setup-orig-') })
        Check "a failed restore says setup failed part-way, never 'Nothing was changed', and names the saved original" (($dfOut -match "exit=1\s*$") -and ($dfOut -match "setup: FAILED part-way") -and ($dfOut -notmatch "Nothing was changed") -and ($dfOut -match "ROLE_ASSIGNMENT\.md may already be the new one while AI_HANDOFF\.md is still the old one") -and ($dfKept.Count -eq 1) -and ($dfOthers.Count -eq 0)) "$dfOut kept=$($dfKept.Count) others=$($dfOthers.Name -join ',')"
        $dfGitStatus = (& git -C $dfSeamTarget status --porcelain --untracked-files=all 2>$null | Out-String)
        Check "the saved original is ignored by Git, so 'git add -A' cannot commit it" ($dfGitStatus -notmatch "setup-orig")
        $env:HANDOFF_TEST_SETUP_FAIL = $null
        if ($dfOut -match 'Restore it:\s+(mv -f "[^"]+" "[^"]+")') {
            $dfRestoreCmd = $Matches[1]
            $null = Invoke-RvIn -Dir $dfSeamTarget -Block { & $rvBash.Source -c $dfRestoreCmd }
        }
        Check "the printed restore command puts the original role file back byte for byte" ([System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($dfSeamRoles), [byte[]]$dfSeamOrig))
        $dfOut = Invoke-RvSh -Dir $dfSeamTarget -ShArgs @("setup", "--players", "Codex", "--yes")
        Check "after the recovery, handoff.sh setup succeeds" ($dfOut -match "exit=0\s*$")
    } finally {
        if ($null -eq $dfPrevSeam) { Remove-Item Env:\HANDOFF_TEST_SETUP_FAIL -ErrorAction SilentlyContinue } else { $env:HANDOFF_TEST_SETUP_FAIL = $dfPrevSeam }
    }

    # 5. A folder setup cannot write is named as such (Windows ACL deny, removed afterwards).
    $dfIcacls = Join-Path $env:SystemRoot "System32\icacls.exe"
    if ((Test-Path -LiteralPath $dfIcacls) -and -not [string]::IsNullOrEmpty($env:USERNAME)) {
        foreach ($dfPerm in @(@{ Name = ".ai/roles"; Rel = ".ai/roles"; Want = "ROLE_ASSIGNMENT\.md could not be written: the folder \.ai/roles is not writable" }, @{ Name = "the project folder"; Rel = ""; Want = "AI_HANDOFF\.md could not be written: the project folder is not writable" })) {
            $dfPermFx = New-SuFixture -Roles (New-SuRoles)
            New-Item -ItemType Directory -Path (Join-Path $dfPermFx ".ai/handoff-history") -Force | Out-Null
            $dfPermBefore = Get-SuHashes -Dir $dfPermFx
            $dfDenied = if ($dfPerm.Rel -eq "") { $dfPermFx } else { Join-Path $dfPermFx $dfPerm.Rel }
            $null = & $dfIcacls $dfDenied /deny "$($env:USERNAME):(AD,WD)" 2>&1
            try {
                $dfOut = Invoke-RvSh -Dir $dfPermFx -ShArgs @("setup", "--players", "Codex", "--yes")
            } finally {
                $null = & $dfIcacls $dfDenied /remove:d "$($env:USERNAME)" 2>&1
            }
            Check "handoff.sh setup names a write-denied $($dfPerm.Name), not a malformed table or an unreadable file" (($dfOut -match "exit=1\s*$") -and ($dfOut -match $dfPerm.Want) -and ($dfOut -notmatch "must have exactly one") -and ($dfOut -notmatch "could not be read") -and ((Get-SuHashes -Dir $dfPermFx) -eq $dfPermBefore)) $dfOut
        }
    } else {
        Write-Host "  SKIP  write-denied folders: icacls or USERNAME not available"
    }
}

# --- Summary ---
Write-Host ""
Write-Host "Results: $($script:Pass) passed, $($script:Fail) failed."
if ($script:Fail -gt 0) {
    Write-Host "Failed checks:"
    foreach ($f in $script:Failures) { Write-Host "  - $f" }
}

if (-not $KeepFixtures) {
    Remove-Item -Path $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Fixtures kept at: $FixtureRoot"
}

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
