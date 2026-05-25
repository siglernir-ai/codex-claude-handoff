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

if ($State -eq "NEEDS_ANALYSIS" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Codex"
    Write-Host "Action: Classify the task and set the correct State and Waiting For."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    Write-Host "=== Prompt ==="
    Write-Host "Use the codex-claude-handoff skill. Read AI_HANDOFF.md."
    Write-Host "Classify the task and set the correct state."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "NEEDS_INVESTIGATION" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Claude Code"
    Write-Host "Action: Investigate only. Do not modify source files."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    Write-Host "=== Prompt ==="
    Write-Host "Read CLAUDE.md and AI_HANDOFF.md. Investigate only - do not modify source files."
    Write-Host "Report findings in AI_HANDOFF.md. Set State: READY_FOR_REVIEW."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "PLAN_REQUIRED" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Claude Code"
    Write-Host "Action: Write a plan only. Do not modify source files."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    Write-Host "=== Prompt ==="
    Write-Host "Read CLAUDE.md and AI_HANDOFF.md. Write a plan only - do not modify source files."
    Write-Host "Set State: PLAN_READY_FOR_REVIEW when done."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "PLAN_READY_FOR_REVIEW" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Codex"
    Write-Host "Action: Review the plan. Approve or request changes before implementation begins."
    Write-Host "Commit: Blocked - plan not yet approved."
    Write-Host ""
    Write-Host "=== Prompt ==="
    Write-Host "Use the codex-claude-handoff skill. Read AI_HANDOFF.md. Review the plan."
    Write-Host "Set State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "READY_FOR_IMPLEMENTATION" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Claude Code"
    Write-Host "Action: Implement the approved scope. Do not modify unrelated files."
    Write-Host "Commit: Blocked - waiting for Codex review after implementation."
    Write-Host ""
    Write-Host "=== Prompt ==="
    Write-Host "Read CLAUDE.md and AI_HANDOFF.md. Continue the protocol from the current state."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "IMPLEMENTED") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Review the work. Commit if satisfied, or ask Codex to review first."
    Write-Host "Commit: ALLOWED - no Codex review was required for this task."
}
elseif ($State -eq "READY_FOR_REVIEW" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Codex"
    Write-Host "Action: Review Changed Files. Run git status and git diff before approving."
    Write-Host "Commit: Blocked - waiting for Codex approval."
    Write-Host ""
    Write-Host "=== Prompt ==="
    Write-Host "Use the codex-claude-handoff skill. Read AI_HANDOFF.md and review Changed Files."
    Write-Host "Run git status and git diff before approving. Check Changed Files match."
    Write-Host "Current task: $CurrentTask"
}
elseif ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Commit and push approved changes. Do not commit AI_HANDOFF.md."
    Write-Host "Commit: ALLOWED - Codex approved. Commit only the files listed under Changed Files."
}
elseif ($State -eq "BLOCKED") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md."
    Write-Host "Commit: Blocked - work is blocked."
    if ($OpenIssuesLines.Count -gt 0) {
        Write-Host ""
        Write-Host "Open Issues:"
        foreach ($line in $OpenIssuesLines) {
            if ($line.Trim() -ne "") { Write-Host $line }
        }
    }
}
elseif ($State -eq "WAITING_FOR_USER") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Review AI_HANDOFF.md and decide the next step or provide approval."
    Write-Host "Commit: Blocked - waiting for user decision."
}
else {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Inspect AI_HANDOFF.md and decide the next step."
    Write-Host "Commit: Blocked - state is unknown."
}

Write-Host ""
