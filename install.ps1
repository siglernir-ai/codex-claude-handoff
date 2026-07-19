param(
    [string]$Project = (Get-Location).Path,
    [switch]$Force,
    [switch]$AlwaysOn,
    [switch]$DisableAlwaysOn
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateRoot = Join-Path $repoRoot "templates"
$targetRoot = [System.IO.Path]::GetFullPath($Project)

if (-not (Test-Path -LiteralPath $templateRoot)) {
    throw "templates folder not found next to install.ps1: $templateRoot"
}

if (-not (Test-Path -LiteralPath $targetRoot)) {
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
}

if ($AlwaysOn -and $DisableAlwaysOn) {
    throw "Choose either -AlwaysOn or -DisableAlwaysOn, not both."
}

$gitDir = Join-Path $targetRoot ".git"
if (-not (Test-Path -LiteralPath $gitDir)) {
    Write-Host "WARNING: target is not a Git repository yet: $targetRoot"
    Write-Host "Run 'git init' and create a baseline commit before using review/commit guards."
}

# Root AGENTS.md and CLAUDE.md make the protocol active for every agent turn. They are
# intentionally excluded from the default installation. Opt in with -AlwaysOn only when
# the project owner explicitly wants that behavior.
$alwaysOnFiles = @("AGENTS.md", "CLAUDE.md")

if ($DisableAlwaysOn) {
    $removalCandidates = @()
    foreach ($relative in $alwaysOnFiles) {
        $targetFile = Join-Path $targetRoot $relative
        if (-not (Test-Path -LiteralPath $targetFile)) { continue }

        $templateFile = Join-Path $templateRoot $relative
        $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetFile).Hash
        $templateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $templateFile).Hash
        if ($targetHash -ne $templateHash) {
            throw "Refusing to remove customized root instructions: $targetFile"
        }
        $removalCandidates += $targetFile
    }

    foreach ($targetFile in $removalCandidates) {
        Remove-Item -LiteralPath $targetFile -Force
        Write-Host "Removed unmodified bundled root instruction: $targetFile"
    }
}

# These files belong to the distributable repository, not to an installed user project.
$packageOnlyFiles = @(
    "gitignore-snippet.txt",
    "scripts\protocol-tests.ps1",
    "scripts\protocol-tests.sh"
)

$installFiles = @(
    Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
        $normalized = $rel -replace '/', '\'

        if ($packageOnlyFiles -contains $normalized) { return }
        if ((-not $AlwaysOn) -and ($alwaysOnFiles -contains $normalized)) { return }

        [pscustomobject]@{
            Source = $_.FullName
            Relative = $normalized
        }
    }
)

$wouldOverwrite = @()
foreach ($file in $installFiles) {
    $dest = Join-Path $targetRoot $file.Relative
    if ((Test-Path -LiteralPath $dest) -and -not $Force) {
        $wouldOverwrite += $file.Relative
    }
}

if ($wouldOverwrite.Count -gt 0) {
    Write-Host "install.ps1: blocked to avoid overwriting existing files."
    Write-Host "Existing target files:"
    $wouldOverwrite | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Re-run with -Force only when you intentionally want to refresh installed protocol files."
    exit 1
}

foreach ($file in $installFiles) {
    $dest = Join-Path $targetRoot $file.Relative
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $file.Source -Destination $dest -Force
}

$snippetPath = Join-Path $templateRoot "gitignore-snippet.txt"
$gitignorePath = Join-Path $targetRoot ".gitignore"
if (Test-Path -LiteralPath $snippetPath) {
    $snippet = (Get-Content -Raw -LiteralPath $snippetPath).Trim()
    $current = if (Test-Path -LiteralPath $gitignorePath) {
        Get-Content -Raw -LiteralPath $gitignorePath
    }
    else {
        ""
    }

    if ($current -notmatch [regex]::Escape("AI_HANDOFF.md")) {
        Add-Content -LiteralPath $gitignorePath -Value ""
        Add-Content -LiteralPath $gitignorePath -Value $snippet
    }
}

$mode = if ($AlwaysOn) { "always-on" } else { "opt-in" }

if ((-not $AlwaysOn) -and (-not $DisableAlwaysOn)) {
    $legacyBundledFiles = @()
    foreach ($relative in $alwaysOnFiles) {
        $targetFile = Join-Path $targetRoot $relative
        $templateFile = Join-Path $templateRoot $relative
        if ((Test-Path -LiteralPath $targetFile) -and (Test-Path -LiteralPath $templateFile)) {
            $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetFile).Hash
            $templateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $templateFile).Hash
            if ($targetHash -eq $templateHash) { $legacyBundledFiles += $relative }
        }
    }

    if ($legacyBundledFiles.Count -gt 0) {
        Write-Host "WARNING: bundled always-on root instructions are still present: $($legacyBundledFiles -join ', ')"
        Write-Host "To migrate an unmodified older install to opt-in mode, re-run with -Force -DisableAlwaysOn."
    }
}

Write-Host ""
Write-Host "codex-claude-handoff installed into:"
Write-Host "  $targetRoot"
Write-Host "Activation mode: $mode"
Write-Host ""
Write-Host "Check the installation:"
Write-Host "  cd `"$targetRoot`""
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 doctor"
Write-Host ""

if ($AlwaysOn) {
    Write-Host "Always-on mode is enabled. Codex and Claude root instructions were installed."
}
else {
    Write-Host "Use it for one task in Codex Desktop:"
    Write-Host "  1. Enter /skills in the Codex composer."
    Write-Host "  2. Select codex-claude-handoff."
    Write-Host "  3. Describe the task you want completed through the full protocol."
    Write-Host ""
    Write-Host "For normal Codex work, do not select or mention the skill."
}

Write-Host "The workflow stops before commit, push, tag, release, or deploy until you explicitly authorize it."
Write-Host ""
