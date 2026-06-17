param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$Request,
    [string]$Version,
    [string]$Message,
    [string]$Authorize,
    [string]$ReleasedVersion,
    [string]$Commit,
    [string]$Tag,
    [string]$NextTask,
    [string]$SupersededVersions,
    [int]$TimeoutSeconds = 180,
    [switch]$Yes,
    [switch]$Clip,
    [switch]$CopyPrompt,  # backward-compatible alias for -Clip
    [decimal]$BudgetUsd = 2,
    [int]$MaxTurns = 3,
    [decimal]$SessionBudgetUsd = 6
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

# Backward-compatible state aliases (pre-v0.13.0 tool-named dialogue states)
$StateAlias = @{
    "QUESTION_FOR_CODEX"  = "QUESTION_FOR_MASTER"
    "QUESTION_FOR_CLAUDE" = "QUESTION_FOR_IMPLEMENTER"
}

function Read-HandoffState {
    param([string[]]$Lines)
    $status = @{ State = "(unknown)"; WaitingFor = "(unknown)"; CurrentTask = "(unknown)" }
    foreach ($line in (Get-SectionLines -Lines $Lines -Heading "Status")) {
        if ($line -match "^- State:\s*(.+)")        { $status.State       = $Matches[1].Trim() }
        if ($line -match "^- Waiting For:\s*(.+)")  { $status.WaitingFor  = $Matches[1].Trim() }
        if ($line -match "^- Current Task:\s*(.+)") { $status.CurrentTask = $Matches[1].Trim() }
    }
    if ($StateAlias.ContainsKey($status.State)) { $status.State = $StateAlias[$status.State] }
    return $status
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

# Local Codex Reviewer POC artifacts (v1.2.0). Local, gitignored, never committed.
$ReviewJsonlName = "CODEX_REVIEW.jsonl"
$ReviewLastName  = "CODEX_REVIEW_LAST.md"

# Local protocol files exempt from the clean-tree guard - they are expected to
# change between turns and must never be committed.
$LocalHandoffFiles = @("AI_HANDOFF.md", "AI_SEQUENCE.md", "NEXT_TURN.md", "USER_REQUEST.md", "HANDOFF_LOOP.log", $ReviewJsonlName, $ReviewLastName)

# Working tree state for the automation guards (cycle and loop).
# Returns @{ Ok = git check succeeded; Files = non-exempt changed files (tracked + untracked) }.
function Get-WorkingTreeState {
    $files = [System.Collections.Generic.List[string]]::new()
    $ok = $false
    try {
        $gitStatusLines = & git status --short --untracked-files=all 2>$null
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
            foreach ($gitLine in $gitStatusLines) {
                if ($null -eq $gitLine -or $gitLine.Length -lt 3) { continue }
                $filePart = $gitLine.Substring(3).Trim()
                if ($filePart -match ' -> (.+)$') { $filePart = $Matches[1].Trim() }  # renames
                if ($filePart -eq "") { continue }
                if ($LocalHandoffFiles -contains $filePart) { continue }
                $files.Add($filePart)
            }
        }
    } catch { }
    return @{ Ok = $ok; Files = $files }
}

function Test-ClaudeAvailable {
    $null = npx --yes @anthropic-ai/claude-code --version 2>&1
    return ($LASTEXITCODE -eq 0)
}

# Run one Claude Code Implementer turn with the standard safety constraints.
function Invoke-ClaudeTurn {
    $prompt = "Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
    npx --yes @anthropic-ai/claude-code -p $prompt `
        --permission-mode acceptEdits `
        --disallowed-tools "Bash" `
        --max-budget-usd $BudgetUsd `
        --no-session-persistence `
        --output-format text
    return $LASTEXITCODE
}

function Get-AdapterProfile {
    param([string]$Role, [string]$Tool)

    $manual = "Run 'handoff.ps1 next' then paste the prompt into $Tool."
    if ($Role -eq "User") {
        return @{
            Role = "User"; Tool = "User"; Callable = $false; SupportedStates = @();
            Invocation = "See AI_HANDOFF.md and decide or authorize the next step.";
            SafetyLimits = "User approval authority; no automation.";
            StopCategory = "User Decision"; UserAuthorizationRequired = "yes";
            Reason = "The protocol requires user authority for this turn.";
            NextStep = "Read AI_HANDOFF.md."
        }
    }

    if ($Role -eq "Implementer" -and $Tool -eq "Claude Code") {
        return @{
            Role = $Role; Tool = $Tool; Callable = $true; SupportedStates = @("READY_FOR_IMPLEMENTATION");
            Invocation = "npx --yes @anthropic-ai/claude-code -p `"<prompt>`" --permission-mode acceptEdits --disallowed-tools `"Bash`" --max-budget-usd N --no-session-persistence --output-format text";
            SafetyLimits = "Explicit yes confirmation; Reviewer != Implementer; clean tree except local handoff files; Bash disallowed; budget cap; no commit/push/tag/deploy/db/secrets automation.";
            StopCategory = "Non-callable Actor"; UserAuthorizationRequired = "yes, before cycle or loop session";
            Reason = "Only READY_FOR_IMPLEMENTATION is automated; investigation, planning, and questions remain manual.";
            NextStep = "Use handoff.ps1 cycle or loop for READY_FOR_IMPLEMENTATION; use next + paste for other Implementer states."
        }
    }

    $reason = "$Tool has no verified local callable adapter for the $Role role."
    if ($Tool -eq "Codex") {
        $reason = "No Codex CLI, MCP adapter, API bridge, or other local callable adapter is present in this repository."
    }
    return @{
        Role = $Role; Tool = $Tool; Callable = $false; SupportedStates = @();
        Invocation = $manual;
        SafetyLimits = "Manual prompt handoff only; no commit/push/tag/deploy/db/secrets automation.";
        StopCategory = "Non-callable Actor"; UserAuthorizationRequired = "no for paste; yes for protected actions";
        Reason = $reason;
        NextStep = "Add and verify a real local adapter before marking this role callable."
    }
}

function Resolve-TurnAdapter {
    param([string]$ForState, [string]$Role, [string]$Tool)
    $adapter = Get-AdapterProfile -Role $Role -Tool $Tool
    $stateSupported = $false
    foreach ($s in $adapter.SupportedStates) {
        if ($s -eq $ForState) { $stateSupported = $true; break }
    }
    $callableForState = [bool]($adapter.Callable -and $stateSupported)
    $reason = $adapter.Reason
    if ($adapter.Callable -and -not $stateSupported) {
        $supported = if ($adapter.SupportedStates.Count -gt 0) { $adapter.SupportedStates -join ", " } else { "none" }
        $reason = "$Role/$Tool adapter does not support state $ForState. Supported automated states: $supported."
    }
    return @{
        Role = $Role; Tool = $Tool; Callable = $callableForState;
        SupportedStates = $adapter.SupportedStates; Invocation = $adapter.Invocation;
        SafetyLimits = $adapter.SafetyLimits; StopCategory = $adapter.StopCategory;
        UserAuthorizationRequired = $adapter.UserAuthorizationRequired; Reason = $reason;
        NextStep = $adapter.NextStep
    }
}

function Invoke-Adapters {
    Write-Host ""
    Write-Host "Adapter status"
    Write-Host "Contract: .ai/skills/codex-claude-handoff/ADAPTERS.md"
    Write-Host ""
    foreach ($role in @("Master", "Implementer", "Reviewer")) {
        $tool = Resolve-Actor -Role $role -Binding $script:Binding
        $adapter = Get-AdapterProfile -Role $role -Tool $tool
        $callable = if ($adapter.Callable) { "yes" } else { "no" }
        $states = if ($adapter.SupportedStates.Count -gt 0) { $adapter.SupportedStates -join ", " } else { "none" }
        Write-Host "Role:        $role"
        Write-Host "Tool:        $tool"
        Write-Host "Callable:    $callable"
        Write-Host "States:      $states"
        Write-Host "Reason:      $($adapter.Reason)"
        Write-Host "Invocation:  $($adapter.Invocation)"
        Write-Host "Safety:      $($adapter.SafetyLimits)"
        Write-Host "Stop:        $($adapter.StopCategory)"
        Write-Host "User auth:   $($adapter.UserAuthorizationRequired)"
        Write-Host "Enable next: $($adapter.NextStep)"
        Write-Host ""
    }
    Write-Host "Capability:  Authorized release executor"
    Write-Host "Callable:    yes (PowerShell only)"
    Write-Host "States:      REVIEW_DONE with Waiting For: User"
    Write-Host "Invocation:  release-check -Version vX.Y.Z; release -Version vX.Y.Z -Message `"<msg>`" -Authorize `"I_AUTHORIZE_RELEASE_vX.Y.Z`""
    Write-Host "Safety:      Exact user authorization token; Reviewer != Implementer; Changed Files == git status; pre-release checks; commit before tag; no deploy/db/secrets/production-config actions."
    Write-Host "Stop:        User Release Authorization until token is supplied; Environment/Preflight when unavailable."
    Write-Host "User auth:   yes, exact token required for execution"
    Write-Host "Enable next: Use release-check for dry run; use release only after independent review has set REVIEW_DONE."
    Write-Host ""
}

# Stop-category label for printed stops (v0.18.2 controlled stop routing).
# Categories: see PROTOCOL_METHOD.md, "Stop Routing".
function Get-StopCategoryLine {
    param([string]$ForState, [string]$ActorTool, [bool]$Automation = $false)
    if ($ActorTool -eq "User") {
        if ($ForState -eq "REVIEW_DONE") {
            return "Stop category: User Release Authorization - approve the release; technical readiness was attested by the Reviewer."
        }
        if ($ForState -eq "IMPLEMENTED") {
            return "Stop category: User Release Authorization - this work did not require Reviewer review; check it yourself before approving the commit."
        }
        return "Stop category: User Decision - see AI_HANDOFF.md."
    }
    if ($Automation) {
        return "Stop category: Non-callable Actor (automation limitation) - next step is an Operator Manual Action: paste the prompt into $ActorTool."
    }
    return "Stop category: Operator Manual Action - paste the prompt into $ActorTool."
}

# Append-only local loop log (ASCII, never committed - see .gitignore).
function Write-LoopLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    try {
        Add-Content -Path (Join-Path (Get-Location) "HANDOFF_LOOP.log") -Value "$ts $Message" -Encoding ascii
    } catch { }
}

$Binding = Get-RoleBinding

$HandoffStatus = Read-HandoffState -Lines $Lines
$State         = $HandoffStatus.State
$WaitingFor    = $HandoffStatus.WaitingFor
$CurrentTask   = $HandoffStatus.CurrentTask

$CommitStatus = switch ($State) {
    "REVIEW_DONE" { "ALLOWED - the Reviewer attested technical readiness; the remaining step is your release authorization. Commit only the files listed under Changed Files." }
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
        Action = "Release authorization: the Reviewer attested technical readiness. Approve and run the commit/push yourself. Do not commit AI_HANDOFF.md."
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
    Write-Host "Adapters:     run 'handoff.ps1 adapters' for callable/manual automation status"
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
    # -ErrorAction Stop: write failures must be terminating so callers' try/catch
    # blocks fire and the workflow fails closed instead of reporting a handoff that
    # was never written.
    Set-Content -Path $ntPath -Value ($ntLines -join "`n") -Encoding utf8 -ErrorAction Stop

    $pasteInstruction = "Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."

    if (-not $Silent) {
        Write-Host ""
        Write-Host "NEXT_TURN.md written."

        if ($isMismatch) {
            Write-Host "WARNING: State $State expects Waiting For: $role ($expTool), but found: $WaitingFor."
            Write-Host "Next actor: User - resolve the handoff mismatch in AI_HANDOFF.md before continuing."
            Write-Host "Stop category: Protocol Repair - a correction, not a product decision."
        } elseif ($actor -eq "User") {
            Write-Host "Next actor: User"
            Write-Host (Get-StopCategoryLine -ForState $State -ActorTool "User")
            Write-Host "No tool handoff needed."
            Write-Host "Review the status, start a new request, or run commit-check if you are about to commit."
        } else {
            Write-Host "Open:  $actor  (role: $role)"
            Write-Host "Paste: $pasteInstruction"
            Write-Host (Get-StopCategoryLine -ForState $State -ActorTool $actor)
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
        $localIgnored  = $LocalHandoffFiles
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

        # Compare sets to detect mismatch (Test-SameFileSet is null-safe for empty lists)
        $mismatch = $false
        if ($actualTracked.Count -gt 0) {
            $mismatch = -not (Test-SameFileSet -Expected $commitFiles -Actual $actualTracked)
            # Also warn if NS explicitly says commit only AI_HANDOFF.md while real files changed
            if (-not $mismatch -and $nsHasStaleGuidance) { $mismatch = $true }
        }

        Write-Host "Commit: ALLOWED - the Reviewer attested technical readiness."
        Write-Host "Stop category: User Release Authorization - you approve the release; running the commands is an Operator Manual Action."
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

function Get-ReleaseChangedFiles {
    $changedFilesLines = Get-SectionLines -Lines $Lines -Heading "Changed Files"
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $changedFilesLines) {
        $trimmed = $line.Trim()
        if ($trimmed -notmatch '^-\s+') { continue }
        $entry = $trimmed -replace '^-\s+', '' -replace '`', ''
        if ($entry -match '^(.+?)\s+-\s+.+$') { $entry = $Matches[1].Trim() }
        $entry = $entry.Trim()
        if ($entry -ne "" -and $entry -ne "None yet" -and ($LocalHandoffFiles -notcontains $entry)) {
            $files.Add($entry)
        }
    }
    return $files
}

function Get-GitChangedFilesForRelease {
    $files = [System.Collections.Generic.List[string]]::new()
    $ok = $false
    try {
        $gitLines = & git status --short --untracked-files=all 2>$null
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
            foreach ($gitLine in $gitLines) {
                if ($null -eq $gitLine -or $gitLine.Length -lt 3) { continue }
                $filePart = $gitLine.Substring(3).Trim()
                if ($filePart -match ' -> (.+)$') { $filePart = $Matches[1].Trim() }
                if ($filePart -ne "" -and ($LocalHandoffFiles -notcontains $filePart)) {
                    $files.Add($filePart)
                }
            }
        }
    } catch { }
    return @{ Ok = $ok; Files = $files }
}

function Get-TaskActors {
    $implementers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $reviewers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $taskActorLines = Get-SectionLines -Lines $Lines -Heading "Task Actors"
    foreach ($line in $taskActorLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^-\s*Implementer:\s*(.+)$') {
            $value = $Matches[1].Trim()
            if ($value -ne "") { [void]$implementers.Add($value) }
        }
        if ($trimmed -match '^-\s*Reviewer:\s*(.+)$') {
            $value = $Matches[1].Trim()
            if ($value -ne "") { [void]$reviewers.Add($value) }
        }
    }
    $implementer = if ($implementers.Count -eq 1) { @($implementers)[0] } else { "" }
    $reviewer = if ($reviewers.Count -eq 1) { @($reviewers)[0] } else { "" }
    return @{
        Implementer = $implementer
        Reviewer = $reviewer
        ImplementerCount = $implementers.Count
        ReviewerCount = $reviewers.Count
    }
}

function Test-SameFileSet {
    param([object[]]$Expected, [object[]]$Actual)
    # Build sets defensively: an empty collection binds as $null to an [object[]]
    # parameter, and HashSet's (IEnumerable, comparer) constructor throws
    # "Value cannot be null" on a null source. foreach over $null is a no-op.
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Expected) { [void]$expectedSet.Add([string]$e) }
    $actualSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $Actual) { [void]$actualSet.Add([string]$a) }
    return $expectedSet.SetEquals($actualSet)
}

function Test-FileContentMatch {
    param([string]$Left, [string]$Right)
    if (-not (Test-Path $Left) -or -not (Test-Path $Right)) { return $false }
    $leftHash = (Get-FileHash -Algorithm SHA256 -Path $Left).Hash
    $rightHash = (Get-FileHash -Algorithm SHA256 -Path $Right).Hash
    return $leftHash -eq $rightHash
}

function Invoke-ReleasePreflightChecks {
    param([object[]]$ReleaseFiles)

    Write-Host ""
    Write-Host "Pre-release checks"

    & git diff --check
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: git diff --check"
        return $false
    }
    Write-Host "OK: git diff --check"

    foreach ($file in $ReleaseFiles) {
        if ($file -like "*.ps1" -and (Test-Path $file)) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count -gt 0) {
                Write-Host "FAILED: PowerShell parser $file"
                foreach ($err in $errors) { Write-Host "  $($err.Message)" }
                return $false
            }
            Write-Host "OK: PowerShell parser $file"
        }
    }

    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    foreach ($file in $ReleaseFiles) {
        if ($file -like "*.sh" -and (Test-Path $file)) {
            if ($null -eq $bashCmd) {
                Write-Host "FAILED: bash is unavailable; cannot syntax-check $file"
                return $false
            }
            & bash -n $file
            if ($LASTEXITCODE -ne 0) {
                Write-Host "FAILED: bash -n $file"
                return $false
            }
            Write-Host "OK: bash -n $file"
        }
    }

    $canonicalRoot = Join-Path (Get-Location) ".ai/skills/codex-claude-handoff"
    $templateRoot = Join-Path (Get-Location) "templates/.ai/skills/codex-claude-handoff"
    if (Test-Path $canonicalRoot) {
        foreach ($canonicalFile in (Get-ChildItem -Path $canonicalRoot -File)) {
            $relative = $canonicalFile.Name
            $templateFile = Join-Path $templateRoot $relative
            if (-not (Test-FileContentMatch -Left $canonicalFile.FullName -Right $templateFile)) {
                Write-Host "FAILED: mirror mismatch .ai/skills/codex-claude-handoff/$relative"
                return $false
            }
        }
        Write-Host "OK: canonical/template skill mirrors"
    }

    if ((Test-Path "scripts/handoff.ps1") -and (Test-Path "templates/scripts/handoff.ps1")) {
        if (-not (Test-FileContentMatch -Left "scripts/handoff.ps1" -Right "templates/scripts/handoff.ps1")) {
            Write-Host "FAILED: mirror mismatch scripts/handoff.ps1"
            return $false
        }
        Write-Host "OK: scripts/handoff.ps1 mirror"
    }
    if ((Test-Path "scripts/handoff.sh") -and (Test-Path "templates/scripts/handoff.sh")) {
        if (-not (Test-FileContentMatch -Left "scripts/handoff.sh" -Right "templates/scripts/handoff.sh")) {
            Write-Host "FAILED: mirror mismatch scripts/handoff.sh"
            return $false
        }
        Write-Host "OK: scripts/handoff.sh mirror"
    }

    return $true
}

function Get-ReleasePlan {
    param([string]$RequestedVersion)

    $releaseFiles = Get-ReleaseChangedFiles
    $gitState = Get-GitChangedFilesForRelease
    $taskActors = Get-TaskActors

    $ok = $true
    $errors = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
        $ok = $false
        $errors.Add("Missing -Version, for example -Version v0.19.1.")
    } elseif ($RequestedVersion -notmatch '^v\d+\.\d+\.\d+([.-][A-Za-z0-9]+)?$') {
        $ok = $false
        $errors.Add("Version must look like v0.19.1.")
    }
    if ($State -ne "REVIEW_DONE" -or $WaitingFor -ne "User") {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must be State: REVIEW_DONE and Waiting For: User before release execution.")
    }
    if ($taskActors.ImplementerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Implementer for release audit.")
    }
    if ($taskActors.ReviewerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Reviewer for release audit.")
    }
    if ($taskActors.Implementer -ne "" -and $taskActors.Reviewer -ne "" -and $taskActors.Reviewer -eq $taskActors.Implementer) {
        $ok = $false
        $errors.Add("Release audit invariant violation: actual Reviewer must not equal actual Implementer.")
    }
    if (-not $gitState.Ok) {
        $ok = $false
        $errors.Add("Could not read git status.")
    }
    if ($releaseFiles.Count -eq 0) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files has no releasable files.")
    }
    if ($gitState.Ok -and -not (Test-SameFileSet -Expected $releaseFiles -Actual $gitState.Files)) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files does not exactly match git status after excluding local coordination files.")
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
        & git rev-parse -q --verify "refs/tags/$RequestedVersion" *> $null
        if ($LASTEXITCODE -eq 0) {
            $ok = $false
            $errors.Add("Tag $RequestedVersion already exists.")
        }
    }

    return @{
        Ok = $ok
        Errors = $errors
        ReleaseFiles = $releaseFiles
        GitFiles = $gitState.Files
        TaskActors = $taskActors
    }
}

function Show-ReleasePlan {
    param([string]$RequestedVersion, [string]$CommitMessage, [hashtable]$Plan)

    Write-Host ""
    Write-Host "Release plan"
    Write-Host "Version:       $RequestedVersion"
    Write-Host "Commit message: $(if ([string]::IsNullOrWhiteSpace($CommitMessage)) { '(required for release)' } else { $CommitMessage })"
    Write-Host "State:         $State"
    Write-Host "Waiting For:   $WaitingFor"
    Write-Host "Current Task:  $CurrentTask"
    Write-Host "Global binding Reviewer:    $($Binding.Reviewer)"
    Write-Host "Global binding Implementer: $($Binding.Implementer)"
    Write-Host "Actual Reviewer:            $(if ($Plan.TaskActors.Reviewer -ne '') { $Plan.TaskActors.Reviewer } else { '(missing or ambiguous)' })"
    Write-Host "Actual Implementer:         $(if ($Plan.TaskActors.Implementer -ne '') { $Plan.TaskActors.Implementer } else { '(missing or ambiguous)' })"
    Write-Host ""

    Write-Host "Files from AI_HANDOFF.md Changed Files (local coordination files excluded):"
    if ($Plan.ReleaseFiles.Count -eq 0) {
        Write-Host "  (none)"
    } else {
        foreach ($f in $Plan.ReleaseFiles) { Write-Host "  $f" }
    }
    Write-Host ""
    Write-Host "Git status files to release (local coordination files excluded):"
    if ($Plan.GitFiles.Count -eq 0) {
        Write-Host "  (none)"
    } else {
        foreach ($f in $Plan.GitFiles) { Write-Host "  $f" }
    }
    Write-Host ""

    Write-Host "Exact mutating commands if authorized:"
    Write-Host "  git add -- <files listed above>"
    Write-Host "  git commit -m `"$CommitMessage`""
    Write-Host "  git push origin HEAD"
    Write-Host "  git tag -a $RequestedVersion -m $RequestedVersion"
    Write-Host "  git push origin $RequestedVersion"
    Write-Host ""
}

function Invoke-ReleaseCheck {
    $plan = Get-ReleasePlan -RequestedVersion $Version
    Show-ReleasePlan -RequestedVersion $Version -CommitMessage $Message -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "release-check: blocked."
        foreach ($err in $plan.Errors) { Write-Host "Reason: $err" }
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }
    Write-Host "release-check: ready for explicit authorization."
    Write-Host "To execute, run:"
    Write-Host "  handoff.ps1 release -Version $Version -Message `"<message>`" -Authorize `"I_AUTHORIZE_RELEASE_$Version`""
    Write-Host ""
}

function Invoke-Release {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host ""
        Write-Host "release: blocked."
        Write-Host "Reason: Missing -Message."
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }

    $expectedToken = "I_AUTHORIZE_RELEASE_$Version"
    if ($Authorize -ne $expectedToken) {
        Write-Host ""
        Write-Host "release: blocked."
        Write-Host "Reason: Missing exact authorization token."
        Write-Host "Expected: -Authorize `"$expectedToken`""
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }

    $plan = Get-ReleasePlan -RequestedVersion $Version
    Show-ReleasePlan -RequestedVersion $Version -CommitMessage $Message -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "release: blocked."
        foreach ($err in $plan.Errors) { Write-Host "Reason: $err" }
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }

    $checksOk = Invoke-ReleasePreflightChecks -ReleaseFiles $plan.ReleaseFiles
    if (-not $checksOk) {
        Write-Host ""
        Write-Host "release: blocked."
        Write-Host "Reason: Pre-release checks failed."
        Write-Host "No git mutations were run after the failed check."
        Write-Host ""
        exit 1
    }

    Write-Host ""
    Write-Host "Authorization accepted. Executing release."
    $fileArray = [string[]]$plan.ReleaseFiles
    & git add -- @fileArray
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git add"; exit 1 }
    & git commit -m $Message
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git commit"; exit 1 }
    & git push origin HEAD
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git push origin HEAD"; exit 1 }
    & git tag -a $Version -m $Version
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git tag"; exit 1 }
    & git push origin $Version
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git push origin $Version"; exit 1 }

    Write-Host ""
    Write-Host "release: complete."
    Write-Host "Next state instructions:"
    Write-Host "  Master / Sequence Owner: update local AI_SEQUENCE.md release checkpoint for $CurrentTask."
    Write-Host "  Then prepare the next active task in AI_HANDOFF.md."
    Write-Host "  Do not commit AI_HANDOFF.md, AI_SEQUENCE.md, NEXT_TURN.md, USER_REQUEST.md, or HANDOFF_LOOP.log."
    Write-Host ""
}

# --- Sequence advance (v0.19.2): local coordination only, never git mutation ---

function Test-CommitFormat {
    param([string]$Value)
    return ($Value -match '^[0-9a-fA-F]{7,40}$')
}

function Test-ReleaseVersionFormat {
    param([string]$Value)
    return ($Value -match '^v\d+\.\d+\.\d+([.-][A-Za-z0-9]+)?$')
}

function Get-TaskVersionToken {
    param([string]$TaskText)
    if ($TaskText -match '^\s*(v\d+\.\d+\.\d+([.-][A-Za-z0-9]+)?)\b') { return $Matches[1] }
    return ""
}

# Parse the markdown table under "## Tasks" in AI_SEQUENCE.md.
function Get-SequenceTaskRows {
    param([string[]]$SeqLines)
    $rows = [System.Collections.Generic.List[object]]::new()
    $inTasks = $false
    foreach ($line in $SeqLines) {
        if ($line.TrimEnd() -eq "## Tasks") { $inTasks = $true; continue }
        if ($inTasks -and $line -match "^##\s") { break }
        if (-not $inTasks) { continue }
        $t = $line.Trim()
        if ($t -notmatch '^\|') { continue }
        $cols = $t.Trim('|') -split '\|'
        if ($cols.Count -lt 4) { continue }
        $num = $cols[0].Trim(); $task = $cols[1].Trim(); $status = $cols[2].Trim(); $checkpoint = $cols[3].Trim()
        if ($num -eq '#' -or $num -match '^[-: ]+$') { continue }     # header or separator
        if ($num -eq '' -and $task -eq '') { continue }
        $rows.Add([ordered]@{ Num = $num; Task = $task; Status = $status; Checkpoint = $checkpoint })
    }
    return $rows
}

# Validate the advance request. Always returns every key so callers can print safely.
function Get-SequencePlan {
    param([string]$RelVersion, [string]$RelCommit, [string]$RelTag, [string]$NextTaskText, [string]$Superseded)

    $ok = $true
    $errors = [System.Collections.Generic.List[string]]::new()
    $seqPath = Join-Path (Get-Location) "AI_SEQUENCE.md"
    $seqLines = @()
    $rows = [System.Collections.Generic.List[object]]::new()
    $activeRow = $null
    $nextRow = $null
    $supersededRows = [System.Collections.Generic.List[object]]::new()

    if ([string]::IsNullOrWhiteSpace($RelVersion)) { $ok = $false; $errors.Add("Missing -ReleasedVersion, for example -ReleasedVersion v0.19.1.1.") }
    elseif (-not (Test-ReleaseVersionFormat $RelVersion)) { $ok = $false; $errors.Add("-ReleasedVersion must look like v0.19.1.1.") }
    if ([string]::IsNullOrWhiteSpace($RelCommit)) { $ok = $false; $errors.Add("Missing -Commit, for example -Commit fc0ed49.") }
    elseif (-not (Test-CommitFormat $RelCommit)) { $ok = $false; $errors.Add("-Commit must be a git commit SHA (7-40 hex characters).") }
    if ([string]::IsNullOrWhiteSpace($RelTag)) { $ok = $false; $errors.Add("Missing -Tag, for example -Tag v0.19.1.1.") }
    elseif (-not (Test-ReleaseVersionFormat $RelTag)) { $ok = $false; $errors.Add("-Tag must look like v0.19.1.1.") }

    # Verify the released checkpoint exists in git (read-only).
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCmd) {
        $ok = $false; $errors.Add("git is not available; cannot verify the release checkpoint.")
    } elseif (-not [string]::IsNullOrWhiteSpace($RelCommit) -and -not [string]::IsNullOrWhiteSpace($RelTag)) {
        & git rev-parse -q --verify "$RelCommit^{commit}" *> $null
        $commitOk = ($LASTEXITCODE -eq 0)
        if (-not $commitOk) { $ok = $false; $errors.Add("Commit $RelCommit could not be verified in this repository.") }
        & git rev-parse -q --verify "refs/tags/$RelTag" *> $null
        $tagOk = ($LASTEXITCODE -eq 0)
        if (-not $tagOk) { $ok = $false; $errors.Add("Tag $RelTag does not exist in this repository.") }
        if ($commitOk -and $tagOk) {
            # Distinct local names: PowerShell variables are case-insensitive, so a
            # local like $relCommit would alias the $RelCommit parameter and overwrite
            # the user-supplied (short) SHA with the resolved full SHA.
            $tagSha = (& git rev-parse -q --verify "$RelTag^{commit}" 2>$null)
            $commitSha = (& git rev-parse -q --verify "$RelCommit^{commit}" 2>$null)
            if ($tagSha -and $commitSha -and ($tagSha.Trim() -ne $commitSha.Trim())) {
                $ok = $false; $errors.Add("Tag $RelTag does not point to commit $RelCommit.")
            }
        }
    }

    if (-not (Test-Path $seqPath)) {
        $ok = $false; $errors.Add("AI_SEQUENCE.md not found; the Sequence Owner must create it before advancing.")
    } else {
        $seqLines = Get-Content -Path $seqPath
        $rows = Get-SequenceTaskRows -SeqLines $seqLines
        if ($rows.Count -eq 0) {
            $ok = $false; $errors.Add("AI_SEQUENCE.md has no parseable Tasks table rows.")
        } else {
            $activeRows = @($rows | Where-Object { $_.Status -eq 'active' })
            if ($activeRows.Count -ne 1) {
                $ok = $false; $errors.Add("AI_SEQUENCE.md must have exactly one active task (found $($activeRows.Count)).")
            } else {
                $activeRow = $activeRows[0]
                $activeToken = Get-TaskVersionToken $activeRow.Task
                if (-not [string]::IsNullOrWhiteSpace($RelVersion) -and $activeToken -ne $RelVersion) {
                    $ok = $false; $errors.Add("The active sequence task is '$($activeRow.Task)' (version '$activeToken'), not the released version $RelVersion.")
                }
            }

            $pendingRows = @($rows | Where-Object { $_.Status -eq 'pending' })
            if (-not [string]::IsNullOrWhiteSpace($NextTaskText)) {
                $match = @($pendingRows | Where-Object { $_.Task -eq $NextTaskText.Trim() })
                if ($match.Count -eq 1) { $nextRow = $match[0] }
                elseif ($match.Count -eq 0) { $ok = $false; $errors.Add("-NextTask '$($NextTaskText.Trim())' does not match any pending task in AI_SEQUENCE.md.") }
                else { $ok = $false; $errors.Add("-NextTask '$($NextTaskText.Trim())' matches multiple pending tasks; resolve the ambiguity in AI_SEQUENCE.md.") }
            } else {
                if ($pendingRows.Count -eq 1) { $nextRow = $pendingRows[0] }
                elseif ($pendingRows.Count -eq 0) { $ok = $false; $errors.Add("No pending task to activate; update AI_SEQUENCE.md or finish the sequence.") }
                else { $ok = $false; $errors.Add("Multiple pending tasks; specify -NextTask to choose the next active task unambiguously.") }
            }

            if (-not [string]::IsNullOrWhiteSpace($Superseded)) {
                foreach ($sv in ($Superseded -split ',')) {
                    $svTrim = $sv.Trim()
                    if ($svTrim -eq "") { continue }
                    $svMatch = @($rows | Where-Object { (Get-TaskVersionToken $_.Task) -eq $svTrim })
                    if ($svMatch.Count -eq 0) { $ok = $false; $errors.Add("Superseded version $svTrim not found in AI_SEQUENCE.md Tasks."); continue }
                    foreach ($m in $svMatch) {
                        if ($activeRow -and $m.Task -eq $activeRow.Task) { $ok = $false; $errors.Add("Superseded version $svTrim is the active task; it cannot also be superseded.") }
                        elseif ($nextRow -and $m.Task -eq $nextRow.Task) { $ok = $false; $errors.Add("Superseded version $svTrim is the next task; it cannot be superseded.") }
                        else { $supersededRows.Add($m) }
                    }
                }
            }
        }
    }

    return @{
        Ok = $ok; Errors = $errors; SeqPath = $seqPath; SeqLines = $seqLines; Rows = $rows;
        ActiveRow = $activeRow; NextRow = $nextRow; SupersededRows = $supersededRows;
        ReleasedVersion = $RelVersion; Commit = $RelCommit; Tag = $RelTag
    }
}

function Show-SequencePlan {
    param([hashtable]$Plan)
    Write-Host ""
    Write-Host "Sequence advance plan"
    Write-Host "Released version: $($Plan.ReleasedVersion)"
    Write-Host "Commit:           $($Plan.Commit)"
    Write-Host "Tag:              $($Plan.Tag)"
    Write-Host "Sequence file:    AI_SEQUENCE.md (local, gitignored, never committed)"
    Write-Host "Handoff file:     AI_HANDOFF.md (local, gitignored, never committed)"
    Write-Host ""
    if ($Plan.ActiveRow) {
        Write-Host "Released task (active -> released): $($Plan.ActiveRow.Task)"
        Write-Host "  checkpoint -> commit $($Plan.Commit) / tag $($Plan.Tag)"
    } else {
        Write-Host "Released task: (could not resolve a single active task)"
    }
    if ($Plan.SupersededRows.Count -gt 0) {
        Write-Host "Superseded task(s) (-> released, bundled into $($Plan.ReleasedVersion)):"
        foreach ($r in $Plan.SupersededRows) { Write-Host "  $($r.Task)" }
    }
    if ($Plan.NextRow) {
        Write-Host "Next task (pending -> active): $($Plan.NextRow.Task)"
    } else {
        Write-Host "Next task: (could not resolve a single next task)"
    }
    Write-Host ""
    Write-Host "AI_HANDOFF.md will be prepared for the next task:"
    Write-Host "  State: NEEDS_ANALYSIS / Waiting For: Master"
    Write-Host "  Task Actors: Implementer TBD / Reviewer TBD"
    Write-Host ""
    Write-Host "Local coordination only: never runs git add/commit/push/tag/deploy/db/secrets."
    Write-Host ""
}

# Rebuild AI_SEQUENCE.md lines with the advanced statuses + an appended note.
function New-SequenceLines {
    param([hashtable]$Plan)
    $date = (Get-Date).ToString("yyyy-MM-dd")
    $activeCheckpoint = "commit $($Plan.Commit) / tag $($Plan.Tag)"
    $supersededCheckpoint = "bundled into $($Plan.ReleasedVersion) (commit $($Plan.Commit) / tag $($Plan.Tag))"
    $supersededTasks = @($Plan.SupersededRows | ForEach-Object { $_.Task })

    $result = [System.Collections.Generic.List[string]]::new()
    $inTasks = $false
    foreach ($line in $Plan.SeqLines) {
        if ($line.TrimEnd() -eq "## Tasks") { $inTasks = $true; $result.Add($line); continue }
        if ($inTasks -and $line -match "^##\s") { $inTasks = $false }
        $emit = $line
        if ($inTasks -and $line.Trim() -match '^\|') {
            $cols = $line.Trim().Trim('|') -split '\|'
            if ($cols.Count -ge 4) {
                $num = $cols[0].Trim(); $task = $cols[1].Trim(); $status = $cols[2].Trim(); $checkpoint = $cols[3].Trim()
                if ($num -ne '#' -and $num -notmatch '^[-: ]+$' -and -not ($num -eq '' -and $task -eq '')) {
                    if ($Plan.ActiveRow -and $task -eq $Plan.ActiveRow.Task -and $status -eq 'active') {
                        $status = 'released'; $checkpoint = $activeCheckpoint
                    } elseif ($Plan.NextRow -and $task -eq $Plan.NextRow.Task -and $status -eq 'pending') {
                        $status = 'active'
                    } elseif ($supersededTasks -contains $task) {
                        $status = 'released'; $checkpoint = $supersededCheckpoint
                    }
                    $emit = "| $num | $task | $status | $checkpoint |"
                }
            }
        }
        $result.Add($emit)
    }

    $result.Add("- $($Plan.ReleasedVersion) released on ${date}: commit $($Plan.Commit) / tag $($Plan.Tag). Next active task: $($Plan.NextRow.Task).")
    if ($supersededTasks.Count -gt 0) {
        $result.Add("- $($Plan.ReleasedVersion) bundled superseded task(s): $([string]::Join('; ', $supersededTasks)).")
    }
    return $result
}

# Prepare a fresh AI_HANDOFF.md for the next task (template conventions + Task Actors).
function New-NextHandoffContent {
    param([hashtable]$Plan)
    $date = (Get-Date).ToString("yyyy-MM-dd")
    $nextTask = $Plan.NextRow.Task
    $supersededTasks = @($Plan.SupersededRows | ForEach-Object { $_.Task })
    $supersededLine = ""
    if ($supersededTasks.Count -gt 0) {
        $supersededLine = "`n- Bundled superseded task(s): $([string]::Join('; ', $supersededTasks))."
    }
    $content = @"
# AI Handoff

## Status
- State: NEEDS_ANALYSIS
- Waiting For: Master
- Last Updated By: Sequence Advance
- Last Updated At: $date
- Current Task: $nextTask

## Last Update
- Actor: Sequence Advance (local coordination via handoff.ps1 sequence-advance)
- Date: $date
- Task: Advanced the local sequence after the $($Plan.ReleasedVersion) release checkpoint (commit $($Plan.Commit) / tag $($Plan.Tag)) and opened the next task.

## Task Actors
- Implementer: TBD
- Reviewer: TBD

## Release Checkpoint (previous task)
- $($Plan.ReleasedVersion) released: commit $($Plan.Commit) / tag $($Plan.Tag).$supersededLine

## Done
- None yet - this task has not started.

## Changed Files
- None yet

## Verification
- Commands Run: [list commands, or none for documentation-only changes]
- Build: [result or not run]
- Lint: [result or not run]
- Tests: [result or not run]
- Manual Check: [expected vs actual, or not applicable]

## Dialogue / Open Questions
- None

## Open Issues
- None.

## Risks / Notes
- AI_HANDOFF.md and AI_SEQUENCE.md are local and ignored by Git; never commit them.

## Next Recommended Step
- Master: analyze the next task '$nextTask' via the Decision Router, set the appropriate gate (READY_FOR_IMPLEMENTATION, NEEDS_INVESTIGATION, or PLAN_REQUIRED), and assign the Task Actors before implementation begins.
"@
    return $content
}

function Invoke-SequenceCheck {
    $plan = Get-SequencePlan -RelVersion $ReleasedVersion -RelCommit $Commit -RelTag $Tag -NextTaskText $NextTask -Superseded $SupersededVersions
    Show-SequencePlan -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "sequence-check: blocked."
        foreach ($e in $plan.Errors) { Write-Host "Reason: $e" }
        Write-Host "No files were changed."
        Write-Host ""
        exit 1
    }
    Write-Host "sequence-check: ready."
    Write-Host "To apply, run:"
    Write-Host "  handoff.ps1 sequence-advance -ReleasedVersion $ReleasedVersion -Commit $Commit -Tag $Tag -NextTask `"$($plan.NextRow.Task)`""
    Write-Host ""
}

function Invoke-SequenceAdvance {
    $plan = Get-SequencePlan -RelVersion $ReleasedVersion -RelCommit $Commit -RelTag $Tag -NextTaskText $NextTask -Superseded $SupersededVersions
    Show-SequencePlan -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "sequence-advance: blocked."
        foreach ($e in $plan.Errors) { Write-Host "Reason: $e" }
        Write-Host "No files were changed."
        Write-Host ""
        exit 1
    }

    $newSeq = New-SequenceLines -Plan $plan
    Set-Content -Path $plan.SeqPath -Value ($newSeq -join "`n") -Encoding utf8 -ErrorAction Stop

    $newHandoff = New-NextHandoffContent -Plan $plan
    Set-Content -Path (Join-Path (Get-Location) "AI_HANDOFF.md") -Value $newHandoff -Encoding utf8 -ErrorAction Stop

    Write-Host "sequence-advance: applied (local coordination files only)."
    Write-Host "AI_SEQUENCE.md: '$($plan.ActiveRow.Task)' -> released (commit $($plan.Commit) / tag $($plan.Tag)); '$($plan.NextRow.Task)' -> active."
    if ($plan.SupersededRows.Count -gt 0) {
        Write-Host "AI_SEQUENCE.md: marked superseded/bundled: $([string]::Join('; ', @($plan.SupersededRows | ForEach-Object { $_.Task })))."
    }
    Write-Host "AI_HANDOFF.md: prepared for '$($plan.NextRow.Task)' (State: NEEDS_ANALYSIS / Waiting For: Master; Task Actors TBD)."
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Master: analyze the next task via the Decision Router and assign the Task Actors."
    Write-Host "  2. AI_SEQUENCE.md and AI_HANDOFF.md remain local and gitignored - do not commit them."
    Write-Host "  3. This command made no git changes (no add/commit/push/tag) and no deploy/db/secrets actions."
    Write-Host ""
}

# --- Codex Reviewer POC (v1.2.0): read-only review capture, never git mutation ---

# Verify the resolved CLI actually supports the read-only exec subcommand shape.
# Returns @{ Ok; Error; Output } so preflight failures are explainable.
function Test-CodexExecHelp {
    param([string]$CodexPath)
    try {
        $output = & $CodexPath exec --help 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return @{ Ok = $true; Error = ""; Output = $output }
        }
        $firstLine = @($output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        $detail = if ($firstLine.Count -gt 0) { $firstLine[0].Trim() } else { "exit code $exitCode" }
        return @{ Ok = $false; Error = "'$CodexPath' failed 'exec --help': $detail"; Output = $output }
    } catch {
        return @{ Ok = $false; Error = "'$CodexPath' threw while running 'exec --help': $($_.Exception.Message)"; Output = "" }
    }
}

function Add-CodexCliCandidate {
    param(
        [System.Collections.Generic.List[hashtable]]$Candidates,
        [hashtable]$Seen,
        [string]$Path,
        [string]$Source
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    $resolved = $Path
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        $resolved = $Path
    }
    $key = $resolved.ToLowerInvariant()
    if (-not $Seen.ContainsKey($key)) {
        $Seen[$key] = $true
        $Candidates.Add(@{ Path = $resolved; Source = $Source }) | Out-Null
    }
}

# Resolve a RUNNABLE Codex CLI: prefer an explicit CODEX_CLI environment override, then a
# local install under %LOCALAPPDATA%\OpenAI\Codex\bin, then PATH. Every candidate is
# verified with `exec --help` before it is accepted.
function Resolve-CodexCli {
    $override = $env:CODEX_CLI
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (-not (Test-Path -LiteralPath $override)) {
            return @{ Ok = $false; Path = $override; Source = "CODEX_CLI environment override"; Error = "CODEX_CLI points to a path that does not exist: $override" }
        }
        $resolvedOverride = (Resolve-Path -LiteralPath $override).Path
        $overrideProbe = Test-CodexExecHelp -CodexPath $resolvedOverride
        if ($overrideProbe.Ok) {
            return @{ Ok = $true; Path = $resolvedOverride; Source = "CODEX_CLI environment override"; Error = "" }
        }
        return @{ Ok = $false; Path = $resolvedOverride; Source = "CODEX_CLI environment override"; Error = "CODEX_CLI is set, but the pointed Codex CLI is not runnable for 'exec --help'. $($overrideProbe.Error)" }
    }

    $candidates = [System.Collections.Generic.List[hashtable]]::new()
    $seen = @{}

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $localCodexRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
        if (Test-Path -LiteralPath $localCodexRoot) {
            $localExecutables = @(Get-ChildItem -Path $localCodexRoot -Recurse -Filter codex.exe -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending)
            foreach ($exe in $localExecutables) {
                Add-CodexCliCandidate -Candidates $candidates -Seen $seen -Path $exe.FullName -Source "LOCALAPPDATA OpenAI Codex install"
            }
        }
    }

    foreach ($cmd in @(Get-Command codex -All -ErrorAction SilentlyContinue)) {
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
            Add-CodexCliCandidate -Candidates $candidates -Seen $seen -Path $cmd.Source -Source "PATH"
        }
    }

    if ($candidates.Count -eq 0) {
        return @{ Ok = $false; Path = ""; Source = "none"; Error = "No runnable Codex CLI found. Set `$env:CODEX_CLI to the codex executable, or install Codex so it is available under `%LOCALAPPDATA%\OpenAI\Codex\bin` or on PATH." }
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $probe = Test-CodexExecHelp -CodexPath $candidate.Path
        if ($probe.Ok) {
            return @{ Ok = $true; Path = $candidate.Path; Source = $candidate.Source; Error = "" }
        }
        $failures.Add("$($candidate.Source): $($probe.Error)")
    }

    return @{
        Ok = $false
        Path = $candidates[0].Path
        Source = $candidates[0].Source
        Error = "Found Codex CLI candidate(s), but none were runnable for 'exec --help'. Tried: $([string]::Join(' | ', $failures)). Set `$env:CODEX_CLI to a runnable codex executable if needed."
    }
}

# Validate the Codex Reviewer POC request. Always returns every key so callers can
# print a plan even when blocked. Reuses the release-grade Changed Files parser and
# git-status comparison so review scope is verified exactly like a release.
function Get-ReviewPlan {
    $ok = $true
    $errors = [System.Collections.Generic.List[string]]::new()

    $reviewFiles = Get-ReleaseChangedFiles
    $gitState = Get-GitChangedFilesForRelease
    $taskActors = Get-TaskActors
    $boundReviewer = Resolve-Actor -Role "Reviewer" -Binding $Binding
    $boundImplementer = Resolve-Actor -Role "Implementer" -Binding $Binding

    # The approved scope requires eligibility only at Waiting For: Reviewer (the role
    # name), so match it exactly rather than also accepting the bound tool name.
    if ($State -ne "READY_FOR_REVIEW" -or $WaitingFor -ne "Reviewer") {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must be State: READY_FOR_REVIEW and Waiting For: Reviewer for the Codex Reviewer POC.")
    }
    if ($boundReviewer -ne "Codex") {
        $ok = $false
        $errors.Add("The bound Reviewer tool must be Codex (found: $boundReviewer). This POC only invokes Codex as Reviewer.")
    }
    if ($taskActors.ImplementerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Implementer.")
    }
    if ($taskActors.ReviewerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Reviewer.")
    }
    if ($taskActors.Reviewer -ne "" -and $taskActors.Reviewer -ne "Codex") {
        $ok = $false
        $errors.Add("The actual task Reviewer must be Codex (found: $($taskActors.Reviewer)).")
    }
    if ($taskActors.Implementer -ne "" -and $taskActors.Reviewer -ne "" -and $taskActors.Reviewer -eq $taskActors.Implementer) {
        $ok = $false
        $errors.Add("Independent-review invariant: the actual Reviewer must not equal the actual Implementer.")
    }
    if (-not $gitState.Ok) {
        $ok = $false
        $errors.Add("Could not read git status.")
    }
    if ($reviewFiles.Count -eq 0) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files has no reviewable files.")
    }
    if ($gitState.Ok -and -not (Test-SameFileSet -Expected $reviewFiles -Actual $gitState.Files)) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files does not match git status after excluding local coordination files.")
    }

    $cli = Resolve-CodexCli

    return @{
        Ok = $ok
        Errors = $errors
        ReviewFiles = $reviewFiles
        GitFiles = $gitState.Files
        TaskActors = $taskActors
        BoundReviewer = $boundReviewer
        BoundImplementer = $boundImplementer
        Cli = $cli
    }
}

function Show-ReviewPlan {
    param([hashtable]$Plan)
    $repoRoot = (Get-Location).Path
    Write-Host ""
    Write-Host "Codex Reviewer POC plan (read-only; capture only)"
    Write-Host "State:               $State"
    Write-Host "Waiting For:         $WaitingFor"
    Write-Host "Current Task:        $CurrentTask"
    Write-Host "Bound Reviewer:      $($Plan.BoundReviewer)"
    Write-Host "Bound Implementer:   $($Plan.BoundImplementer)"
    Write-Host "Actual Reviewer:     $(if ($Plan.TaskActors.Reviewer -ne '') { $Plan.TaskActors.Reviewer } else { '(missing or ambiguous)' })"
    Write-Host "Actual Implementer:  $(if ($Plan.TaskActors.Implementer -ne '') { $Plan.TaskActors.Implementer } else { '(missing or ambiguous)' })"
    Write-Host ""
    Write-Host "Files to review (from AI_HANDOFF.md Changed Files; local coordination files excluded):"
    if ($Plan.ReviewFiles.Count -eq 0) { Write-Host "  (none)" } else { foreach ($f in $Plan.ReviewFiles) { Write-Host "  $f" } }
    Write-Host ""
    Write-Host "Codex CLI resolution:"
    if ($Plan.Cli.Ok) {
        Write-Host "  Resolved: $($Plan.Cli.Path)"
        Write-Host "  Source:   $($Plan.Cli.Source)"
    } else {
        Write-Host "  Not resolved: $($Plan.Cli.Error)"
    }
    Write-Host ""
    Write-Host "Read-only invocation shape (review-run, after explicit confirmation):"
    Write-Host "  codex exec --cd `"$repoRoot`" --sandbox read-only --ephemeral --json --output-last-message `"$ReviewLastName`" -   (review prompt via stdin)"
    Write-Host "Captured artifacts (local, gitignored, never committed):"
    Write-Host "  $ReviewJsonlName  (JSONL events)"
    Write-Host "  $ReviewLastName  (Codex final message)"
    Write-Host ""
    Write-Host "Safety: read-only sandbox; no --ask-for-approval; no --dangerously-bypass-approvals-and-sandbox;"
    Write-Host "        no git add/commit/push/tag; no deploy/db/secrets; no AI_HANDOFF.md state change (capture only)."
    Write-Host ""
}

function Invoke-ReviewCheck {
    $plan = Get-ReviewPlan
    Show-ReviewPlan -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "review-check: blocked."
        foreach ($e in $plan.Errors) { Write-Host "Reason: $e" }
        Write-Host "No files were changed and no Codex invocation was run."
        Write-Host ""
        exit 1
    }
    if (-not $plan.Cli.Ok) {
        Write-Host "review-check: protocol guards pass, but no runnable Codex CLI is available."
        Write-Host "Reason: $($plan.Cli.Error)"
        Write-Host "Stop category: Environment/Preflight - resolve the Codex CLI before review-run."
        Write-Host "No files were changed and no Codex invocation was run."
        Write-Host ""
        exit 1
    }
    Write-Host "review-check: ready for operator-confirmed review-run."
    Write-Host "To run the read-only Codex review, run:"
    Write-Host "  handoff.ps1 review-run"
    Write-Host "Stop category: Operator Manual Action - review-run requires an explicit 'yes' confirmation."
    Write-Host "No files were changed and no Codex invocation was run."
    Write-Host ""
}

function Invoke-ReviewRun {
    if ($TimeoutSeconds -lt 1) {
        Write-Host ""
        Write-Host "review-run: blocked."
        Write-Host "Reason: -TimeoutSeconds must be at least 1 (got: $TimeoutSeconds)."
        Write-Host "No Codex invocation was run."
        Write-Host ""
        exit 1
    }
    $plan = Get-ReviewPlan
    Show-ReviewPlan -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "review-run: blocked."
        foreach ($e in $plan.Errors) { Write-Host "Reason: $e" }
        Write-Host "No Codex invocation was run."
        Write-Host ""
        exit 1
    }
    if (-not $plan.Cli.Ok) {
        Write-Host "review-run: blocked."
        Write-Host "Reason: $($plan.Cli.Error)"
        Write-Host "Stop category: Environment/Preflight (Codex CLI unavailable) - not a user decision."
        Write-Host "No Codex invocation was run."
        Write-Host ""
        exit 3
    }
    $execHelp = Test-CodexExecHelp -CodexPath $plan.Cli.Path
    if (-not $execHelp.Ok) {
        Write-Host "review-run: blocked."
        Write-Host "Reason: The resolved Codex CLI did not accept 'exec --help'; cannot verify the read-only exec path. $($execHelp.Error)"
        Write-Host "Resolved: $($plan.Cli.Path)"
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Write-Host "No Codex review invocation was run."
        Write-Host ""
        exit 3
    }

    $repoRoot = (Get-Location).Path
    $jsonlPath = Join-Path $repoRoot $ReviewJsonlName
    $lastPath  = Join-Path $repoRoot $ReviewLastName

    Write-Host ""
    Write-Host "WARNING: This invokes the Codex CLI in a read-only sandbox to review the files above."
    Write-Host "         It captures Codex output locally and makes NO changes to git or AI_HANDOFF.md."
    Write-Host ""
    if ($Yes) {
        Write-Host "Confirmation: -Yes supplied; proceeding without an interactive prompt (read-only capture only)."
    } else {
        # Fail closed: only an explicit, non-null "yes" proceeds.
        $confirm = Read-Host 'Type "yes" to run the read-only Codex review, or press Enter to cancel'
        if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
            Write-Host "Cancelled."
            Write-Host "No Codex invocation was run."
            exit 2
        }
    }

    # Build a single-line prompt and deliver it via STDIN (codex exec -). Start-Process
    # -ArgumentList does NOT robustly quote a multi-word element, so passing the prompt as
    # an argument splits it into separate argv tokens (codex: "unexpected argument ...").
    # stdin delivers the whole prompt as one channel and avoids that entirely.
    # Tightly scoped prompt so the review finishes in bounded time: tell Codex not to load
    # broad skill/protocol context and to inspect only the handoff, git status, and the
    # changed files' diffs. Keep it free of shell metacharacters; it is delivered on stdin.
    $reviewFileList = [string]::Join("; ", @($plan.ReviewFiles))
    $reviewPrompt = "Read-only code review. Be fast and minimal: keep tool calls to a strict minimum and do not explore the repository broadly. " +
        "Do NOT read or follow AGENTS.md, CLAUDE.md, the codex-claude-handoff skill, or any other protocol or skill files. " +
        "Inspect ONLY these sources: AI_HANDOFF.md for the current task and approved scope; the output of git status --short; and git diff -- for each of these Changed Files: $reviewFileList . " +
        "Decide only whether those changed files match the task and approved scope described in AI_HANDOFF.md. Do not modify any file. " +
        "If you use ripgrep on a pattern that begins with two dashes, pass it after a -- separator, for example rg -- the-pattern. " +
        "Finish quickly and end your reply with exactly one final line: VERDICT: APPROVED or VERDICT: BLOCKED followed by a one-line reason."

    Write-Host ""
    Write-Host "Running Codex read-only review (timeout: ${TimeoutSeconds}s)..."
    Write-Host "Invocation: codex exec --cd `"$repoRoot`" --sandbox read-only --ephemeral --json --output-last-message `"$ReviewLastName`" -   (prompt via stdin)"
    Write-Host ""

    # Clear any stale capture artifacts so old/partial output is never mistaken for this run.
    Remove-Item $jsonlPath, $lastPath -Force -ErrorAction SilentlyContinue

    # Run Codex as a tracked child process with a hard timeout. The prompt is written to a
    # temp file and fed to StandardInput (codex exec -), so a multi-word prompt is never
    # split into argv tokens. Capture stdout/stderr to temp files so partial output and
    # diagnostics survive a kill. Start-Process -PassThru gives the real PID so a hung
    # Codex (and its children) can be terminated - a bare job cannot.
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $promptFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $promptFile -Value $reviewPrompt -Encoding utf8 -ErrorAction SilentlyContinue
    $argList = @('exec', '--cd', $repoRoot, '--sandbox', 'read-only', '--ephemeral', '--json', '--output-last-message', $lastPath, '-')
    $timedOut = $false
    $codexExit = -1
    try {
        $proc = Start-Process -FilePath $plan.Cli.Path -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardInput $promptFile -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    } catch {
        Write-Host "review-run: blocked."
        Write-Host "Reason: Failed to start the Codex CLI: $_"
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
        Remove-Item $tmpOut, $tmpErr, $promptFile -Force -ErrorAction SilentlyContinue
        exit 3
    }
    # Cache the process handle now so $proc.ExitCode is reliably available after exit. A
    # Start-Process -PassThru object that never had its handle accessed returns a null
    # ExitCode, which would make a successful run look like a non-zero failure.
    try { $null = $proc.Handle } catch { }

    if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
        $codexExit = $proc.ExitCode
    } else {
        $timedOut = $true
        # Terminate the whole Codex process tree; a child can outlive a bare Kill().
        if (Get-Command taskkill -ErrorAction SilentlyContinue) { & taskkill /PID $proc.Id /T /F *> $null }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }

    # Preserve partial stdout (JSONL) and capture stderr for diagnostics, regardless of outcome.
    $partial = ""
    if (Test-Path $tmpOut) { $partial = (Get-Content -Raw -Path $tmpOut -ErrorAction SilentlyContinue) }
    if (-not [string]::IsNullOrEmpty($partial)) {
        Set-Content -Path $jsonlPath -Value $partial -Encoding utf8 -ErrorAction SilentlyContinue
    }
    $stderrText = ""
    if (Test-Path $tmpErr) { $stderrText = (Get-Content -Raw -Path $tmpErr -ErrorAction SilentlyContinue) }
    Remove-Item $tmpOut, $tmpErr, $promptFile -Force -ErrorAction SilentlyContinue

    Write-Host ""
    if ($timedOut) {
        Write-Host "review-run: TIMED OUT after $TimeoutSeconds seconds."
        Write-Host "The Codex process (and its children) were terminated. NO final verdict was captured."
        if (Test-Path $jsonlPath) {
            Write-Host "Partial, INCOMPLETE Codex output was preserved (NOT a verdict): $ReviewJsonlName"
        }
        # A partial/empty last-message file must never be mistaken for a completed verdict.
        if (Test-Path $lastPath) { Remove-Item $lastPath -Force -ErrorAction SilentlyContinue }
        Write-Host "No $ReviewLastName final verdict exists for this run."
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Codex stderr (partial, before termination):"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight (Codex review timed out) - not a user decision."
        Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
        Write-Host "Re-run with a larger -TimeoutSeconds if the review legitimately needs more time."
        Write-Host ""
        exit 4
    }

    # Fail closed if Codex exited 0 but produced no final message: the POC's purpose is to
    # CAPTURE a verdict, so "success" must always mean a verdict file exists. Reporting
    # "complete" without one would be a false success. Treat a missing/unreadable ExitCode
    # the same way when there is no verdict file: still no captured review result.
    $hasVerdict = Test-Path $lastPath
    if (-not $hasVerdict -and ($null -eq $codexExit -or $codexExit -eq 0)) {
        Write-Host "review-run: blocked."
        if ($null -eq $codexExit) {
            Write-Host "Reason: Codex wrote no final message ($ReviewLastName), and no reliable process exit code was available; no review verdict was captured."
        } else {
            Write-Host "Reason: Codex exited 0 but wrote no final message ($ReviewLastName); no review verdict was captured."
        }
        Write-Host "Captured JSONL (if any): $ReviewJsonlName"
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Codex stderr:"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight (no verdict captured) - not a user decision."
        Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 6
    }

    if ($codexExit -ne 0) {
        Write-Host "review-run: Codex exited with a non-zero code ($codexExit)."
        Write-Host "Captured JSONL (if any): $ReviewJsonlName"
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Codex stderr:"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight - inspect the captured output."
        Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 5
    }

    Write-Host "review-run: complete (read-only capture)."
    Write-Host "Captured artifacts (local, gitignored - do not commit):"
    Write-Host "  $ReviewJsonlName"
    Write-Host "  $ReviewLastName"
    Write-Host ""
    Write-Host "Codex final message:"
    Get-Content -Path $lastPath | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "This POC captured the review only. It made no git changes and did not modify AI_HANDOFF.md."
    Write-Host "A human or the Master applies the actual REVIEW_DONE / READY_FOR_IMPLEMENTATION transition from this output."
    Write-Host "Stop category: Operator Manual Action - apply the protocol state transition manually."
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
    Write-Host "5. Run one handoff cycle          - one Implementer turn, then Reviewer handoff prep (cycle)"
    Write-Host "6. Run bounded loop session       - up to MaxTurns automated Implementer turns (loop)"
    Write-Host "7. Show adapter status            - callable/manual automation status"
    Write-Host "8. Check authorized release       - dry-run release plan (release-check)"
    Write-Host "9. Check sequence advance         - dry-run local sequence advance (sequence-check)"
    Write-Host "10. Check Codex review (POC)       - dry-run Codex Reviewer plan (review-check)"
    Write-Host "11. Exit"
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
        "5" { Invoke-Cycle }
        "6" { Invoke-Loop }
        "7" { Invoke-Adapters }
        "8" { Invoke-ReleaseCheck }
        "9" { Invoke-SequenceCheck }
        "10" { Invoke-ReviewCheck }
        "11" { }
        default {
            Write-Host ""
            Write-Host "Invalid selection: $choice"
            Write-Host ""
        }
    }
}

function Invoke-Cycle {
    param([string]$CommandLabel = "cycle")

    $implementerTool = $Binding.Implementer
    $turnAdapter = Resolve-TurnAdapter -ForState $State -Role "Implementer" -Tool $implementerTool

    # Only READY_FOR_IMPLEMENTATION is eligible
    if ($State -ne "READY_FOR_IMPLEMENTATION") {
        Write-Host ""
        Write-Host "${CommandLabel}: blocked."
        Write-Host "State:       $State"
        Write-Host "Waiting For: $WaitingFor"
        $entry = $ActionMap[$State]
        $role  = if ($entry) { $entry.Role } else { "" }
        if ($State -eq "NEEDS_INVESTIGATION" -or $State -eq "PLAN_REQUIRED") {
            Write-Host "Reason:      $($turnAdapter.Reason)"
            Write-Host "Stop category: $($turnAdapter.StopCategory) (automation limitation) - not a user decision."
            Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into the Implementer."
        } elseif ($role -eq "Master" -or $role -eq "Reviewer") {
            $t = Resolve-Actor -Role $role -Binding $Binding
            $blockedAdapter = Resolve-TurnAdapter -ForState $State -Role $role -Tool $t
            Write-Host "Reason:      $($blockedAdapter.Reason)"
            Write-Host "Stop category: $($blockedAdapter.StopCategory) ($t has no callable adapter) - not a user decision."
            Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into $t."
        } elseif ($role -eq "User") {
            Write-Host "Reason:      This turn requires user action."
            Write-Host (Get-StopCategoryLine -ForState $State -ActorTool "User")
            Write-Host "Next step:   See AI_HANDOFF.md for details."
        } else {
            Write-Host "Reason:      State '$State' is not eligible for $CommandLabel in this version."
            Write-Host "Stop category: Non-callable Actor (this turn type is not automatable in this version)."
        }
        Write-Host ""
        exit 1
    }

    # Turn ownership: Waiting For must indicate the Implementer's turn (role name or resolved tool)
    if ($WaitingFor -ne "Implementer" -and $WaitingFor -ne $implementerTool) {
        Write-Host ""
        Write-Host "${CommandLabel}: blocked."
        Write-Host "State:       $State"
        Write-Host "Waiting For: $WaitingFor"
        Write-Host "Reason:      Turn ownership mismatch. State $State expects the Implementer's turn ($implementerTool), but Waiting For is '$WaitingFor'."
        Write-Host "Stop category: Protocol Repair - a correction, not a product decision."
        Write-Host "Next step:   Correct Waiting For in AI_HANDOFF.md to Implementer, or re-route via the Master."
        Write-Host ""
        exit 1
    }

    if (-not $turnAdapter.Callable) {
        Write-Host ""
        Write-Host "${CommandLabel}: blocked."
        Write-Host "State:       $State"
        Write-Host "Implementer: $implementerTool"
        Write-Host "Reason:      $($turnAdapter.Reason)"
        Write-Host "Stop category: $($turnAdapter.StopCategory) (automation limitation) - not a user decision."
        Write-Host "Next step:   Run 'handoff.ps1 next' then paste the prompt into $implementerTool."
        Write-Host ""
        exit 1
    }

    # Role invariant: the Reviewer must never be the same tool as the Implementer.
    # An implementer cannot be the sole reviewer of its own work.
    if ($Binding.Reviewer -eq $implementerTool) {
        Write-Host ""
        Write-Host "${CommandLabel}: blocked."
        Write-Host "Reviewer:    $($Binding.Reviewer)"
        Write-Host "Implementer: $implementerTool"
        Write-Host "Reason:      Role invariant violation. The Reviewer must not be the same tool as the Implementer."
        Write-Host "Stop category: Protocol Repair (the role binding contradicts the invariant) - a correction, not a product decision."
        Write-Host "Next step:   Fix the binding in .ai/roles/ROLE_ASSIGNMENT.md so Reviewer and Implementer are different tools."
        Write-Host ""
        exit 1
    }

    # Guard: block if any working tree changes exist (tracked or untracked).
    # Only the local handoff files are exempt - they are expected to change between turns.
    $tree = Get-WorkingTreeState

    if (-not $tree.Ok) {
        Write-Host ""
        Write-Host "${CommandLabel}: blocked."
        Write-Host "Could not determine Git working tree state."
        Write-Host "Ensure you are in a Git repository and git is available, then try again."
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Write-Host ""
        exit 1
    }

    if ($tree.Files.Count -gt 0) {
        Write-Host ""
        Write-Host "${CommandLabel}: blocked."
        Write-Host "Working tree is not clean."
        Write-Host ""
        Write-Host "Changed files (tracked and untracked; local handoff files excluded):"
        foreach ($f in $tree.Files) { Write-Host "  $f" }
        Write-Host ""
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Write-Host "Commit, stash, revert, or remove these files before running $CommandLabel."
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
    Write-Host "Adapter:      callable via ADAPTERS.md contract"
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
    if (-not (Test-ClaudeAvailable)) {
        Write-Host "Claude Code is not available. Check network or install globally: npm install -g @anthropic-ai/claude-code"
        Write-Host "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
        exit 3
    }

    Write-Host ""
    Write-Host "Command: npx --yes @anthropic-ai/claude-code -p `"<prompt>`" --permission-mode acceptEdits --disallowed-tools `"Bash`" --max-budget-usd $BudgetUsd --no-session-persistence"
    Write-Host ""
    Write-Host "WARNING: This state allows source file edits. Claude Code may modify approved source files."
    Write-Host "         This tool does not commit, push, or deploy automatically."
    Write-Host ""
    # Fail closed: only an explicit, non-null "yes" proceeds. Null (EOF, redirected
    # no-input, non-interactive), empty, whitespace, or anything else cancels.
    $confirm = Read-Host 'Type "yes" to proceed, or press Enter to cancel'
    if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
        Write-Host "Cancelled."
        exit 2
    }

    Write-Host ""
    Write-Host "Running Claude Code assisted turn..."
    Write-Host ""

    $claudeExit = Invoke-ClaudeTurn

    Write-Host ""
    if ($claudeExit -eq 0) {
        Write-Host "Claude Code turn complete (exit 0)."
        Write-Host "Tests and lint were not run - execute them manually before committing."
        Write-Host ""

        # Re-read AI_HANDOFF.md to get post-turn state (pre-run values are stale)
        $script:Lines       = Get-Content -Path $HandoffFile
        $freshStatus        = Read-HandoffState -Lines $script:Lines
        $script:State       = $freshStatus.State
        $script:WaitingFor  = $freshStatus.WaitingFor
        $script:CurrentTask = $freshStatus.CurrentTask

        # Refresh NEXT_TURN.md with the updated state. Fail closed: do not print
        # Reviewer handoff instructions for a NEXT_TURN.md that was never written.
        try {
            Invoke-Next -Silent $true
        } catch {
            Write-Host "Failed to refresh NEXT_TURN.md: $_"
            Write-Host "Stop category: Environment/Preflight - not a user decision."
            Write-Host "The Implementer turn completed, but the next-turn handoff could not be generated."
            Write-Host "Inspect AI_HANDOFF.md manually before continuing."
            exit 4
        }

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
            Write-Host "Stop category: Non-callable Actor ($reviewerTool has no callable adapter) - next step is an Operator Manual Action: paste into $reviewerTool."
            Write-Host "$CommandLabel stops here - one Implementer turn per invocation."
        } elseif ($script:State -eq "READY_FOR_REVIEW") {
            Write-Host "Post-turn handoff mismatch detected."
            Write-Host "State:       $($script:State)"
            Write-Host "Waiting For: $($script:WaitingFor)"
            Write-Host "Expected:    Reviewer ($reviewerTool)"
            Write-Host "NEXT_TURN.md updated for User mismatch resolution."
            Write-Host "Stop category: Protocol Repair - a correction, not a product decision."
            Write-Host "Do not continue to a review turn or commit until AI_HANDOFF.md is corrected."
            Write-Host "$CommandLabel stops here - one Implementer turn per invocation."
            Write-Host ""
            exit 6
        } elseif ($ActionMap.ContainsKey($script:State)) {
            $nextRole = $ActionMap[$script:State].Role
            $nextTool = Resolve-Actor -Role $nextRole -Binding $Binding
            $postMismatch = ($script:WaitingFor -ne "(unknown)") -and
                ($script:WaitingFor -ne $nextRole) -and ($script:WaitingFor -ne $nextTool)
            Write-Host "State is now: $($script:State) (Waiting For: $($script:WaitingFor))"
            if ($postMismatch) {
                Write-Host "WARNING: State $($script:State) expects Waiting For: $nextRole ($nextTool), but found: $($script:WaitingFor)."
                Write-Host "NEXT_TURN.md routed to User for mismatch resolution."
                Write-Host "Stop category: Protocol Repair - a correction, not a product decision."
                Write-Host "$CommandLabel stops here - one Implementer turn per invocation."
                Write-Host ""
                exit 6
            }
            Write-Host "Next actor: $nextTool ($nextRole)"
            Write-Host (Get-StopCategoryLine -ForState $script:State -ActorTool $nextTool -Automation $true)
            Write-Host "NEXT_TURN.md refreshed. $CommandLabel stops here - one Implementer turn per invocation."
        } else {
            Write-Host "WARNING: Unrecognized post-turn state: $($script:State)."
            Write-Host "NEXT_TURN.md was not refreshed for this state. Inspect AI_HANDOFF.md manually before continuing."
            Write-Host "Stop category: Protocol Repair (unrecognized state) - a correction, not a product decision."
            Write-Host "$CommandLabel stops here - one Implementer turn per invocation."
            Write-Host ""
            exit 6
        }
    } else {
        Write-Host "Claude Code exited with error (code: $claudeExit)."
        Write-Host "AI_HANDOFF.md may be incomplete. Verify manually."
        exit 5
    }
    Write-Host ""
}

# Bounded loop skeleton (v0.17.0). Runs automated turns until a hard stop.
# Only callable turn: READY_FOR_IMPLEMENTATION / Implementer bound to Claude Code.
# Master, Reviewer, and User turns are never automated - the loop prepares
# NEXT_TURN.md, prints the next actor, and stops.
function Invoke-Loop {
    # --- Validate arguments ---
    if ($MaxTurns -lt 1) {
        Write-Host ""
        Write-Host "loop: blocked."
        Write-Host "Reason:      -MaxTurns must be at least 1 (got: $MaxTurns)."
        Write-Host ""
        exit 1
    }
    if ($BudgetUsd -le 0) {
        Write-Host ""
        Write-Host "loop: blocked."
        Write-Host "Reason:      -BudgetUsd must be greater than 0 (got: $BudgetUsd)."
        Write-Host ""
        exit 1
    }
    if ($SessionBudgetUsd -lt $BudgetUsd) {
        Write-Host ""
        Write-Host "loop: blocked."
        Write-Host "Reason:      -SessionBudgetUsd ($SessionBudgetUsd) must be at least -BudgetUsd ($BudgetUsd)."
        Write-Host ""
        exit 1
    }

    # --- Session preflight: role invariant ---
    if ($Binding.Reviewer -eq $Binding.Implementer) {
        Write-Host ""
        Write-Host "loop: blocked."
        Write-Host "Reviewer:    $($Binding.Reviewer)"
        Write-Host "Implementer: $($Binding.Implementer)"
        Write-Host "Reason:      Role invariant violation. The Reviewer must not be the same tool as the Implementer."
        Write-Host "Stop category: Protocol Repair (the role binding contradicts the invariant) - a correction, not a product decision."
        Write-Host "Next step:   Fix the binding in .ai/roles/ROLE_ASSIGNMENT.md so Reviewer and Implementer are different tools."
        Write-Host ""
        exit 1
    }

    # --- Session preflight: clean working tree ---
    $tree = Get-WorkingTreeState
    if (-not $tree.Ok) {
        Write-Host ""
        Write-Host "loop: blocked."
        Write-Host "Could not determine Git working tree state."
        Write-Host "Ensure you are in a Git repository and git is available, then try again."
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Write-Host ""
        exit 1
    }
    if ($tree.Files.Count -gt 0) {
        Write-Host ""
        Write-Host "loop: blocked."
        Write-Host "Working tree is not clean."
        Write-Host ""
        Write-Host "Changed files (tracked and untracked; local handoff files excluded):"
        foreach ($f in $tree.Files) { Write-Host "  $f" }
        Write-Host ""
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Write-Host "Commit, stash, revert, or remove these files before running loop."
        Write-Host ""
        exit 1
    }

    # --- Budget info + single session confirmation ---
    $worstCase = [Math]::Min($MaxTurns * $BudgetUsd, $SessionBudgetUsd)
    Write-Host ""
    Write-Host "Preparing bounded loop session..."
    Write-Host ""
    Write-Host "Max turns:          $MaxTurns"
    Write-Host "Per-turn budget:    `$$BudgetUsd (passed to --max-budget-usd)"
    Write-Host "Session budget cap: `$$SessionBudgetUsd (worst-case authorized spend this session: `$$worstCase)"
    Write-Host "Callable turns:     Resolved through ADAPTERS.md; currently READY_FOR_IMPLEMENTATION only when Implementer is Claude Code."
    Write-Host "Never automated:    Master turns, Reviewer turns, User turns, commit/push/tag/deploy."
    Write-Host ""
    Write-Host "WARNING: Automated turns allow source file edits (Bash disallowed during turns)."
    Write-Host ""
    # Fail closed: only an explicit, non-null "yes" starts the session.
    $confirm = Read-Host 'Type "yes" to start the loop session, or press Enter to cancel'
    if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
        Write-Host "Cancelled."
        exit 2
    }

    Write-LoopLog "=== session start MaxTurns=$MaxTurns BudgetUsd=$BudgetUsd SessionBudgetUsd=$SessionBudgetUsd"

    $authorized = [decimal]0
    $turnsRun   = 0
    $ntPath     = Join-Path (Get-Location) "NEXT_TURN.md"

    while ($true) {
        # Re-read handoff state and role binding every iteration
        $script:Lines       = Get-Content -Path $HandoffFile
        $freshStatus        = Read-HandoffState -Lines $script:Lines
        $script:State       = $freshStatus.State
        $script:WaitingFor  = $freshStatus.WaitingFor
        $script:CurrentTask = $freshStatus.CurrentTask
        $script:Binding     = Get-RoleBinding

        $entry = $ActionMap[$script:State]
        if (-not $entry) {
            Write-Host ""
            Write-Host "loop: stop - unrecognized state: $($script:State)."
            Write-Host "NEXT_TURN.md was not refreshed for this state. Inspect AI_HANDOFF.md manually before continuing."
            Write-Host "Stop category: Protocol Repair (unrecognized state) - a correction, not a product decision."
            Write-LoopLog "turn=$turnsRun stop reason=unrecognized-state state=$($script:State) exit=6"
            Write-Host ""
            exit 6
        }
        $role = $entry.Role
        $tool = Resolve-Actor -Role $role -Binding $Binding

        # Turn-ownership mismatch routes to User (same rule as next/cycle)
        if (($script:WaitingFor -ne "(unknown)") -and ($script:WaitingFor -ne $role) -and ($script:WaitingFor -ne $tool)) {
            try {
                Invoke-Next -Silent $true
            } catch {
                Write-Host "Failed to refresh NEXT_TURN.md: $_"
            Write-Host "Stop category: Environment/Preflight - not a user decision."
                Write-LoopLog "turn=$turnsRun stop reason=next-turn-refresh-failed exit=4"
                exit 4
            }
            Write-Host ""
            Write-Host "loop: stop - handoff mismatch."
            Write-Host "State $($script:State) expects Waiting For: $role ($tool), but found: $($script:WaitingFor)."
            Write-Host "NEXT_TURN.md routed to User for mismatch resolution."
            Write-Host "Stop category: Protocol Repair - a correction, not a product decision."
            Write-LoopLog "turn=$turnsRun stop reason=mismatch state=$($script:State) waitingFor=$($script:WaitingFor) expected=$role/$tool exit=6"
            Write-Host ""
            exit 6
        }

        $turnAdapter = Resolve-TurnAdapter -ForState $script:State -Role $role -Tool $tool
        $callable = $turnAdapter.Callable

        if (-not $callable) {
            try {
                Invoke-Next -Silent $true
            } catch {
                Write-Host "Failed to refresh NEXT_TURN.md: $_"
            Write-Host "Stop category: Environment/Preflight - not a user decision."
                Write-LoopLog "turn=$turnsRun stop reason=next-turn-refresh-failed exit=4"
                exit 4
            }
            Write-Host ""
            Write-Host "loop: stop - next actor is not callable."
            Write-Host "State:      $($script:State)"
            Write-Host "Next actor: $tool ($role)"
            if ($tool -eq "User") {
                Write-Host (Get-StopCategoryLine -ForState $script:State -ActorTool $tool -Automation $true)
            } else {
                Write-Host "Reason:     $($turnAdapter.Reason)"
                Write-Host "Stop category: $($turnAdapter.StopCategory) (automation limitation) - next step is an Operator Manual Action."
            }
            if ($tool -ne "User") {
                Write-Host "Paste:      Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
            }
            Write-Host "Turns run:  $turnsRun  (authorized spend cap used: `$$authorized of `$$SessionBudgetUsd)"
            Write-LoopLog "turn=$turnsRun stop reason=not-callable state=$($script:State) nextActor=$tool($role) exit=0"
            Write-Host ""
            exit 0
        }

        # Hard caps before another automated turn
        if ($turnsRun -ge $MaxTurns) {
            Write-Host ""
            Write-Host "loop: stop - MaxTurns ($MaxTurns) reached."
            Write-Host "Stop category: Operator Manual Action - re-run loop to continue if desired; no user decision required."
            Write-Host "Turns run:  $turnsRun  (authorized spend cap used: `$$authorized of `$$SessionBudgetUsd)"
            Write-LoopLog "turn=$turnsRun stop reason=max-turns exit=0"
            Write-Host ""
            exit 0
        }
        if (($authorized + $BudgetUsd) -gt $SessionBudgetUsd) {
            Write-Host ""
            Write-Host "loop: stop - session budget cap reached."
            Write-Host "Stop category: Operator Manual Action - re-run loop (optionally with a higher -SessionBudgetUsd) to continue; no user decision required."
            Write-Host "Authorized so far: `$$authorized. Next turn would authorize `$$BudgetUsd more, exceeding `$$SessionBudgetUsd."
            Write-LoopLog "turn=$turnsRun stop reason=session-budget authorized=$authorized exit=0"
            Write-Host ""
            exit 0
        }

        # Per-turn re-checks: the binding or the tree may have changed since the session started
        if ($script:Binding.Reviewer -eq $script:Binding.Implementer) {
            Write-Host ""
            Write-Host "loop: blocked."
            Write-Host "Reason:      Role invariant violation detected mid-session (Reviewer == Implementer)."
            Write-Host "Next step:   Fix the binding in .ai/roles/ROLE_ASSIGNMENT.md so Reviewer and Implementer are different tools."
            Write-LoopLog "turn=$turnsRun stop reason=role-invariant exit=1"
            Write-Host ""
            exit 1
        }
        $tree = Get-WorkingTreeState
        if (-not $tree.Ok -or $tree.Files.Count -gt 0) {
            Write-Host ""
            Write-Host "loop: blocked."
            Write-Host "Working tree is not clean (or git is unavailable)."
            foreach ($f in $tree.Files) { Write-Host "  $f" }
            Write-Host "Stop category: Environment/Preflight - not a user decision."
            Write-Host "Commit, stash, revert, or remove these files before continuing the loop."
            Write-LoopLog "turn=$turnsRun stop reason=dirty-tree exit=1"
            Write-Host ""
            exit 1
        }

        # Refresh NEXT_TURN.md for the automated turn
        try {
            Invoke-Next -Silent $true
        } catch {
            Write-Host "Failed to refresh NEXT_TURN.md: $_"
            Write-Host "Stop category: Environment/Preflight - not a user decision."
            Write-LoopLog "turn=$turnsRun stop reason=next-turn-refresh-failed exit=4"
            exit 4
        }
        if (-not (Test-Path $ntPath)) {
            Write-Host "NEXT_TURN.md was not created. Aborting."
            Write-LoopLog "turn=$turnsRun stop reason=next-turn-missing exit=4"
            exit 4
        }

        # Preflight: Claude Code availability
        if (-not (Test-ClaudeAvailable)) {
            Write-Host "Claude Code is not available. Check network or install globally: npm install -g @anthropic-ai/claude-code"
        Write-Host "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
            Write-LoopLog "turn=$turnsRun stop reason=claude-unavailable exit=3"
            exit 3
        }

        # Run one automated Implementer turn
        $turnNo = $turnsRun + 1
        Write-Host ""
        Write-Host "loop: turn $turnNo of $MaxTurns - automated Claude Code Implementer turn (per-turn budget `$$BudgetUsd)..."
        Write-LoopLog "turn=$turnNo action=automated-claude-turn preState=$($script:State) preWaitingFor=$($script:WaitingFor) actor=Claude Code(Implementer) budget=$BudgetUsd"
        $authorized += $BudgetUsd
        $turnsRun    = $turnNo

        $claudeExit = Invoke-ClaudeTurn
        Write-LoopLog "turn=$turnNo claudeExit=$claudeExit authorizedSoFar=$authorized"

        if ($claudeExit -ne 0) {
            Write-Host "Claude Code exited with error (code: $claudeExit)."
            Write-Host "AI_HANDOFF.md may be incomplete. Verify manually."
            Write-LoopLog "turn=$turnNo stop reason=claude-error exit=5"
            exit 5
        }

        # Log the post-turn state; the next iteration re-reads and routes it
        $postStatus = Read-HandoffState -Lines (Get-Content -Path $HandoffFile)
        Write-LoopLog "turn=$turnNo post state=$($postStatus.State) waitingFor=$($postStatus.WaitingFor)"
    }
}

# --- Dispatch ---

switch ($Command) {
    "status"       { Invoke-Status }
    "adapters"     { Invoke-Adapters }
    "next"         { Invoke-Next }
    "start"        { Invoke-Start -Request $Request }
    "commit-check" { Invoke-CommitCheck }
    "release-check" { Invoke-ReleaseCheck }
    "release"      { Invoke-Release }
    "sequence-check"   { Invoke-SequenceCheck }
    "sequence-advance" { Invoke-SequenceAdvance }
    "review-check" { Invoke-ReviewCheck }
    "review-run"   { Invoke-ReviewRun }
    "cycle"        { Invoke-Cycle }
    "run-next"     { Invoke-Cycle -CommandLabel "run-next" }
    "loop"         { Invoke-Loop }
    default {
        if ([string]::IsNullOrWhiteSpace($Command)) {
            Invoke-Menu
        } else {
            Write-Host ""
            Write-Host "Usage: handoff.ps1 <command> [options]"
            Write-Host ""
            Write-Host "Commands:"
            Write-Host "  status                    Show current handoff state, role binding, and commit status."
            Write-Host "  adapters                  Show adapter callable/manual status for each role."
            Write-Host "  next [-Clip]              Generate NEXT_TURN.md and print the paste instruction."
            Write-Host '  start "<request>" [-Clip]  Save request and print a Master entry prompt.'
            Write-Host "  commit-check              Show whether a commit is allowed and what to commit."
            Write-Host "  release-check -Version vX.Y.Z"
            Write-Host "                            Dry-run the guarded release plan. Never mutates git."
            Write-Host "  release -Version vX.Y.Z -Message `"<msg>`" -Authorize `"I_AUTHORIZE_RELEASE_vX.Y.Z`""
            Write-Host "                            Run the authorized release executor after REVIEW_DONE."
            Write-Host "  sequence-check -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z [-NextTask `"<task>`"]"
            Write-Host "                            Dry-run the local sequence advance. Edits no files."
            Write-Host "  sequence-advance -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z -NextTask `"<task>`" [-SupersededVersions `"vA.B.C`"]"
            Write-Host "                            Advance local AI_SEQUENCE.md/AI_HANDOFF.md after a release. Never runs git."
            Write-Host "  review-check              Dry-run the Codex Reviewer POC plan for READY_FOR_REVIEW. Mutates nothing."
            Write-Host "  review-run [-TimeoutSeconds N] [-Yes]"
            Write-Host "                            Run a read-only Codex review (explicit confirmation, or -Yes for automation) and capture output locally. Bounded by -TimeoutSeconds (default 180): on timeout it kills Codex, keeps partial JSONL, writes no verdict, exits 4; fails closed (exit 6) if Codex exits 0 without a captured verdict. Never runs git or changes AI_HANDOFF.md."
            Write-Host "  cycle [-BudgetUsd N]      Run one bounded handoff cycle for a callable adapter turn, then prepare the next handoff."
            Write-Host "  run-next [-BudgetUsd N]   Alias of cycle (kept for backward compatibility)."
            Write-Host "  loop [-MaxTurns N] [-BudgetUsd N] [-SessionBudgetUsd N]"
            Write-Host "                            Run a bounded loop of callable adapter turns; stops at any non-callable actor or hard stop. Writes HANDOFF_LOOP.log."
            Write-Host ""
        }
    }
}
