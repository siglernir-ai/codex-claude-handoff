param(
    [string]$PrimarySkillPath
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $PrimarySkillPath) {
    $PrimarySkillPath = Join-Path $repoRoot ".agents\skills\codex-claude-handoff"
}
$primarySkill = [System.IO.Path]::GetFullPath($PrimarySkillPath)
$claudeSkill = Join-Path $repoRoot ".claude\skills\codex-claude-handoff"
$packageRoot = Join-Path $primarySkill "assets\package"
$templateSource = Join-Path $repoRoot "templates"

if (-not (Test-Path -LiteralPath (Join-Path $primarySkill "SKILL.md"))) {
    throw "Primary skill SKILL.md is missing: $primarySkill"
}

if (Test-Path -LiteralPath $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $packageRoot "scripts") -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $repoRoot "install.ps1") -Destination (Join-Path $packageRoot "install.ps1") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\install.sh") -Destination (Join-Path $packageRoot "scripts\install.sh") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination (Join-Path $primarySkill "LICENSE") -Force

$excludedTemplateFiles = @(
    "scripts\protocol-tests.ps1",
    "scripts\protocol-tests.sh"
)

Get-ChildItem -LiteralPath $templateSource -Recurse -File -Force | ForEach-Object {
    $relative = $_.FullName.Substring($templateSource.Length).TrimStart('\', '/') -replace '/', '\'
    if ($excludedTemplateFiles -contains $relative) { return }

    $destination = Join-Path (Join-Path $packageRoot "templates") $relative
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
}

# The skills CLI may select either common agent discovery location. Keep both
# complete and byte-identical so either source produces a standalone install.
Get-ChildItem -LiteralPath $primarySkill -Recurse -File -Force | ForEach-Object {
    $relative = $_.FullName.Substring($primarySkill.Length).TrimStart('\', '/')
    $destination = Join-Path $claudeSkill $relative
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
}

Write-Host "Standalone skill package refreshed:"
Write-Host "  $primarySkill"
Write-Host "  $claudeSkill"
