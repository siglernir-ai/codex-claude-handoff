param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateRoot = Join-Path $repoRoot "templates"
$targetRoot = [System.IO.Path]::GetFullPath($Project)

if (-not (Test-Path $templateRoot)) {
    throw "templates folder not found next to install.ps1: $templateRoot"
}

if (-not (Test-Path $targetRoot)) {
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
}

$gitDir = Join-Path $targetRoot ".git"
if (-not (Test-Path $gitDir)) {
    Write-Host "WARNING: target is not a Git repository yet: $targetRoot"
    Write-Host "You can still install, but run 'git init' before using commit/review guards."
}

$wouldOverwrite = @()
Get-ChildItem -Path $templateRoot -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
    $dest = Join-Path $targetRoot $rel
    if ((Test-Path $dest) -and -not $Force) { $wouldOverwrite += $rel }
}

if ($wouldOverwrite.Count -gt 0) {
    Write-Host "install.ps1: blocked to avoid overwriting existing files."
    Write-Host "Existing target files:"
    $wouldOverwrite | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Re-run with -Force only if you want to refresh/replace installed protocol files."
    exit 1
}

Get-ChildItem -Path $templateRoot -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
    $dest = Join-Path $targetRoot $rel
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
}

$snippetPath = Join-Path $templateRoot "gitignore-snippet.txt"
$gitignorePath = Join-Path $targetRoot ".gitignore"
if (Test-Path $snippetPath) {
    $snippet = (Get-Content -Raw -Path $snippetPath).Trim()
    $current = if (Test-Path $gitignorePath) { Get-Content -Raw -Path $gitignorePath } else { "" }
    if ($current -notmatch [regex]::Escape("AI_HANDOFF.md")) {
        Add-Content -Path $gitignorePath -Value ""
        Add-Content -Path $gitignorePath -Value $snippet
    }
}

Write-Host ""
Write-Host "codex-claude-handoff installed into:"
Write-Host "  $targetRoot"
Write-Host ""
Write-Host "Next:"
Write-Host "  cd `"$targetRoot`""
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 doctor"
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 work"
Write-Host ""
Write-Host "Start a task:"
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 start `"Describe your task here`""
Write-Host ""
