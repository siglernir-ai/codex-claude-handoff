param(
    [string]$Project = (Get-Location).Path,
    [switch]$Refresh
)

$ErrorActionPreference = "Stop"

$skillRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$packageRoot = Join-Path $skillRoot "assets\package"
$installer = Join-Path $packageRoot "install.ps1"
$targetRoot = [System.IO.Path]::GetFullPath($Project)
$protocolVersion = Join-Path $targetRoot ".ai\skills\codex-claude-handoff\VERSION"

if (-not (Test-Path -LiteralPath (Join-Path $targetRoot ".git"))) {
    [Console]::Error.WriteLine("Setup requires a Git repository. Run 'git init' and create a clean baseline commit first: $targetRoot")
    exit 2
}

if (-not (Test-Path -LiteralPath $installer)) {
    [Console]::Error.WriteLine("Bundled installer is missing from the skill package: $installer")
    exit 3
}

if ((Test-Path -LiteralPath $protocolVersion) -and -not $Refresh) {
    $installedVersion = (Get-Content -Raw -LiteralPath $protocolVersion).Trim()
    Write-Host "codex-claude-handoff is already installed (version $installedVersion)."
    Write-Host "Re-run with -Refresh only when the user explicitly approves refreshing managed protocol files."
    exit 0
}

# -Force is required because skills CLI has already placed this skill's adapter
# in the target project. The installer still preserves local coordination state
# and the current role binding during an approved refresh.
$installArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $installer,
    "-Project", $targetRoot,
    "-Force"
)

& powershell.exe @installArgs
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("Bundled protocol installer failed with exit code $LASTEXITCODE.")
    exit $LASTEXITCODE
}

$handoff = Join-Path $targetRoot "scripts\handoff.ps1"
Push-Location $targetRoot
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $handoff doctor
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Protocol files were copied, but doctor failed with exit code $LASTEXITCODE.")
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}

# v3.18.0: a fresh install has not chosen its players and its Master. Say so; never choose.
$roleFile = Join-Path $targetRoot ".ai\roles\ROLE_ASSIGNMENT.md"
$setupPending = $false
if (Test-Path -LiteralPath $roleFile) {
    foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $roleFile)) {
        if ($line.Replace([string][char]0x00A0, ' ') -match '^\s*(?:[-*]\s+)?Setup\s*:\s*pending\s*$') { $setupPending = $true }
    }
}
if ($setupPending) {
    Write-Host ""
    Write-Host "Setup: NOT CONFIGURED. Work commands are blocked (exit 14) until the players and the Master are chosen."
    Write-Host "Ask the user which tools work on this project and which one is the Master, then run in the project:"
    Write-Host "  .\scripts\handoff.ps1 setup -Players `"<Claude Code, Codex, or both>`" -Master `"<one of the players>`""
    Write-Host "A person at the machine can run .\scripts\handoff.ps1 setup to choose in a window."
}

Write-Host ""
Write-Host "Skill setup complete. Review the installed files before committing them."
Write-Host "No git commit, push, tag, release, deploy, database, or secret action was run."
Write-Host ""
Write-Host "After review, the usual stable install commit is:"
if (Test-Path -LiteralPath (Join-Path $targetRoot "skills-lock.json")) {
    Write-Host "  git add .agents .ai .claude scripts .gitignore COMMANDS.md skills-lock.json"
}
else {
    Write-Host "  git add .agents .ai .claude scripts .gitignore COMMANDS.md"
}
Write-Host "  git commit -m `"Install codex-claude-handoff`""
