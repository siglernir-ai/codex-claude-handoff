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

function Get-InstalledRoleBinding {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $binding = @{}
    $counts = @{ Master = 0; Reviewer = 0; Implementer = 0 }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\|\s*(Master|Reviewer|Implementer)\s*\|\s*(.+?)\s*\|') {
            $counts[$Matches[1]]++
            $binding[$Matches[1]] = $Matches[2].Trim()
        }
    }
    if ($binding.Count -ne 3) { return $null }
    foreach ($role in @('Master', 'Reviewer', 'Implementer')) {
        if ($counts[$role] -ne 1 -or [string]::IsNullOrWhiteSpace($binding[$role])) { return $null }
    }
    return $binding
}

# v3.7.0: an upgrade must not delete what the project added to this file.
#
# The merge below builds the new file from the template and substitutes only the three
# role rows, so any section the project added of its own - a Role Swap History table, a
# note explaining why a binding was chosen - disappeared on the next -Force upgrade,
# with no warning and no copy kept. The protocol asks the user to record a swap here
# ("record what changed, when, and that the user approved it") and the installer then
# deleted the record. Three swap histories were reconstructed by hand in one day before
# this was noticed.
#
# Sections whose heading the template does not have are carried across and re-inserted
# after the section they followed, so their position survives too. A section the
# template owns is still refreshed from the template - that is what -Force is for.
function Get-MarkdownSectionMap {
    param([string]$Content)
    $order = [System.Collections.Generic.List[string]]::new()
    $bodies = @{}
    $current = $null
    $buffer = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^##\s+(.+?)\s*$') {
            if ($null -ne $current) { $bodies[$current] = ($buffer -join "`n") }
            $current = $Matches[1]
            $order.Add($current)
            $buffer = [System.Collections.Generic.List[string]]::new()
            $buffer.Add($line)
        } else {
            $buffer.Add($line)
        }
    }
    if ($null -ne $current) { $bodies[$current] = ($buffer -join "`n") }
    return @{ Order = $order; Bodies = $bodies }
}

function Add-PreservedRoleSections {
    param([string]$MergedContent, [string]$ExistingContent)
    if ([string]::IsNullOrWhiteSpace($ExistingContent)) { return $MergedContent }
    $existing = Get-MarkdownSectionMap -Content $ExistingContent
    $merged   = Get-MarkdownSectionMap -Content $MergedContent
    $extra = @($existing.Order | Where-Object { -not $merged.Bodies.ContainsKey($_) })
    if ($extra.Count -eq 0) { return $MergedContent }

    $lines = @($MergedContent -split "`r?`n")
    foreach ($heading in $extra) {
        $idx = $existing.Order.IndexOf($heading)
        $anchor = $null
        for ($i = $idx - 1; $i -ge 0; $i--) {
            if ($merged.Bodies.ContainsKey($existing.Order[$i])) { $anchor = $existing.Order[$i]; break }
        }
        $block = @($existing.Bodies[$heading] -split "`n")
        while ($block.Count -gt 0 -and [string]::IsNullOrWhiteSpace($block[-1])) { $block = $block[0..($block.Count - 2)] }
        $insertAt = $lines.Count
        if ($anchor) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match ('^##\s+' + [regex]::Escape($anchor) + '\s*$')) {
                    $insertAt = $i + 1
                    while ($insertAt -lt $lines.Count -and $lines[$insertAt] -notmatch '^##\s') { $insertAt++ }
                    break
                }
            }
        }
        $head = if ($insertAt -gt 0) { $lines[0..($insertAt - 1)] } else { @() }
        $tail = if ($insertAt -lt $lines.Count) { $lines[$insertAt..($lines.Count - 1)] } else { @() }
        $lines = @($head) + @($block) + @("") + @($tail)
    }
    return ($lines -join "`r`n")
}
function Get-MergedRoleAssignmentContent {
    param([string]$TemplatePath, [hashtable]$Binding, [string]$InstalledPath)
    $content = Get-Content -Raw -LiteralPath $TemplatePath
    foreach ($role in @('Master', 'Reviewer', 'Implementer')) {
        $pattern = '(?m)^\|\s*' + [regex]::Escape($role) + '\s*\|\s*.+?\s*\|\s*$'
        $replacement = "| $role | $($Binding[$role]) |"
        $content = [regex]::Replace($content, $pattern, $replacement)
    }
    $existingRoleContent = if ($InstalledPath -and (Test-Path -LiteralPath $InstalledPath)) { Get-Content -Raw -LiteralPath $InstalledPath } else { "" }
    return (Add-PreservedRoleSections -MergedContent $content -ExistingContent $existingRoleContent)
}

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

# Run update validation before any operation that can mutate the target. An invalid
# existing role file must fail closed without removing or copying anything.
# v3.7.0: DECISIONS.md accumulates across tasks and must survive an upgrade for the
# same reason AI_HANDOFF.md does - overwriting it would destroy the only record of
# what the product is, which no commit message reconstructs.
$preserveOnForceFiles = @("AI_HANDOFF.md", "AI_SEQUENCE.md", "DECISIONS.md")
$roleAssignmentRelative = ".ai\roles\ROLE_ASSIGNMENT.md"
$installedRolePath = Join-Path $targetRoot $roleAssignmentRelative
$preservedRoleBinding = $null
if ($Force -and (Test-Path -LiteralPath $installedRolePath)) {
    $preservedRoleBinding = Get-InstalledRoleBinding -Path $installedRolePath
    if (-not $preservedRoleBinding) {
        throw "Refusing -Force update: existing ROLE_ASSIGNMENT.md cannot be parsed exactly. Repair it before updating: $installedRolePath"
    }
    if ($preservedRoleBinding.Reviewer -eq $preservedRoleBinding.Implementer) {
        throw "Refusing -Force update: existing role binding violates Reviewer != Implementer. Repair it before updating: $installedRolePath"
    }
}

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
    if ($Force -and ($preserveOnForceFiles -contains $file.Relative) -and (Test-Path -LiteralPath $dest)) {
        Write-Host "Preserved local coordination state: $($file.Relative)"
        continue
    }
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ($file.Relative -eq $roleAssignmentRelative -and $preservedRoleBinding) {
        $mergedRoleContent = Get-MergedRoleAssignmentContent -TemplatePath $file.Source -Binding $preservedRoleBinding -InstalledPath $installedRolePath
        $tempRolePath = "$dest.update-$([guid]::NewGuid().ToString('N'))"
        $backupRolePath = "$dest.backup-$([guid]::NewGuid().ToString('N'))"
        try {
            [System.IO.File]::WriteAllText($tempRolePath, $mergedRoleContent, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::Replace($tempRolePath, $dest, $backupRolePath)
        }
        finally {
            if (Test-Path -LiteralPath $tempRolePath) { Remove-Item -LiteralPath $tempRolePath -Force }
            if (Test-Path -LiteralPath $backupRolePath) { Remove-Item -LiteralPath $backupRolePath -Force }
        }
        Write-Host "Preserved current role binding while refreshing role instructions."
    }
    else {
        Copy-Item -LiteralPath $file.Source -Destination $dest -Force
    }
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

    # v3.5.0: reconcile line by line, not block-presence.
    #
    # This used to append the whole snippet only when AI_HANDOFF.md was absent from
    # .gitignore. That is correct for a first install and silently wrong for an upgrade:
    # a project installed before v3.5.0 already contains the block, so a version that
    # adds new local capture files would skip them entirely. Those files would then be
    # untracked-but-not-ignored, and the very next review-run would fail the exact-scope
    # guard on artifacts the protocol itself had just written.
    #
    # Compare the paths the snippet declares against the paths already ignored, and
    # append only what is missing. Existing entries and hand-written additions are left
    # untouched.
    $snippetLines = @($snippet -split "`r`n|`n|`r" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch "^#" })
    $currentLines = @($current -split "`r`n|`n|`r" | ForEach-Object { $_.Trim() })
    if ($current -notmatch [regex]::Escape("AI_HANDOFF.md")) {
        Add-Content -LiteralPath $gitignorePath -Value ""
        Add-Content -LiteralPath $gitignorePath -Value $snippet
    }
    else {
        $missingIgnores = @($snippetLines | Where-Object { $currentLines -notcontains $_ })
        if ($missingIgnores.Count -gt 0) {
            Add-Content -LiteralPath $gitignorePath -Value ""
            Add-Content -LiteralPath $gitignorePath -Value "# Codex-Claude handoff protocol (added by upgrade)"
            foreach ($missingLine in $missingIgnores) {
                Add-Content -LiteralPath $gitignorePath -Value $missingLine
            }
        }
    }
}

# v3.9.0: keep Claude Code's file tools out of files that hold credentials.
#
# On 2026-09-14 an Implementer opened .mcp.json against an explicit written instruction,
# and a live access token and an API key went into that session. A sentence in a prompt
# is not a boundary; a permission rule is. The rules live in one shipped file that both
# installers read. An existing settings file is merged, never replaced, and one that
# cannot be parsed is left untouched with a warning rather than rewritten.
function Add-CredentialReadGuard {
    param([string]$TargetRoot, [string]$RulesPath)

    if (-not (Test-Path -LiteralPath $RulesPath)) { return }
    $rules = @(Get-Content -LiteralPath $RulesPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch '^#' })
    if ($rules.Count -eq 0) { return }

    $settingsDir = Join-Path $TargetRoot ".claude"
    $settingsPath = Join-Path $settingsDir "settings.json"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    if (-not (Test-Path -LiteralPath $settingsPath)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        $lines = @('{', '  "permissions": {', '    "deny": [')
        for ($i = 0; $i -lt $rules.Count; $i++) {
            $separator = if ($i -lt $rules.Count - 1) { ',' } else { '' }
            $lines += '      "' + $rules[$i] + '"' + $separator
        }
        $lines += @('    ]', '  }', '}')
        [System.IO.File]::WriteAllText($settingsPath, (($lines -join "`n") + "`n"), $utf8NoBom)
        Write-Host "Credential read guard: created .claude/settings.json with $($rules.Count) deny rules."
        return
    }

    try {
        $raw = [System.IO.File]::ReadAllText($settingsPath)
        $settings = if ([string]::IsNullOrWhiteSpace($raw)) { New-Object psobject } else { $raw | ConvertFrom-Json -ErrorAction Stop }
        if ($settings -isnot [System.Management.Automation.PSCustomObject]) { throw "settings.json is not a JSON object" }
        if (-not ($settings.PSObject.Properties.Name -contains 'permissions') -or $null -eq $settings.permissions) {
            $settings | Add-Member -NotePropertyName 'permissions' -NotePropertyValue (New-Object psobject) -Force
        }
        if ($settings.permissions -isnot [System.Management.Automation.PSCustomObject]) { throw "permissions is not a JSON object" }
        $existing = @()
        if (($settings.permissions.PSObject.Properties.Name -contains 'deny') -and $null -ne $settings.permissions.deny) {
            $existing = @($settings.permissions.deny)
        }
        $missing = @($rules | Where-Object { $existing -notcontains $_ })
        if ($missing.Count -eq 0) {
            Write-Host "Credential read guard: already present in .claude/settings.json."
            return
        }
        $settings.permissions | Add-Member -NotePropertyName 'deny' -NotePropertyValue @($existing + $missing) -Force
        [System.IO.File]::WriteAllText($settingsPath, (($settings | ConvertTo-Json -Depth 32) + "`n"), $utf8NoBom)
        Write-Host "Credential read guard: added $($missing.Count) deny rules to .claude/settings.json."
    }
    catch {
        Write-Host "WARNING: the credential read guard was not added, because .claude/settings.json could not be merged safely ($($_.Exception.Message))."
        Write-Host "The file was left unchanged. Add these entries to permissions.deny by hand: $($rules -join ', ')"
    }
}

Add-CredentialReadGuard -TargetRoot $targetRoot -RulesPath (Join-Path $templateRoot ".ai\skills\codex-claude-handoff\CREDENTIAL_READ_DENY.txt")

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
