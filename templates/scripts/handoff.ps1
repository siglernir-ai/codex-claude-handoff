param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$Request,
    [switch]$Clip,
    [switch]$CopyPrompt,  # backward-compatible alias for -Clip
    [decimal]$BudgetUsd = 2
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
    $skillAdapter = Join-Path (Get-Location) ".agents/skills/codex-claude-handoff/SKILL.md"
    if (Test-Path $skillAdapter) {
        Write-Host "Protocol:     installed (canonical: .ai/skills/codex-claude-handoff/; Codex adapter: .agents/skills/codex-claude-handoff/SKILL.md)"
    }
    Write-Host ""
}

function Invoke-Next {
    param([bool]$MenuMode = $false, [bool]$Silent = $false)

    $entry = $ActionMap[$State]
    if (-not $entry) {
        Write-Host "Unrecognized state: $State. Inspect AI_HANDOFF.md manually."
        return
    }

    # Use $WaitingFor as the actor (source of truth from AI_HANDOFF.md)
    # Fall back to ActionMap entry only when WaitingFor is unparsed
    $actor      = if ($WaitingFor -ne "(unknown)") { $WaitingFor } else { $entry.Actor }
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

    if (-not $Silent) {
        Write-Host ""
        Write-Host "NEXT_TURN.md written."

        if ($actor -eq "User") {
            Write-Host "Next actor: User"
            Write-Host "No tool handoff needed."
            Write-Host "Review the status, start a new request, or run commit-check if you are about to commit."
        } else {
            Write-Host "Open:  $actor"
            Write-Host "Paste: $pasteInstruction"
            Write-Host ""

            if ($Clip -or $MenuMode) {
                try {
                    Set-Clipboard -Value $pasteInstruction
                    if ($MenuMode) {
                        Write-Host "Copied to clipboard. Open $actor and press Ctrl+V."
                    } else {
                        Write-Host "Copied to clipboard. Paste with Ctrl+V."
                    }
                } catch {
                    Write-Host "Could not copy to clipboard: $_"
                    Write-Host "Copy the Paste line manually."
                }
            } else {
                Write-Host "Copy the Paste line manually."
            }
        }
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

    $codexPrompt = "Use the codex-claude-handoff skill.`nRead USER_REQUEST.md for the user's request.`nRead AI_HANDOFF.md for current handoff state.`nRead .agents/skills/codex-claude-handoff/SKILL.md as local protocol instructions.`nRoute the request through the Codex Decision Router.`nWhen correctness depends on current repo behavior, local implementation details, or verification constraints, default to a read-only Claude investigation pass (NEEDS_INVESTIGATION) before finalizing the task.`nIf the request is advisory-only, answer directly and do not update AI_HANDOFF.md.`nUpdate AI_HANDOFF.md only if the protocol requires investigation, planning, implementation, user decision tracking, or review."

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
        # Parse handoff Changed Files (exclude AI_HANDOFF.md)
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

        # Also extract file guidance from Next Recommended Step (commit-scope lines).
        # Track raw mentions (including AI_HANDOFF.md) so stale guidance is not silently dropped.
        $nextStepLines   = Get-SectionLines -Lines $Lines -Heading "Next Recommended Step"
        $nsRawMentioned  = [System.Collections.Generic.List[string]]::new()
        foreach ($nsLine in $nextStepLines) {
            if ($nsLine -imatch 'commit only|AI_HANDOFF\.md only') {
                $tokens = [regex]::Matches($nsLine, '[\w./\\-]+\.\w+')
                foreach ($token in $tokens) {
                    $f = $token.Value.Trim()
                    if ($f -ne "") { $nsRawMentioned.Add($f) }
                }
            }
        }
        # Merge real (non-handoff) NS files into commitFiles
        foreach ($f in $nsRawMentioned) {
            if ($f -ne "AI_HANDOFF.md" -and -not $commitFiles.Contains($f)) { $commitFiles.Add($f) }
        }
        # Stale NS indicator: NS has commit-scope guidance but mentions only AI_HANDOFF.md
        $nsHasStaleGuidance = ($nsRawMentioned.Count -gt 0) -and
            (($nsRawMentioned | Where-Object { $_ -ne "AI_HANDOFF.md" }).Count -eq 0)

        # Get actual tracked changed files from git status --short
        $actualTracked = [System.Collections.Generic.List[string]]::new()
        try {
            $gitLines = & git status --short 2>$null
            foreach ($gitLine in $gitLines) {
                if ($gitLine.Length -lt 3) { continue }
                if ($gitLine.Substring(0, 2) -eq "??") { continue }  # skip untracked
                $filePart = $gitLine.Substring(3).Trim()
                if ($filePart -match ' -> (.+)$') { $filePart = $Matches[1].Trim() }  # renames
                if ($filePart -ne "" -and $filePart -ne "AI_HANDOFF.md") {
                    $actualTracked.Add($filePart)
                }
            }
        } catch {
            # git unavailable - skip mismatch check
        }

        # Clean tree: no tracked source changes to commit
        if ($actualTracked.Count -eq 0) {
            Write-Host "Commit: No tracked changes to commit."
            Write-Host "Working tree is clean."
            Write-Host ""
            return
        }

        # Compare sets to detect mismatch
        $mismatch = $false
        if ($actualTracked.Count -gt 0) {
            $handoffSet = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]$commitFiles, [System.StringComparer]::OrdinalIgnoreCase)
            $actualSet  = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]$actualTracked, [System.StringComparer]::OrdinalIgnoreCase)
            $mismatch = -not $handoffSet.SetEquals($actualSet)
            # Also warn if NS explicitly says commit only AI_HANDOFF.md while real files changed
            if (-not $mismatch -and $nsHasStaleGuidance) { $mismatch = $true }
        }

        Write-Host "Commit: ALLOWED - Codex approved."
        Write-Host ""

        if ($mismatch) {
            Write-Host "Handoff suggested files:"
            if ($commitFiles.Count -eq 0 -and $nsHasStaleGuidance) {
                Write-Host "  (none - Next Recommended Step references only AI_HANDOFF.md)"
            } elseif ($commitFiles.Count -eq 0) {
                Write-Host "  (none - handoff only lists AI_HANDOFF.md)"
            } else {
                foreach ($f in $commitFiles) { Write-Host "  $f" }
            }
            Write-Host ""
            Write-Host "Actual changed tracked files:"
            foreach ($f in $actualTracked) { Write-Host "  $f" }
            Write-Host ""
            Write-Host "WARNING:"
            Write-Host "The handoff file list does not match git status."
            Write-Host "Confirm the correct commit scope manually before committing."
        } else {
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
    Write-Host "Use this menu for local workflow actions."
    Write-Host "For questions, planning, or decisions, continue chatting with Codex."
    Write-Host ""
    Write-Host "1. Start new request              - begin a new task from natural language"
    Write-Host "2. Continue next turn             - prepare prompt for Codex/Claude if needed"
    Write-Host "3. Show status                    - show current state and next actor"
    Write-Host "4. Check commit                   - verify whether commit is allowed"
    Write-Host "5. Run next assisted Claude turn  - only when Waiting For: Claude Code"
    Write-Host "6. Exit"
    Write-Host ""
    $choice = Read-Host "Select"

    switch ($choice.Trim()) {
        "1" {
            $userRequest = Read-Host "Enter your request"
            Invoke-Start -Request $userRequest
        }
        "2" { Invoke-Next -MenuMode $true }
        "3" { Invoke-Status }
        "4" { Invoke-CommitCheck }
        "5" { Invoke-RunNext }
        "6" { }
        default {
            Write-Host ""
            Write-Host "Invalid selection: $choice"
            Write-Host ""
        }
    }
}

function Invoke-RunNext {
    $eligibleStates = @("READY_FOR_IMPLEMENTATION")

    # Dual eligibility check - actor first, then state
    if ($WaitingFor -ne "Claude Code") {
        Write-Host ""
        Write-Host "run-next: blocked."
        Write-Host "State:       $State"
        Write-Host "Waiting For: $WaitingFor"
        if ($WaitingFor -eq "Codex") {
            Write-Host "Reason:      This turn is for Codex. run-next cannot automate Codex turns."
            Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into ChatGPT."
        } else {
            Write-Host "Reason:      This turn requires user action."
            Write-Host "Next step:   See AI_HANDOFF.md for details."
        }
        Write-Host ""
        exit 1
    }

    if ($eligibleStates -notcontains $State) {
        Write-Host ""
        Write-Host "run-next: blocked."
        Write-Host "State:       $State"
        Write-Host "Waiting For: $WaitingFor"
        if ($State -eq "NEEDS_INVESTIGATION" -or $State -eq "PLAN_REQUIRED") {
            Write-Host "Reason:      run-next does not automate investigation or planning turns in this version."
            Write-Host "             The Claude Code CLI cannot safely restrict file edits to AI_HANDOFF.md only in these states."
        } else {
            Write-Host "Reason:      State '$State' is not eligible for run-next in this version."
        }
        Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into Claude Code."
        Write-Host ""
        exit 1
    }

    # Guard: block if tracked working tree changes exist
    $trackedDirtyFiles = [System.Collections.Generic.List[string]]::new()
    $gitCheckOk = $false
    try {
        $gitStatusLines = & git status --short 2>$null
        if ($LASTEXITCODE -eq 0) {
            $gitCheckOk = $true
            foreach ($gitLine in $gitStatusLines) {
                if ($null -eq $gitLine -or $gitLine.Length -lt 3) { continue }
                if ($gitLine.Substring(0, 2) -eq "??") { continue }  # skip untracked
                $filePart = $gitLine.Substring(3).Trim()
                if ($filePart -ne "") { $trackedDirtyFiles.Add($filePart) }
            }
        }
    } catch { }

    if (-not $gitCheckOk) {
        Write-Host ""
        Write-Host "run-next: blocked."
        Write-Host "Could not determine Git working tree state."
        Write-Host "Ensure you are in a Git repository and git is available, then try again."
        Write-Host ""
        exit 1
    }

    if ($trackedDirtyFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "run-next: blocked."
        Write-Host "Working tree is not clean."
        Write-Host ""
        Write-Host "Tracked changed files:"
        foreach ($f in $trackedDirtyFiles) { Write-Host "  $f" }
        Write-Host ""
        Write-Host "Commit, stash, or revert existing changes before running run-next."
        Write-Host ""
        exit 1
    }

    Write-Host ""
    Write-Host "Preparing assisted Claude Code turn..."
    Write-Host ""
    Write-Host "State:        $State"
    Write-Host "Actor:        Claude Code"
    Write-Host "Permission:   acceptEdits  (Bash explicitly disallowed)"
    Write-Host "Budget limit: `$$BudgetUsd"
    Write-Host ""
    Write-Host "Note: Tests and lint cannot run during this turn (Bash is blocked). Run them manually after."
    Write-Host ""

    # Refresh NEXT_TURN.md (silent - suppress manual paste/copy guidance)
    Write-Host "Refreshing NEXT_TURN.md..."
    try {
        Invoke-Next -Silent $true
    } catch {
        Write-Host "Failed to refresh NEXT_TURN.md: $_"
        Write-Host "Aborting."
        exit 4
    }
    $ntPath = Join-Path (Get-Location) "NEXT_TURN.md"
    if (-not (Test-Path $ntPath)) {
        Write-Host "NEXT_TURN.md was not created. Aborting."
        exit 4
    }

    # Preflight: confirm Claude Code is available
    Write-Host "Checking Claude Code availability..."
    $null = npx --yes @anthropic-ai/claude-code --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Claude Code is not available. Check network or install globally: npm install -g @anthropic-ai/claude-code"
        exit 3
    }

    $prompt = "Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."

    Write-Host ""
    Write-Host "Command: npx --yes @anthropic-ai/claude-code -p `"<prompt>`" --permission-mode acceptEdits --disallowed-tools `"Bash`" --max-budget-usd $BudgetUsd --no-session-persistence"
    Write-Host ""
    Write-Host "WARNING: This state allows source file edits. Claude Code may modify approved source files."
    Write-Host "         This tool does not commit, push, or deploy automatically."
    Write-Host ""
    $confirm = Read-Host 'Type "yes" to proceed, or press Enter to cancel'
    if ($confirm.Trim() -ne "yes") {
        Write-Host "Cancelled."
        exit 2
    }

    Write-Host ""
    Write-Host "Running Claude Code assisted turn..."
    Write-Host ""

    npx --yes @anthropic-ai/claude-code -p $prompt `
        --permission-mode acceptEdits `
        --disallowed-tools "Bash" `
        --max-budget-usd $BudgetUsd `
        --no-session-persistence `
        --output-format text

    $claudeExit = $LASTEXITCODE

    Write-Host ""
    if ($claudeExit -eq 0) {
        Write-Host "Claude Code turn complete (exit 0)."
        Write-Host "Tests and lint were not run - execute them manually before committing."
        Write-Host ""

        # Re-read AI_HANDOFF.md to get post-Claude state (pre-run values are stale)
        $script:Lines       = Get-Content -Path $HandoffFile
        $freshStatusLines   = Get-SectionLines -Lines $script:Lines -Heading "Status"
        $script:State       = "(unknown)"
        $script:WaitingFor  = "(unknown)"
        $script:CurrentTask = "(unknown)"
        foreach ($line in $freshStatusLines) {
            if ($line -match "^- State:\s*(.+)")        { $script:State       = $Matches[1].Trim() }
            if ($line -match "^- Waiting For:\s*(.+)")  { $script:WaitingFor  = $Matches[1].Trim() }
            if ($line -match "^- Current Task:\s*(.+)") { $script:CurrentTask = $Matches[1].Trim() }
        }

        # Refresh NEXT_TURN.md with the updated state
        try { Invoke-Next -Silent $true } catch { Write-Host "Could not refresh NEXT_TURN.md: $_" }

        if ($script:State -eq "READY_FOR_REVIEW" -and $script:WaitingFor -eq "Codex") {
            $pasteInstruction = "Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
            try { Set-Clipboard -Value $pasteInstruction } catch { Write-Host "Could not copy to clipboard: $_" }
            Write-Host "NEXT_TURN.md updated for Codex review."
            Write-Host ""
            Write-Host "Open Codex and press Ctrl+V."
            Write-Host "Do not commit before Codex review."
        } else {
            Write-Host "State is now: $($script:State) (Waiting For: $($script:WaitingFor))"
            Write-Host "Run 'handoff.ps1 next' to prepare the next turn."
        }
    } else {
        Write-Host "Claude Code exited with error (code: $claudeExit)."
        Write-Host "AI_HANDOFF.md may be incomplete. Verify manually."
        exit 5
    }
    Write-Host ""
}

# --- Dispatch ---

switch ($Command) {
    "status"       { Invoke-Status }
    "next"         { Invoke-Next }
    "start"        { Invoke-Start -Request $Request }
    "commit-check" { Invoke-CommitCheck }
    "run-next"     { Invoke-RunNext }
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
            Write-Host "  run-next [-BudgetUsd N]   Run one Claude Code assisted turn (READY_FOR_IMPLEMENTATION only)."
            Write-Host ""
        }
    }
}
