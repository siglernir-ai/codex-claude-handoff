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
# captured verdict file (CODEX_REVIEW_LAST.md). Returns the fixture dir path.
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
    if (-not $NoCapture) { Set-Content -Path (Join-Path $fx "CODEX_REVIEW_LAST.md") -Value $Capture -Encoding utf8 }
    return $fx
}

# Build a disposable master-apply fixture: NEEDS_ANALYSIS handoff plus an optional
# captured Master recommendation file (CODEX_MASTER_LAST.md).
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
    if (-not $NoCapture) { Set-Content -Path (Join-Path $fx "CODEX_MASTER_LAST.md") -Value $Capture -Encoding utf8 }
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
Check "work after start points to Codex Master" (($r.Code -eq 0) -and ($r.Out -match "NEEDS_ANALYSIS") -and ($r.Out -match "open Codex") -and ($r.Out -match "next -Clip"))

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
# The printed Results line is the suite's claim about itself; the exit code is the
# independent signal. A run that crashes after printing, or fails where the counter
# cannot see it, still exits nonzero - so success requires BOTH.
Check "review evidence requires a zero suite exit code, not just a zero-failure line" (($handoffSource -match '\$suiteExit = \$LASTEXITCODE') -and ($handoffSource -match 'suiteExit -eq 0'))
Check "a zero-failure line with a nonzero exit is reported as INCONSISTENT and blocks" ($handoffSource -match 'INCONSISTENT - the suite printed')
Check "the review sandbox stays read-only" ($handoffSource -match "'--sandbox', 'read-only'")

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

# Bound Reviewer is not Codex. v3.4.1 uses an APPROVED swap between two known tools:
# an unrecognized tool (the pre-v3.4.1 fixture used "Gemini") is now rejected earlier,
# at the role checkpoint, so it can no longer reach the adapter guard being tested here.
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
# Still blocked, but the reason is the missing ADAPTER, not the role assignment.
# Reassigning the Reviewer is legitimate; it routes to a manual window turn.
Check "review-check blocks when the bound Reviewer has no callable adapter" (($r.Code -eq 1) -and ($r.Out -match "No callable Reviewer adapter"))
Check "review-check names the manual route instead of rejecting the role swap" ($r.Out -match "role assignment itself is valid")

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
Check "review-run timeout writes no final verdict file" (-not (Test-Path (Join-Path $fx "CODEX_REVIEW_LAST.md")))
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
echo VERDICT: APPROVED stdin-delivery-ok> CODEX_REVIEW_LAST.md
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
Check "review-run succeeds (exit 0) and captures the verdict on a clean Codex exit" (($r.Code -eq 0) -and (Test-Path (Join-Path $fx "CODEX_REVIEW_LAST.md")))

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
Check "review-run no-verdict path leaves no verdict file and no handoff change" ((-not (Test-Path (Join-Path $fx "CODEX_REVIEW_LAST.md"))) -and ($before -eq $after))

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
Check "review-apply APPROVED records the verdict and source pointer" (($h -match "Verdict:\s+APPROVED") -and ($h -match "CODEX_REVIEW_LAST.md"))
Check "review-apply changes no file other than AI_HANDOFF.md (reviewed file untouched)" ($reviewedBefore -eq $reviewedAfter)
Check "review-apply creates no git commit" ("$commitsAfter".Trim() -eq "$commitsBefore".Trim())

# Codex writes output-last-message as BOM-less UTF-8. Prove Windows PowerShell 5.1
# preserves a non-ASCII task through the anti-stale comparison instead of reading
# the capture through the active ANSI code page.
$utf8ReviewTask = (-join @([char]0x05DE, [char]0x05E9, [char]0x05D9, [char]0x05DE, [char]0x05D4)) + " UTF-8"
$utf8ReviewCapture = "VERDICT: APPROVED`nREVIEWER: Codex`nTASK: $utf8ReviewTask`nREASON: UTF-8 task matches"
$fx = New-ReviewApplyFixture -NoCapture -CurrentTask $utf8ReviewTask
[System.IO.File]::WriteAllText(
    (Join-Path $fx "CODEX_REVIEW_LAST.md"),
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

# Bound Master is not Codex. v3.4.1 uses an APPROVED swap to a known tool; an
# unrecognized tool is now rejected at the role checkpoint and never reaches this guard.
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
Check "master-check blocks when the bound Master has no callable adapter" (($r.Code -eq 1) -and ($r.Out -match "No callable Master adapter"))
Check "master-check keeps the reassigned role valid and routes it manually" ($r.Out -match "role assignment itself is valid")

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
Check "master-run timeout writes no final capture file" (-not (Test-Path (Join-Path $fx "CODEX_MASTER_LAST.md")))
Check "master-run timeout does not modify AI_HANDOFF.md" ($before -eq $after)

# master-run delivers the multi-word Master prompt through stdin (not split argv), and a clean
# Codex exit that writes the capture file succeeds (exit 0). The fake records stdin and argv.
$fakeEcho = Join-Path $FixtureRoot "fake-codex-master-echo.cmd"
@'
@echo off
if "%~2"=="--help" goto done
findstr "^" > FAKE_STDIN.txt
echo %* > FAKE_ARGV.txt
echo MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION> CODEX_MASTER_LAST.md
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
Check "master-run succeeds (exit 0) and captures the recommendation on a clean Codex exit" (($r.Code -eq 0) -and (Test-Path (Join-Path $fx "CODEX_MASTER_LAST.md")))
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
Check "master-run no-capture path leaves no capture file and no handoff change" ((-not (Test-Path (Join-Path $fx "CODEX_MASTER_LAST.md"))) -and ($before -eq $after))

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
    (Join-Path $fx "CODEX_MASTER_LAST.md"),
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
echo MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION> CODEX_MASTER_LAST.md
echo WAITING_FOR: Implementer>> CODEX_MASTER_LAST.md
echo IMPLEMENTER: Claude Code>> CODEX_MASTER_LAST.md
echo REVIEWER: Codex>> CODEX_MASTER_LAST.md
echo TASK: v2.1.0 - Loop Master Test>> CODEX_MASTER_LAST.md
echo REASON: safe simple implementation task>> CODEX_MASTER_LAST.md
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
Check "loop without -IncludeMaster captures no recommendation and does not transition the handoff" ((-not (Test-Path (Join-Path $fx "CODEX_MASTER_LAST.md"))) -and ($before -eq $after))
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
# CODEX_REVIEW_LAST.md (a local, gitignored, clean-tree-exempt artifact) so the in-loop
# review-apply's Changed Files == git status guard still matches the single untracked
# scripts/handoff.ps1. The TASK line matches the fixture's Current Task verbatim.
$loopTask = "v1.4.0 - Loop Reviewer Test"

$fakeApprove = Join-Path $FixtureRoot "fake-codex-loop-approve.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
echo VERDICT: APPROVED> CODEX_REVIEW_LAST.md
echo REVIEWER: Codex>> CODEX_REVIEW_LAST.md
echo TASK: v1.4.0 - Loop Reviewer Test>> CODEX_REVIEW_LAST.md
echo REASON: scope matches the approved task>> CODEX_REVIEW_LAST.md
exit /b 0
'@ | Set-Content -Path $fakeApprove -Encoding ascii

$fakeBlock = Join-Path $FixtureRoot "fake-codex-loop-block.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
echo VERDICT: BLOCKED> CODEX_REVIEW_LAST.md
echo REVIEWER: Codex>> CODEX_REVIEW_LAST.md
echo TASK: v1.4.0 - Loop Reviewer Test>> CODEX_REVIEW_LAST.md
echo REASON: needs a fix before approval>> CODEX_REVIEW_LAST.md
exit /b 0
'@ | Set-Content -Path $fakeBlock -Encoding ascii

$fakeMalformed = Join-Path $FixtureRoot "fake-codex-loop-malformed.cmd"
@'
@echo off
if "%~2"=="--help" exit /b 0
echo this is not a verdict block> CODEX_REVIEW_LAST.md
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
Check "loop without -IncludeReviewer captures no verdict and does not transition the handoff" ((-not (Test-Path (Join-Path $fx "CODEX_REVIEW_LAST.md"))) -and ($before -eq $after))
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
    $claudeLast = Join-Path $fx "CLAUDE_IMPLEMENTER_LAST.md"
    $claudeCommand = Join-Path $fx "CLAUDE_IMPLEMENTER_COMMAND.md"
    $claudeJsonl = Join-Path $fx "CLAUDE_IMPLEMENTER.jsonl"
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
    $mappedCapture = Get-Content -Raw -LiteralPath (Join-Path $mappedFx "CLAUDE_IMPLEMENTER_LAST.md")
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
    $timeoutLast = Join-Path $fx "CLAUDE_IMPLEMENTER_LAST.md"
    $timeoutCommand = Join-Path $fx "CLAUDE_IMPLEMENTER_COMMAND.md"
    $timeoutJsonl = Join-Path $fx "CLAUDE_IMPLEMENTER.jsonl"
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
    Check "automated investigation prompt explicitly forbids source edits" ((Get-Content -Raw -Path (Join-Path $fx "CLAUDE_IMPLEMENTER_LAST.md")) -match "READ-ONLY investigation turn")

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
