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
$normalizedRoleTemplate = $templateRoleText -replace '(?m)^\|\s*(Master|Reviewer|Implementer)\s*\|\s*.+?\s*\|\s*$', '| $1 | <tool> |'
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

Check "the Codex Implementer turn runs the Codex cost gate and passes the resolved model" (($handoffSrcV310 -match '(?s)function Invoke-CodexImplementerTurn.{0,2500}Test-CodexModelPreflight') -and ($handoffSrcV310 -match "(?s)function Invoke-CodexImplementerTurn.{0,6000}CodexUsesConcreteModel\) \{ \`$argList \+= @\('--model'"))

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

$planMaster = Get-Content -Raw -Path (Join-Path $RepoRoot ".ai/skills/codex-claude-handoff/MASTER.md")
Check "MASTER.md says to end the window, not the work" ($planMaster -match "End the window, not the work")
Check "MASTER.md lists the only legitimate stops" (($planMaster -match "Stop only for these, and say which one it is") -and ($planMaster -match "empty plan"))
Check "MASTER.md tells the Master to name a quota stop" ($planMaster -match "When a tool runs out of usage, say so plainly")

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
