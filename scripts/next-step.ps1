param([switch]$CopyPrompt, [switch]$PrepareFile)

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

function Get-SectionContent {
    param([string[]]$Lines, [string]$Heading)
    $sectionLines = Get-SectionLines -Lines $Lines -Heading $Heading
    return ($sectionLines -join "`n").Trim()
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

$ExpectedWaiting = @{
    "NEEDS_ANALYSIS"           = "Codex"
    "NEEDS_INVESTIGATION"      = "Claude Code"
    "PLAN_REQUIRED"            = "Claude Code"
    "PLAN_READY_FOR_REVIEW"    = "Codex"
    "READY_FOR_IMPLEMENTATION" = "Claude Code"
    "READY_FOR_REVIEW"         = "Codex"
    "REVIEW_DONE"              = "User"
    "BLOCKED"                  = "User"
    "WAITING_FOR_USER"         = "User"
}

if ($ExpectedWaiting.ContainsKey($State) -and $WaitingFor -ne $ExpectedWaiting[$State]) {
    Write-Host "WARNING: State $State normally expects Waiting For: $($ExpectedWaiting[$State]) but found: $WaitingFor."
    Write-Host ""
}

if ($State -eq "READY_FOR_REVIEW") {
    $ChangedFilesLines = Get-SectionLines -Lines $Lines -Heading "Changed Files"
    $changedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $ChangedFilesLines) {
        $entry = $line.Trim()
        if ($entry -eq "" -or $entry -eq "None yet" -or $entry -eq "- None yet") { continue }
        $entry = $entry -replace '^-\s+', ''
        $entry = $entry -replace '`', ''
        $entry = $entry.Trim()
        if ($entry -match '^(.+?)\s+-\s+.+$') { $entry = $Matches[1].Trim() }
        if ($entry -ne "") { $changedFiles.Add($entry) }
    }
    $nonHandoffFiles = $changedFiles | Where-Object { $_ -ne "AI_HANDOFF.md" }
    if ($changedFiles.Count -gt 0 -and $nonHandoffFiles.Count -eq 0) {
        Write-Host "WARNING: Changed Files lists only AI_HANDOFF.md. No tracked source file is listed for review."
        Write-Host ""
    }
}

$PromptText = ""
$ActionLine = ""
$AfterLine = ""

if ($State -eq "NEEDS_ANALYSIS" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Codex"
    Write-Host "Action: Classify the task and set the correct State and Waiting For."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read AI_HANDOFF.md.`nClassify the task and set the correct state.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Classify the task and set the correct State and Waiting For."
    $AfterLine = "Set State to the appropriate gate and Waiting For to the correct actor. Update AI_HANDOFF.md."
}
elseif ($State -eq "NEEDS_INVESTIGATION" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Claude Code"
    Write-Host "Action: Investigate only. Do not modify source files."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    $PromptText = "Read CLAUDE.md and AI_HANDOFF.md. Investigate only - do not modify source files.`nReport findings in AI_HANDOFF.md. Set State: READY_FOR_REVIEW.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Investigate only. Do not modify source files."
    $AfterLine = "Set State: READY_FOR_REVIEW and Waiting For: Codex. Update AI_HANDOFF.md."
}
elseif ($State -eq "PLAN_REQUIRED" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Claude Code"
    Write-Host "Action: Write a plan only. Do not modify source files."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    $PromptText = "Read CLAUDE.md and AI_HANDOFF.md. Write a plan only - do not modify source files.`nSet State: PLAN_READY_FOR_REVIEW when done.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Write a plan only. Do not modify source files."
    $AfterLine = "Set State: PLAN_READY_FOR_REVIEW and Waiting For: Codex. Update AI_HANDOFF.md."
}
elseif ($State -eq "PLAN_READY_FOR_REVIEW" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Codex"
    Write-Host "Action: Review the plan. Approve or request changes before implementation begins."
    Write-Host "Commit: Blocked - plan not yet approved."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read AI_HANDOFF.md. Review the plan.`nSet State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Review the plan. Approve or request changes before implementation begins."
    $AfterLine = "Set State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED. Set Waiting For accordingly. Update AI_HANDOFF.md."
}
elseif ($State -eq "READY_FOR_IMPLEMENTATION" -and $WaitingFor -eq "Claude Code") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Claude Code"
    Write-Host "Action: Implement the approved scope. Do not modify unrelated files."
    Write-Host "Commit: Blocked - waiting for Codex review after implementation."
    Write-Host ""
    $PromptText = "Read CLAUDE.md and AI_HANDOFF.md. Continue the protocol from the current state.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Implement the approved scope. Do not modify unrelated files."
    $AfterLine = "Set State: READY_FOR_REVIEW and Waiting For: Codex. Update AI_HANDOFF.md."
}
elseif ($State -eq "IMPLEMENTED") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Review the work. Commit if satisfied, or ask Codex to review first."
    Write-Host "Commit: ALLOWED - no Codex review was required for this task."
    $ActionLine = "Review the work. Commit if satisfied, or ask Codex to review first."
    $AfterLine = "No handoff update required. Commit only the files listed under Changed Files."
}
elseif ($State -eq "READY_FOR_REVIEW" -and $WaitingFor -eq "Codex") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  Codex"
    Write-Host "Action: Review Changed Files. Run git status and git diff before approving."
    Write-Host "Commit: Blocked - waiting for Codex approval."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read AI_HANDOFF.md and review Changed Files.`nRun git status and git diff before approving. Check Changed Files match.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Review Changed Files. Run git status and git diff before approving."
    $AfterLine = "Set State: REVIEW_DONE and Waiting For: User, or READY_FOR_IMPLEMENTATION if changes are needed. Update AI_HANDOFF.md."
}
elseif ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Commit and push approved changes. Do not commit AI_HANDOFF.md."
    Write-Host "Commit: ALLOWED - Codex approved. Commit only the files listed under Changed Files."
    $ActionLine = "Commit and push approved changes. Do not commit AI_HANDOFF.md."
    $AfterLine = "No handoff update required. Commit only the files listed under Changed Files."
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
    $ActionLine = "Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md."
    $AfterLine = "Resolve the blocker, update AI_HANDOFF.md, and set State and Waiting For appropriately."
}
elseif ($State -eq "WAITING_FOR_USER") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Review AI_HANDOFF.md and decide the next step or provide approval."
    Write-Host "Commit: Blocked - waiting for user decision."
    $ActionLine = "Review AI_HANDOFF.md and decide the next step or provide approval."
    $AfterLine = "Update AI_HANDOFF.md with your decision and set State and Waiting For accordingly."
}
elseif ($ExpectedWaiting.ContainsKey($State)) {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Resolve handoff mismatch. $State normally expects $($ExpectedWaiting[$State])."
    Write-Host "Commit: Blocked - handoff state is inconsistent."
    $ActionLine = "Resolve handoff mismatch. $State normally expects Waiting For: $($ExpectedWaiting[$State])."
    $AfterLine = "Correct Waiting For in AI_HANDOFF.md to match the expected actor for this state."
}
else {
    $knownStates = @("NEEDS_ANALYSIS", "NEEDS_INVESTIGATION", "PLAN_REQUIRED", "PLAN_READY_FOR_REVIEW",
        "READY_FOR_IMPLEMENTATION", "IMPLEMENTED", "READY_FOR_REVIEW", "REVIEW_DONE",
        "BLOCKED", "WAITING_FOR_USER")
    if ($knownStates -notcontains $State) {
        Write-Host "WARNING: Unrecognized state: $State."
        Write-Host ""
    }
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Inspect AI_HANDOFF.md and decide the next step."
    Write-Host "Commit: Blocked - state is unknown."
    $ActionLine = "Inspect AI_HANDOFF.md and decide the next step."
    $AfterLine = "Update AI_HANDOFF.md with the correct State and Waiting For."
}

if ($CopyPrompt) {
    if ($PromptText -ne "") {
        try {
            Set-Clipboard -Value $PromptText
            Write-Host "Prompt copied to clipboard."
        } catch {
            Write-Host "Could not copy to clipboard: $_"
        }
    } else {
        Write-Host "No prompt to copy."
    }
}

if ($PrepareFile) {
    $NextStepContent = Get-SectionContent -Lines $Lines -Heading "Next Recommended Step"

    $KeyContext = ""
    if ($State -eq "READY_FOR_REVIEW" -or $State -eq "PLAN_READY_FOR_REVIEW") {
        $ChangedFilesContent = Get-SectionContent -Lines $Lines -Heading "Changed Files"
        if ($ChangedFilesContent -ne "") {
            $KeyContext = "Changed Files:`n$ChangedFilesContent"
        }
    }

    $Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")

    $NtLines = [System.Collections.Generic.List[string]]::new()
    $NtLines.Add("# Next Turn Entry Brief")
    $NtLines.Add("Generated: $Timestamp")
    $NtLines.Add("Actor: $WaitingFor")
    $NtLines.Add("State: $State")
    $NtLines.Add("Current Task: $CurrentTask")
    $NtLines.Add("")
    $NtLines.Add("NOTE: This file is a convenience summary. Read AI_HANDOFF.md before acting.")
    $NtLines.Add("")
    $NtLines.Add("## Your Action This Turn")
    $NtLines.Add($ActionLine)
    $NtLines.Add("")
    $NtLines.Add("## Next Recommended Step (from AI_HANDOFF.md)")
    if ($NextStepContent -ne "") {
        $NtLines.Add($NextStepContent)
    } else {
        $NtLines.Add("(none - see AI_HANDOFF.md)")
    }
    if ($KeyContext -ne "") {
        $NtLines.Add("")
        $NtLines.Add("## Key Context")
        $NtLines.Add($KeyContext)
    }
    if ($AfterLine -ne "") {
        $NtLines.Add("")
        $NtLines.Add("## After You Finish")
        $NtLines.Add($AfterLine)
    }

    $NtContent = $NtLines -join "`n"
    $NtPath = Join-Path (Get-Location) "NEXT_TURN.md"
    Set-Content -Path $NtPath -Value $NtContent -Encoding utf8

    Write-Host ""
    Write-Host "NEXT_TURN.md written."
    Write-Host "Paste to $WaitingFor`: Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
    Write-Host ""
}

Write-Host ""
