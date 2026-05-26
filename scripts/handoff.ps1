param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$Request,
    [switch]$Clip,
    [switch]$CopyPrompt  # backward-compatible alias for -Clip
)

if ($CopyPrompt) { $Clip = $true }

$HandoffFile = Join-Path (Get-Location) "AI_HANDOFF.md"

if (-not (Test-Path $HandoffFile)) {
    Write-Host "No AI_HANDOFF.md found. Run from your project root."
    exit 1
}

$Lines = Get-Content -Path $HandoffFile

# --- Shared parser ---

function Get-SectionLines {
    param([string[]]$Lines, [string]$Heading)
    $inSection = $false
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line.TrimEnd() -eq "## $Heading") { $inSection = $true; continue }
        if ($inSection) {
            if ($line -match "^##\s") { break }
            $result.Add($line)
        }
    }
    return $result.ToArray()
}

function Get-SectionContent {
    param([string[]]$Lines, [string]$Heading)
    return ((Get-SectionLines -Lines $Lines -Heading $Heading) -join "`n").Trim()
}

$StatusLines = Get-SectionLines -Lines $Lines -Heading "Status"
$State       = "(unknown)"
$WaitingFor  = "(unknown)"
$CurrentTask = "(unknown)"

foreach ($line in $StatusLines) {
    if ($line -match "^- State:\s*(.+)")        { $State       = $Matches[1].Trim() }
    if ($line -match "^- Waiting For:\s*(.+)")  { $WaitingFor  = $Matches[1].Trim() }
    if ($line -match "^- Current Task:\s*(.+)") { $CurrentTask = $Matches[1].Trim() }
}

$CommitStatus = switch ($State) {
    "REVIEW_DONE" { "ALLOWED - Codex approved. Commit only the files listed under Changed Files." }
    "IMPLEMENTED" { "ALLOWED - no Codex review required. Review the work before committing." }
    default       { "Blocked - $State requires action before committing." }
}

# --- Action map for next command ---

$ActionMap = @{
    "NEEDS_ANALYSIS"           = @{
        Actor  = "Codex"
        Action = "Classify the task and set the correct State and Waiting For."
        After  = "Set State to the appropriate gate and Waiting For to the correct actor. Update AI_HANDOFF.md."
    }
    "NEEDS_INVESTIGATION"      = @{
        Actor  = "Claude Code"
        Action = "Investigate only. Do not modify source files."
        After  = "Set State: READY_FOR_REVIEW and Waiting For: Codex. Update AI_HANDOFF.md."
    }
    "PLAN_REQUIRED"            = @{
        Actor  = "Claude Code"
        Action = "Write a plan only. Do not modify source files."
        After  = "Set State: PLAN_READY_FOR_REVIEW and Waiting For: Codex. Update AI_HANDOFF.md."
    }
    "PLAN_READY_FOR_REVIEW"    = @{
        Actor  = "Codex"
        Action = "Review the plan. Approve or request changes before implementation begins."
        After  = "Set State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED. Set Waiting For accordingly. Update AI_HANDOFF.md."
    }
    "READY_FOR_IMPLEMENTATION" = @{
        Actor  = "Claude Code"
        Action = "Implement the approved scope. Do not modify unrelated files."
        After  = "Set State: READY_FOR_REVIEW and Waiting For: Codex. Update AI_HANDOFF.md."
    }
    "IMPLEMENTED"              = @{
        Actor  = "User"
        Action = "Review the work. Commit if satisfied, or ask Codex to review first."
        After  = "No handoff update required. Commit only the files listed under Changed Files."
    }
    "READY_FOR_REVIEW"         = @{
        Actor  = "Codex"
        Action = "Review Changed Files. Run git status and git diff before approving."
        After  = "Set State: REVIEW_DONE and Waiting For: User, or READY_FOR_IMPLEMENTATION if changes are needed. Update AI_HANDOFF.md."
    }
    "REVIEW_DONE"              = @{
        Actor  = "User"
        Action = "Commit and push approved changes. Do not commit AI_HANDOFF.md."
        After  = "No handoff update required. Commit only the files listed under Changed Files."
    }
    "BLOCKED"                  = @{
        Actor  = "User"
        Action = "Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md."
        After  = "Resolve the blocker, update AI_HANDOFF.md, and set State and Waiting For appropriately."
    }
    "WAITING_FOR_USER"         = @{
        Actor  = "User"
        Action = "Review AI_HANDOFF.md and decide the next step or provide approval."
        After  = "Update AI_HANDOFF.md with your decision and set State and Waiting For accordingly."
    }
}

# --- Commands ---

function Invoke-Status {
    Write-Host ""
    Write-Host "State:        $State"
    Write-Host "Waiting For:  $WaitingFor"
    Write-Host "Task:         $CurrentTask"
    Write-Host "Commit:       $CommitStatus"
    Write-Host ""
}

function Invoke-Next {
    $entry = $ActionMap[$State]
    if (-not $entry) {
        Write-Host "Unrecognized state: $State. Inspect AI_HANDOFF.md manually."
        return
    }

    $actor      = $entry.Actor
    $actionLine = $entry.Action
    $afterLine  = $entry.After
    $nextStep   = Get-SectionContent -Lines $Lines -Heading "Next Recommended Step"

    $keyContext = ""
    if ($State -eq "READY_FOR_REVIEW" -or $State -eq "PLAN_READY_FOR_REVIEW") {
        $changedContent = Get-SectionContent -Lines $Lines -Heading "Changed Files"
        if ($changedContent -ne "") { $keyContext = "Changed Files:`n$changedContent" }
    }

    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $ntLines   = [System.Collections.Generic.List[string]]::new()
    $ntLines.Add("# Next Turn Entry Brief")
    $ntLines.Add("Generated: $timestamp")
    $ntLines.Add("Actor: $actor")
    $ntLines.Add("State: $State")
    $ntLines.Add("Current Task: $CurrentTask")
    $ntLines.Add("")
    $ntLines.Add("NOTE: This file is a convenience summary. Read AI_HANDOFF.md before acting.")
    $ntLines.Add("")
    $ntLines.Add("## Your Action This Turn")
    $ntLines.Add($actionLine)
    $ntLines.Add("")
    $ntLines.Add("## Next Recommended Step (from AI_HANDOFF.md)")
    if ($nextStep -ne "") { $ntLines.Add($nextStep) } else { $ntLines.Add("(none - see AI_HANDOFF.md)") }
    if ($keyContext -ne "") { $ntLines.Add(""); $ntLines.Add("## Key Context"); $ntLines.Add($keyContext) }
    if ($afterLine -ne "") { $ntLines.Add(""); $ntLines.Add("## After You Finish"); $ntLines.Add($afterLine) }

    $ntPath = Join-Path (Get-Location) "NEXT_TURN.md"
    Set-Content -Path $ntPath -Value ($ntLines -join "`n") -Encoding utf8

    $pasteInstruction = "Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."

    Write-Host ""
    Write-Host "NEXT_TURN.md written."
    Write-Host "Open:  $actor"
    Write-Host "Paste: $pasteInstruction"
    Write-Host ""

    if ($Clip) {
        try {
            Set-Clipboard -Value $pasteInstruction
            Write-Host "Copied to clipboard. Paste with Ctrl+V."
        } catch {
            Write-Host "Could not copy to clipboard: $_"
            Write-Host "Copy the Paste line manually."
        }
    } else {
        Write-Host "Copy the Paste line manually."
    }
    Write-Host ""
}

function Invoke-Start {
    param([string]$Request)

    if (-not $Request) {
        Write-Host 'Usage: handoff.ps1 start "<natural user request>"'
        return
    }

    $requestPath = Join-Path (Get-Location) "USER_REQUEST.md"
    Set-Content -Path $requestPath -Value $Request -Encoding utf8
    Write-Host ""
    Write-Host "USER_REQUEST.md written."

    # Safety fallback: warn if not gitignored (pre-v0.10.0 installs)
    # Line-by-line check to avoid false positives from CRLF line endings on Windows.
    $gitignorePath = Join-Path (Get-Location) ".gitignore"
    if (Test-Path $gitignorePath) {
        $giLines = Get-Content -Path $gitignorePath
        $isIgnored = $false
        foreach ($giLine in $giLines) {
            if ($giLine.Trim() -eq "USER_REQUEST.md") { $isIgnored = $true; break }
        }
        if (-not $isIgnored) {
            Write-Host "WARNING: USER_REQUEST.md is not in .gitignore. Add it to avoid committing user requests."
        }
    }

    $codexPrompt = "Use the codex-claude-handoff skill.`nRead USER_REQUEST.md for the user's request.`nRead AI_HANDOFF.md for current handoff state.`nRead .agents/skills/codex-claude-handoff/SKILL.md as local protocol instructions.`nRoute the request through the Codex Decision Router.`nIf the request is advisory-only, answer directly and do not update AI_HANDOFF.md.`nUpdate AI_HANDOFF.md only if the protocol requires investigation, planning, implementation, user decision tracking, or review."

    Write-Host ""
    Write-Host "=== Codex Entry Prompt ==="
    Write-Host $codexPrompt
    Write-Host ""

    if ($Clip) {
        try {
            Set-Clipboard -Value $codexPrompt
            Write-Host "Prompt copied to clipboard."
        } catch {
            Write-Host "Could not copy to clipboard: $_"
        }
    }
}

function Invoke-CommitCheck {
    Write-Host ""

    if ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") {
        $changedFilesLines = Get-SectionLines -Lines $Lines -Heading "Changed Files"
        $commitFiles = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $changedFilesLines) {
            $entry = $line.Trim() -replace '^-\s+', '' -replace '`', ''
            if ($entry -match '^(.+?)\s+-\s+.+$') { $entry = $Matches[1].Trim() }
            $entry = $entry.Trim()
            if ($entry -ne "" -and $entry -ne "None yet" -and $entry -ne "AI_HANDOFF.md") {
                $commitFiles.Add($entry)
            }
        }

        Write-Host "Commit: ALLOWED - Codex approved."
        Write-Host ""
        Write-Host "Files to commit:"
        foreach ($f in $commitFiles) { Write-Host "  $f" }
        Write-Host ""
        $fileArgs = $commitFiles -join " "
        Write-Host "Suggested commands (reference only - run these yourself):"
        Write-Host "  git add $fileArgs"
        Write-Host '  git commit -m "<your commit message>"'
        Write-Host "  git push"
        Write-Host ""
        Write-Host "These commands are shown for reference only. Run them yourself after confirming the file list."
    }
    else {
        Write-Host "Commit: Not yet allowed."
        Write-Host "State: $State - Waiting For: $WaitingFor"
        $reason = switch ($State) {
            "READY_FOR_REVIEW"         { "Waiting for Codex to review." }
            "PLAN_READY_FOR_REVIEW"    { "Waiting for Codex to review the plan." }
            "READY_FOR_IMPLEMENTATION" { "Waiting for Claude Code to implement." }
            "PLAN_REQUIRED"            { "Waiting for Claude Code to write a plan." }
            "NEEDS_INVESTIGATION"      { "Waiting for Claude Code to investigate." }
            "NEEDS_ANALYSIS"           { "Waiting for Codex to analyze." }
            "BLOCKED"                  { "Work is blocked. Resolve the issue in AI_HANDOFF.md." }
            "WAITING_FOR_USER"         { "User decision or approval required. See AI_HANDOFF.md." }
            default                    { "Inspect AI_HANDOFF.md for details." }
        }
        Write-Host "Reason: $reason"
    }

    Write-Host ""
}

function Invoke-Menu {
    Write-Host ""
    Write-Host "State:  $State"
    Write-Host "Actor:  $WaitingFor"
    Write-Host "Task:   $CurrentTask"
    Write-Host ""
    Write-Host "This tool does not run Codex or Claude automatically. It only prepares the next instruction."
    Write-Host ""
    Write-Host "1. Start new request"
    Write-Host "2. Continue next turn"
    Write-Host "3. Show status"
    Write-Host "4. Check commit"
    Write-Host "5. Exit"
    Write-Host ""
    $choice = Read-Host "Select"

    switch ($choice.Trim()) {
        "1" {
            $userRequest = Read-Host "Enter your request"
            Invoke-Start -Request $userRequest
        }
        "2" { Invoke-Next }
        "3" { Invoke-Status }
        "4" { Invoke-CommitCheck }
        "5" { }
        default {
            Write-Host ""
            Write-Host "Invalid selection: $choice"
            Write-Host ""
        }
    }
}

# --- Dispatch ---

switch ($Command) {
    "status"       { Invoke-Status }
    "next"         { Invoke-Next }
    "start"        { Invoke-Start -Request $Request }
    "commit-check" { Invoke-CommitCheck }
    default {
        if ([string]::IsNullOrWhiteSpace($Command)) {
            Invoke-Menu
        } else {
            Write-Host ""
            Write-Host "Usage: handoff.ps1 <command> [options]"
            Write-Host ""
            Write-Host "Commands:"
            Write-Host "  status                    Show current handoff state and commit status."
            Write-Host "  next [-Clip]              Generate NEXT_TURN.md and print the paste instruction."
            Write-Host '  start "<request>" [-Clip]  Save request and print a Codex entry prompt.'
            Write-Host "  commit-check              Show whether a commit is allowed and what to commit."
            Write-Host ""
        }
    }
}
