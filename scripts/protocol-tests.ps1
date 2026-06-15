#requires -Version 5.1
<#
    Protocol Test Harness (PowerShell-first) - codex-claude-handoff v1.1.0

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
