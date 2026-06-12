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

# --- Role binding (State -> Role -> Tool) ---

function Get-RoleBinding {
    $binding = @{ Master = "Codex"; Reviewer = "Codex"; Implementer = "Claude Code" }
    $rolesFile = Join-Path (Get-Location) ".ai/roles/ROLE_ASSIGNMENT.md"
    if (Test-Path $rolesFile) {
        foreach ($line in (Get-Content -Path $rolesFile)) {
            if ($line -match '^\|\s*(Master|Reviewer|Implementer)\s*\|\s*(.+?)\s*\|') {
                $binding[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    return $binding
}

function Resolve-Actor {
    param([string]$Role, [hashtable]$Binding)
    if ($Role -eq "User") { return "User" }
    if ($Binding.ContainsKey($Role)) { return $Binding[$Role] }
    return $Role
}

$Binding = Get-RoleBinding

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

# Backward-compatible state aliases (pre-v0.13.0 tool-named dialogue states)
$StateAlias = @{
    "QUESTION_FOR_CODEX"  = "QUESTION_FOR_MASTER"
    "QUESTION_FOR_CLAUDE" = "QUESTION_FOR_IMPLEMENTER"
}
if ($StateAlias.ContainsKey($State)) { $State = $StateAlias[$State] }

Write-Host ""
Write-Host "=== Handoff Status ==="
Write-Host "State:        $State"
Write-Host "Waiting For:  $WaitingFor"
Write-Host "Current Task: $CurrentTask"
Write-Host "Roles:        Master=$($Binding.Master), Reviewer=$($Binding.Reviewer), Implementer=$($Binding.Implementer)"
Write-Host ""

# State -> expected Role
$ExpectedRole = @{
    "NEEDS_ANALYSIS"           = "Master"
    "NEEDS_INVESTIGATION"      = "Implementer"
    "PLAN_REQUIRED"            = "Implementer"
    "PLAN_READY_FOR_REVIEW"    = "Reviewer"
    "READY_FOR_IMPLEMENTATION" = "Implementer"
    "READY_FOR_REVIEW"         = "Reviewer"
    "REVIEW_DONE"              = "User"
    "QUESTION_FOR_MASTER"      = "Master"
    "QUESTION_FOR_IMPLEMENTER" = "Implementer"
    "RE_GATE_REQUESTED"        = "Master"
    "BLOCKED"                  = "User"
    "WAITING_FOR_USER"         = "User"
}

$Mismatch = $false
$expRole = ""
$expTool = ""
if ($ExpectedRole.ContainsKey($State)) {
    $expRole = $ExpectedRole[$State]
    $expTool = Resolve-Actor -Role $expRole -Binding $Binding
    # Accept either the role name or the resolved tool name in Waiting For (tolerates old tool-named handoffs)
    if ($WaitingFor -ne $expRole -and $WaitingFor -ne $expTool) {
        $Mismatch = $true
        Write-Host "WARNING: State $State normally expects Waiting For: $expRole ($expTool) but found: $WaitingFor."
        Write-Host ""
    }
}

if ($State -eq "READY_FOR_REVIEW") {
    $ChangedFilesLines = Get-SectionLines -Lines $Lines -Heading "Changed Files"
    $changedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $ChangedFilesLines) {
        $entry = $line.Trim()
        # Only markdown bullet lines ("- path") are files; skip headings/summary/notes.
        if ($entry -notmatch '^-\s+') { continue }
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

# Resolve the acting tool for the current state
$ActorRole = if ($ExpectedRole.ContainsKey($State)) { $ExpectedRole[$State] } else { "User" }
$ActorTool = Resolve-Actor -Role $ActorRole -Binding $Binding

$PromptText = ""
$ActionLine = ""
$AfterLine = ""

if ($Mismatch) {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Resolve handoff mismatch. State $State normally expects Waiting For: $expRole ($expTool), but found: $WaitingFor."
    Write-Host "Commit: Blocked - handoff state is inconsistent."
    Write-Host "Stop:   Protocol Repair - a correction, not a product decision."
    $ActionLine = "Resolve handoff mismatch. State $State normally expects Waiting For: $expRole ($expTool)."
    $AfterLine = "Correct Waiting For in AI_HANDOFF.md to match the expected role for this state."
}
elseif ($State -eq "NEEDS_ANALYSIS") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Master)"
    Write-Host "Action: Classify the task and set the correct State and Waiting For."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the Master role.`nClassify the task and set the correct state.`nWhen correctness depends on current repo behavior, local details, or verification constraints, default to a read-only Implementer investigation pass before finalizing.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Classify the task and set the correct State and Waiting For."
    $AfterLine = "Set State to the appropriate gate and Waiting For to the correct role. Update AI_HANDOFF.md."
}
elseif ($State -eq "NEEDS_INVESTIGATION") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Implementer)"
    Write-Host "Action: Investigate only. Do not modify source files."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    $PromptText = "Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the Implementer role. Investigate only - do not modify source files.`nReport findings in AI_HANDOFF.md. Set State: READY_FOR_REVIEW.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Investigate only. Do not modify source files."
    $AfterLine = "Set State: READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md."
}
elseif ($State -eq "PLAN_REQUIRED") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Implementer)"
    Write-Host "Action: Write a plan only. Do not modify source files."
    Write-Host "Commit: Blocked - no approved implementation yet."
    Write-Host ""
    $PromptText = "Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the Implementer role. Write a plan only - do not modify source files.`nSet State: PLAN_READY_FOR_REVIEW when done.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Write a plan only. Do not modify source files."
    $AfterLine = "Set State: PLAN_READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md."
}
elseif ($State -eq "PLAN_READY_FOR_REVIEW") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Reviewer)"
    Write-Host "Action: Review the plan. Approve or request changes before implementation begins."
    Write-Host "Commit: Blocked - plan not yet approved."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read AI_HANDOFF.md. You hold the Reviewer role. Review the plan.`nSet State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Review the plan. Approve or request changes before implementation begins."
    $AfterLine = "Set State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED. Set Waiting For accordingly. Update AI_HANDOFF.md."
}
elseif ($State -eq "READY_FOR_IMPLEMENTATION") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Implementer)"
    Write-Host "Action: Implement the approved scope. Do not modify unrelated files."
    Write-Host "Commit: Blocked - waiting for Reviewer review after implementation."
    Write-Host ""
    $PromptText = "Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the Implementer role. Continue the protocol from the current state.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Implement the approved scope. Do not modify unrelated files."
    $AfterLine = "Set State: READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md."
}
elseif ($State -eq "IMPLEMENTED") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Review the work. Commit if satisfied, or ask the Reviewer to review first."
    Write-Host "Commit: ALLOWED - no Reviewer review was required for this task."
    Write-Host "Stop:   User Release Authorization - approve the release; running the commit is an Operator Manual Action."
    $ActionLine = "Review the work. Commit if satisfied, or ask the Reviewer to review first."
    $AfterLine = "No handoff update required. Commit only the files listed under Changed Files."
}
elseif ($State -eq "READY_FOR_REVIEW") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Reviewer)"
    Write-Host "Action: Review Changed Files. Run git status and git diff before approving."
    Write-Host "Commit: Blocked - waiting for Reviewer approval."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read AI_HANDOFF.md and review Changed Files. You hold the Reviewer role.`nRun git status and git diff before approving. Check Changed Files match.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Review Changed Files. Run git status and git diff before approving."
    $AfterLine = "Set State: REVIEW_DONE and Waiting For: User, or READY_FOR_IMPLEMENTATION if changes are needed. Update AI_HANDOFF.md."
}
elseif ($State -eq "REVIEW_DONE") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Release authorization: the Reviewer attested technical readiness. Approve and run the commit/push yourself. Do not commit AI_HANDOFF.md."
    Write-Host "Commit: ALLOWED - the Reviewer attested technical readiness; the remaining step is your release authorization. Commit only the files listed under Changed Files."
    Write-Host "Stop:   User Release Authorization - approval only; technical verification was attested by the Reviewer."
    $ActionLine = "Release authorization: the Reviewer attested technical readiness. Approve and run the commit/push yourself. Do not commit AI_HANDOFF.md."
    $AfterLine = "No handoff update required. Commit only the files listed under Changed Files."
}
elseif ($State -eq "QUESTION_FOR_MASTER") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Master)"
    Write-Host "Action: Answer the Implementer's question under Dialogue / Open Questions, then return the working state."
    Write-Host "Commit: Blocked - dialogue in progress."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read AI_HANDOFF.md and the Dialogue / Open Questions section. You hold the Master role.`nAnswer the Implementer's scoped question, then set State back to the Implementer's working state and Waiting For: Implementer.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Answer the Implementer's question under Dialogue / Open Questions, then return the working state."
    $AfterLine = "Set State back to the Implementer's working state and Waiting For: Implementer. Update AI_HANDOFF.md."
}
elseif ($State -eq "QUESTION_FOR_IMPLEMENTER") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Implementer)"
    Write-Host "Action: Answer the Master's question read-only under Dialogue / Open Questions. Do not modify source files."
    Write-Host "Commit: Blocked - dialogue in progress."
    Write-Host ""
    $PromptText = "Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the Implementer role. Answer the Master's scoped question under Dialogue / Open Questions - read-only, no source edits.`nThen set State back to the value the Master specified and Waiting For: Master.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Answer the Master's question read-only under Dialogue / Open Questions. Do not modify source files."
    $AfterLine = "Set State back to the value the Master specified and Waiting For: Master. Update AI_HANDOFF.md."
}
elseif ($State -eq "RE_GATE_REQUESTED") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  $ActorTool (Master)"
    Write-Host "Action: Re-route the task. The Implementer found it riskier/larger than scoped."
    Write-Host "Commit: Blocked - task is being re-gated."
    Write-Host ""
    $PromptText = "Use the codex-claude-handoff skill. Read AI_HANDOFF.md, the Dialogue / Open Questions section, and Open Issues. You hold the Master role.`nRe-route the task through the Decision Router (usually PLAN_REQUIRED or NEEDS_INVESTIGATION), or set a revised READY_FOR_IMPLEMENTATION scope.`nCurrent task: $CurrentTask"
    Write-Host "=== Prompt ==="
    Write-Host $PromptText
    $ActionLine = "Re-route the task. The Implementer found it riskier/larger than scoped."
    $AfterLine = "Re-classify through the Decision Router and set State/Waiting For accordingly. Update AI_HANDOFF.md."
}
elseif ($State -eq "BLOCKED") {
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md."
    Write-Host "Commit: Blocked - work is blocked."
    Write-Host "Stop:   User Decision - resolve the documented blocker."
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
    Write-Host "Stop:   User Decision - product, scope, or risk decision required."
    $ActionLine = "Review AI_HANDOFF.md and decide the next step or provide approval."
    $AfterLine = "Update AI_HANDOFF.md with your decision and set State and Waiting For accordingly."
}
else {
    Write-Host "WARNING: Unrecognized state: $State."
    Write-Host ""
    Write-Host "=== Next Action ==="
    Write-Host "Actor:  User"
    Write-Host "Action: Inspect AI_HANDOFF.md and decide the next step."
    Write-Host "Commit: Blocked - state is unknown."
    Write-Host "Stop:   Protocol Repair (unrecognized state) - a correction, not a product decision."
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
    $NtLines.Add("Actor: $ActorTool ($ActorRole)")
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
    Write-Host "Paste to $ActorTool`: Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
    Write-Host ""
}

Write-Host ""
