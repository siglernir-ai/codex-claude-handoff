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
$State       = "(unknown)"
$WaitingFor  = "(unknown)"
$CurrentTask = "(unknown)"

foreach ($line in $StatusLines) {
    if ($line -match "^- State:\s*(.+)")        { $State       = $Matches[1].Trim() }
    if ($line -match "^- Waiting For:\s*(.+)")  { $WaitingFor  = $Matches[1].Trim() }
    if ($line -match "^- Current Task:\s*(.+)") { $CurrentTask = $Matches[1].Trim() }
}

# Backward-compatible state aliases (pre-v0.13.0 tool-named dialogue states)
$StateAlias = @{
    "QUESTION_FOR_CODEX"  = "QUESTION_FOR_MASTER"
    "QUESTION_FOR_CLAUDE" = "QUESTION_FOR_IMPLEMENTER"
}
if ($StateAlias.ContainsKey($State)) { $State = $StateAlias[$State] }

$CommitStatus = switch ($State) {
    "REVIEW_DONE" { "ALLOWED - the Reviewer approved. Commit only the files listed under Changed Files." }
    "IMPLEMENTED" { "ALLOWED - no Reviewer review required. Review the work before committing." }
    default       { "Blocked - $State requires action before committing." }
}

# --- Action map for next command (keyed by State; Actor is resolved from Role) ---

$ActionMap = @{
    "NEEDS_ANALYSIS"           = @{
        Role   = "Master"
        Action = "Classify the task and set the correct State and Waiting For."
        After  = "Set State to the appropriate gate and Waiting For to the correct role. Update AI_HANDOFF.md."
    }
    "NEEDS_INVESTIGATION"      = @{
        Role   = "Implementer"
        Action = "Investigate only. Do not modify source files."
        After  = "Set State: READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md."
    }
    "PLAN_REQUIRED"            = @{
        Role   = "Implementer"
        Action = "Write a plan only. Do not modify source files."
        After  = "Set State: PLAN_READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md."
    }
    "PLAN_READY_FOR_REVIEW"    = @{
        Role   = "Reviewer"
        Action = "Review the plan. Approve or request changes before implementation begins."
        After  = "Set State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED. Set Waiting For accordingly. Update AI_HANDOFF.md."
    }
    "READY_FOR_IMPLEMENTATION" = @{
        Role   = "Implementer"
        Action = "Implement the approved scope. Do not modify unrelated files."
        After  = "Set State: READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md."
    }
    "IMPLEMENTED"              = @{
        Role   = "User"
        Action = "Review the work. Commit if satisfied, or ask the Reviewer to review first."
        After  = "No handoff update required. Commit only the files listed under Changed Files."
    }
    "READY_FOR_REVIEW"         = @{
        Role   = "Reviewer"
        Action = "Review Changed Files. Run git status and git diff before approving."
        After  = "Set State: REVIEW_DONE and Waiting For: User, or READY_FOR_IMPLEMENTATION if changes are needed. Update AI_HANDOFF.md."
    }
    "REVIEW_DONE"              = @{
        Role   = "User"
        Action = "Commit and push approved changes. Do not commit AI_HANDOFF.md."
        After  = "No handoff update required. Commit only the files listed under Changed Files."
    }
    "QUESTION_FOR_MASTER"      = @{
        Role   = "Master"
        Action = "Answer the Implementer's question under Dialogue / Open Questions, then return the working state."
        After  = "Set State back to the Implementer's working state and Waiting For: Implementer. Update AI_HANDOFF.md."
    }
    "QUESTION_FOR_IMPLEMENTER"  = @{
        Role   = "Implementer"
        Action = "Answer the Master's question read-only under Dialogue / Open Questions. No source edits."
        After  = "Set State back to the value the Master specified and Waiting For: Master. Update AI_HANDOFF.md."
    }
    "RE_GATE_REQUESTED"        = @{
        Role   = "Master"
        Action = "Re-route the task; the Implementer found it riskier/larger than scoped."
        After  = "Re-classify through the Decision Router and set State/Waiting For accordingly. Update AI_HANDOFF.md."
    }
    "BLOCKED"                  = @{
        Role   = "User"
        Action = "Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md."
        After  = "Resolve the blocker, update AI_HANDOFF.md, and set State and Waiting For appropriately."
    }
    "WAITING_FOR_USER"         = @{
        Role   = "User"
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
    Write-Host "Roles:        Master=$($Binding.Master), Reviewer=$($Binding.Reviewer), Implementer=$($Binding.Implementer)"
    Write-Host "Commit:       $CommitStatus"
    $skillAdapter = Join-Path (Get-Location) ".agents/skills/codex-claude-handoff/SKILL.md"
    if (Test-Path $skillAdapter) {
        Write-Host "Protocol:     installed (canonical: .ai/skills/codex-claude-handoff/; roles: .ai/roles/ROLE_ASSIGNMENT.md)"
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

    # Resolve the acting tool from the state's role (authoritative, swap-correct)
    $role    = $entry.Role
    $expTool = Resolve-Actor -Role $role -Binding $Binding

    # Turn-ownership / mismatch: Waiting For must be the expected role or the resolved tool.
    # On mismatch, route to User instead of generating a normal prompt for the wrong actor.
    $isMismatch = ($WaitingFor -ne "(unknown)") -and ($WaitingFor -ne $role) -and ($WaitingFor -ne $expTool)

    if ($isMismatch) {
        $actor      = "User"
        $roleLabel  = "handoff mismatch"
        $actionLine = "Resolve handoff mismatch. State $State normally expects Waiting For: $role ($expTool), but found: $WaitingFor."
        $afterLine  = "Correct Waiting For in AI_HANDOFF.md to match the expected role for this state."
    } else {
        $actor      = $expTool
        $roleLabel  = $role
        $actionLine = $entry.Action
        $afterLine  = $entry.After
    }
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
    $ntLines.Add("Actor: $actor ($roleLabel)")
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

        if ($isMismatch) {
            Write-Host "WARNING: State $State expects Waiting For: $role ($expTool), but found: $WaitingFor."
            Write-Host "Next actor: User - resolve the handoff mismatch in AI_HANDOFF.md before continuing."
        } elseif ($actor -eq "User") {
            Write-Host "Next actor: User"
            Write-Host "No tool handoff needed."
            Write-Host "Review the status, start a new request, or run commit-check if you are about to commit."
        } else {
            Write-Host "Open:  $actor  (role: $role)"
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

    $masterTool = Resolve-Actor -Role "Master" -Binding $Binding
    $masterPrompt = "Use the codex-claude-handoff skill.`nRead USER_REQUEST.md for the user's request.`nRead AI_HANDOFF.md for current handoff state.`nRead .ai/roles/ROLE_ASSIGNMENT.md to confirm you hold the Master role.`nRead .agents/skills/codex-claude-handoff/SKILL.md as local protocol instructions.`nRoute the request through the Decision Router.`nWhen correctness depends on current repo behavior, local implementation details, or verification constraints, default to a read-only Implementer investigation pass (NEEDS_INVESTIGATION) before finalizing the task.`nIf the request is advisory-only, answer directly and do not update AI_HANDOFF.md.`nUpdate AI_HANDOFF.md only if the protocol requires investigation, planning, implementation, user decision tracking, or review."

    Write-Host ""
    Write-Host "=== Master Entry Prompt (open: $masterTool) ==="
    Write-Host $masterPrompt
    Write-Host ""

    if ($Clip) {
        try {
            Set-Clipboard -Value $masterPrompt
            Write-Host "Prompt copied to clipboard."
        } catch {
            Write-Host "Could not copy to clipboard: $_"
        }
    }
}

function Invoke-CommitCheck {
    Write-Host ""

    if ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") {
        # Parse handoff Changed Files. Only markdown bullet lines ("- path") are files;
        # skip group headings ("New (6):", "Modified (26):"), the "Total:" summary, and notes.
        $localIgnored  = @("AI_HANDOFF.md", "NEXT_TURN.md", "USER_REQUEST.md")
        $changedFilesLines = Get-SectionLines -Lines $Lines -Heading "Changed Files"
        $commitFiles = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $changedFilesLines) {
            $trimmed = $line.Trim()
            if ($trimmed -notmatch '^-\s+') { continue }
            $entry = $trimmed -replace '^-\s+', '' -replace '`', ''
            if ($entry -match '^(.+?)\s+-\s+.+$') { $entry = $Matches[1].Trim() }
            $entry = $entry.Trim()
            if ($entry -ne "" -and $entry -ne "None yet" -and ($localIgnored -notcontains $entry)) {
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

        # Get actual changed files from git status --short (modified AND new/untracked),
        # excluding local ignored handoff/request files.
        $actualTracked = [System.Collections.Generic.List[string]]::new()
        try {
            # --untracked-files=all expands untracked directories so new files under
            # new directories (e.g. .ai/roles/ROLE_ASSIGNMENT.md) are listed individually
            # rather than collapsed to the directory name.
            $gitLines = & git status --short --untracked-files=all 2>$null
            foreach ($gitLine in $gitLines) {
                if ($gitLine.Length -lt 3) { continue }
                $filePart = $gitLine.Substring(3).Trim()
                if ($filePart -match ' -> (.+)$') { $filePart = $Matches[1].Trim() }  # renames
                if ($filePart -ne "" -and $localIgnored -notcontains $filePart) {
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

        Write-Host "Commit: ALLOWED - the Reviewer approved."
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
            "READY_FOR_REVIEW"         { "Waiting for the Reviewer to review." }
            "PLAN_READY_FOR_REVIEW"    { "Waiting for the Reviewer to review the plan." }
            "READY_FOR_IMPLEMENTATION" { "Waiting for the Implementer to implement." }
            "PLAN_REQUIRED"            { "Waiting for the Implementer to write a plan." }
            "NEEDS_INVESTIGATION"      { "Waiting for the Implementer to investigate." }
            "NEEDS_ANALYSIS"           { "Waiting for the Master to analyze." }
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
    Write-Host "Waiting For: $WaitingFor"
    Write-Host "Task:   $CurrentTask"
    Write-Host "Roles:  Master=$($Binding.Master), Reviewer=$($Binding.Reviewer), Implementer=$($Binding.Implementer)"
    Write-Host ""
    Write-Host "Use this menu for local workflow actions."
    Write-Host "For questions, planning, or decisions, continue chatting with the Master."
    Write-Host ""
    Write-Host "1. Start new request              - begin a new task from natural language"
    Write-Host "2. Continue next turn             - prepare prompt for the Master/Implementer if needed"
    Write-Host "3. Show status                    - show current state and next actor"
    Write-Host "4. Check commit                   - verify whether commit is allowed"
    Write-Host "5. Run next assisted turn         - only when the Implementer (Claude Code) should act"
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
    $implementerTool = $Binding.Implementer

    # Only READY_FOR_IMPLEMENTATION is eligible
    if ($State -ne "READY_FOR_IMPLEMENTATION") {
        Write-Host ""
        Write-Host "run-next: blocked."
        Write-Host "State:       $State"
        Write-Host "Waiting For: $WaitingFor"
        $entry = $ActionMap[$State]
        $role  = if ($entry) { $entry.Role } else { "" }
        if ($State -eq "NEEDS_INVESTIGATION" -or $State -eq "PLAN_REQUIRED") {
            Write-Host "Reason:      run-next does not automate investigation or planning turns in this version."
            Write-Host "             The Claude Code CLI cannot safely restrict file edits to AI_HANDOFF.md only in these states."
            Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into the Implementer."
        } elseif ($role -eq "Master" -or $role -eq "Reviewer") {
            $t = Resolve-Actor -Role $role -Binding $Binding
            Write-Host "Reason:      This turn is for the $role ($t). run-next cannot automate $role turns."
            Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into $t."
        } elseif ($role -eq "User") {
            Write-Host "Reason:      This turn requires user action."
            Write-Host "Next step:   See AI_HANDOFF.md for details."
        } else {
            Write-Host "Reason:      State '$State' is not eligible for run-next in this version."
        }
        Write-Host ""
        exit 1
    }

    # Turn ownership: Waiting For must indicate the Implementer's turn (role name or resolved tool)
    if ($WaitingFor -ne "Implementer" -and $WaitingFor -ne $implementerTool) {
        Write-Host ""
        Write-Host "run-next: blocked."
        Write-Host "State:       $State"
        Write-Host "Waiting For: $WaitingFor"
        Write-Host "Reason:      Turn ownership mismatch. State $State expects the Implementer's turn ($implementerTool), but Waiting For is '$WaitingFor'."
        Write-Host "Next step:   Correct Waiting For in AI_HANDOFF.md to Implementer, or re-route via the Master."
        Write-Host ""
        exit 1
    }

    # READY_FOR_IMPLEMENTATION: run-next can only drive an Implementer bound to Claude Code
    if ($implementerTool -ne "Claude Code") {
        Write-Host ""
        Write-Host "run-next: blocked."
        Write-Host "State:       $State"
        Write-Host "Implementer: $implementerTool"
        Write-Host "Reason:      run-next can only automate an Implementer bound to Claude Code."
        Write-Host "             $implementerTool has no local CLI, so this turn must be run manually."
        Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into $implementerTool."
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
    Write-Host "Preparing assisted Implementer turn..."
    Write-Host ""
    Write-Host "State:        $State"
    Write-Host "Actor:        $implementerTool (Implementer)"
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

        # Re-read AI_HANDOFF.md to get post-turn state (pre-run values are stale)
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
        if ($StateAlias.ContainsKey($script:State)) { $script:State = $StateAlias[$script:State] }

        # Refresh NEXT_TURN.md with the updated state
        try { Invoke-Next -Silent $true } catch { Write-Host "Could not refresh NEXT_TURN.md: $_" }

        $reviewerTool = Resolve-Actor -Role "Reviewer" -Binding $Binding
        $reviewerReady = ($script:State -eq "READY_FOR_REVIEW") -and
            ($script:WaitingFor -eq "Reviewer" -or $script:WaitingFor -eq $reviewerTool)

        if ($reviewerReady) {
            $pasteInstruction = "Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
            try { Set-Clipboard -Value $pasteInstruction } catch { Write-Host "Could not copy to clipboard: $_" }
            Write-Host "NEXT_TURN.md updated for Reviewer review."
            Write-Host ""
            Write-Host "Open $reviewerTool and press Ctrl+V."
            Write-Host "Do not commit before review."
        } elseif ($script:State -eq "READY_FOR_REVIEW") {
            Write-Host "Post-turn handoff mismatch detected."
            Write-Host "State:       $($script:State)"
            Write-Host "Waiting For: $($script:WaitingFor)"
            Write-Host "Expected:    Reviewer ($reviewerTool)"
            Write-Host "NEXT_TURN.md updated for User mismatch resolution."
            Write-Host "Do not continue to a review turn or commit until AI_HANDOFF.md is corrected."
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
            Write-Host "  status                    Show current handoff state, role binding, and commit status."
            Write-Host "  next [-Clip]              Generate NEXT_TURN.md and print the paste instruction."
            Write-Host '  start "<request>" [-Clip]  Save request and print a Master entry prompt.'
            Write-Host "  commit-check              Show whether a commit is allowed and what to commit."
            Write-Host "  run-next [-BudgetUsd N]   Run one assisted Implementer turn (READY_FOR_IMPLEMENTATION; Implementer must be Claude Code)."
            Write-Host ""
        }
    }
}
