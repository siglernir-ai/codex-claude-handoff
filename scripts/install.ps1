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
    "AI_HANDOFF.md",
    "AI_SEQUENCE.md"
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
    Set-Content -Path $GitignorePath -Value "# Local AI handoff context`nAI_HANDOFF.md`nNEXT_TURN.md`nUSER_REQUEST.md`nHANDOFF_LOOP.log`nAI_SEQUENCE.md`nCODEX_REVIEW.jsonl`nCODEX_REVIEW_LAST.md`nCODEX_MASTER.jsonl`nCODEX_MASTER_LAST.md`nCLAUDE_IMPLEMENTER.jsonl`nCLAUDE_IMPLEMENTER_LAST.md`nCLAUDE_IMPLEMENTER_COMMAND.md`nIMPLEMENTER_CLI_BRIEF.md" -Encoding utf8
    Write-Host "Created .gitignore with AI_HANDOFF.md, NEXT_TURN.md, USER_REQUEST.md, HANDOFF_LOOP.log, AI_SEQUENCE.md, CODEX_REVIEW.jsonl, CODEX_REVIEW_LAST.md, CODEX_MASTER.jsonl, CODEX_MASTER_LAST.md, CLAUDE_IMPLEMENTER.jsonl, CLAUDE_IMPLEMENTER_LAST.md, CLAUDE_IMPLEMENTER_COMMAND.md, and IMPLEMENTER_CLI_BRIEF.md rules"
}
else {
    $GitignoreContent = Get-Content -Path $GitignorePath -Raw
    $lines = $GitignoreContent -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    $addedRules = [System.Collections.Generic.List[string]]::new()

    if ($lines -notcontains "AI_HANDOFF.md") {
        Add-Content -Path $GitignorePath -Value "`n# Local AI handoff context`nAI_HANDOFF.md"
        $addedRules.Add("AI_HANDOFF.md")
    }

    if ($lines -notcontains "NEXT_TURN.md") {
        Add-Content -Path $GitignorePath -Value "NEXT_TURN.md"
        $addedRules.Add("NEXT_TURN.md")
    }

    if ($lines -notcontains "USER_REQUEST.md") {
        Add-Content -Path $GitignorePath -Value "USER_REQUEST.md"
        $addedRules.Add("USER_REQUEST.md")
    }

    if ($lines -notcontains "HANDOFF_LOOP.log") {
        Add-Content -Path $GitignorePath -Value "HANDOFF_LOOP.log"
        $addedRules.Add("HANDOFF_LOOP.log")
    }

    if ($lines -notcontains "AI_SEQUENCE.md") {
        Add-Content -Path $GitignorePath -Value "AI_SEQUENCE.md"
        $addedRules.Add("AI_SEQUENCE.md")
    }

    if ($lines -notcontains "CODEX_REVIEW.jsonl") {
        Add-Content -Path $GitignorePath -Value "CODEX_REVIEW.jsonl"
        $addedRules.Add("CODEX_REVIEW.jsonl")
    }

    if ($lines -notcontains "CODEX_REVIEW_LAST.md") {
        Add-Content -Path $GitignorePath -Value "CODEX_REVIEW_LAST.md"
        $addedRules.Add("CODEX_REVIEW_LAST.md")
    }

    if ($lines -notcontains "CODEX_MASTER.jsonl") {
        Add-Content -Path $GitignorePath -Value "CODEX_MASTER.jsonl"
        $addedRules.Add("CODEX_MASTER.jsonl")
    }

    if ($lines -notcontains "CODEX_MASTER_LAST.md") {
        Add-Content -Path $GitignorePath -Value "CODEX_MASTER_LAST.md"
        $addedRules.Add("CODEX_MASTER_LAST.md")
    }

    if ($lines -notcontains "CLAUDE_IMPLEMENTER.jsonl") {
        Add-Content -Path $GitignorePath -Value "CLAUDE_IMPLEMENTER.jsonl"
        $addedRules.Add("CLAUDE_IMPLEMENTER.jsonl")
    }

    if ($lines -notcontains "CLAUDE_IMPLEMENTER_LAST.md") {
        Add-Content -Path $GitignorePath -Value "CLAUDE_IMPLEMENTER_LAST.md"
        $addedRules.Add("CLAUDE_IMPLEMENTER_LAST.md")
    }

    if ($lines -notcontains "CLAUDE_IMPLEMENTER_COMMAND.md") {
        Add-Content -Path $GitignorePath -Value "CLAUDE_IMPLEMENTER_COMMAND.md"
        $addedRules.Add("CLAUDE_IMPLEMENTER_COMMAND.md")
    }

    if ($lines -notcontains "IMPLEMENTER_CLI_BRIEF.md") {
        Add-Content -Path $GitignorePath -Value "IMPLEMENTER_CLI_BRIEF.md"
        $addedRules.Add("IMPLEMENTER_CLI_BRIEF.md")
    }

    if ($addedRules.Count -gt 0) {
        Write-Host "Added to .gitignore: $($addedRules -join ', ')"
    } else {
        Write-Host ".gitignore already contains AI_HANDOFF.md, NEXT_TURN.md, USER_REQUEST.md, HANDOFF_LOOP.log, AI_SEQUENCE.md, CODEX_REVIEW.jsonl, CODEX_REVIEW_LAST.md, CODEX_MASTER.jsonl, CODEX_MASTER_LAST.md, CLAUDE_IMPLEMENTER.jsonl, CLAUDE_IMPLEMENTER_LAST.md, CLAUDE_IMPLEMENTER_COMMAND.md, and IMPLEMENTER_CLI_BRIEF.md"
    }
}

# Install shared canonical skill folder and adapter stubs
$SkillFiles = @(
    ".ai/roles/ROLE_ASSIGNMENT.md",
    ".ai/skills/codex-claude-handoff/VERSION",
    ".ai/skills/codex-claude-handoff/README.md",
    ".ai/skills/codex-claude-handoff/SKILL.md",
    ".ai/skills/codex-claude-handoff/MASTER.md",
    ".ai/skills/codex-claude-handoff/IMPLEMENTER.md",
    ".ai/skills/codex-claude-handoff/PROTOCOL_METHOD.md",
    ".ai/skills/codex-claude-handoff/ADAPTERS.md",
    ".ai/skills/codex-claude-handoff/CODEX.md",
    ".ai/skills/codex-claude-handoff/CLAUDE.md",
    ".ai/skills/codex-claude-handoff/CAPABILITIES.md",
    ".ai/skills/codex-claude-handoff/CLAUDE_EXECUTION_POLICY.md",
    ".agents/skills/codex-claude-handoff/SKILL.md",
    ".claude/skills/codex-claude-handoff/SKILL.md"
)

foreach ($RelPath in $SkillFiles) {
    $NormPath    = $RelPath -replace "/", [System.IO.Path]::DirectorySeparatorChar
    $SourceFile  = Join-Path $TemplatesDir $NormPath
    $TargetFile  = Join-Path $TargetPath $NormPath
    $TargetDir   = Split-Path -Parent $TargetFile

    if (-not (Test-Path $SourceFile)) {
        Write-Host "Warning: Missing skill template: $RelPath"
        continue
    }

    if (Test-Path $TargetFile) {
        Write-Host "Skipped existing skill file: $RelPath"
    }
    else {
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
        }
        Copy-Item -Path $SourceFile -Destination $TargetFile
        Write-Host "Copied skill: $RelPath"
    }
}

# Install workflow scripts
$WorkflowScripts = @(
    "scripts/handoff.ps1",
    "scripts/next-step.ps1",
    "scripts/handoff.sh",
    "scripts/next-step.sh",
    "scripts/protocol-tests.ps1",
    "scripts/protocol-tests.sh"
)

foreach ($RelPath in $WorkflowScripts) {
    $NormPath    = $RelPath -replace "/", [System.IO.Path]::DirectorySeparatorChar
    $SourceFile  = Join-Path $TemplatesDir $NormPath
    $TargetFile  = Join-Path $TargetPath $NormPath
    $TargetDir   = Split-Path -Parent $TargetFile

    if (-not (Test-Path $SourceFile)) {
        Write-Host "Warning: Missing workflow script template: $RelPath"
        continue
    }

    if (Test-Path $TargetFile) {
        Write-Host "Skipped existing workflow script: $RelPath"
    }
    else {
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
        }
        Copy-Item -Path $SourceFile -Destination $TargetFile
        Write-Host "Copied workflow script: $RelPath"
    }
}

Write-Host ""
Write-Host "Install complete."
Write-Host "Next steps:"
Write-Host "1. Open AGENTS.md and customize the project context."
Write-Host "2. Review CLAUDE.md."
Write-Host "3. Use AI_HANDOFF.md to start the first task."
Write-Host "4. Run workflow commands from the target project root:"
Write-Host "   - powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 status"
Write-Host "   - powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 next"
