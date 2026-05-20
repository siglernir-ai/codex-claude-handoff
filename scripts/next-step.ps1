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
    Write-Host "Use the codex-claude-handoff skill."
    Write-Host ""
    Write-Host "Read AI_HANDOFF.md and review the files listed under Changed Files."
    Write-Host "Only review the requested scope."
    Write-Host "Update AI_HANDOFF.md with your review result."
}
elseif ($State -eq "READY_FOR_IMPLEMENTATION" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Recommended Prompt for Claude Code ==="
    Write-Host ""
    Write-Host "Read CLAUDE.md and AI_HANDOFF.md."
    Write-Host ""
    Write-Host "Implement only the current task in AI_HANDOFF.md."
    Write-Host "Keep changes limited to the requested scope."
    Write-Host "After finishing, update AI_HANDOFF.md with changed files, verification, risks, and next step."
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
else {
    Write-Host "=== Next Step ==="
    Write-Host ""
    Write-Host "Inspect AI_HANDOFF.md and decide the next step."
}

Write-Host ""
