$HandoffFile = Join-Path (Get-Location) "AI_HANDOFF.md"

if (-not (Test-Path $HandoffFile)) {
    Write-Host "No AI_HANDOFF.md found in the current directory."
    Write-Host "Run this script from your project root, or install the handoff protocol first."
    exit 0
}

$Lines = Get-Content -Path $HandoffFile

function Get-SectionLines {
    param([string[]]$Lines, [string]$Heading)
    $inSection = $false
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line.TrimEnd() -eq "## $Heading") {
            $inSection = $true
            continue
        }
        if ($inSection) {
            if ($line -match "^##\s") { break }
            $result.Add($line)
        }
    }
    return $result.ToArray()
}

$StatusLines = Get-SectionLines -Lines $Lines -Heading "Status"
$OpenIssuesLines = Get-SectionLines -Lines $Lines -Heading "Open Issues"

$State = "(unknown)"
$WaitingFor = "(unknown)"
$CurrentTask = "(unknown)"

foreach ($line in $StatusLines) {
    if ($line -match "^- State:\s*(.+)") { $State = $Matches[1].Trim() }
    if ($line -match "^- Waiting For:\s*(.+)") { $WaitingFor = $Matches[1].Trim() }
    if ($line -match "^- Current Task:\s*(.+)") { $CurrentTask = $Matches[1].Trim() }
}

Write-Host ""
Write-Host "=== Handoff Status ==="
Write-Host "State:        $State"
Write-Host "Waiting For:  $WaitingFor"
Write-Host "Current Task: $CurrentTask"
Write-Host ""

if ($State -eq "READY_FOR_REVIEW" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Recommended Prompt for Codex ==="
    Write-Host ""
    Write-Host "Use the codex-claude-handoff skill. Read AI_HANDOFF.md and review Changed Files."
    Write-Host "Run git status and git diff before approving. Check Changed Files match."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "READY_FOR_IMPLEMENTATION" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Recommended Prompt for Claude Code ==="
    Write-Host ""
    Write-Host "Read CLAUDE.md and AI_HANDOFF.md. Continue the protocol from the current state."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "NEEDS_INVESTIGATION" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Recommended Prompt for Claude Code ==="
    Write-Host ""
    Write-Host "Read CLAUDE.md and AI_HANDOFF.md. Investigate only - do not modify source files."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "PLAN_REQUIRED" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Recommended Prompt for Claude Code ==="
    Write-Host ""
    Write-Host "Read CLAUDE.md and AI_HANDOFF.md. Write a plan only - do not modify source files."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "PLAN_READY_FOR_REVIEW" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Recommended Prompt for Codex ==="
    Write-Host ""
    Write-Host "Use the codex-claude-handoff skill. Read AI_HANDOFF.md and review the plan."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") {
    Write-Host "=== Next Step: User Action Required ==="
    Write-Host ""
    Write-Host "Review the result in AI_HANDOFF.md."
    Write-Host "Commit approved changes, or decide the next step."
}
elseif ($State -eq "BLOCKED") {
    Write-Host "=== BLOCKED: User Input Needed ==="
    Write-Host ""
    if ($OpenIssuesLines.Count -gt 0) {
        Write-Host "Open Issues:"
        foreach ($line in $OpenIssuesLines) {
            if ($line.Trim() -ne "") { Write-Host $line }
        }
        Write-Host ""
    }
    Write-Host "Review AI_HANDOFF.md and resolve the blocking issue before continuing."
}
elseif ($State -eq "NEEDS_ANALYSIS" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Recommended Prompt for Codex ==="
    Write-Host ""
    Write-Host "Use the codex-claude-handoff skill. Read AI_HANDOFF.md."
    Write-Host "Classify the task and set the correct state."
    Write-Host "Current task: $CurrentTask"
}
else {
    Write-Host "=== Next Step ==="
    Write-Host ""
    Write-Host "Inspect AI_HANDOFF.md and decide the next step."
}

Write-Host ""
