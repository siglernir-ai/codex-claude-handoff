#requires -Version 5.1
<#
    Protocol Test Harness (PowerShell-first) - codex-claude-handoff v1.2.0

    Repeatable, black-box protocol tests for scripts/handoff.ps1. Each test runs the
    real handoff.ps1 as a child process against a scripted fixture project in a temp
    directory, then asserts on exit code and printed output. Fixtures are disposable;
    the real local coordination files (AI_HANDOFF.md / AI_SEQUENCE.md / NEXT_TURN.md)
    are never read or mutated by these tests.

    Coverage: state routing, turn-ownership mismatch routing, adapter decisions,
    stop categories, release executor guards, sequence advance guards, mirror parity,
    and safety boundaries (dry runs change no files and run no git mutations).

    Usage:  pwsh -File scripts/protocol-tests.ps1
    Exit:   0 = all passed, 1 = one or more failures or a harness error.
#>

param(
    [switch]$KeepFixtures
)

$ErrorActionPreference = "Stop"

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
Check "Master/Codex adapter is not callable (manual handoff)" ($r.Out -match "(?s)Role:\s+Master.*?Tool:\s+Codex.*?Callable:\s+no")
Check "Release executor advertised as PowerShell-only, REVIEW_DONE-gated" (($r.Out -match "Authorized release executor") -and ($r.Out -match "REVIEW_DONE"))

# === 4. Stop categories ===
Write-Host "[4] Stop categories"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "REVIEW_DONE" -WaitingFor "User"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "REVIEW_DONE prints User Release Authorization stop category" ($r.Out -match "Stop category: User Release Authorization")
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("next")
Check "Callable-tool handoff prints Operator Manual Action stop category" ($r.Out -match "Stop category: Operator Manual Action")

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
Check "release-check blocks when actual Reviewer == actual Implementer" (($r.Code -eq 1) -and ($r.Out -match "Reviewer must not equal actual Implementer"))

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

# Bound Reviewer is not Codex: this POC only invokes Codex.
$nonCodexRoles = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Gemini |
| Implementer | Claude Code |
"@
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"); ".ai/roles/ROLE_ASSIGNMENT.md" = $nonCodexRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "review-check blocks when the bound Reviewer is not Codex" (($r.Code -eq 1) -and ($r.Out -match "bound Reviewer tool must be Codex"))

# Independent-review invariant: actual Reviewer must not equal actual Implementer.
$badHandoff = New-Handoff -State "READY_FOR_REVIEW" -WaitingFor "Reviewer"
$badHandoff = $badHandoff -replace "- Reviewer: Codex", "- Reviewer: Claude Code"
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $badHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
$r = Invoke-Handoff -WorkDir $fx -Arguments @("review-check")
Check "review-check blocks when actual Reviewer == actual Implementer" (($r.Code -eq 1) -and ($r.Out -match "actual task Reviewer must be Codex|must not equal the actual Implementer"))

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
$prevPath = $env:PATH
$hadLocalAppData = Test-Path Env:\LOCALAPPDATA
$prevLocalAppData = $env:LOCALAPPDATA
try {
    $env:PATH = "$fakeBrokenPathDir;$prevPath"
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
    $env:PATH = $prevPath
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
