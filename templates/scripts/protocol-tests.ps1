#requires -Version 5.1
<#
    Protocol Test Harness (PowerShell-first) - codex-claude-handoff v3.1.4

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
    ".ai/skills/codex-claude-handoff/VERSION" = "3.0.0"
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
Check "doctor prints Handoff Doctor, protocol version, role assignment, and AI_HANDOFF status" (($r.Code -eq 0) -and ($r.Out -match "Handoff Doctor") -and ($r.Out -match "Protocol version:\s+3\.0\.0") -and ($r.Out -match "Role assignment: Master=Codex, Reviewer=Codex, Implementer=Claude Code") -and ($r.Out -match "AI_HANDOFF.md status"))
Check "doctor does not mutate AI_HANDOFF.md or create git commits" (($beforeHash -eq $afterHash) -and ("$beforeCommits".Trim() -eq "$afterCommits".Trim()))

# === 4D. One-command installer ===
Write-Host "[4D] One-command installer"
$installScript = Join-Path $RepoRoot "install.ps1"
$installTarget = Join-Path $FixtureRoot "install-target"
$installOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $installTarget 2>&1 | Out-String
$installCode = $LASTEXITCODE
$installedHandoff = Join-Path $installTarget "AI_HANDOFF.md"
$installedScript = Join-Path $installTarget "scripts/handoff.ps1"
$installedVersion = Join-Path $installTarget ".ai/skills/codex-claude-handoff/VERSION"
$installedGitignore = Join-Path $installTarget ".gitignore"
$installedGitignoreText = if (Test-Path $installedGitignore) { Get-Content -Raw -Path $installedGitignore } else { "" }
Check "install.ps1 installs protocol files into an empty target" (($installCode -eq 0) -and (Test-Path $installedHandoff) -and (Test-Path $installedScript) -and (Test-Path $installedVersion))
Check "install.ps1 adds local coordination files to .gitignore" (($installedGitignoreText -match "AI_HANDOFF\.md") -and ($installedGitignoreText -match "NEXT_TURN\.md"))
Check "install.ps1 prints doctor/work/start next steps" (($installOut -match [regex]::Escape(".\scripts\handoff.ps1 doctor")) -and ($installOut -match [regex]::Escape(".\scripts\handoff.ps1 work")) -and ($installOut -match [regex]::Escape(".\scripts\handoff.ps1 start")))

$blockedOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $installTarget 2>&1 | Out-String
$blockedCode = $LASTEXITCODE
Check "install.ps1 blocks overwriting an existing install without -Force" (($blockedCode -eq 1) -and ($blockedOut -match "blocked to avoid overwriting"))

$forcedOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $installScript -Project $installTarget -Force 2>&1 | Out-String
$forcedCode = $LASTEXITCODE
Check "install.ps1 refreshes an existing install with -Force" (($forcedCode -eq 0) -and ($forcedOut -match "codex-claude-handoff installed into"))
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
Check "commit-check blocks when actual Reviewer == actual Implementer" (($r.Code -eq 1) -and ($r.Out -match "Reviewer must not equal actual Implementer"))

$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = $commitHandoff; ".ai/roles/ROLE_ASSIGNMENT.md" = $DefaultRoles } -InitGit
Initialize-FixtureGitBaseline -Dir $fx
Set-Content -Path (Join-Path $fx "COMMIT_TARGET.md") -Value "# approved commit fixture" -Encoding utf8
Set-Content -Path (Join-Path $fx "EXTRA.md") -Value "# extra" -Encoding utf8
$r = Invoke-Handoff -WorkDir $fx -Arguments @("commit-check", "-Message", "Mismatch fixture")
Check "commit-check blocks when Changed Files does not match git status" (($r.Code -eq 1) -and ($r.Out -match "does not exactly match git status"))

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
Check "review-apply blocks when actual Reviewer == actual Implementer" (($r.Code -eq 1) -and ($before -eq $after))

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

# Bound Master is not Codex: this POC only invokes Codex.
$nonCodexMaster = @"
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Gemini |
| Reviewer | Codex |
| Implementer | Claude Code |
"@
$fx = New-Fixture -Files @{ "AI_HANDOFF.md" = (New-Handoff -State "NEEDS_ANALYSIS" -WaitingFor "Master"); ".ai/roles/ROLE_ASSIGNMENT.md" = $nonCodexMaster }
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-check")
Check "master-check blocks when the bound Master is not Codex" (($r.Code -eq 1) -and ($r.Out -match "bound Master tool must be Codex"))

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
Check "master-apply creates no git commit" ("$afterCommits".Trim() -eq "$beforeCommits".Trim())

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
$before = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
$r = Invoke-Handoff -WorkDir $fx -Arguments @("master-apply", "-Yes")
$after = (Get-FileHash -Algorithm SHA256 -Path $handoffPath).Hash
Check "master-apply blocks captured actors that do not match current role binding" (($r.Code -eq 1) -and ($r.Out -match "Role swaps require explicit user approval") -and ($before -eq $after))

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
if not "!ALL:--version=!"=="!ALL!" set IS_VERSION=1
if not "!ALL:--permission-mode=!"=="!ALL!" if not "!ALL:acceptEdits=!"=="!ALL!" set SAW_PERMISSION=1
if not "!ALL:--disallowed-tools=!"=="!ALL!" if not "!ALL:Bash=!"=="!ALL!" set SAW_DISALLOWED=1
if not "!ALL:--no-session-persistence=!"=="!ALL!" set SAW_NOSESSION=1
if defined IS_VERSION (
  echo claude-code-test
  exit /b 0
)
echo FAKE_CLAUDE_FAST_STDOUT
if "%FAKE_NPX_ARGV%"=="" goto after_arg_capture
echo permission=!SAW_PERMISSION! > "%FAKE_NPX_ARGV%"
echo disallowed=!SAW_DISALLOWED! >> "%FAKE_NPX_ARGV%"
echo nosession=!SAW_NOSESSION! >> "%FAKE_NPX_ARGV%"
echo arg3=%~3 >> "%FAKE_NPX_ARGV%"
echo arg4=%~4 >> "%FAKE_NPX_ARGV%"
echo arg5=%~5 >> "%FAKE_NPX_ARGV%"
echo arg6=%~6 >> "%FAKE_NPX_ARGV%"
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
    Check "bounded Claude runner preserves multi-word system and user prompts as single argv values (v2.10.0)" (($argvText -match "arg3=--append-system-prompt") -and ($argvText -match "arg4=You are a non-interactive, headless automation agent") -and ($argvText -match "arg5=-p") -and ($argvText -match "arg6=You are running as the Implementer"))
    $claudeLast = Join-Path $fx "CLAUDE_IMPLEMENTER_LAST.md"
    $claudeCommand = Join-Path $fx "CLAUDE_IMPLEMENTER_COMMAND.md"
    $claudeJsonl = Join-Path $fx "CLAUDE_IMPLEMENTER.jsonl"
    $captureText = if (Test-Path $claudeLast) { Get-Content -Raw -Path $claudeLast } else { "" }
    $commandText = if (Test-Path $claudeCommand) { Get-Content -Raw -Path $claudeCommand } else { "" }
    [string[]]$jsonLines = if (Test-Path $claudeJsonl) { [regex]::Split((Get-Content -Raw -Path $claudeJsonl).Trim(), "`r?`n") | Where-Object { $_ -ne "" } } else { @() }
    $captureRecord = if ($jsonLines.Count -gt 0) { $jsonLines[$jsonLines.Count - 1] | ConvertFrom-Json } else { $null }
    Check "cycle writes Claude Implementer last capture" ((Test-Path $claudeLast) -and ($captureText -match "FAKE_CLAUDE_FAST_STDOUT") -and ($captureText -match "CLAUDE_EXECUTION_POLICY.md") -and ($captureText -match "Claude Execution Evidence") -and ($captureText -match "Command Transparency") -and ($captureText -match "Model Evidence"))
    Check "cycle writes sanitized Claude command capture" ((Test-Path $claudeCommand) -and ($commandText -match "Claude Implementer Command Capture") -and ($commandText -match "<prompt:redacted>") -and ($commandText -match "--permission-mode acceptEdits") -and ($commandText -match "--disallowed-tools Bash") -and ($commandText -match "Sanitized: true"))
    Check "cycle appends Claude Implementer JSONL capture" ((Test-Path $claudeJsonl) -and ($null -ne $captureRecord) -and ($captureRecord.exitCode -eq 0) -and ($captureRecord.timedOut -eq $false) -and ($captureRecord.stdout -match "FAKE_CLAUDE_FAST_STDOUT"))
    Check "JSONL capture includes command and model evidence" (($null -ne $captureRecord.commands) -and ($captureRecord.commands[0].sanitized -eq $true) -and ($captureRecord.commands[0].cmd -match "<prompt:redacted>") -and ($null -ne $captureRecord.modelEvidence) -and ($captureRecord.modelEvidence.actualModelObserved -eq "unknown/not exposed") -and ($captureRecord.modelEvidence.source -eq "not exposed") -and ($captureRecord.modelEvidence.confidence -eq "low"))
    $r2 = Invoke-Handoff -WorkDir $fx -Arguments @("cycle", "-Yes", "-TimeoutSeconds", "5")
    Check "Claude capture artifacts are clean-tree exempt for cycle (2nd run still reaches the turn)" (($r2.Code -eq 7) -and ($r2.Out -notmatch "Working tree is not clean"))
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
