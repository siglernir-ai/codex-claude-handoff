param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
)

$ErrorActionPreference = "Stop"

# Resolve paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$TemplatesDir = Join-Path $RepoRoot "templates"

$RequiredTemplates = @(
    "AGENTS.md",
    "CLAUDE.md",
    "AI_HANDOFF.md"
)

Write-Host "Codex-Claude Handoff Installer"
Write-Host "Target project: $TargetPath"
Write-Host ""

# Validate target path
if (-not (Test-Path $TargetPath)) {
    Write-Error "Target path does not exist: $TargetPath"
}

# Validate templates folder
if (-not (Test-Path $TemplatesDir)) {
    Write-Error "Templates folder not found: $TemplatesDir"
}

# Copy required template files without overwriting existing files
foreach ($FileName in $RequiredTemplates) {
    $SourceFile = Join-Path $TemplatesDir $FileName
    $TargetFile = Join-Path $TargetPath $FileName

    if (-not (Test-Path $SourceFile)) {
        Write-Error "Missing template file: $SourceFile"
    }

    if (Test-Path $TargetFile) {
        Write-Host "Skipped existing file: $FileName"
    }
    else {
        Copy-Item -Path $SourceFile -Destination $TargetFile
        Write-Host "Copied: $FileName"
    }
}

# Ensure .gitignore exists and ignores AI_HANDOFF.md and NEXT_TURN.md
$GitignorePath = Join-Path $TargetPath ".gitignore"

if (-not (Test-Path $GitignorePath)) {
    Set-Content -Path $GitignorePath -Value "# Local AI handoff context`nAI_HANDOFF.md`nNEXT_TURN.md" -Encoding utf8
    Write-Host "Created .gitignore with AI_HANDOFF.md and NEXT_TURN.md rules"
}
else {
    $GitignoreContent = Get-Content -Path $GitignorePath -Raw

    $addedRules = [System.Collections.Generic.List[string]]::new()

    if (-not ($GitignoreContent -match "(?m)^AI_HANDOFF\.md$")) {
        Add-Content -Path $GitignorePath -Value "`n# Local AI handoff context`nAI_HANDOFF.md"
        $addedRules.Add("AI_HANDOFF.md")
    }

    if (-not ($GitignoreContent -match "(?m)^NEXT_TURN\.md$")) {
        Add-Content -Path $GitignorePath -Value "NEXT_TURN.md"
        $addedRules.Add("NEXT_TURN.md")
    }

    if ($addedRules.Count -gt 0) {
        Write-Host "Added to .gitignore: $($addedRules -join ', ')"
    } else {
        Write-Host ".gitignore already contains AI_HANDOFF.md and NEXT_TURN.md"
    }
}

Write-Host ""
Write-Host "Install complete."
Write-Host "Next steps:"
Write-Host "1. Open AGENTS.md and customize the project context."
Write-Host "2. Review CLAUDE.md."
Write-Host "3. Use AI_HANDOFF.md to start the first task."