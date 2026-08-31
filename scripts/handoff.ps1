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
    [string]$ModelProfile,
    [string]$Model,
    [int]$TimeoutSeconds = 180,
    [switch]$Yes,
    [switch]$IncludeMaster,
    [switch]$IncludeReviewer,
    [switch]$Clip,
    [switch]$CopyPrompt,  # backward-compatible alias for -Clip
    [switch]$CheckUpdates,
    [switch]$AllowModelEscalation,
    [switch]$Activate,
    [string]$Standard,
    [string]$CheapReadonly,
    [string]$Economy,
    [string]$HighReasoning,
    [decimal]$BudgetUsd = 2,
    [int]$MaxTurns = 3,
    [decimal]$SessionBudgetUsd = 6
)

if ($CopyPrompt) { $Clip = $true }

# Some Windows hosts can expose both Path and PATH in the process environment. PowerShell's
# Start-Process fails before launching children when those case-only duplicates exist.
if ($env:OS -eq "Windows_NT") {
    $pathValue = $env:Path
    if ([string]::IsNullOrEmpty($pathValue)) { $pathValue = $env:PATH }
    [System.Environment]::SetEnvironmentVariable("PATH", $null, "Process")
    if (-not [string]::IsNullOrEmpty($pathValue)) {
        [System.Environment]::SetEnvironmentVariable("Path", $pathValue, "Process")
    }
}

$HandoffFile = Join-Path (Get-Location) "AI_HANDOFF.md"

if (-not (Test-Path $HandoffFile) -and $Command -ne "doctor") {
    Write-Host "No AI_HANDOFF.md found. Run from your project root."
    exit 1
}

$Lines = @()
if (Test-Path $HandoffFile) {
    $Lines = Get-Content -Path $HandoffFile
}

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
    $status = @{ State = "(unknown)"; WaitingFor = "(unknown)"; CurrentTask = "(unknown)"; ModelProfile = "auto" }
    foreach ($line in (Get-SectionLines -Lines $Lines -Heading "Status")) {
        if ($line -match "^- State:\s*(.+)")        { $status.State       = $Matches[1].Trim() }
        if ($line -match "^- Waiting For:\s*(.+)")  { $status.WaitingFor  = $Matches[1].Trim() }
        if ($line -match "^- Current Task:\s*(.+)") { $status.CurrentTask = $Matches[1].Trim() }
        if ($line -match "^- Model Profile:\s*(.+)") { $status.ModelProfile = $Matches[1].Trim() }
    }
    if ($StateAlias.ContainsKey($status.State)) { $status.State = $StateAlias[$status.State] }
    return $status
}

# --- Dynamic model routing ---

$ModelRoutingFile = Join-Path (Get-Location) ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json"
$ValidModelProfiles = @("auto", "inherit", "economy", "cheap_readonly", "standard", "high_reasoning", "explicit_user_choice")

function Normalize-ModelProfile {
    param([string]$Value)
    $normalized = if ([string]::IsNullOrWhiteSpace($Value)) { "auto" } else { $Value.Trim().ToLowerInvariant() }
    switch ($normalized) {
        "economical" { return "economy" }
        "cheap" { return "economy" }
        "readonly" { return "cheap_readonly" }
        "deep_reasoning" { return "high_reasoning" }
        "strongest_available" { return "high_reasoning" }
        default { return $normalized }
    }
}

function Test-SafeModelValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match "^[A-Za-z0-9][A-Za-z0-9._:/@-]*$")
}

function Resolve-ModelSelection {
    param(
        [string]$ForState,
        [string]$HandoffProfile,
        [string]$CommandProfile,
        [string]$CommandModel
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $requested = if (-not [string]::IsNullOrWhiteSpace($CommandProfile)) {
        Normalize-ModelProfile -Value $CommandProfile
    } else {
        Normalize-ModelProfile -Value $HandoffProfile
    }

    if (-not [string]::IsNullOrWhiteSpace($CommandModel)) {
        $requested = "explicit_user_choice"
    }
    if ($ValidModelProfiles -notcontains $requested) {
        $errors.Add("Unknown model profile '$requested'. Valid profiles: $($ValidModelProfiles -join ', ').")
    }

    $effective = $requested
    if ($effective -eq "auto") {
        $effective = if ($ForState -eq "NEEDS_INVESTIGATION") { "cheap_readonly" } else { "standard" }
    }

    $resolvedModel = "inherit"
    $source = "built-in fallback"
    $config = $null
    if (Test-Path -LiteralPath $ModelRoutingFile) {
        try {
            $config = Get-Content -Raw -LiteralPath $ModelRoutingFile | ConvertFrom-Json -ErrorAction Stop
            if ($config.schemaVersion -ne 1) {
                $errors.Add("MODEL_ROUTING.json schemaVersion must be 1.")
            }
        } catch {
            $errors.Add("MODEL_ROUTING.json is invalid JSON: $($_.Exception.Message)")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CommandModel)) {
        $resolvedModel = $CommandModel.Trim()
        $source = "command line -Model"
    } else {
        $envName = "HANDOFF_CLAUDE_MODEL_" + $effective.ToUpperInvariant()
        $envValue = [System.Environment]::GetEnvironmentVariable($envName, "Process")
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            $resolvedModel = $envValue.Trim()
            $source = "environment $envName"
        } elseif ($null -ne $config -and $null -ne $config.profiles) {
            $profileConfig = $config.profiles.PSObject.Properties[$effective]
            if ($null -ne $profileConfig -and $null -ne $profileConfig.Value.claudeModel) {
                $candidate = [string]$profileConfig.Value.claudeModel
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $resolvedModel = $candidate.Trim()
                    $source = "MODEL_ROUTING.json"
                }
            }
        }
    }

    if ($resolvedModel -eq "default") { $resolvedModel = "inherit" }
    if ($resolvedModel -ne "inherit" -and -not (Test-SafeModelValue -Value $resolvedModel)) {
        $errors.Add("Resolved model value must be a single model identifier using letters, digits, dot, underscore, colon, slash, at-sign, or hyphen.")
    }

    $needsEscalationApproval = ($effective -eq "high_reasoning" -and $resolvedModel -ne "inherit")
    return @{
        Ok = ($errors.Count -eq 0)
        Errors = $errors
        RequestedProfile = $requested
        EffectiveProfile = $effective
        ClaudeModel = $resolvedModel
        Source = $source
        UsesConcreteModel = ($resolvedModel -ne "inherit")
        NeedsEscalationApproval = $needsEscalationApproval
    }
}

# --- Canonical tool identity (v3.4.1) ---
#
# Role gates must compare tool IDENTITY, never display text. Before v3.4.1 the
# invariant checks used raw string equality, so 'Codex' and 'Codex Window' read as
# two different tools and one tool could implement and review the same task.
#
# Every legal tool has one canonical id, one display name, and an explicit alias
# list. An identity that is not in the registry is REJECTED, never guessed: an
# unrecognized actor must fail closed rather than silently satisfy an invariant.

$CanonicalToolRegistry = @(
    @{
        Canonical = "codex"
        Display   = "Codex"
        Aliases   = @("codex", "codex window", "codex cli", "codex desktop", "openai codex")
    },
    @{
        Canonical = "claude-code"
        Display   = "Claude Code"
        Aliases   = @("claude code", "claude-code", "claudecode", "claude code cli", "claude code window")
    }
)

# Sentinels are not tools. They are legal placeholders for a freshly opened task
# whose actors are not bound yet, and they never satisfy or violate the
# Reviewer != Implementer invariant.
$ToolIdentitySentinels = @("tbd", "(unknown)", "unknown")

function Resolve-ToolIdentity {
    param([string]$Tool)

    $raw = if ($null -eq $Tool) { "" } else { $Tool.Trim() }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{
            Ok = $false; Kind = "empty"; Canonical = ""; Display = ""; Input = $raw
            Reason = "No tool identity was supplied."
        }
    }

    $key = $raw.ToLowerInvariant()

    if ($ToolIdentitySentinels -contains $key) {
        return @{
            Ok = $true; Kind = "sentinel"; Canonical = ""; Display = $raw; Input = $raw
            Reason = "Placeholder actor; not bound to a tool yet."
        }
    }

    if ($key -eq "user") {
        return @{
            Ok = $true; Kind = "user"; Canonical = "user"; Display = "User"; Input = $raw
            Reason = "The User is the approval authority and is never a tool role."
        }
    }

    foreach ($entry in $CanonicalToolRegistry) {
        if ($entry.Aliases -contains $key) {
            return @{
                Ok = $true; Kind = "tool"; Canonical = $entry.Canonical; Display = $entry.Display; Input = $raw
                Reason = ""
            }
        }
    }

    $known = ($CanonicalToolRegistry | ForEach-Object { $_.Display }) -join ", "
    return @{
        Ok = $false; Kind = "unknown"; Canonical = ""; Display = $raw; Input = $raw
        Reason = "Unrecognized tool identity '$raw'. Known tools: $known. Add an explicit alias to the canonical registry rather than relying on a display name."
    }
}

# True only when both values resolve to the SAME real tool. Sentinels, empty
# values and unresolvable identities never report a collision here; callers that
# must reject those cases check Resolve-ToolIdentity directly, so that an
# unknown identity fails closed on its own terms instead of masquerading as
# "not a collision".
function Test-SameToolIdentity {
    param([string]$First, [string]$Second)
    $a = Resolve-ToolIdentity -Tool $First
    $b = Resolve-ToolIdentity -Tool $Second
    if (-not $a.Ok -or -not $b.Ok) { return $false }
    if ($a.Kind -ne "tool" -or $b.Kind -ne "tool") { return $false }
    return ($a.Canonical -eq $b.Canonical)
}

# --- Git ignore semantics (v3.4.1) ---
#
# Ask Git whether a path is ignored. Hand-parsing .gitignore text cannot know
# about anchoring, negation, directory rules or precedence, and getting any of
# them wrong produces a warning the user learns to dismiss.
#
# Unresolvable answers report "not ignored" on purpose: warning when we cannot
# tell is the safe direction for a file that must never be committed.
function Test-PathIgnoredByGit {
    param([string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    try {
        & git check-ignore -q -- $RelativePath *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# --- Handoff history: archive before reset (v3.4.1) ---
#
# AI_HANDOFF.md is gitignored, so the record of who implemented a task, who
# reviewed it, and what was approved lives on exactly one disk and in exactly one
# file. Until v3.4.1 `start` overwrote it, and that record was simply gone.
#
# The archive lives in a VISIBLE project-local directory rather than inside .git:
# an audit trail hidden in .git is the most deletable thing in the repository, and
# it survives neither a fresh clone nor a .git cleanup.
#
# Every archive is verified by re-reading the written bytes and comparing hashes.
# A failed archive must leave the live handoff untouched: losing history silently
# is worse than refusing to start a new task.

$HandoffHistoryRelative = ".ai/handoff-history"

function Save-HandoffArchive {
    param(
        [string]$HandoffPath,
        [string]$Label = "handoff"
    )

    $result = @{ Ok = $false; Path = ""; Hash = ""; Error = "" }

    if (-not (Test-Path -LiteralPath $HandoffPath)) {
        $result.Error = "No handoff file to archive at '$HandoffPath'."
        return $result
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($HandoffPath)
        $sourceHash = (Get-FileHash -LiteralPath $HandoffPath -Algorithm SHA256).Hash

        $historyDir = Join-Path (Get-Location) $HandoffHistoryRelative
        if (-not (Test-Path -LiteralPath $historyDir)) {
            New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
        }

        $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmssZ")
        $slug = ($Label -replace '[^A-Za-z0-9]+', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "handoff" }
        if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).Trim('-') }

        # Collision-safe: two archives inside the same second must not overwrite
        # each other, which would defeat the entire point of archiving.
        $base = "$stamp-$slug"
        $target = Join-Path $historyDir "$base-AI_HANDOFF.md"
        $n = 2
        while (Test-Path -LiteralPath $target) {
            $target = Join-Path $historyDir "$base-$n-AI_HANDOFF.md"
            $n++
        }

        $temp = "$target.tmp"
        [System.IO.File]::WriteAllBytes($temp, $bytes)
        Move-Item -LiteralPath $temp -Destination $target -Force

        $archiveHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($archiveHash -ne $sourceHash) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            $result.Error = "Archive verification failed: written bytes do not match the source hash."
            return $result
        }

        # Sidecar metadata so the archive is interpretable without the live file.
        $commit = "(unknown)"
        try {
            $rev = & git rev-parse --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $rev) { $commit = "$rev".Trim() }
        } catch { }

        $actors = Get-TaskActors
        $meta = @(
            "archived-at-utc: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
            "sha256: $sourceHash",
            "bytes: $($bytes.Length)",
            "commit: $commit",
            "state: $State",
            "waiting-for: $WaitingFor",
            "current-task: $CurrentTask",
            "implementer: $($actors.Implementer)",
            "reviewer: $($actors.Reviewer)",
            "note: exact bytes of AI_HANDOFF.md at archive time; never edit this file."
        ) -join "`n"
        [System.IO.File]::WriteAllText("$target.meta.txt", $meta, (New-Object System.Text.UTF8Encoding($false)))

        $result.Ok = $true
        $result.Path = $target
        $result.Hash = $sourceHash
        return $result
    } catch {
        $result.Error = "$($_.Exception.Message)"
        return $result
    }
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

function Test-RoleCheckpoint {
    $errors = [System.Collections.Generic.List[string]]::new()
    $drifted = $false
    $driftErrors = 0

    # The bound identities must resolve before anything is compared. An
    # unrecognized tool in ROLE_ASSIGNMENT.md is rejected outright: guessing what
    # it means is exactly how one tool ends up reviewing its own work.
    foreach ($role in @('Implementer', 'Reviewer', 'Master')) {
        $bound = Resolve-ToolIdentity -Tool $Binding[$role]
        if (-not $bound.Ok) {
            $errors.Add("Invalid role binding: $role='$($Binding[$role])'. $($bound.Reason)")
        }
    }
    if (Test-SameToolIdentity -First $Binding.Reviewer -Second $Binding.Implementer) {
        $errors.Add("Invalid role binding: Reviewer and Implementer both resolve to the same tool ('$($Binding.Reviewer)' / '$($Binding.Implementer)'). An implementer cannot be the sole reviewer of its own work.")
    }

    $actors = @{ Implementer = ""; Reviewer = "" }
    foreach ($line in (Get-SectionLines -Lines $Lines -Heading "Task Actors")) {
        if ($line.Trim() -match '^[-*]\s*Implementer:\s*(.+)$') { $actors.Implementer = $Matches[1].Trim() }
        if ($line.Trim() -match '^[-*]\s*Reviewer:\s*(.+)$') { $actors.Reviewer = $Matches[1].Trim() }
    }
    foreach ($role in @('Implementer', 'Reviewer')) {
        $actual = $actors[$role]
        if ([string]::IsNullOrWhiteSpace($actual)) { continue }
        $resolved = Resolve-ToolIdentity -Tool $actual
        # A fresh task may carry a sentinel actor; it is not drift.
        if ($resolved.Ok -and $resolved.Kind -eq "sentinel") { continue }
        if (-not $resolved.Ok) {
            $errors.Add("Unrecognized Task Actors $role='$actual'. $($resolved.Reason)")
            continue
        }
        $expected = $Binding[$role]
        # Compare canonical identity, not display text, so a legacy alias such as
        # 'Codex Window' matches the bound 'Codex' instead of reading as drift.
        if (-not (Test-SameToolIdentity -First $actual -Second $expected)) {
            $drifted = $true
            $driftErrors++
            $errors.Add("Role drift: AI_HANDOFF.md Task Actors $role='$actual' but ROLE_ASSIGNMENT.md binds $role='$expected'.")
        }
    }

    # The actual actors must also be two different tools, even when both match the
    # binding, because the binding itself can be edited between turns.
    if (Test-SameToolIdentity -First $actors.Implementer -Second $actors.Reviewer) {
        $errors.Add("Independent-review invariant: Task Actors Implementer='$($actors.Implementer)' and Reviewer='$($actors.Reviewer)' resolve to the same tool.")
    }

    # DriftOnly means the ONLY problem is that Task Actors name different tools than
    # the binding. An unknown identity or a Reviewer/Implementer collision is never
    # drift-only, so neither can be waved through by the start recovery path.
    return @{
        Ok = ($errors.Count -eq 0)
        Errors = $errors
        Drifted = $drifted
        DriftOnly = ($drifted -and $driftErrors -eq $errors.Count)
    }
}

function Write-RoleCheckpointFailure {
    param([hashtable]$Checkpoint)
    Write-Host ""
    Write-Host "Role checkpoint: BLOCKED - the current role binding and AI_HANDOFF.md are out of sync."
    foreach ($error in $Checkpoint.Errors) { Write-Host "Reason: $error" }
    Write-Host ""
    Write-Host "Recovery:"
    if ($Checkpoint.Drifted) {
        # Before v3.4.1 this message told the user to synchronize the Task Actors by
        # hand. On a finished task that silently rewrites who implemented and who
        # reviewed it - the audit record the protocol exists to protect. The
        # supported route archives the finished record first and lets start reset
        # the actors itself.
        Write-Host "  If the drifted task is FINISHED (State REVIEW_DONE or BLOCKED, Waiting For: User)"
        Write-Host "  and the working tree is clean, retire it with a new request:"
        Write-Host ""
        Write-Host "      handoff.ps1 start `"<your next request>`""
        Write-Host ""
        Write-Host "  start archives the finished record to .ai/handoff-history/ with a verified"
        Write-Host "  hash, then opens a fresh task. It will refuse if the archive cannot be"
        Write-Host "  written, so the live handoff is never lost."
        Write-Host ""
        Write-Host "  If the drifted task is still ACTIVE, do NOT retire it. Finish or block the"
        Write-Host "  current turn first, or correct .ai/roles/ROLE_ASSIGNMENT.md so the binding"
        Write-Host "  matches the tools that actually did the work."
        Write-Host ""
        Write-Host "  Do not hand-edit Task Actors on a finished task. That rewrites the audit"
        Write-Host "  record instead of retiring it."
    } else {
        Write-Host "  Correct .ai/roles/ROLE_ASSIGNMENT.md. Reviewer and Implementer must be two"
        Write-Host "  different known tools, and every bound tool must be a recognized identity."
    }
    Write-Host ""
    Write-Host "No role-dependent action was performed."
}

# --- v3.5.0: captures are named after the ROLE, not the vendor ---
#
# These files used to be CODEX_REVIEW_LAST.md and CODEX_MASTER_LAST.md, which was
# accurate only while each role had exactly one possible tool. Roles are symmetric now -
# either tool may hold either role - so a vendor-named capture would lie as soon as the
# roles were swapped. The name states which role produced the file.
#
# Legacy vendor-named captures are still READ when no role-named file is present, so an
# install carrying captures written by an earlier version keeps working. New captures are
# always written under the role name.
# Local, gitignored, never committed.
$ReviewJsonlName = "REVIEW.jsonl"
$ReviewLastName  = "REVIEW_LAST.md"
$LegacyReviewJsonlName = "CODEX_REVIEW.jsonl"
$LegacyReviewLastName  = "CODEX_REVIEW_LAST.md"

$MasterJsonlName = "MASTER.jsonl"
$MasterLastName  = "MASTER_LAST.md"
$LegacyMasterJsonlName = "CODEX_MASTER.jsonl"
$LegacyMasterLastName  = "CODEX_MASTER_LAST.md"

# Local Implementer capture artifacts (v2.3.0/v2.4.0; renamed by role in v3.5.0).
# Either tool may now hold the Implementer role, so these are named after the role.
# Local, gitignored, never committed.
$ClaudeImplementerJsonlName = "IMPLEMENTER.jsonl"
$ClaudeImplementerLastName  = "IMPLEMENTER_LAST.md"
$ClaudeImplementerCommandName = "IMPLEMENTER_COMMAND.md"
$ImplementerJsonlName = $ClaudeImplementerJsonlName
$ImplementerLastName  = $ClaudeImplementerLastName
$LegacyImplementerJsonlName = "CLAUDE_IMPLEMENTER.jsonl"
$LegacyImplementerLastName  = "CLAUDE_IMPLEMENTER_LAST.md"
$LegacyImplementerCommandName = "CLAUDE_IMPLEMENTER_COMMAND.md"

# Marker written while an automated turn is in flight (v3.4.2). Local and gitignored.
$RunMarkerName = "HANDOFF_RUN.json"

# Local protocol files exempt from the clean-tree guard - they are expected to
# change between turns and must never be committed.
# v3.5.0: the legacy vendor-named captures stay on this list. They are still readable,
# so an install that carries them must not trip the clean-tree guard on their account.
$LocalHandoffFiles = @("AI_HANDOFF.md", "AI_SEQUENCE.md", "NEXT_TURN.md", "USER_REQUEST.md", "HANDOFF_LOOP.log", $RunMarkerName, $ReviewJsonlName, $ReviewLastName, $LegacyReviewJsonlName, $LegacyReviewLastName, $MasterJsonlName, $MasterLastName, $LegacyMasterJsonlName, $LegacyMasterLastName, $ClaudeImplementerJsonlName, $ClaudeImplementerLastName, $ClaudeImplementerCommandName, $LegacyImplementerJsonlName, $LegacyImplementerLastName, $LegacyImplementerCommandName)

# --- v3.5.0: permission follows the ROLE, not the tool ---
#
# Until v3.5.0 the permission a turn ran under was in practice a property of the vendor:
# Codex was always invoked read-only, because Codex only ever held Master or Reviewer,
# and Claude Code was always invoked write-enabled, because it only ever held
# Implementer. Nothing stated the rule; it was an accident of who sat where. That stays
# invisible until the roles are allowed to swap, at which point it silently hands a
# Reviewer write access purely because of which vendor filled the seat.
#
# The rule is stated once, here, and every adapter and every invocation reads it:
#   Master      -> read-only. It routes work; it must never edit what it routes.
#   Reviewer    -> read-only. It judges work; a reviewer that can edit is not independent.
#   Implementer -> write.     It is the only role that changes the repository.
# Whichever tool holds a role inherits the ROLE's permission, never its own.
function Get-RolePermission {
    param([string]$Role)
    switch ($Role) {
        "Master"      { return "read-only" }
        "Reviewer"    { return "read-only" }
        "Implementer" { return "write" }
        default       { return "read-only" }
    }
}

# Returns the capture path to READ for a role: the role-named file when it exists,
# otherwise a legacy vendor-named file that does, otherwise the role-named path (so the
# caller reports the current name when nothing has been captured at all).
function Resolve-CapturePath {
    param([string]$RepoRoot, [string]$Preferred, [string]$Legacy)
    $preferredPath = Join-Path $RepoRoot $Preferred
    if (Test-Path -LiteralPath $preferredPath) { return $preferredPath }
    $legacyPath = Join-Path $RepoRoot $Legacy
    if (Test-Path -LiteralPath $legacyPath) { return $legacyPath }
    return $preferredPath
}

# --- Exact-scope Git status capture (v3.4.1) ---
#
# The scope guards compare AI_HANDOFF.md Changed Files against what Git actually
# reports. Until v3.4.1 that comparison read `git status --short` and sliced the
# path with Substring(3). Two separate defects hid there:
#
#   1. With the default core.quotePath, Git QUOTES and octal-escapes any path
#      containing non-ASCII characters or spaces. A short Hebrew filename
#      "\327\236\327\241\327\236\327\232.md" - quotes and escapes included - which can
#      never equal a path a human wrote by hand. The comparison failed closed, so
#      commit-check and release-check were simply unusable in such a repository.
#
#   2. Even with -z (which suppresses quoting), `& git` decodes native output using
#      [Console]::OutputEncoding. Under a non-UTF-8 console - codepage 437 is the
#      Windows default - the same command yields mojibake. A -z-only fix passes every
#      test on a UTF-8 machine and silently corrupts non-ASCII paths for everyone
#      else: the identical failure class, one layer down.
#
# So the capture is explicit about BOTH: -z for the wire format, and an explicit
# UTF-8 decode that does not depend on the host console.
#
# Returns @{ Ok = capture succeeded; Fields = raw NUL-delimited fields }.
function Get-GitStatusFields {
    $result = @{ Ok = $false; Fields = @() }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "git"
        $psi.Arguments = "status --porcelain=v1 -z --untracked-files=all"
        $psi.WorkingDirectory = (Get-Location).Path
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Both redirected pipes must be drained CONCURRENTLY. Reading stdout to EOF
        # first would hang the moment git wrote enough to fill the stderr buffer:
        # git blocks on the unread stderr pipe, never closes stdout, and this process
        # waits forever - a hang, not a fail-closed result. Start stderr asynchronously
        # before the blocking stdout read so neither pipe can back up.
        $errTask = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $null = $errTask.GetAwaiter().GetResult()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return $result }

        $result.Ok = $true
        # A trailing NUL always produces one empty tail field; drop empties.
        $result.Fields = @($stdout -split "`0" | Where-Object { $_ -ne "" })
        return $result
    } catch {
        return $result
    }
}

# Walk the NUL-delimited fields into changed paths.
#
# Each entry field is "XY<space><path>". For a rename or copy (X or Y is R or C)
# the SOURCE path follows as its own bare field with no XY prefix, so it must be
# consumed and discarded - otherwise the pre-rename path is counted as an extra
# changed file. The pre-v3.4.1 " -> " regex is meaningless under -z.
#
# Paths are used exactly as Git spells them: forward slashes, no normalization.
# Changed Files must be authored the same way. Normalizing separators would be
# wrong on filesystems where a backslash is a legal filename character, and it
# would weaken the exact identity this guard exists to enforce.
function ConvertFrom-GitStatusFields {
    param([string[]]$Fields)
    $files = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $Fields.Count) {
        $entry = $Fields[$i]
        $i++
        if ($null -eq $entry -or $entry.Length -lt 4) { continue }
        $x = $entry.Substring(0, 1)
        $y = $entry.Substring(1, 1)
        $path = $entry.Substring(3)
        if (($x -eq "R") -or ($x -eq "C") -or ($y -eq "R") -or ($y -eq "C")) {
            $i++   # discard the source path field that follows
        }
        if ([string]::IsNullOrEmpty($path)) { continue }
        if ($LocalHandoffFiles -contains $path) { continue }
        $files.Add($path)
    }
    return $files
}

# Working tree state for the automation guards (cycle and loop).
# Returns @{ Ok = git check succeeded; Files = non-exempt changed files (tracked + untracked) }.
function Get-WorkingTreeState {
    $status = Get-GitStatusFields
    if (-not $status.Ok) { return @{ Ok = $false; Files = [System.Collections.Generic.List[string]]::new() } }
    return @{ Ok = $true; Files = (ConvertFrom-GitStatusFields -Fields $status.Fields) }
}

# --- v3.5.0: content-level read-only boundary ---
#
# A Reviewer legitimately runs on a DIRTY tree: the whole point of a code review is that
# the Implementer's changes are sitting there waiting to be judged. So "did the tree
# change" cannot be answered by comparing the set of changed FILE NAMES before and after
# the turn - a read-only turn that edits a file which was already dirty leaves that set
# identical and walks straight through. The reviewer could silently rewrite the very code
# it was reviewing, which is precisely the failure the independent-review invariant
# exists to prevent.
#
# So the boundary is taken at the level of CONTENT. Every file Git reports as changed,
# plus every local coordination file, is hashed before the turn and again after it. A
# differing hash, a vanished path, or a path that appeared are all changes.
#
# Fails closed: if the tree cannot be read or a file cannot be hashed, the snapshot is
# not Ok, and the caller must refuse the capture rather than accept an unverified one.
function Get-ReadOnlyBoundarySnapshot {
    param([string[]]$ExcludePaths = @())
    $result = @{ Ok = $false; Entries = @{} }
    $tree = Get-WorkingTreeState
    if (-not $tree.Ok) { return $result }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $tree.Files) { if (-not $paths.Contains($f)) { $paths.Add($f) } }
    # The local coordination files are excluded from the changed-file list by design, so
    # they must be added explicitly - a read-only turn must not rewrite AI_HANDOFF.md
    # either. review-run and master-run promise capture only.
    foreach ($local in $LocalHandoffFiles) { if (-not $paths.Contains($local)) { $paths.Add($local) } }

    $repoRoot = (Get-Location).Path
    $entries = @{}
    foreach ($p in $paths) {
        if ($ExcludePaths -contains $p) { continue }
        $full = Join-Path $repoRoot $p
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            try {
                $entries[$p] = (Get-FileHash -Algorithm SHA256 -LiteralPath $full -ErrorAction Stop).Hash
            } catch {
                return $result
            }
        } else {
            $entries[$p] = "<absent>"
        }
    }
    $result.Ok = $true
    $result.Entries = $entries
    return $result
}

# Names every path whose content, presence or absence differs between two snapshots.
function Compare-ReadOnlyBoundary {
    param([hashtable]$Before, [hashtable]$After)
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) { $changed.Add($key); continue }
        if ($After[$key] -cne $Before[$key]) { $changed.Add($key) }
    }
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) { $changed.Add($key) }
    }
    return @($changed | Sort-Object -Unique)
}

function Test-ClaudeAvailable {
    $null = npx --yes @anthropic-ai/claude-code --version 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Get-ChildProcessIds {
    param([int]$ParentProcessId)
    $ids = [System.Collections.Generic.List[int]]::new()
    $children = @()
    try {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction Stop)
    } catch {
        try { $children = @(Get-WmiObject Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction Stop) } catch { $children = @() }
    }
    foreach ($child in $children) {
        $childId = [int]$child.ProcessId
        $ids.Add($childId)
        foreach ($descendantId in (Get-ChildProcessIds -ParentProcessId $childId)) {
            $ids.Add([int]$descendantId)
        }
    }
    return $ids.ToArray()
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    $descendants = @(Get-ChildProcessIds -ParentProcessId $ProcessId)
    $taskkill = $null
    if ($env:SystemRoot) {
        $candidate = Join-Path $env:SystemRoot "System32\taskkill.exe"
        if (Test-Path $candidate) { $taskkill = $candidate }
    }
    if (-not $taskkill) {
        $cmd = Get-Command taskkill.exe -ErrorAction SilentlyContinue
        if ($cmd) { $taskkill = $cmd.Source }
    }
    if ($taskkill) {
        & $taskkill /PID $ProcessId /T /F *> $null
    }
    foreach ($id in ($descendants | Select-Object -Unique | Sort-Object -Descending)) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 200
    foreach ($id in ($descendants | Select-Object -Unique | Sort-Object -Descending)) {
        try {
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($p) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
}

# Windows Job Objects provide a WMI-independent process-tree boundary. This is
# important in restricted environments where Win32_Process enumeration and
# taskkill /T can both be denied even for descendants of the current process.
function New-HandoffProcessJob {
    param([System.Diagnostics.Process]$Process)
    if ($env:OS -ne "Windows_NT" -or $null -eq $Process) { return [IntPtr]::Zero }
    try {
        if (-not ("HandoffWindowsJob" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HandoffWindowsJob {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
        }
        $job = [HandoffWindowsJob]::CreateJobObject([IntPtr]::Zero, $null)
        if ($job -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        if (-not [HandoffWindowsJob]::AssignProcessToJobObject($job, $Process.Handle)) {
            [HandoffWindowsJob]::CloseHandle($job) | Out-Null
            return [IntPtr]::Zero
        }
        return $job
    } catch {
        return [IntPtr]::Zero
    }
}

function Stop-HandoffProcessJob {
    param([IntPtr]$Job)
    if ($Job -eq [IntPtr]::Zero -or -not ("HandoffWindowsJob" -as [type])) { return $false }
    try {
        $terminated = [HandoffWindowsJob]::TerminateJobObject($Job, 4)
        [HandoffWindowsJob]::CloseHandle($Job) | Out-Null
        return [bool]$terminated
    } catch {
        try { [HandoffWindowsJob]::CloseHandle($Job) | Out-Null } catch { }
        return $false
    }
}

function Close-HandoffProcessJob {
    param([IntPtr]$Job)
    if ($Job -eq [IntPtr]::Zero -or -not ("HandoffWindowsJob" -as [type])) { return }
    try { [HandoffWindowsJob]::CloseHandle($Job) | Out-Null } catch { }
}

function Remove-AnsiEscape {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ([regex]::Replace($Value, "\x1B\[[0-?]*[ -/]*[@-~]", ""))
}

function Get-ClaudeEvidenceField {
    param([string]$Text, [string]$Label, [string]$Default = "unknown/not exposed")
    $clean = Remove-AnsiEscape -Value $Text
    $pattern = "(?im)^\s*-?\s*" + [regex]::Escape($Label) + "\s*:\s*(.+?)\s*$"
    $m = [regex]::Match($clean, $pattern)
    if ($m.Success -and -not [string]::IsNullOrWhiteSpace($m.Groups[1].Value)) {
        return $m.Groups[1].Value.Trim()
    }
    return $Default
}

function Get-ClaudeModelCommandSuffix {
    if ($null -ne $script:ModelSelection -and $script:ModelSelection.UsesConcreteModel) {
        return " --model `"$($script:ModelSelection.ClaudeModel)`""
    }
    return ""
}

function Get-SanitizedClaudeInvocation {
    return "npx --yes @anthropic-ai/claude-code --safe-mode --append-system-prompt <system-prompt:redacted> -p <prompt:redacted> --permission-mode acceptEdits --disallowed-tools Bash --max-budget-usd <budget> --no-session-persistence --output-format text --setting-sources `"project,local`"$(Get-ClaudeModelCommandSuffix)"
}

function Test-ModelTurnPreflight {
    if (-not $script:ModelSelection.Ok) {
        Write-Host "Model routing blocked."
        foreach ($error in $script:ModelSelection.Errors) { Write-Host "Reason: $error" }
        Write-Host "Stop category: Environment/Preflight - repair model routing before retrying."
        return $false
    }
    if ($script:ModelSelection.NeedsEscalationApproval -and -not $AllowModelEscalation) {
        Write-Host "Model routing blocked."
        Write-Host "Reason: profile high_reasoning resolves to a concrete model and requires explicit cost escalation approval."
        Write-Host "Next step: rerun with -AllowModelEscalation after reviewing the resolved model with 'handoff.ps1 models'."
        Write-Host "Stop category: User Decision - model cost escalation approval required."
        return $false
    }
    return $true
}

function New-ClaudeCommandEvidence {
    param([int]$ExitCode)
    return @([ordered]@{
        cmd = Get-SanitizedClaudeInvocation
        exitCode = $ExitCode
        purpose = "run Claude Code Implementer turn through the bounded handoff adapter"
        sanitized = $true
        redactions = @("prompt", "system prompt", "budget value")
    })
}

function Write-ClaudeCommandCapture {
    param([string]$Timestamp, [int]$ExitCode, [bool]$TimedOut)
    try {
        $commandPath = Join-Path (Get-Location) $ClaudeImplementerCommandName
        $timeoutText = if ($TimedOut) { "true" } else { "false" }
        $body = @(
            "# Claude Implementer Command Capture",
            "",
            "- Timestamp: $Timestamp",
            "- Current Task: $CurrentTask",
            "- Runner: bounded PowerShell runner",
            "- Adapter: Claude Code Implementer",
            "- Sanitized: true",
            "- Exit Code: $ExitCode",
            "- Timed Out: $timeoutText",
            "- Timeout Seconds: $TimeoutSeconds",
            "- Budget USD: $BudgetUsd",
            "",
            "## Sanitized Invocation",
            "",
            '```text',
            (Get-SanitizedClaudeInvocation),
            '```',
            "",
            "## Redaction Rules",
            "",
            "- Prompt content is redacted from the command line view; see CLAUDE_IMPLEMENTER_LAST.md for the captured prompt.",
            "- Secret-like values, tokens, credentials, and dangerous full commands must be redacted before writing command evidence.",
            "- This file is local coordination evidence only and must never be committed."
        )
        Set-Content -Path $commandPath -Value ($body -join "`n") -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Host "WARNING: could not write Claude Implementer command capture artifact: $_"
    }
}
function Write-ClaudeImplementerCapture {
    param(
        [string]$Prompt,
        [string]$StdoutText,
        [string]$StderrText,
        [int]$ExitCode,
        [bool]$TimedOut
    )

    try {
        $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        $lastPath = Join-Path (Get-Location) $ClaudeImplementerLastName
        $jsonlPath = Join-Path (Get-Location) $ClaudeImplementerJsonlName
        $cleanStdout = Remove-AnsiEscape -Value $StdoutText
        $stdoutForMd = if ([string]::IsNullOrWhiteSpace($cleanStdout)) { "(empty)" } else { $cleanStdout.TrimEnd() }
        $stderrForMd = if ([string]::IsNullOrWhiteSpace($StderrText)) { "(empty)" } else { $StderrText.TrimEnd() }
        $modelPolicyRequested = if ($null -ne $script:ModelSelection) { $script:ModelSelection.EffectiveProfile } else { Get-ClaudeEvidenceField -Text $cleanStdout -Label "Model policy requested" -Default "inherit" }
        $modelRequestedViaCli = if ($null -ne $script:ModelSelection -and $script:ModelSelection.UsesConcreteModel) { $script:ModelSelection.ClaudeModel } else { "none (inherit)" }
        $actualModelObserved = Get-ClaudeEvidenceField -Text $cleanStdout -Label "Actual model observed" -Default "unknown/not exposed"
        $modelSource = if ($null -ne $script:ModelSelection) { $script:ModelSelection.Source } else { Get-ClaudeEvidenceField -Text $cleanStdout -Label "Model source" -Default "not exposed" }
        $modelConfidence = Get-ClaudeEvidenceField -Text $cleanStdout -Label "Model confidence" -Default "low"
        $commands = New-ClaudeCommandEvidence -ExitCode $ExitCode
        Write-ClaudeCommandCapture -Timestamp $ts -ExitCode $ExitCode -TimedOut $TimedOut
        $body = @(
            "# Claude Implementer Turn Capture",
            "",
            "- Timestamp: $ts",
            "- State Before Turn: $State",
            "- Waiting For Before Turn: $WaitingFor",
            "- Current Task: $CurrentTask",
            "- Exit Code: $ExitCode",
            "- Timed Out: $TimedOut",
            "",
            "## Command Transparency",
            "",
            "- Command Evidence: $ClaudeImplementerCommandName",
            "- Sanitized Invocation: $(Get-SanitizedClaudeInvocation)",
            "",
            "## Model Evidence",
            "",
            "- Requested policy/profile: $modelPolicyRequested",
            "- Requested concrete model: $modelRequestedViaCli",
            "- Actual model observed: $actualModelObserved",
            "- Model source: $modelSource",
            "- Confidence: $modelConfidence",
            "",
            "## Prompt",
            "",
            '```text',
            $Prompt.TrimEnd(),
            '```',
            "",
            "## Stdout",
            "",
            '```text',
            $stdoutForMd,
            '```',
            "",
            "## Stderr",
            "",
            '```text',
            $stderrForMd,
            '```'
        )
        Set-Content -Path $lastPath -Value ($body -join "`n") -Encoding utf8 -ErrorAction Stop

        $record = [ordered]@{
            ts = $ts
            state = $State
            waitingFor = $WaitingFor
            currentTask = $CurrentTask
            exitCode = $ExitCode
            timedOut = $TimedOut
            stdout = $StdoutText
            stderr = $StderrText
            commands = $commands
            modelEvidence = [ordered]@{
                requestedProfile = $modelPolicyRequested
                requestedConcreteModel = $modelRequestedViaCli
                actualModelObserved = $actualModelObserved
                source = $modelSource
                confidence = $modelConfidence
            }
        }
        Add-Content -Path $jsonlPath -Value ($record | ConvertTo-Json -Compress -Depth 6) -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Host "WARNING: could not write Claude Implementer capture artifacts: $_"
    }
}
# --- Running-turn visibility and stop (v3.4.2) ---
#
# Automated turns are bounded by timeout, MaxTurns and budget, and nothing runs unless
# the operator asks for it. But until v3.4.2 a turn in flight was invisible from any
# other window, and the only way to end one was Ctrl+C in the window that started it.
# A bounded process you cannot see or stop still feels like a runaway.
#
# The marker is local and gitignored, like every other coordination file. A marker
# whose process is gone is reported as stale and cleared - never treated as a live run,
# because a false "something is running" is its own kind of alarm.

function Write-RunMarker {
    param([int]$ProcessId, [string]$Kind, [decimal]$Budget, [int]$Timeout)
    try {
        # A process id alone is not an identity: the operating system reuses ids, so a
        # recycled id would let stop terminate an unrelated process. Recording the
        # process start time makes the pair unique in practice.
        $startTicks = 0
        try { $startTicks = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { $startTicks = 0 }
        $marker = [ordered]@{
            processId  = $ProcessId
            startTicks = $startTicks
            kind       = $Kind
            startedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            budgetUsd  = $Budget
            timeoutSec = $Timeout
        }
        $path = Join-Path (Get-Location) $RunMarkerName
        [System.IO.File]::WriteAllText($path, ($marker | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Clear-RunMarker {
    try {
        $path = Join-Path (Get-Location) $RunMarkerName
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Get-RunMarkerState {
    $result = @{ Present = $false; Alive = $false; Stale = $false; ProcessId = 0; StartTicks = 0; Kind = ""; StartedUtc = ""; BudgetUsd = 0; TimeoutSec = 0 }
    $path = Join-Path (Get-Location) $RunMarkerName
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    $result.Present = $true
    try {
        $data = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $result.ProcessId  = [int]$data.processId
        if ($null -ne $data.startTicks) { $result.StartTicks = [int64]$data.startTicks }
        $result.Kind       = [string]$data.kind
        $result.StartedUtc = [string]$data.startedUtc
        $result.BudgetUsd  = $data.budgetUsd
        $result.TimeoutSec = $data.timeoutSec
    } catch {
        $result.Stale = $true
        return $result
    }
    # Alive means "the recorded process is still running", not "some process holds that
    # id". A reused id must read as stale, so stop can never target a stranger.
    # No verifiable identity means STALE, never alive. Falling back to a bare id match
    # when startTicks is missing or zero would reintroduce exactly the hazard the field
    # exists to remove: a recycled id could then be terminated by stop. The cost of
    # being wrong here is asymmetric - refusing to kill something is recoverable,
    # killing a stranger is not.
    $alive = $false
    if ($result.StartTicks -gt 0) {
        try {
            $running = Get-Process -Id $result.ProcessId -ErrorAction Stop
            $alive = ($running.StartTime.ToUniversalTime().Ticks -eq $result.StartTicks)
        } catch { $alive = $false }
    }
    $result.Alive = $alive
    $result.Stale = -not $alive
    return $result
}

function Invoke-Stop {
    $state = Get-RunMarkerState
    Write-Host ""
    if (-not $state.Present) {
        Write-Host "stop: nothing to stop."
        Write-Host "No automated turn is recorded as running in this project."
        Write-Host "Nothing runs in the background here: turns start only from cycle or loop."
        Write-Host ""
        return
    }
    if ($state.Stale) {
        Clear-RunMarker
        Write-Host "stop: nothing to stop."
        Write-Host "A stale run marker was found (process $($state.ProcessId) is no longer running) and has been cleared."
        Write-Host ""
        return
    }

    Write-Host "Stopping the running turn."
    Write-Host "  Kind:       $($state.Kind)"
    Write-Host "  Process:    $($state.ProcessId)"
    Write-Host "  Started:    $($state.StartedUtc) UTC"
    Stop-ProcessTree -ProcessId $state.ProcessId
    Clear-RunMarker
    Write-Host ""
    Write-Host "stop: complete. The process tree was terminated and the marker cleared."
    Write-Host "AI_HANDOFF.md was not changed, and no git, deploy, database or secret action was run."
    Write-Host "The turn stopped mid-flight, so re-read AI_HANDOFF.md and git status before continuing."
    Write-Host ""
}

# Run one Claude Code Implementer turn with the standard safety constraints.
function Invoke-ClaudeTurn {
    if ($TimeoutSeconds -lt 1) {
        Write-Host "Claude Code turn blocked."
        Write-Host "Reason: -TimeoutSeconds must be at least 1 (got: $TimeoutSeconds)."
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        return 1
    }

    if (-not (Test-ModelTurnPreflight)) { return 1 }

    $prompt = "You are running as the Implementer in a NON-INTERACTIVE, headless automation turn. There is no human available to talk to during this turn. Do NOT greet anyone, do NOT ask what to work on, do NOT ask for plugin choices, do NOT wait for input, and do NOT treat this as the start of an interactive session.`nRead NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state: immediately either complete the required Implementer action for the current state, or update AI_HANDOFF.md with a protocol-valid blocker or question. Do not stop to ask the operator.`nIf present, read CLAUDE_IMPLEMENTER_LAST.md, CLAUDE_IMPLEMENTER_COMMAND.md, CODEX_MASTER_LAST.md, CODEX_REVIEW_LAST.md, and HANDOFF_LOOP.log to reconstruct recent context before acting.`nRead .ai/skills/codex-claude-handoff/CAPABILITIES.md and .ai/skills/codex-claude-handoff/CLAUDE_EXECUTION_POLICY.md if present.`nTreat every preservation or backward-compatibility clause in the task as strict. Existing tests are evidence, not an exhaustive specification: reason about previously supported input classes, and avoid broad transformations or coercion changes unless the task explicitly requires them.`nAt the end of your response, include a concise Claude Execution Evidence block with: model policy requested; model requested via CLI if known; actual model observed or unknown/not exposed; model source; model confidence; model relevance; subagent evidence as used / not observed / unavailable; skills/capabilities consulted; and a short why / decisions / risks summary. Strip ANSI/control noise from model names. Do not invent evidence."
    $prompt += "`nModel routing for this turn: effective profile=$($script:ModelSelection.EffectiveProfile); resolved Claude model=$($script:ModelSelection.ClaudeModel); resolution source=$($script:ModelSelection.Source). Report these requested values as adapter evidence, but do not claim they prove the actual runtime model unless Claude Code exposes it directly."
    $systemPrompt = "You are a non-interactive, headless automation agent (the Claude Code Implementer). Never greet, never ask what to work on, never ask for plugin choices, and never wait for input. Read the requested local files exactly as written. Follow the AI_HANDOFF.md handoff state and perform the required action now; if you cannot act, update AI_HANDOFF.md with a protocol-valid blocker or question. Do not treat this as the start of an interactive session."
    $prompt += "`nBash is unavailable in this automated turn. Do NOT create temporary helper, capture, runner, or wrapper scripts to work around that restriction. Create or edit only files required by the approved task. If verification cannot run without Bash, record it as not run with the reason; never claim a command or test passed without observed output."
    $systemPrompt += " Bash is unavailable: never create helper, capture, runner, or wrapper scripts to simulate shell verification, and never claim unobserved verification. Edit only task-required files and the local handoff."
    if ($State -eq "NEEDS_INVESTIGATION") {
        $prompt += "`nThis is a READ-ONLY investigation turn. Do not create, edit, rename, or delete application/source/test/config files. You may update only AI_HANDOFF.md and local handoff evidence files. Record repository findings, then transition exactly as NEXT_TURN.md requires."
        $systemPrompt += " This NEEDS_INVESTIGATION turn is read-only: do not modify application, source, test, or configuration files. Only local handoff coordination files may be updated."
    }
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $promptFile = [System.IO.Path]::GetTempFileName()
    $sysPromptFile = [System.IO.Path]::GetTempFileName()
    $childPidFile = [System.IO.Path]::GetTempFileName()
    $runnerScript = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".ps1")
    $budgetText = $BudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture)

    $runnerBody = @'
param(
    [string]$PromptFile,
    [string]$SystemPromptFile,
    [string]$BudgetUsdText,
    [string]$ChildPidFile,
    [string]$ModelName
)
$ErrorActionPreference = "Continue"
$prompt = (Get-Content -Raw -LiteralPath $PromptFile) -replace "(`r`n|`n|`r)", " "
$sysPrompt = Get-Content -Raw -LiteralPath $SystemPromptFile
$argList = @(
    '--yes',
    '@anthropic-ai/claude-code',
    '--safe-mode',
    '--append-system-prompt',
    $sysPrompt,
    '-p',
    $prompt,
    '--permission-mode',
    'acceptEdits',
    '--disallowed-tools',
    'Bash',
    '--max-budget-usd',
    $BudgetUsdText,
    '--no-session-persistence',
    '--output-format',
    'text',
    '--setting-sources',
    'project,local'
)
if (-not [string]::IsNullOrWhiteSpace($ModelName) -and $ModelName -ne '__HANDOFF_INHERIT__') {
    $argList += '--model'
    $argList += $ModelName
}
try {
    $npxCommand = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npxCommand) { $npxCommand = Get-Command npx -ErrorAction Stop }
    # Invoke with a real PowerShell argument array. Passing the same values through
    # Start-Process to npx.cmd builds a cmd.exe command line where prompt characters
    # can be reinterpreted and the true child exit code can be lost on Windows.
    # The outer bounded runner still owns this process and kills its full descendant
    # tree on timeout, so a separate child PID is not required here.
    & $npxCommand.Source @argList
    if ($null -eq $LASTEXITCODE) { exit 3 }
    exit ([int]$LASTEXITCODE)
} catch {
    Write-Error $_
    exit 3
}
'@

    $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $psHost) { $psHost = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
    if (-not $psHost) {
        Write-Host "Claude Code turn blocked."
        Write-Host "Reason: no PowerShell host (pwsh/powershell) is available for the bounded runner."
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Remove-Item $tmpOut, $tmpErr, $promptFile, $sysPromptFile, $childPidFile, $runnerScript -Force -ErrorAction SilentlyContinue
        return 3
    }

    try {
        Set-Content -Path $promptFile -Value $prompt -Encoding utf8 -NoNewline -ErrorAction Stop
        Set-Content -Path $sysPromptFile -Value $systemPrompt -Encoding utf8 -NoNewline -ErrorAction Stop
        Set-Content -Path $runnerScript -Value $runnerBody -Encoding utf8 -ErrorAction Stop
        $runnerModel = if ($script:ModelSelection.UsesConcreteModel) { $script:ModelSelection.ClaudeModel } else { "__HANDOFF_INHERIT__" }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerScript, '-PromptFile', $promptFile, '-SystemPromptFile', $sysPromptFile, '-BudgetUsdText', $budgetText, '-ChildPidFile', $childPidFile, '-ModelName', $runnerModel)
        $proc = Start-Process -FilePath $psHost -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $processJob = New-HandoffProcessJob -Process $proc
        Write-RunMarker -ProcessId $proc.Id -Kind "Claude Code Implementer turn" -Budget $BudgetUsd -Timeout $TimeoutSeconds
    } catch {
        Write-Host "Claude Code turn blocked."
        Write-Host "Reason: failed to start bounded Claude Code runner: $_"
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Remove-Item $tmpOut, $tmpErr, $promptFile, $sysPromptFile, $childPidFile, $runnerScript -Force -ErrorAction SilentlyContinue
        return 3
    }

    try { $null = $proc.Handle } catch { }
    $timedOut = $false
    $claudeExit = -1
    if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
        $claudeExit = $proc.ExitCode
        Close-HandoffProcessJob -Job $processJob
        $processJob = [IntPtr]::Zero
    } else {
        $timedOut = $true
        $childPid = $null
        if (Test-Path $childPidFile) {
            $childPidRaw = Get-Content -Raw -Path $childPidFile -ErrorAction SilentlyContinue
            $childPidText = if ($null -eq $childPidRaw) { "" } else { $childPidRaw.Trim() }
            if ($childPidText -match '^\d+$') { $childPid = [int]$childPidText }
        }
        $jobStopped = Stop-HandoffProcessJob -Job $processJob
        $processJob = [IntPtr]::Zero
        if (-not $jobStopped) {
            if ($childPid) { Stop-ProcessTree -ProcessId $childPid }
            Stop-ProcessTree -ProcessId $proc.Id
        }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    Clear-RunMarker

    $stdoutText = ""
    if (Test-Path $tmpOut) { $stdoutText = (Get-Content -Raw -Path $tmpOut -ErrorAction SilentlyContinue) }
    $stderrText = ""
    if (Test-Path $tmpErr) { $stderrText = (Get-Content -Raw -Path $tmpErr -ErrorAction SilentlyContinue) }
    Write-ClaudeImplementerCapture -Prompt $prompt -StdoutText $stdoutText -StderrText $stderrText -ExitCode $claudeExit -TimedOut $timedOut
    Remove-Item $tmpOut, $tmpErr, $promptFile, $sysPromptFile, $childPidFile, $runnerScript -Force -ErrorAction SilentlyContinue

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        ($stdoutText -split "`n") | ForEach-Object { Write-Host $_.TrimEnd() }
    }

    if ($timedOut) {
        Write-Host "Claude Code turn TIMED OUT after $TimeoutSeconds seconds."
        Write-Host "The Claude Code runner process tree was terminated."
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Claude Code stderr (partial, before termination):"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight (Claude Code turn timed out) - not a user decision."
        Write-Host "No git commands were run by handoff.ps1. Inspect AI_HANDOFF.md before continuing."
        return 4
    }

    if ($null -eq $claudeExit) { $claudeExit = -1 }
    if ($claudeExit -ne 0 -and -not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Host "Claude Code stderr:"
        ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
    }
    return $claudeExit
}


# --- v3.5.0: read-only Claude Code turn for the Master and Reviewer roles ---
#
# Invoke-ClaudeTurn above runs the Implementer: it is write-enabled because
# Get-RolePermission grants the Implementer role write. This function runs the other
# two roles, which Get-RolePermission holds to read-only, and it is the reason Claude
# Code can now hold them at all.
#
# Read-only here is enforced three ways, not one:
#   1. The write tools are DISALLOWED at the CLI. Edit, Write and NotebookEdit are
#      passed to --disallowed-tools alongside Bash, so the turn has no instrument for
#      changing a file. This is the guarantee; the other two are defence in depth.
#   2. The prompt and the system prompt both state the turn is read-only.
#   3. The working tree is compared after the turn. Anything that moved fails the turn
#      even if the capture looks valid - the same standard the NEEDS_INVESTIGATION
#      boundary already applies to the Implementer.
#
# The caller supplies the role prompt and receives the final message at LastPath, which
# is the same contract codex exec --output-last-message satisfies for the Codex path.
# That is what lets review-apply and master-apply stay identical for both tools: they
# parse a captured file and never learn which vendor produced it.
function Invoke-ClaudeReadOnlyCapture {
    param(
        [string]$TurnRole,
        [string]$Prompt,
        [string]$LastPath,
        [string]$JsonlPath,
        [int]$TurnTimeoutSeconds,
        [double]$TurnBudgetUsd
    )

    $result = @{ Ok = $false; ExitCode = -1; TimedOut = $false; SourceChanged = $false; ChangedFiles = @(); Error = "" }

    if ($TurnTimeoutSeconds -lt 1) {
        $result.Error = "-TimeoutSeconds must be at least 1 (got: $TurnTimeoutSeconds)."
        return $result
    }

    $systemPrompt = "You are a non-interactive, headless automation agent holding the $TurnRole role in the codex-claude-handoff protocol. Never greet, never ask what to work on, never ask for plugin choices, and never wait for input. This turn is STRICTLY READ-ONLY: do not create, edit, rename or delete any file, including local handoff coordination files. The file-writing tools are disabled for this turn and the working tree is checked afterwards. Read the requested local files exactly as written and answer in the exact output format the prompt requires, with no preamble and no closing commentary."

    $fullPrompt = $Prompt + "`nThis is a NON-INTERACTIVE, headless, READ-ONLY automation turn. There is no human available during this turn. Do not greet anyone, do not ask questions, and do not wait for input. Do not modify any file: your entire output is your answer. Emit the required block as the last thing in your response, with no text after it."

    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $promptFile = [System.IO.Path]::GetTempFileName()
    $sysPromptFile = [System.IO.Path]::GetTempFileName()
    $runnerScript = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".ps1")
    $budgetText = $TurnBudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture)

    $runnerBody = @'
param(
    [string]$PromptFile,
    [string]$SystemPromptFile,
    [string]$BudgetUsdText,
    [string]$ModelName
)
$ErrorActionPreference = "Continue"
$prompt = (Get-Content -Raw -LiteralPath $PromptFile) -replace "(`r`n|`n|`r)", " "
$sysPrompt = Get-Content -Raw -LiteralPath $SystemPromptFile
$argList = @(
    '--yes',
    '@anthropic-ai/claude-code',
    '--safe-mode',
    '--append-system-prompt',
    $sysPrompt,
    '-p',
    $prompt,
    '--disallowed-tools',
    'Bash,Edit,Write,NotebookEdit',
    '--max-budget-usd',
    $BudgetUsdText,
    '--no-session-persistence',
    '--output-format',
    'text',
    '--setting-sources',
    'project,local'
)
if (-not [string]::IsNullOrWhiteSpace($ModelName) -and $ModelName -ne '__HANDOFF_INHERIT__') {
    $argList += '--model'
    $argList += $ModelName
}
try {
    $npxCommand = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npxCommand) { $npxCommand = Get-Command npx -ErrorAction Stop }
    & $npxCommand.Source @argList
    if ($null -eq $LASTEXITCODE) { exit 3 }
    exit ([int]$LASTEXITCODE)
} catch {
    Write-Error $_
    exit 3
}
'@

    $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $psHost) { $psHost = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
    if (-not $psHost) {
        $result.Error = "No PowerShell host (pwsh/powershell) is available for the bounded runner."
        Remove-Item $tmpOut, $tmpErr, $promptFile, $sysPromptFile, $runnerScript -Force -ErrorAction SilentlyContinue
        return $result
    }

    # Content-level snapshot BEFORE the turn. See Get-ReadOnlyBoundarySnapshot for why a
    # filename comparison is not sufficient here. The two capture paths are excluded
    # because this function writes them itself, after the boundary has been checked.
    $boundaryExclude = @($ReviewJsonlName, $ReviewLastName, $MasterJsonlName, $MasterLastName,
                         $LegacyReviewJsonlName, $LegacyReviewLastName, $LegacyMasterJsonlName, $LegacyMasterLastName)
    $preSnapshot = Get-ReadOnlyBoundarySnapshot -ExcludePaths $boundaryExclude

    try {
        Set-Content -Path $promptFile -Value $fullPrompt -Encoding utf8 -NoNewline -ErrorAction Stop
        Set-Content -Path $sysPromptFile -Value $systemPrompt -Encoding utf8 -NoNewline -ErrorAction Stop
        Set-Content -Path $runnerScript -Value $runnerBody -Encoding utf8 -ErrorAction Stop
        $runnerModel = if ($script:ModelSelection -and $script:ModelSelection.UsesConcreteModel) { $script:ModelSelection.ClaudeModel } else { "__HANDOFF_INHERIT__" }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerScript, '-PromptFile', $promptFile, '-SystemPromptFile', $sysPromptFile, '-BudgetUsdText', $budgetText, '-ModelName', $runnerModel)
        $proc = Start-Process -FilePath $psHost -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $processJob = New-HandoffProcessJob -Process $proc
        Write-RunMarker -ProcessId $proc.Id -Kind "Claude Code $TurnRole turn (read-only)" -Budget $TurnBudgetUsd -Timeout $TurnTimeoutSeconds
    } catch {
        $result.Error = "Failed to start the bounded Claude Code runner: $_"
        Remove-Item $tmpOut, $tmpErr, $promptFile, $sysPromptFile, $runnerScript -Force -ErrorAction SilentlyContinue
        return $result
    }

    try { $null = $proc.Handle } catch { }
    if ($proc.WaitForExit($TurnTimeoutSeconds * 1000)) {
        $result.ExitCode = $proc.ExitCode
        Close-HandoffProcessJob -Job $processJob
    } else {
        $result.TimedOut = $true
        $jobStopped = Stop-HandoffProcessJob -Job $processJob
        if (-not $jobStopped) { Stop-ProcessTree -ProcessId $proc.Id }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    Clear-RunMarker

    $stdoutText = ""
    if (Test-Path $tmpOut) { $stdoutText = (Get-Content -Raw -Path $tmpOut -ErrorAction SilentlyContinue) }
    $stderrText = ""
    if (Test-Path $tmpErr) { $stderrText = (Get-Content -Raw -Path $tmpErr -ErrorAction SilentlyContinue) }

    Remove-Item $tmpOut, $tmpErr, $promptFile, $sysPromptFile, $runnerScript -Force -ErrorAction SilentlyContinue

    # Enforcement 3: nothing may have changed. A capture is not accepted from a turn that
    # edited the repository, however well-formed the capture looks - a Reviewer that
    # edits what it reviews is not a Reviewer. This runs before anything is written, so
    # the comparison sees only what the TURN did.
    $postSnapshot = Get-ReadOnlyBoundarySnapshot -ExcludePaths $boundaryExclude
    if (-not $preSnapshot.Ok -or -not $postSnapshot.Ok) {
        $result.SourceChanged = $true
        $result.Error = "Could not verify the working tree around the read-only $TurnRole turn. Refusing to accept a capture whose read-only boundary is unverified."
        return $result
    }
    $changedPaths = Compare-ReadOnlyBoundary -Before $preSnapshot.Entries -After $postSnapshot.Entries
    if ($changedPaths.Count -gt 0) {
        $result.SourceChanged = $true
        $result.ChangedFiles = $changedPaths
        $result.Error = "The read-only $TurnRole turn changed files: $([string]::Join(', ', $changedPaths))."
        return $result
    }

    # Event log parity with the Codex path: the Codex runs keep a JSONL stream, so keep
    # one here too. Written only after the boundary check, so the protocol's own
    # diagnostics can never be mistaken for something the turn did.
    try {
        $logLine = "{`"role`":`"$TurnRole`",`"tool`":`"Claude Code`",`"permission`":`"read-only`",`"exit`":$($result.ExitCode),`"timedOut`":$($result.TimedOut.ToString().ToLowerInvariant())}"
        Add-Content -LiteralPath $JsonlPath -Value $logLine -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }

    if ($result.TimedOut) {
        $result.Error = "The Claude Code $TurnRole turn timed out after $TurnTimeoutSeconds seconds and its process tree was terminated."
        return $result
    }
    if ($result.ExitCode -ne 0) {
        $detail = if (-not [string]::IsNullOrWhiteSpace($stderrText)) { " Stderr: $($stderrText.Trim())" } else { "" }
        $result.Error = "Claude Code exited $($result.ExitCode) and produced no usable capture.$detail"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($stdoutText)) {
        $result.Error = "Claude Code exited 0 but produced no output, so no capture was written."
        return $result
    }

    # Claude Code has no --output-last-message; its final message IS stdout under
    # --output-format text. Writing it to LastPath gives the Codex path's exact contract,
    # so the apply commands parse one file shape regardless of which tool produced it.
    try {
        [System.IO.File]::WriteAllText($LastPath, $stdoutText, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        $result.Error = "Failed to write the captured $TurnRole output to $LastPath : $_"
        return $result
    }

    $result.Ok = $true
    return $result
}


# --- v3.5.0: Codex holding the Implementer role ---
#
# This is the only turn in the protocol that Get-RolePermission grants write, and the
# grant is bounded three ways:
#
#   --sandbox workspace-write   confines writes to the repository working directory.
#                               Not danger-full-access, which would also reach outside it.
#   no approval escape hatches  --ask-for-approval and
#                               --dangerously-bypass-approvals-and-sandbox are never
#                               passed. There is no human in a headless turn to answer an
#                               approval prompt, so a turn that asks for one hangs until
#                               the timeout - and a turn that bypasses the sandbox is not
#                               bounded at all. Both are refused for the same reason.
#   the exact-scope check       runs after the turn, in the caller, exactly as it does for
#                               the Claude Implementer. Writing an undeclared file fails
#                               the turn whichever tool wrote it.
#
# NEEDS_INVESTIGATION uses workspace-write like any other Implementer turn, NOT
# --sandbox read-only. The first version of this function used read-only there, reasoning
# that a source-read-only state should be enforced by the sandbox rather than checked
# afterwards. That was a deadlock, caught in review: an investigation turn has to record
# its findings in AI_HANDOFF.md and transition the state, and a read-only sandbox forbids
# writing that file. The state would have been advertised as callable and been unable to
# finish - the same shape as the v3.4.1 defect where the Reviewer's read-only sandbox
# denied the test fixtures the suite needed.
#
# "Source-read-only" was never "writes nothing"; it means the coordination files may move
# and application, source, test and config files may not. That is a boundary a sandbox
# cannot express, so it is enforced where it always has been for the Claude Implementer:
# by Get-InvestigationSourceBoundary after the turn, which fails the turn if any
# non-coordination file changed. Both tools now reach the identical check.
function Invoke-CodexImplementerTurn {
    if ($TimeoutSeconds -lt 1) {
        Write-Host "Codex Implementer turn blocked."
        Write-Host "Reason: -TimeoutSeconds must be at least 1 (got: $TimeoutSeconds)."
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        return 1
    }

    $cli = Resolve-CodexCli
    if (-not $cli.Ok) {
        Write-Host "Codex Implementer turn blocked."
        Write-Host "Reason: $($cli.Error)"
        Write-Host "Stop category: Environment/Preflight (Codex CLI unavailable) - not a user decision."
        return 3
    }
    $execHelp = Test-CodexExecHelp -CodexPath $cli.Path
    if (-not $execHelp.Ok) {
        Write-Host "Codex Implementer turn blocked."
        Write-Host "Reason: The resolved Codex CLI did not accept 'exec --help'. $($execHelp.Error)"
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        return 3
    }

    $repoRoot = (Get-Location).Path
    $lastPath = Join-Path $repoRoot $ClaudeImplementerLastName
    $jsonlPath = Join-Path $repoRoot $ClaudeImplementerJsonlName

    # The Implementer role is write-enabled (Get-RolePermission), and that holds for the
    # investigation state too: the turn must be able to write AI_HANDOFF.md. What it must
    # not touch is source, and that is checked after the turn, not fenced by the sandbox.
    #
    # The name says IMPLEMENTER on purpose. This file builds three different codex
    # invocations - Master, Reviewer and Implementer - and a bare $sandbox here reads as
    # "the sandbox this script uses" rather than "the sandbox this ROLE gets". A reviewer
    # misread it exactly that way and reported that Master and Reviewer had been given
    # write access. They had not: Invoke-MasterRun and Invoke-ReviewRun each pass a
    # literal 'read-only' and neither reads this variable. The ambiguity was real even
    # though the defect was not, so the variable is named for the only role it serves.
    $readOnlyTurn = ($State -eq "NEEDS_INVESTIGATION")
    $implementerSandbox = "workspace-write"

    $prompt = "You are running as the Implementer in a NON-INTERACTIVE, headless automation turn. There is no human available during this turn. Do not greet anyone, do not ask what to work on, and do not wait for input. " +
        "Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state: either complete the required Implementer action for the current state, or update AI_HANDOFF.md with a protocol-valid blocker or question. " +
        "If present, read IMPLEMENTER_LAST.md, MASTER_LAST.md, REVIEW_LAST.md and HANDOFF_LOOP.log to reconstruct recent context before acting. " +
        "Read .ai/skills/codex-claude-handoff/CAPABILITIES.md if present. " +
        "Change ONLY the files listed under AI_HANDOFF.md Changed Files, plus AI_HANDOFF.md itself. The set of files you change is compared against that list after this turn, and an undeclared file fails the turn. " +
        "Treat every preservation or backward-compatibility clause in the task as strict. Existing tests are evidence, not an exhaustive specification. " +
        "Never install dependencies, use the network, deploy, access or mutate a database, inspect or modify secrets or production configuration, or run git add, git commit, git push or git tag. Those are the user's decisions and are made outside this turn. " +
        "Never claim a command or test passed without observed output; if verification could not run, record it as not run with the reason."
    if ($readOnlyTurn) {
        $prompt += " This is a SOURCE-READ-ONLY investigation turn. Do not create, edit, rename or delete any application, source, test or configuration file. You may update ONLY AI_HANDOFF.md and local handoff coordination files. The working tree is checked after this turn and any source change fails it, even if the handoff transition itself was correct. Record repository findings in AI_HANDOFF.md and transition exactly as NEXT_TURN.md requires."
    }

    Write-Host "Invocation: codex exec --cd `"$repoRoot`" --sandbox $implementerSandbox --ephemeral --json --output-last-message `"$ClaudeImplementerLastName`" -   (prompt via stdin)"
    Write-Host ""

    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $promptFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $promptFile -Value $prompt -Encoding utf8 -ErrorAction SilentlyContinue
    $argList = @('exec', '--cd', $repoRoot, '--sandbox', $implementerSandbox, '--ephemeral', '--json', '--output-last-message', $lastPath, '-')
    $timedOut = $false
    $codexExit = -1
    try {
        $proc = Start-Process -FilePath $cli.Path -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardInput $promptFile -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $processJob = New-HandoffProcessJob -Process $proc
        Write-RunMarker -ProcessId $proc.Id -Kind "Codex Implementer turn ($implementerSandbox)" -Budget $BudgetUsd -Timeout $TimeoutSeconds
    } catch {
        Write-Host "Codex Implementer turn blocked."
        Write-Host "Reason: Failed to start the Codex CLI: $_"
        Write-Host "Stop category: Environment/Preflight - not a user decision."
        Remove-Item $tmpOut, $tmpErr, $promptFile -Force -ErrorAction SilentlyContinue
        return 3
    }
    try { $null = $proc.Handle } catch { }

    if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
        $codexExit = $proc.ExitCode
        Close-HandoffProcessJob -Job $processJob
    } else {
        $timedOut = $true
        $jobStopped = Stop-HandoffProcessJob -Job $processJob
        if (-not $jobStopped) { Stop-ProcessTree -ProcessId $proc.Id }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    Clear-RunMarker

    $partial = ""
    if (Test-Path $tmpOut) { $partial = (Get-Content -Raw -Path $tmpOut -ErrorAction SilentlyContinue) }
    if (-not [string]::IsNullOrEmpty($partial)) {
        Add-Content -LiteralPath $jsonlPath -Value $partial -Encoding utf8 -ErrorAction SilentlyContinue
    }
    $stderrText = ""
    if (Test-Path $tmpErr) { $stderrText = (Get-Content -Raw -Path $tmpErr -ErrorAction SilentlyContinue) }
    Remove-Item $tmpOut, $tmpErr, $promptFile -Force -ErrorAction SilentlyContinue

    if ($timedOut) {
        Write-Host "Codex Implementer turn TIMED OUT after $TimeoutSeconds seconds."
        Write-Host "The Codex process tree was terminated."
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Codex stderr (partial, before termination):"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight (Codex Implementer turn timed out) - not a user decision."
        Write-Host "No git commands were run by handoff.ps1. Inspect AI_HANDOFF.md before continuing."
        return 4
    }
    if ($codexExit -ne 0 -and -not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Host "Codex stderr:"
        ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
    }
    return $codexExit
}

# Dispatch the Implementer turn to whichever tool holds the role. Both branches return an
# exit code with the same meaning, so every caller - cycle, loop, the no-op guard, the
# exact-scope check - is unchanged and vendor-blind.
function Invoke-ImplementerTurn {
    $implementerTool = Resolve-Actor -Role "Implementer" -Binding $script:Binding
    if (Test-SameToolIdentity -First $implementerTool -Second "Codex") {
        return Invoke-CodexImplementerTurn
    }
    return Invoke-ClaudeTurn
}

function Get-AdapterProfile {
    param([string]$Role, [string]$Tool)

    $manual = "Run 'handoff.ps1 next' then paste the prompt into $Tool."
    if ($Role -eq "User") {
        return @{
            Role = "User"; Tool = "User"; Callable = $false; AutoLoopEligible = $false; SupportedStates = @();
            Invocation = "See AI_HANDOFF.md and decide or authorize the next step.";
            SafetyLimits = "User approval authority; no automation.";
            StopCategory = "User Decision"; UserAuthorizationRequired = "yes";
            Reason = "The protocol requires user authority for this turn.";
            NextStep = "Read AI_HANDOFF.md."
        }
    }

    # --- v3.5.0: symmetric role adapters ---
    #
    # All six role/tool combinations are callable: Master, Reviewer and Implementer, each
    # held by either Codex or Claude Code. Before v3.5.0 only three were, and which three
    # was an accident of history rather than a decision - so swapping the roles silently
    # dropped you back to manual copy-paste in one direction and not the other.
    #
    # The permission each turn runs under comes from Get-RolePermission - from the ROLE -
    # and never from which vendor holds it. Only the INVOCATION differs per tool, because
    # only the command line is vendor-specific. The lookup keys on canonical identity, so
    # a legacy display name such as 'Codex Window' still finds the adapter it names.
    $adapterIdentity = Resolve-ToolIdentity -Tool $Tool
    $isCodex  = ($adapterIdentity.Ok -and $adapterIdentity.Canonical -eq "codex")
    $isClaude = ($adapterIdentity.Ok -and $adapterIdentity.Canonical -eq "claude-code")

    if ($Role -eq "Implementer" -and ($isCodex -or $isClaude)) {
        # The Implementer is the only role Get-RolePermission grants write, and both tools
        # receive it the same way: confined to the repository working directory, with the
        # declared-scope check run against git status after the turn either way.
        if ($isClaude) {
            $invocation = "bounded PowerShell runner -> npx --yes @anthropic-ai/claude-code --safe-mode --append-system-prompt `"<system-prompt:redacted>`" -p `"<prompt>`" --permission-mode acceptEdits --disallowed-tools `"Bash`" --max-budget-usd N --no-session-persistence --output-format text --setting-sources `"project,local`" [--model `"<resolved-local-model>`"]"
            $toolLimits = "Claude customizations/plugins/hooks disabled with --safe-mode; Bash disallowed"
        } else {
            $invocation = "bounded runner -> codex exec --cd `"<repo>`" --sandbox workspace-write --ephemeral --json --output-last-message `"$ImplementerLastName`" -   (prompt via stdin)"
            $toolLimits = "Codex runs --sandbox workspace-write, which confines writes to the repository working directory; no --ask-for-approval; no --dangerously-bypass-approvals-and-sandbox; no danger-full-access"
        }
        return @{
            Role = $Role; Tool = $Tool; Callable = $true; AutoLoopEligible = $true; SupportedStates = @("READY_FOR_IMPLEMENTATION", "NEEDS_INVESTIGATION");
            Invocation = $invocation;
            SafetyLimits = "Explicit yes confirmation (interactive yes or -Yes); Reviewer != Implementer; clean tree except local handoff files; dynamic model profile resolves through local configuration and falls back to inherit; concrete high_reasoning routing requires -AllowModelEscalation; NEEDS_INVESTIGATION is source-read-only and checked after the turn; $toolLimits; budget cap; hard timeout; stdout/stderr capture; process-tree kill on timeout; declared scope enforced against git status after the turn; no commit/push/tag/deploy/db/secrets automation.";
            StopCategory = "Non-callable Actor"; UserAuthorizationRequired = "yes, before cycle or loop session";
            Reason = "READY_FOR_IMPLEMENTATION and read-only NEEDS_INVESTIGATION are automated for $($adapterIdentity.Display) in the Implementer role; planning and question turns remain manual.";
            NextStep = "Use handoff.ps1 cycle or loop for READY_FOR_IMPLEMENTATION or NEEDS_INVESTIGATION; use next + paste for other Implementer states."
        }
    }

    # Master (Codex since v2.0.1, Claude Code since v3.5.0): callable for NEEDS_ANALYSIS
    # via the explicit two-step master-run (read-only capture) + master-apply (apply the
    # captured recommendation's local AI_HANDOFF.md transition). AutoLoopEligible is FALSE
    # on purpose for both tools; since v2.1.0, loop -IncludeMaster may opt this exact turn
    # into one authorized loop session.
    if ($Role -eq "Master" -and ($isCodex -or $isClaude)) {
        if ($isCodex) {
            $runShape = "read-only Codex Master analysis"
            $toolLimits = "Codex runs --sandbox read-only; no --ask-for-approval; no --dangerously-bypass-approvals-and-sandbox"
        } else {
            $runShape = "read-only Claude Code Master analysis"
            $toolLimits = "Claude Code runs with source edits refused in both the prompt and the system prompt, and a post-turn source-change check that fails the turn if any non-handoff file moved; --safe-mode; Bash disallowed"
        }
        return @{
            Role = $Role; Tool = $Tool; Callable = $true; AutoLoopEligible = $false; SupportedStates = @("NEEDS_ANALYSIS");
            Invocation = "Capture: handoff.ps1 master-run ($runShape, explicit yes). Apply: handoff.ps1 master-apply (applies the captured recommendation's local AI_HANDOFF.md transition, explicit yes). PowerShell loop -IncludeMaster may run this pair in-session.";
            SafetyLimits = "Explicit yes per command, or explicit loop -IncludeMaster for one authorized loop session; NEEDS_ANALYSIS only; the actual Master must match the bound Master; $toolLimits; captured TASK must match Current Task; recommendation/waiting-for pair must be valid; non-BLOCKED routing must use the current bound Implementer and Reviewer and preserve Reviewer != Implementer; master-apply edits only AI_HANDOFF.md; not auto-run by default and never by cycle; no git add/commit/push/tag/deploy/db/secrets.";
            StopCategory = "Operator Manual Action"; UserAuthorizationRequired = "yes, explicit yes before master-run and master-apply; loop session authorization when -IncludeMaster is used";
            Reason = "master-run + master-apply complete the Master's NEEDS_ANALYSIS routing turn end-to-end for $($adapterIdentity.Display), read-only and fail-closed. Callable via explicit commands; PowerShell loop may include it only with -IncludeMaster; cycle never does.";
            NextStep = "Run master-run to capture a recommendation, then master-apply to route the task to Implementer or User."
        }
    }

    # Reviewer (Codex since v1.3.0, Claude Code since v3.5.0): callable for
    # READY_FOR_REVIEW via the explicit two-step review-run (read-only capture) +
    # review-apply (apply the captured verdict's local AI_HANDOFF.md transition).
    # AutoLoopEligible is FALSE on purpose: "callable" here means "has a verified
    # end-to-end command path", NOT "may be auto-run inside loop/cycle". Reviewer turns
    # are not loop-eligible by default. Since v1.4.0, only loop -IncludeReviewer may opt
    # this exact turn into a single loop session; cycle never does.
    if ($Role -eq "Reviewer" -and ($isCodex -or $isClaude)) {
        if ($isCodex) {
            $runShape = "read-only Codex review"
            $toolLimits = "Codex runs --sandbox read-only; no --ask-for-approval; no --dangerously-bypass-approvals-and-sandbox; no danger-full-access"
        } else {
            $runShape = "read-only Claude Code review"
            $toolLimits = "Claude Code runs with source edits refused in both the prompt and the system prompt, and a post-turn source-change check that fails the turn if any non-handoff file moved; --safe-mode; Bash disallowed"
        }
        return @{
            Role = $Role; Tool = $Tool; Callable = $true; AutoLoopEligible = $false; SupportedStates = @("READY_FOR_REVIEW");
            Invocation = "Capture: handoff.ps1 review-run ($runShape, explicit yes). Apply: handoff.ps1 review-apply (applies the captured verdict's local AI_HANDOFF.md transition, explicit yes).";
            SafetyLimits = "Explicit yes per command; READY_FOR_REVIEW only; the actual Reviewer must match the bound Reviewer and must not equal the actual Implementer; Changed Files == git status; $toolLimits; review-apply edits only AI_HANDOFF.md; not auto-run by loop/cycle by default; only PowerShell loop -IncludeReviewer may opt in; cycle never does; no commit/push/tag/deploy/db/secrets; no release action.";
            StopCategory = "Operator Manual Action"; UserAuthorizationRequired = "yes, explicit yes before review-run and review-apply; commit/release stay separate User authorizations";
            Reason = "review-run + review-apply complete the Reviewer's READY_FOR_REVIEW turn end-to-end for $($adapterIdentity.Display), read-only and fail-closed. Callable via explicit commands; PowerShell loop may include it only with -IncludeReviewer; cycle never does.";
            NextStep = "Run review-run to capture a verdict, then review-apply to set REVIEW_DONE (approved) or READY_FOR_IMPLEMENTATION (blocked)."
        }
    }

    # No verified adapter for this role/tool pair. This is a CAPABILITY limit, not a
    # protocol objection: the role assignment stays valid and the turn simply runs
    # as a manual window handoff. Before v3.4.1 an unresolvable tool reached here
    # too and read as a broken configuration; now an unrecognized identity is named
    # as such so the user fixes the binding instead of hunting for a missing adapter.
    $identity = $adapterIdentity
    if (-not $identity.Ok) {
        $reason = "Unrecognized tool '$Tool' bound to the $Role role. $($identity.Reason)"
        $nextStep = "Correct the $Role entry in .ai/roles/ROLE_ASSIGNMENT.md to a known tool identity."
    } else {
        $reason = "No verified local callable adapter for $($identity.Display) in the $Role role. The role assignment is valid; this turn runs as a manual handoff."
        $nextStep = "Run 'handoff.ps1 next' and complete this turn manually in $($identity.Display). Automation requires adding and verifying a local adapter for this role/tool pair."
    }
    return @{
        Role = $Role; Tool = $Tool; Callable = $false; AutoLoopEligible = $false; SupportedStates = @();
        Invocation = $manual;
        SafetyLimits = "Manual prompt handoff only; no commit/push/tag/deploy/db/secrets automation.";
        StopCategory = "Non-callable Actor"; UserAuthorizationRequired = "no for paste; yes for protected actions";
        Reason = $reason;
        NextStep = $nextStep
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
    # AutoLoopEligible is a STRICT subset of Callable: a turn that is callable via an
    # explicit command (e.g. Reviewer/Codex review-run + review-apply) is NOT necessarily
    # eligible to be auto-run inside loop/cycle. loop and cycle must gate on this field,
    # never on Callable, so an explicit-only adapter never triggers an automated turn.
    $autoLoopForState = [bool]($adapter.AutoLoopEligible -and $stateSupported)
    $reason = $adapter.Reason
    if ($adapter.Callable -and -not $stateSupported) {
        $supported = if ($adapter.SupportedStates.Count -gt 0) { $adapter.SupportedStates -join ", " } else { "none" }
        $reason = "$Role/$Tool adapter does not support state $ForState. Supported automated states: $supported."
    }
    return @{
        Role = $Role; Tool = $Tool; Callable = $callableForState; AutoLoopEligible = $autoLoopForState;
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
        $autoLoop = if ($adapter.AutoLoopEligible) { "yes" } else { "no" }
        $states = if ($adapter.SupportedStates.Count -gt 0) { $adapter.SupportedStates -join ", " } else { "none" }
        Write-Host "Role:        $role"
        Write-Host "Tool:        $tool"
        Write-Host "Callable:    $callable"
        Write-Host "Auto-loop:   $autoLoop  (yes only if loop/cycle may auto-run this turn)"
        Write-Host "States:      $states"
        Write-Host "Reason:      $($adapter.Reason)"
        Write-Host "Invocation:  $($adapter.Invocation)"
        Write-Host "Safety:      $($adapter.SafetyLimits)"
        Write-Host "Stop:        $($adapter.StopCategory)"
        Write-Host "User auth:   $($adapter.UserAuthorizationRequired)"
        Write-Host "Enable next: $($adapter.NextStep)"
        Write-Host ""
    }
    # --- v3.5.0: the full matrix, not just today's binding ---
    #
    # The rows above describe the roles as they are bound right now. That answers
    # "what can I do", but not "what could I do if I swapped the roles" - which is
    # exactly the question the binding exists to let you ask. Printing every
    # combination makes the symmetry checkable instead of promised.
    Write-Host "Role/tool matrix (every combination, independent of today's binding)"
    Write-Host "Permission is a property of the ROLE. The tool holding it does not change it."
    Write-Host ""
    Write-Host ("  {0,-12} {1,-12} {2,-9} {3,-11} {4}" -f "Role", "Tool", "Callable", "Permission", "Automated states")
    foreach ($matrixRole in @("Master", "Implementer", "Reviewer")) {
        foreach ($matrixTool in @("Codex", "Claude Code")) {
            $matrixAdapter = Get-AdapterProfile -Role $matrixRole -Tool $matrixTool
            $matrixCallable = if ($matrixAdapter.Callable) { "yes" } else { "no" }
            $matrixStates = if ($matrixAdapter.SupportedStates.Count -gt 0) { $matrixAdapter.SupportedStates -join ", " } else { "none" }
            Write-Host ("  {0,-12} {1,-12} {2,-9} {3,-11} {4}" -f $matrixRole, $matrixTool, $matrixCallable, (Get-RolePermission -Role $matrixRole), $matrixStates)
        }
    }
    Write-Host ""
    Write-Host "Swapping roles: edit .ai/roles/ROLE_ASSIGNMENT.md, keeping Reviewer != Implementer."
    Write-Host ""
    Write-Host "Capability:  Approved commit executor"
    Write-Host "Callable:    yes (PowerShell only)"
    Write-Host "States:      REVIEW_DONE with Waiting For: User"
    Write-Host "Invocation:  commit-check [-Message `"<msg>`"]; commit-approved -Message `"<msg>`" -Authorize `"I_AUTHORIZE_COMMIT`""
    Write-Host "Safety:      Exact user authorization token; Reviewer != Implementer; Changed Files == git status; commits only approved files; no push/tag/deploy/db/secrets."
    Write-Host "Stop:        User Commit Authorization until token is supplied; Environment/Preflight when unavailable."
    Write-Host "User auth:   yes, exact token required for execution"
    Write-Host "Enable next: Use commit-check for dry run; use commit-approved only after independent review has set REVIEW_DONE."
    Write-Host ""
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
            return "Stop category: User Commit Authorization - approve the guarded commit; technical readiness was attested by the Reviewer."
        }
        if ($ForState -eq "IMPLEMENTED") {
            return "Stop category: User Commit Authorization - this work did not require Reviewer review; check it yourself before approving the commit."
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
$HandoffModelProfile = $HandoffStatus.ModelProfile
$script:ModelSelection = Resolve-ModelSelection -ForState $State -HandoffProfile $HandoffModelProfile -CommandProfile $ModelProfile -CommandModel $Model
$RoleCheckpoint = Test-RoleCheckpoint

# v3.4.1 (G6): the checkpoint gates every command except the three read-only ones.
# That left no way out of role drift: `start` is the command that retires a stale
# record, and it was blocked by the very record it would retire. The only documented
# repair was to hand-edit Task Actors, which rewrites the audit trail on a finished
# task - exactly what the protocol exists to prevent.
#
# The escape is deliberately narrow. `start` may proceed ONLY when the sole problem
# is drift, the task is finished and owned by the User, and a new request was given.
# Everything else - active-state drift, an unknown tool, a Reviewer/Implementer
# collision - stays blocked. Invoke-Start then archives the record before resetting
# it, and refuses to reset if that archive cannot be verified.
$RoleRecoveryAllowed = (
    $Command -eq 'start' -and
    $RoleCheckpoint.DriftOnly -and
    -not [string]::IsNullOrWhiteSpace($Request) -and
    $WaitingFor -eq "User" -and
    $State -in @("REVIEW_DONE", "BLOCKED")
)

if (-not $RoleCheckpoint.Ok -and $Command -notin @('doctor', 'status', 'models') -and -not $RoleRecoveryAllowed) {
    Write-RoleCheckpointFailure -Checkpoint $RoleCheckpoint
    exit 12
}

if ($RoleRecoveryAllowed -and -not $RoleCheckpoint.Ok) {
    Write-Host ""
    Write-Host "Role checkpoint: recovering a finished task with drifted Task Actors."
    foreach ($checkpointError in $RoleCheckpoint.Errors) { Write-Host "  $checkpointError" }
    Write-Host "  The finished record will be archived before it is retired."
}

$CommitStatus = switch ($State) {
    "REVIEW_DONE" { "ALLOWED - the Reviewer attested technical readiness; the remaining step is your commit authorization. Commit only the files listed under Changed Files." }
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
        Action = "Commit authorization: the Reviewer attested technical readiness. Approve the guarded commit if satisfied. Do not commit AI_HANDOFF.md."
        After  = "No handoff update required. Commit only the files listed under Changed Files; push remains a separate user decision."
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

function Get-SafeCommitMessage {
    $task = if ([string]::IsNullOrWhiteSpace($CurrentTask) -or $CurrentTask -eq "(unknown)") { "handoff task" } else { $CurrentTask }
    $msg = "Complete $task"
    $msg = $msg -replace '[\r\n\"]', ''
    return $msg.Trim()
}

function Invoke-UserNext {
    $entry = $ActionMap[$State]
    $commitMessage = Get-SafeCommitMessage
    Write-Host ""
    Write-Host "User Next"
    Write-Host "State:        $State"
    Write-Host "Waiting For:  $WaitingFor"
    Write-Host "Task:         $CurrentTask"
    Write-Host "Model:        $($script:ModelSelection.EffectiveProfile) -> $($script:ModelSelection.ClaudeModel) ($($script:ModelSelection.Source))"
    Write-Host ""

    if ($State -eq "WAITING_FOR_USER" -and $WaitingFor -eq "User" -and $CurrentTask -eq "Initial setup") {
        Write-Host "Do this next: start the first task from this fresh install."
        Write-Host ""
        Write-Host "Command:"
        Write-Host "  .\scripts\handoff.ps1 start `"Describe the change you want`""
        Write-Host ""
        Write-Host "Then paste the printed Master prompt into Codex."
        Write-Host ""
        return
    }

    if ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") {
        Write-Host "Do this next: approve the guarded local commit if you are satisfied with the review."
        Write-Host ""
        Write-Host "Command:"
        # v3.4.1: print a runnable command, not a relative fragment. A bare
        # ".\scripts\handoff.ps1" fails with "not recognized" from anywhere but the
        # repository root, and the error names nothing about the working directory.
        Write-Host "  cd `"$((Get-Location).Path)`"; .\scripts\handoff.ps1 commit-approved -Message `"$commitMessage`" -Authorize `"I_AUTHORIZE_COMMIT`""
        Write-Host "  git status --short --branch"
        Write-Host ""
        Write-Host "Safety: commits only AI_HANDOFF.md Changed Files after scope checks; no push/tag/deploy/db/secrets."
        Write-Host "Do not commit local coordination/evidence files."
        Write-Host ""
        # v3.4.2: name the release path here too. This command previously offered only
        # commit-approved, and because release rebuilt the commit itself, following that
        # advice left the release executor permanently unreachable.
        Write-Host "If this change is a RELEASE, the guarded release executor is the other path:"
        Write-Host "  handoff.ps1 release-check -Version vX.Y.Z"
        Write-Host "Either order works since v3.4.2 - release verifies scope against HEAD when the tree is already clean."
        Write-Host ""
        return
    }

    if ($entry) {
        $role = $entry.Role
        $actor = Resolve-Actor -Role $role -Binding $Binding
        $isMismatch = ($WaitingFor -ne "(unknown)") -and ($WaitingFor -ne $role) -and ($WaitingFor -ne $actor)
        if ($isMismatch) {
            Write-Host "Do this next: repair the handoff state before continuing."
            Write-Host "Expected Waiting For: $role ($actor); found: $WaitingFor."
        } elseif ($actor -eq "User") {
            Write-Host "Do this next: $($entry.Action)"
        } else {
            Write-Host "Do this next: open $actor and paste the standard handoff prompt."
            Write-Host "Prompt: Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
            Write-Host "Tip: run '.\scripts\handoff.ps1 next -Clip' to refresh NEXT_TURN.md and copy the prompt."
        }
    } else {
        Write-Host "Do this next: inspect AI_HANDOFF.md manually; the state is not recognized by this protocol version."
    }
    Write-Host ""
}

function Invoke-Work {
    $entry = $ActionMap[$State]
    $commitMessage = Get-SafeCommitMessage
    Write-Host ""
    Write-Host "Handoff Work"
    Write-Host "State:        $State"
    Write-Host "Waiting For:  $WaitingFor"
    Write-Host "Current Task: $CurrentTask"
    Write-Host ""

    if ($State -eq "WAITING_FOR_USER" -and $WaitingFor -eq "User" -and $CurrentTask -eq "Initial setup") {
        Write-Host "Next action: start the first task from this fresh install."
        Write-Host ""
        Write-Host "Run:"
        Write-Host "  .\scripts\handoff.ps1 start `"Describe the change you want`""
        Write-Host ""
        Write-Host "Then paste the printed Master prompt into Codex."
        Write-Host ""
        return
    }

    if ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") {
        Write-Host "Next action: approve the guarded local commit if you are satisfied with the review."
        Write-Host ""
        Write-Host "Run:"
        # v3.4.1: print a runnable command, not a relative fragment. A bare
        # ".\scripts\handoff.ps1" fails with "not recognized" from anywhere but the
        # repository root, and the error names nothing about the working directory.
        Write-Host "  cd `"$((Get-Location).Path)`"; .\scripts\handoff.ps1 commit-approved -Message `"$commitMessage`" -Authorize `"I_AUTHORIZE_COMMIT`""
        Write-Host ""
        Write-Host "Safety: commits only AI_HANDOFF.md Changed Files after scope checks; no push/tag/deploy/db/secrets."
        Write-Host ""
        return
    }

    if ($entry) {
        $role = $entry.Role
        $actor = Resolve-Actor -Role $role -Binding $Binding
        $isMismatch = ($WaitingFor -ne "(unknown)") -and ($WaitingFor -ne $role) -and ($WaitingFor -ne $actor)
        if ($isMismatch) {
            Write-Host "Next action: repair the handoff state before continuing."
            Write-Host "Expected Waiting For: $role ($actor); found: $WaitingFor."
        } elseif ($actor -eq "User") {
            Write-Host "Next action: $($entry.Action)"
        } else {
            Write-Host "Next action: open $actor and use the standard handoff prompt."
            Write-Host ""
            Write-Host "Run:"
            Write-Host "  .\scripts\handoff.ps1 next -Clip"
        }
    } else {
        Write-Host "Next action: inspect AI_HANDOFF.md manually; the state is not recognized by this protocol version."
    }
    Write-Host ""
}

function Write-DoctorLine {
    param([string]$Level, [string]$Message)
    if ($Level -eq "FAIL") { $script:DoctorHasFailures = $true }
    if ($Level -eq "WARN") { $script:DoctorHasWarnings = $true }
    Write-Host "$Level  $Message"
}

# v3.4.3: activation is one guarded command instead of hand-edited JSON.
#
# The shipped file maps every profile to inherit and stays that way: the v3.1.7 rule
# forbids an install that changes default behavior, and concrete provider model names
# do not belong in the product - that is the whole point of capability profiles. But
# leaving activation to hand-editing JSON and inventing model names is friction that
# kept a working feature switched off.
#
# This writes only the profiles you name, preserves the rest and the file's _readme,
# validates by reading the result back, and touches no git or handoff state.
function Invoke-ModelActivate {
    $requested = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($Standard))      { $requested["standard"]       = $Standard.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($CheapReadonly)) { $requested["cheap_readonly"] = $CheapReadonly.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($Economy))       { $requested["economy"]        = $Economy.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($HighReasoning)) { $requested["high_reasoning"] = $HighReasoning.Trim() }

    Write-Host ""
    Write-Host "Model Routing Activation"
    if ($requested.Count -eq 0) {
        Write-Host "Blocked: no mapping supplied, so nothing was changed."
        Write-Host ""
        Write-Host "Name at least one profile, for example:"
        Write-Host '  handoff.ps1 models -Activate -Standard "<model>" -CheapReadonly "<smaller model>"'
        Write-Host ""
        Write-Host "Profiles: standard, cheap_readonly, economy, high_reasoning."
        Write-Host "Use the model names your local Claude Code accepts; the protocol does not choose them."
        Write-Host ""
        exit 1
    }

    $configPath = Join-Path (Get-Location) ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host "Blocked: MODEL_ROUTING.json was not found at .ai/skills/codex-claude-handoff/."
        Write-Host "Install or repair the protocol before activating routing."
        Write-Host ""
        exit 1
    }

    $before = "inert"
    if (-not (Test-ModelRoutingInert)) { $before = "active" }

    try {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    } catch {
        Write-Host "Blocked: MODEL_ROUTING.json is not valid JSON and was left untouched."
        Write-Host "Reason: $($_.Exception.Message)"
        Write-Host ""
        exit 1
    }
    if ($null -eq $config.profiles) {
        Write-Host "Blocked: MODEL_ROUTING.json has no 'profiles' object. Nothing was changed."
        Write-Host ""
        exit 1
    }

    foreach ($name in $requested.Keys) {
        if ($null -eq $config.profiles.$name) {
            $config.profiles | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{ claudeModel = $requested[$name] }) -Force
        } else {
            $config.profiles.$name | Add-Member -NotePropertyName "claudeModel" -NotePropertyValue $requested[$name] -Force
        }
        Write-Host "  $name -> $($requested[$name])"
    }

    $temp = "$configPath.tmp"
    try {
        [System.IO.File]::WriteAllText($temp, ($config | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        # Read it back before replacing the original: a file that cannot be parsed would
        # block every later command, so it must never become the live configuration.
        $null = Get-Content -Raw -LiteralPath $temp | ConvertFrom-Json
        Move-Item -LiteralPath $temp -Destination $configPath -Force
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "Blocked: the updated configuration could not be written or re-read. The original file is unchanged."
        Write-Host "Reason: $($_.Exception.Message)"
        Write-Host ""
        exit 1
    }

    $after = "inert"
    if (-not (Test-ModelRoutingInert)) { $after = "active" }
    Write-Host ""
    Write-Host "Routing before: $before"
    Write-Host "Routing after:  $after"
    Write-Host ""
    Write-Host "models-activate: complete. Only .ai/skills/codex-claude-handoff/MODEL_ROUTING.json was changed."
    Write-Host "No git action was run and no handoff state was modified."
    Write-Host "Run 'handoff.ps1 models' to see the resolution for the current state."
    Write-Host ""
}

function Invoke-Models {
    if ($Activate) { Invoke-ModelActivate; return }
    Write-Host ""
    Write-Host "Model Routing"
    Write-Host "State:              $State"
    Write-Host "Handoff profile:    $HandoffModelProfile"
    Write-Host "Requested profile:  $($script:ModelSelection.RequestedProfile)"
    Write-Host "Effective profile:  $($script:ModelSelection.EffectiveProfile)"
    Write-Host "Claude model:       $($script:ModelSelection.ClaudeModel)"
    Write-Host "Resolution source:  $($script:ModelSelection.Source)"
    Write-Host "Config:             .ai/skills/codex-claude-handoff/MODEL_ROUTING.json"
    if (-not $script:ModelSelection.Ok) {
        Write-Host "Status:             BLOCKED"
        foreach ($error in $script:ModelSelection.Errors) { Write-Host "Reason:             $error" }
        exit 1
    }
    Write-Host "Status:             OK"
    if ($script:ModelSelection.ClaudeModel -eq "inherit") {
        Write-Host "Behavior:           Claude Code uses its configured/default model."
    } else {
        Write-Host "Behavior:           The Claude adapter passes --model with the resolved value."
    }
    if ($script:ModelSelection.NeedsEscalationApproval) {
        Write-Host "Approval:           -AllowModelEscalation is required for cycle/loop."
    }
    if (Test-ModelRoutingInert) {
        Write-Host ""
        Write-Host "Routing:            INERT - every profile in MODEL_ROUTING.json resolves to inherit."
        Write-Host "                    The Master still selects a capability profile per task, but the"
        Write-Host "                    selection currently changes nothing: every turn runs on whatever"
        Write-Host "                    model Claude Code is already using."
        Write-Host "                    To activate, map profiles to concrete local models in"
        Write-Host "                    .ai/skills/codex-claude-handoff/MODEL_ROUTING.json."
    }

    Write-Host ""
    Write-Host "Override order: -Model, HANDOFF_CLAUDE_MODEL_<PROFILE>, MODEL_ROUTING.json, inherit."
    Write-Host "The protocol selects capability profiles; concrete provider model names remain local and replaceable."
}

# v3.4.2: a feature that silently does nothing is worse than one that is off, because
# the user cannot tell which they have. The shipped MODEL_ROUTING.json maps every
# profile to inherit - deliberately, since the v3.1.7 rule forbids an install that
# changes default behavior, and freezing vendor model names is exactly what the
# capability-profile design avoids. The defect was never the default; it was that no
# output said the routing was doing nothing. This reports that state without changing it.
function Test-ModelRoutingInert {
    $configPath = Join-Path (Get-Location) ".ai/skills/codex-claude-handoff/MODEL_ROUTING.json"
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    try {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    } catch {
        return $false
    }
    if ($null -eq $config -or $null -eq $config.profiles) { return $false }

    $any = $false
    foreach ($property in $config.profiles.PSObject.Properties) {
        $value = $property.Value
        if ($null -eq $value) { continue }
        $model = $value.claudeModel
        if ([string]::IsNullOrWhiteSpace($model)) { continue }
        $any = $true
        if ($model -ne "inherit") { return $false }
    }
    return $any
}

function Invoke-DoctorRemoteVersionCheck {
    param([string]$InstalledVersion)

    if (-not $CheckUpdates) {
        Write-DoctorLine "INFO" "Version update check skipped; rerun with -CheckUpdates to compare against GitHub."
        return
    }

    $remoteUri = "https://github.com/siglernir-ai/codex-claude-handoff.git"
    $remoteLines = @()
    try {
        $remoteLines = @(& git ls-remote --tags --refs $remoteUri "refs/tags/v*" 2>$null)
    } catch { }
    if ($LASTEXITCODE -ne 0 -or $remoteLines.Count -eq 0) {
        $script:DoctorRemoteCheckUnavailable = $true
        Write-DoctorLine "WARN" "Could not check the latest release from GitHub. Local checks still completed."
        return
    }

    $remoteVersions = @(
        foreach ($line in $remoteLines) {
            if ($line -match "\srefs/tags/v(\d+\.\d+\.\d+)$") {
                try { [version]$Matches[1] } catch { }
            }
        }
    )
    if ($remoteVersions.Count -eq 0) {
        $script:DoctorRemoteCheckUnavailable = $true
        Write-DoctorLine "WARN" "GitHub returned no stable vX.Y.Z release tags to compare."
        return
    }

    $latest = $remoteVersions | Sort-Object | Select-Object -Last 1
    $installed = $null
    try { $installed = [version]$InstalledVersion } catch { }
    if ($null -eq $installed) { return }

    # v3.4.1 (G3): a TAG is not a RELEASE. Until now this compared against tags and
    # then called the newest tag "the latest stable release", so v3.4.0 - tagged and
    # pushed with no package, no ZIP and no checksum ever published - was reported as
    # a healthy latest release. The safety tool was blind to the exact gap it should
    # have caught. Report the three facts separately instead of conflating them.
    if ($installed -lt $latest) {
        $script:DoctorUpdateAvailable = $true
        Write-DoctorLine "WARN" "Source tag: installed $InstalledVersion; latest source tag is v$latest."
        Write-Host "      Use the pinned bootstrap command from QUICKSTART.md to update safely."
    } elseif ($installed -eq $latest) {
        Write-DoctorLine "OK" "Source tag: installed $InstalledVersion matches the latest source tag v$latest."
    } else {
        Write-DoctorLine "INFO" "Source tag: installed $InstalledVersion is newer than the latest public tag v$latest."
    }

    Invoke-DoctorReleaseCheck -LatestTag "v$latest"
}

# Ask GitHub what has actually been RELEASED, and whether that release carries the
# artifacts an installer needs. A tag with no release, or a release with no ZIP and
# checksum, is reported as a WARN - it is publishable source, not an installable
# product. Network failure is a WARN too, never a hard failure: local checks must
# still be able to finish.
function Invoke-DoctorReleaseCheck {
    param([string]$LatestTag)

    $api = "https://api.github.com/repos/siglernir-ai/codex-claude-handoff/releases/tags/$LatestTag"
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "codex-claude-handoff-doctor" } -TimeoutSec 15
    } catch {
        $release = $null
    }

    if ($null -eq $release) {
        $script:DoctorRemoteCheckUnavailable = $true
        Write-DoctorLine "WARN" "GitHub Release: no published release found for $LatestTag (or GitHub was unreachable)."
        Write-Host "      A tag is not a release. Until a release is published, the pinned install command has nothing to download."
        return
    }

    Write-DoctorLine "OK" "GitHub Release: $LatestTag is published."

    $zipName = "codex-claude-handoff-$LatestTag.zip"
    $assetNames = @()
    if ($release.assets) { $assetNames = @($release.assets | ForEach-Object { $_.name }) }
    $hasZip = $assetNames -contains $zipName
    $hasSum = $assetNames -contains "$zipName.sha256"

    if ($hasZip -and $hasSum) {
        Write-DoctorLine "OK" "Release assets: $zipName and its .sha256 are attached to $LatestTag."
    } else {
        $script:DoctorRemoteCheckUnavailable = $true
        $missing = @()
        if (-not $hasZip) { $missing += $zipName }
        if (-not $hasSum) { $missing += "$zipName.sha256" }
        Write-DoctorLine "WARN" "Release assets: $LatestTag is missing $($missing -join ' and ')."
        Write-Host "      The installer verifies the checksum before extracting, so this release cannot be installed safely."
    }
}

function Invoke-Doctor {
    Write-Host ""
    Write-Host "Handoff Doctor"
    Write-Host ""

    $script:DoctorHasFailures = $false
    $script:DoctorHasWarnings = $false
    $script:DoctorUpdateAvailable = $false
    $script:DoctorRemoteCheckUnavailable = $false

    $gitOk = $false
    try {
        $inside = (& git rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $inside -eq "true") { $gitOk = $true }
    } catch { }
    if ($gitOk) {
        Write-DoctorLine "OK" "Git repo detected."
    } else {
        Write-DoctorLine "FAIL" "Git repo not detected from this directory."
    }

    $doctorStatus = @{ State = "(unknown)"; WaitingFor = "(unknown)"; CurrentTask = "(unknown)"; ModelProfile = "auto" }
    if (Test-Path $HandoffFile) {
        $doctorStatus = Read-HandoffState -Lines $Lines
        if ($doctorStatus.State -ne "(unknown)" -and $doctorStatus.WaitingFor -ne "(unknown)") {
            Write-DoctorLine "OK" "AI_HANDOFF.md status: State=$($doctorStatus.State); Waiting For=$($doctorStatus.WaitingFor); Current Task=$($doctorStatus.CurrentTask)"
        } else {
            Write-DoctorLine "WARN" "AI_HANDOFF.md exists, but its Status section could not be fully read."
        }
    } else {
        Write-DoctorLine "FAIL" "AI_HANDOFF.md is missing. Run the installer from the project root."
    }

    $versionPath = Join-Path (Get-Location) ".ai/skills/codex-claude-handoff/VERSION"
    $protocolVersion = $null
    if (Test-Path $versionPath) {
        $protocolVersion = (Get-Content -Raw -Path $versionPath).Trim()
        if ($protocolVersion -match '^\d+\.\d+\.\d+$') {
            Write-DoctorLine "OK" "Protocol version: $protocolVersion"
        } else {
            Write-DoctorLine "FAIL" "Protocol VERSION is invalid: '$protocolVersion' (expected X.Y.Z)."
        }
    } else {
        Write-DoctorLine "FAIL" "Protocol VERSION file missing: .ai/skills/codex-claude-handoff/VERSION"
    }

    $requiredProtocolFiles = @(
        "scripts\handoff.ps1",
        "scripts\handoff.sh",
        "scripts\next-step.ps1",
        "scripts\next-step.sh",
        ".agents\skills\codex-claude-handoff\SKILL.md",
        ".claude\skills\codex-claude-handoff\SKILL.md",
        ".ai\skills\codex-claude-handoff\SKILL.md",
        ".ai\skills\codex-claude-handoff\ADAPTERS.md",
        ".ai\skills\codex-claude-handoff\PROTOCOL_METHOD.md",
        ".ai\skills\codex-claude-handoff\CLAUDE_EXECUTION_POLICY.md",
        ".ai\skills\codex-claude-handoff\MODEL_ROUTING.json",
        ".ai\roles\ROLE_ASSIGNMENT.md"
    )
    $missingProtocolFiles = @($requiredProtocolFiles | Where-Object { -not (Test-Path (Join-Path (Get-Location) $_)) })
    if ($missingProtocolFiles.Count -eq 0) {
        Write-DoctorLine "OK" "Installed protocol components are present ($($requiredProtocolFiles.Count) required files)."
    } else {
        Write-DoctorLine "FAIL" "Installed protocol is incomplete; missing required files:"
        foreach ($missing in $missingProtocolFiles) { Write-Host "      $missing" }
    }

    $rolesPath = Join-Path (Get-Location) ".ai/roles/ROLE_ASSIGNMENT.md"
    if (Test-Path $rolesPath) {
        Write-DoctorLine "OK" "Role assignment: Master=$($Binding.Master), Reviewer=$($Binding.Reviewer), Implementer=$($Binding.Implementer)"
    } else {
        Write-DoctorLine "FAIL" "Role assignment file missing: .ai/roles/ROLE_ASSIGNMENT.md"
    }
    if ($RoleCheckpoint.Ok) {
        Write-DoctorLine "OK" "Role checkpoint: binding and derived Task Actors are synchronized."
    } else {
        Write-DoctorLine "FAIL" "Role checkpoint: drift or invalid Reviewer/Implementer binding detected."
        foreach ($error in $RoleCheckpoint.Errors) { Write-Host "      $error" }
    }

    # Report run state UNCONDITIONALLY, before and independent of model resolution.
    # Nesting it inside the model-selection-OK branch meant that a repository with
    # invalid routing - one of the states a user is most likely to run doctor in -
    # silently lost the answer to "is something running right now?".
    $doctorRun = Get-RunMarkerState
    if ($doctorRun.Alive) {
        Write-DoctorLine "INFO" "An automated turn is running now: $($doctorRun.Kind), process $($doctorRun.ProcessId). Stop it with handoff.ps1 stop."
    } elseif ($doctorRun.Present) {
        # doctor deliberately does NOT clear this. It closes every run by stating that
        # no files were changed, and that guarantee is worth more than tidying a marker
        # here: a diagnostic that silently mutates state is no longer a diagnostic.
        # status and stop both clear it, and the message says so.
        Write-DoctorLine "WARN" "A stale run marker is present for process $($doctorRun.ProcessId), which is no longer running. doctor is read-only and will not remove it; run handoff.ps1 status or handoff.ps1 stop to clear it."
    } else {
        Write-DoctorLine "OK" "No automated turn is running."
    }

    $doctorModelSelection = Resolve-ModelSelection -ForState $doctorStatus.State -HandoffProfile $doctorStatus.ModelProfile -CommandProfile $ModelProfile -CommandModel $Model
    if ($doctorModelSelection.Ok) {
        Write-DoctorLine "OK" "Model routing: profile=$($doctorModelSelection.EffectiveProfile); Claude model=$($doctorModelSelection.ClaudeModel); source=$($doctorModelSelection.Source)"
    if (Test-ModelRoutingInert) {
        Write-DoctorLine "INFO" "Model routing is INERT: every profile in MODEL_ROUTING.json resolves to inherit, so profile selection currently changes no model."
        Write-Host "      Map profiles to concrete local models in .ai/skills/codex-claude-handoff/MODEL_ROUTING.json to activate per-task routing."
    }
    } else {
        Write-DoctorLine "FAIL" "Model routing configuration is invalid."
        foreach ($error in $doctorModelSelection.Errors) { Write-Host "      $error" }
    }

    $tree = Get-WorkingTreeState
    if (-not $tree.Ok) {
        Write-DoctorLine "WARN" "Git working tree status could not be read."
    } elseif ($tree.Files.Count -eq 0) {
        Write-DoctorLine "OK" "Git working tree clean after local coordination exclusions."
    } else {
        Write-DoctorLine "WARN" "Git working tree has non-local changes after coordination exclusions:"
        foreach ($f in $tree.Files) { Write-Host "      $f" }
    }

    $npxCmd = Get-Command npx -ErrorAction SilentlyContinue
    if (-not $npxCmd) { $npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue }
    if ($npxCmd) {
        $npxVersion = ""
        try { $npxVersion = (& $npxCmd.Source --version 2>$null | Out-String).Trim() } catch { }
        if ([string]::IsNullOrWhiteSpace($npxVersion)) {
            Write-DoctorLine "OK" "npx available for Claude Code automation: $($npxCmd.Source)"
        } else {
            Write-DoctorLine "OK" "npx available for Claude Code automation: $npxVersion ($($npxCmd.Source))"
        }
    } else {
        Write-DoctorLine "WARN" "npx not found; Claude Code automation cannot start through the local runner."
    }

    if (Get-Command Resolve-CodexCli -ErrorAction SilentlyContinue) {
        $codex = Resolve-CodexCli
        if ($codex.Ok) {
            Write-DoctorLine "OK" "Codex CLI available: $($codex.Path) ($($codex.Source))"
        } else {
            Write-DoctorLine "INFO" "Codex CLI not available or not runnable for exec --help: $($codex.Error)"
        }
    } else {
        Write-DoctorLine "INFO" "Codex CLI helper is not present in this script; skipping Codex CLI availability."
    }

    if ($protocolVersion -and ($protocolVersion -match '^\d+\.\d+\.\d+$')) {
        Invoke-DoctorRemoteVersionCheck -InstalledVersion $protocolVersion
    }

    Write-Host ""
    if ($script:DoctorHasFailures) {
        Write-Host "Doctor result: FAIL (local installation is incomplete or invalid)."
        $doctorExitCode = 10
    } elseif ($script:DoctorUpdateAvailable) {
        Write-Host "Doctor result: UPDATE AVAILABLE (local installation is usable but not current)."
        $doctorExitCode = 11
    } elseif ($script:DoctorRemoteCheckUnavailable) {
        Write-Host "Doctor result: LOCAL CHECKS PASSED; REMOTE VERSION CHECK UNAVAILABLE."
        $doctorExitCode = 12
    } else {
        Write-Host "Doctor result: PASS."
        $doctorExitCode = 0
    }
    Write-Host "Read-only check complete. No files, AI tools, git commits, pushes, tags, deploys, databases, or secrets were changed."
    Write-Host ""
    exit $doctorExitCode
}
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
    $runState = Get-RunMarkerState
    if ($runState.Alive) {
        Write-Host "Running:      YES - $($runState.Kind), process $($runState.ProcessId), started $($runState.StartedUtc) UTC. Stop it with: handoff.ps1 stop"
    } elseif ($runState.Present) {
        # Clear it here as well as in stop. A marker whose process is gone is not
        # information, it is a false alarm, and leaving it for a second command to tidy
        # up means the next status call repeats the same false alarm.
        Clear-RunMarker
        Write-Host "Running:      no (a stale marker for process $($runState.ProcessId) was found and cleared)"
    } else {
        Write-Host "Running:      no automated turn in flight"
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

            # v3.4.1: lead with the automated route when one exists.
            #
            # This command printed "Open / Paste" and nothing else, so the manual
            # window handoff read as THE way to take a turn - even for roles that
            # have had a verified callable adapter since v1.3.0. The information was
            # in `adapters`, which nobody opens. A default command should offer the
            # best available route and keep the manual one as the fallback.
            $turnAdapter = Resolve-TurnAdapter -ForState $State -Role $role -Tool $actor
            if ($turnAdapter.Callable) {
                Write-Host "Automated route available - no paste required:"
                Write-Host "  $($turnAdapter.NextStep)"
                Write-Host "Manual paste above remains valid if you prefer to drive the turn yourself."
                Write-Host ""
            }

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

    # Safety fallback: warn if not gitignored (pre-v0.10.0 installs).
    #
    # Until v3.4.1 this parsed .gitignore by hand and compared against the bare
    # name "USER_REQUEST.md". The shipped .gitignore correctly uses the
    # root-anchored form "/USER_REQUEST.md", so the check never matched and a
    # correctly configured repository was warned on every start. A safety tool
    # that cries wolf teaches the user to ignore it.
    #
    # Ask Git instead. git check-ignore understands anchoring, negation,
    # directory rules, and every other .gitignore semantic we would otherwise
    # have to reimplement.
    if (-not (Test-PathIgnoredByGit -RelativePath "USER_REQUEST.md")) {
        Write-Host "WARNING: USER_REQUEST.md is not ignored by Git. Add /USER_REQUEST.md to .gitignore to avoid committing user requests."
    }

    $handoffPath = Join-Path (Get-Location) "AI_HANDOFF.md"
    if (Test-Path $handoffPath) {
        $safeToOpenNewTask = (
            ($State -eq "WAITING_FOR_USER" -and $WaitingFor -eq "User" -and $CurrentTask -eq "Initial setup") -or
            ($State -eq "REVIEW_DONE" -and $WaitingFor -eq "User") -or
            ($State -eq "BLOCKED" -and $WaitingFor -eq "User")
        )
        if ($safeToOpenNewTask) {
            $tree = Get-WorkingTreeState
            if ($tree.Ok -and $tree.Files.Count -eq 0) {
                $date = (Get-Date).ToString("yyyy-MM-dd")
                $taskLine = ($Request -replace '[\r\n]+', ' ').Trim()
                $handoffContent = @"
# AI Handoff

## Status
- State: NEEDS_ANALYSIS
- Waiting For: Master
- Last Updated By: User
- Last Updated At: $date
- Current Task: $taskLine
- Model Profile: auto

## Last Update
- Actor: User
- Date: $date
- Task: Started a new handoff request with `handoff.ps1 start`.

## Task Actors
- Implementer: TBD
- Reviewer: TBD

## Done
- None yet - this task has not started.

## Changed Files
- None yet

## Verification
- Commands Run: none yet
- Build: not run
- Lint: not run
- Tests: not run
- Manual Check: not run

## Dialogue / Open Questions
- None

## Open Issues
- None.

## Risks / Notes
- AI_HANDOFF.md is local coordination and must not be committed.

## Next Recommended Step
- Master: read USER_REQUEST.md, route through the Decision Router, assign Task Actors, and set the appropriate next state.
"@
                # v3.4.1 (G5): archive before reset, and fail closed. The record about
                # to be overwritten is the only copy of who did what on the finished
                # task; refusing to start is strictly better than losing it.
                $archive = Save-HandoffArchive -HandoffPath $handoffPath -Label $CurrentTask
                if (-not $archive.Ok) {
                    Write-Host ""
                    Write-Host "BLOCKED: AI_HANDOFF.md was NOT reset because it could not be archived."
                    Write-Host "Reason: $($archive.Error)"
                    Write-Host "The existing handoff record is untouched. Resolve the archive problem and run start again."
                    Write-Host ""
                    return
                }
                $archiveRelative = $archive.Path.Substring((Get-Location).Path.Length).TrimStart('\', '/')
                Write-Host "Archived previous handoff -> $archiveRelative"
                Write-Host "  SHA256: $($archive.Hash)  (verified)"

                Set-Content -Path $handoffPath -Value $handoffContent -Encoding utf8
                Write-Host "AI_HANDOFF.md prepared for Master analysis."
            } elseif ($tree.Ok) {
                Write-Host "WARNING: AI_HANDOFF.md was not reset because non-local working-tree changes exist."
                Write-Host "Commit, stash, or resolve these files first:"
                foreach ($f in $tree.Files) { Write-Host "  $f" }
            } else {
                Write-Host "WARNING: AI_HANDOFF.md was not reset because git status could not be checked."
            }
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
    $plan = Get-CommitPlan
    Show-CommitPlan -CommitMessage $Message -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "commit-check: blocked."
        foreach ($err in $plan.Errors) { Write-Host "Reason: $err" }
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }
    Write-Host "commit-check: ready for explicit authorization."
    Write-Host "To execute from Codex Window Mode after user approval, run:"
    $shownMessage = if ([string]::IsNullOrWhiteSpace($Message)) { "<message>" } else { $Message }
    Write-Host "  handoff.ps1 commit-approved -Message `"$shownMessage`" -Authorize `"I_AUTHORIZE_COMMIT`""
    Write-Host ""
}

function Get-ReleaseChangedFiles {
    param([string[]]$FromLines = $Lines)
    $changedFilesLines = Get-SectionLines -Lines $FromLines -Heading "Changed Files"
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

# v3.4.1: shares the single encoding-explicit, NUL-delimited capture with
# Get-WorkingTreeState. Both gates must agree on what a changed file is; two
# parsers meant two answers for the same repository.
function Get-GitChangedFilesForRelease {
    $status = Get-GitStatusFields
    if (-not $status.Ok) { return @{ Ok = $false; Files = [System.Collections.Generic.List[string]]::new() } }
    return @{ Ok = $true; Files = (ConvertFrom-GitStatusFields -Fields $status.Fields) }
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
    # v3.4.3: Ordinal, not OrdinalIgnoreCase. On a case-sensitive filesystem README.md
    # and readme.md are two different files, and this comparison decides what gets
    # committed and released. Treating them as one was a correctness hole in the most
    # important check the protocol has. It never bit on Windows; it would on the Linux
    # and macOS volumes the Bash entry point exists to support.
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $Expected) { [void]$expectedSet.Add([string]$e) }
    $actualSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($a in $Actual) { [void]$actualSet.Add([string]$a) }
    return $expectedSet.SetEquals($actualSet)
}

# When two file sets differ only by letter case, "does not match" printed over two lists
# that look identical is a message nobody can act on. Detect that case so the caller can
# name it.
function Test-FileSetDiffersOnlyByCase {
    param([object[]]$Expected, [object[]]$Actual)
    $exactExpected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $Expected) { [void]$exactExpected.Add([string]$e) }
    $exactActual = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($a in $Actual) { [void]$exactActual.Add([string]$a) }
    if ($exactExpected.SetEquals($exactActual)) { return $false }

    $looseExpected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Expected) { [void]$looseExpected.Add([string]$e) }
    $looseActual = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $Actual) { [void]$looseActual.Add([string]$a) }
    return $looseExpected.SetEquals($looseActual)
}

# A dirty tree is expected after a Reviewer BLOCKED verdict: the Implementer must
# correct the already-reviewed files in place. Permit that resume only when the
# current dirty file set matches AI_HANDOFF.md Changed Files exactly. Arbitrary
# dirty READY_FOR_IMPLEMENTATION states remain blocked.
function Get-ReviewerBlockedResumePlan {
    param(
        [hashtable]$Tree,
        [string]$StateValue = $State,
        [string]$WaitingForValue = $WaitingFor,
        [string[]]$HandoffLines = $Lines
    )

    $expected = @(Get-ReleaseChangedFiles -FromLines $HandoffLines)
    $lastUpdate = (Get-SectionLines -Lines $HandoffLines -Heading "Last Update") -join "`n"
    $implementer = Resolve-Actor -Role "Implementer" -Binding $Binding
    $isBlockedCorrection = ($StateValue -eq "READY_FOR_IMPLEMENTATION") -and
        (($WaitingForValue -eq "Implementer") -or ($WaitingForValue -eq $implementer)) -and
        ($lastUpdate -match '(?im)^-\s*Verdict:\s*BLOCKED\s*$')
    $exactScope = $Tree.Ok -and ($expected.Count -gt 0) -and
        (Test-SameFileSet -Expected $expected -Actual $Tree.Files)

    return @{
        Allowed = ($isBlockedCorrection -and $exactScope)
        IsBlockedCorrection = $isBlockedCorrection
        ExactScope = $exactScope
        ExpectedFiles = $expected
    }
}

function Get-FileSetFingerprint {
    param([object[]]$Files)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @($Files | Sort-Object)) {
        $path = Join-Path (Get-Location) ([string]$file)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
            $parts.Add("$file|file|$hash")
        } elseif (Test-Path -LiteralPath $path) {
            $parts.Add("$file|non-file")
        } else {
            $parts.Add("$file|missing")
        }
    }
    return ($parts -join "`n")
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

# The file set of the current commit, read NUL-delimited so non-ASCII and spaced paths
# survive exactly as they do everywhere else in the exact-scope machinery.
function Get-HeadCommitFiles {
    $files = [System.Collections.Generic.List[string]]::new()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "git"
        $psi.Arguments = "show --name-only -z --format= HEAD"
        $psi.WorkingDirectory = (Get-Location).Path
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $null = $errTask.GetAwaiter().GetResult()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return @{ Ok = $false; Files = $files } }
        foreach ($entry in ($stdout -split "`0")) {
            if ([string]::IsNullOrEmpty($entry)) { continue }
            if ($LocalHandoffFiles -contains $entry) { continue }
            $files.Add($entry)
        }
        return @{ Ok = $true; Files = $files }
    } catch {
        return @{ Ok = $false; Files = $files }
    }
}

# --- Packaging gate (v3.4.1, G4) ---
#
# The release artifacts live in dist/, which is gitignored. Every guard that
# inspects tracked files is therefore blind to a missing package: v3.4.0 was
# tagged and pushed while its ZIP was never built, and no check objected.
#
# This verifies the artifact the same way an installer must: the ZIP exists, the
# checksum file exists, its format is strict, it names this exact ZIP, and the
# recorded hash matches the file on disk. Anything else blocks the release.
function Test-ReleasePackage {
    param([string]$Version)

    $errors = [System.Collections.Generic.List[string]]::new()
    $zipName = "codex-claude-handoff-$Version.zip"
    $zipPath = Join-Path (Get-Location) "dist/$zipName"
    $sumPath = "$zipPath.sha256"
    $hash = ""

    if (-not (Test-Path -LiteralPath $zipPath)) {
        $errors.Add("Release package dist/$zipName does not exist. Build it with scripts/build-package.ps1 before releasing; a tag without a package is not a release.")
    }
    if (-not (Test-Path -LiteralPath $sumPath)) {
        $errors.Add("Release checksum dist/$zipName.sha256 does not exist. The installer verifies this file, so a release without it cannot be installed safely.")
    }

    if ($errors.Count -eq 0) {
        $text = ""
        try { $text = (Get-Content -LiteralPath $sumPath -Raw).Trim() } catch { $text = "" }
        if ($text -notmatch '^([0-9a-fA-F]{64})\s+(\S.*)$') {
            $errors.Add("Malformed checksum file dist/$zipName.sha256. Expected '<64-hex>  $zipName'.")
        } else {
            $expected = $Matches[1].ToLowerInvariant()
            $named = $Matches[2].Trim()
            if ($named -ne $zipName) {
                $errors.Add("Checksum file names '$named' but the package is '$zipName'. Refusing to release a mismatched pair.")
            }
            $actual = ""
            try { $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant() } catch { $actual = "" }
            if ($actual -eq "") {
                $errors.Add("Could not hash dist/$zipName to verify it against its checksum.")
            } elseif ($actual -ne $expected) {
                $errors.Add("SHA-256 mismatch for dist/$zipName. Checksum records $expected but the file is $actual. Rebuild the package.")
            } else {
                $hash = $actual
            }
        }
    }

    return @{ Ok = ($errors.Count -eq 0); Errors = $errors; Zip = $zipPath; Checksum = $sumPath; Hash = $hash }
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
    # v3.4.1: canonical identity, not display text. 'Codex' and 'Codex Window'
    # are the same tool and must not pass this gate as two different reviewers.
    if (Test-SameToolIdentity -First $taskActors.Reviewer -Second $taskActors.Implementer) {
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
    # v3.4.2: accept an already-committed HEAD.
    #
    # release performs add, commit, push and tag, so it assumed uncommitted work. But
    # user-next at REVIEW_DONE always points at commit-approved, and once that has run
    # the tree is clean, git status lists nothing, and this check failed on an empty
    # set - making the release executor unreachable by following the tool's own
    # instructions. That happened while releasing v3.4.1; push and tag were done by hand.
    #
    # Scope is still verified exactly. When the tree is clean, the comparison moves to
    # the file set of HEAD: the reviewed commit must contain exactly the approved files.
    # A HEAD that does not match still blocks.
    $releaseFromHead = $false
    if ($gitState.Ok -and $gitState.Files.Count -eq 0) {
        $headFiles = Get-HeadCommitFiles
        if ($headFiles.Ok -and (Test-SameFileSet -Expected $releaseFiles -Actual $headFiles.Files)) {
            $releaseFromHead = $true
        } else {
            $ok = $false
            $errors.Add("The working tree is clean, so the release would use the files already committed at HEAD - but HEAD's file set does not match AI_HANDOFF.md Changed Files. Release the commit that was reviewed, or restore the pending changes.")
        }
    } elseif ($gitState.Ok -and -not (Test-SameFileSet -Expected $releaseFiles -Actual $gitState.Files)) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files does not exactly match git status after excluding local coordination files. Paths must be spelled exactly as Git reports them: repository-relative, forward slashes, no quoting and no leading ./" + $(if (Test-FileSetDiffersOnlyByCase -Expected $releaseFiles -Actual $gitState.Files) { " The two lists differ only in letter case. Paths are compared exactly, because on a case-sensitive filesystem they are different files." } else { "" }))
    }
    $package = $null
    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
        & git rev-parse -q --verify "refs/tags/$RequestedVersion" *> $null
        if ($LASTEXITCODE -eq 0) {
            $ok = $false
            $errors.Add("Tag $RequestedVersion already exists.")
        }

        # v3.4.1 (G4): packaging gate. A release is not a tag - it is a verified
        # artifact. v3.4.0 was tagged and pushed with no package ever built, and
        # nothing objected, because dist/ is gitignored and therefore invisible to
        # every check that only looks at tracked files. Refuse to release a version
        # whose ZIP and checksum do not exist and agree.
        $package = Test-ReleasePackage -Version $RequestedVersion
        if (-not $package.Ok) {
            $ok = $false
            foreach ($packageError in $package.Errors) { $errors.Add($packageError) }
        }
    }

    return @{
        Ok = $ok
        Errors = $errors
        ReleaseFiles = $releaseFiles
        GitFiles = $gitState.Files
        TaskActors = $taskActors
        Package = $package
        ReleaseFromHead = $releaseFromHead
    }
}

function Get-CommitPlan {
    $commitFiles = Get-ReleaseChangedFiles
    $gitState = Get-GitChangedFilesForRelease
    $taskActors = Get-TaskActors

    $ok = $true
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($State -ne "REVIEW_DONE" -or $WaitingFor -ne "User") {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must be State: REVIEW_DONE and Waiting For: User before approved commit.")
    }
    if ($taskActors.ImplementerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Implementer for commit audit.")
    }
    if ($taskActors.ReviewerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Reviewer for commit audit.")
    }
    # v3.4.1: canonical identity, not display text. 'Codex' and 'Codex Window'
    # are the same tool and must not pass this gate as two different reviewers.
    if (Test-SameToolIdentity -First $taskActors.Reviewer -Second $taskActors.Implementer) {
        $ok = $false
        $errors.Add("Commit audit invariant violation: actual Reviewer must not equal actual Implementer.")
    }
    if (-not $gitState.Ok) {
        $ok = $false
        $errors.Add("Could not read git status.")
    }
    if ($commitFiles.Count -eq 0) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files has no committable files.")
    }
    if ($gitState.Ok -and $gitState.Files.Count -eq 0) {
        $ok = $false
        $errors.Add("Working tree has no committable changes after excluding local coordination files.")
    }
    if ($gitState.Ok -and -not (Test-SameFileSet -Expected $commitFiles -Actual $gitState.Files)) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files does not exactly match git status after excluding local coordination files. Paths must be spelled exactly as Git reports them: repository-relative, forward slashes, no quoting and no leading ./" + $(if (Test-FileSetDiffersOnlyByCase -Expected $commitFiles -Actual $gitState.Files) { " The two lists differ only in letter case. Paths are compared exactly, because on a case-sensitive filesystem they are different files." } else { "" }))
    }

    return @{
        Ok = $ok
        Errors = $errors
        CommitFiles = $commitFiles
        GitFiles = $gitState.Files
        TaskActors = $taskActors
    }
}

function Show-CommitPlan {
    param([string]$CommitMessage, [hashtable]$Plan)

    Write-Host ""
    Write-Host "Approved commit plan"
    Write-Host "Commit message: $(if ([string]::IsNullOrWhiteSpace($CommitMessage)) { '(required for commit-approved)' } else { $CommitMessage })"
    Write-Host "State:          $State"
    Write-Host "Waiting For:    $WaitingFor"
    Write-Host "Current Task:   $CurrentTask"
    Write-Host "Global binding Reviewer:    $($Binding.Reviewer)"
    Write-Host "Global binding Implementer: $($Binding.Implementer)"
    Write-Host "Actual Reviewer:            $(if ($Plan.TaskActors.Reviewer -ne '') { $Plan.TaskActors.Reviewer } else { '(missing or ambiguous)' })"
    Write-Host "Actual Implementer:         $(if ($Plan.TaskActors.Implementer -ne '') { $Plan.TaskActors.Implementer } else { '(missing or ambiguous)' })"
    Write-Host ""

    Write-Host "Files from AI_HANDOFF.md Changed Files (local coordination files excluded):"
    if ($Plan.CommitFiles.Count -eq 0) {
        Write-Host "  (none)"
    } else {
        foreach ($f in $Plan.CommitFiles) { Write-Host "  $f" }
    }
    Write-Host ""
    Write-Host "Git status files to commit (local coordination files excluded):"
    if ($Plan.GitFiles.Count -eq 0) {
        Write-Host "  (none)"
    } else {
        foreach ($f in $Plan.GitFiles) { Write-Host "  $f" }
    }
    Write-Host ""

    Write-Host "Exact mutating commands if authorized:"
    Write-Host "  git add -- <files listed above>"
    Write-Host "  git commit -m `"$CommitMessage`""
    Write-Host ""
    Write-Host "Safety: no git push, no git tag, no deploy/db/secrets, and local coordination files are excluded."
    Write-Host ""
}

function Invoke-CommitApproved {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host ""
        Write-Host "commit-approved: blocked."
        Write-Host "Reason: Missing -Message."
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }

    $expectedToken = "I_AUTHORIZE_COMMIT"
    if ($Authorize -ne $expectedToken) {
        Write-Host ""
        Write-Host "commit-approved: blocked."
        Write-Host "Reason: Missing exact authorization token."
        Write-Host "Expected: -Authorize `"$expectedToken`""
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }

    $plan = Get-CommitPlan
    Show-CommitPlan -CommitMessage $Message -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "commit-approved: blocked."
        foreach ($err in $plan.Errors) { Write-Host "Reason: $err" }
        Write-Host "No git mutations were run."
        Write-Host ""
        exit 1
    }

    Write-Host ""
    Write-Host "Authorization accepted. Creating approved commit."
    $fileArray = [string[]]$plan.CommitFiles
    & git add -- @fileArray
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git add"; exit 1 }
    & git commit -m $Message
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git commit"; exit 1 }

    Write-Host ""
    Write-Host "commit-approved: complete."
    Write-Host "No push/tag/release action was run."
    Write-Host "Next step: continue with the next handoff task, or push manually when you decide."
    Write-Host ""
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
    # v3.4.2: when the reviewed change is already committed, releasing must NOT try to
    # build the commit again. git add would stage nothing and git commit would fail on
    # an empty commit, which is precisely why the release executor was unreachable after
    # commit-approved. Get-ReleasePlan has already verified that HEAD's file set equals
    # the approved Changed Files, so the commit step is complete, not skipped.
    if ($plan.ReleaseFromHead) {
        Write-Host "Working tree is clean and HEAD matches the approved Changed Files."
        Write-Host "Releasing the existing reviewed commit: $(& git rev-parse --short HEAD)"
        Write-Host "Skipping git add and git commit - the commit step is already done."
    } else {
        $fileArray = [string[]]$plan.ReleaseFiles
        & git add -- @fileArray
        if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git add"; exit 1 }
        & git commit -m $Message
        if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: git commit"; exit 1 }
    }
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
- Model Profile: auto

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
    # RequireCli: review-run/review-check need a runnable Codex CLI; review-apply does NOT
    # (it consumes an already-captured verdict file), so it passes -RequireCli:$false and a
    # placeholder Cli result is returned instead of probing the filesystem/PATH.
    param([bool]$RequireCli = $true)
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
        $errors.Add("AI_HANDOFF.md must be State: READY_FOR_REVIEW and Waiting For: Reviewer to run a Reviewer turn.")
    }
    # v3.4.1: resolve identity before the capability lookup, and read the capability
    # from the ADAPTER rather than from a hardcoded vendor name. Until v3.5.0 this asked
    # "is the reviewer Codex", which was the same question only because Codex was the
    # only tool with a Reviewer adapter. It is no longer the same question: asking it the
    # old way would refuse a Claude Code Reviewer that is in fact fully callable.
    # A tool with no adapter is still a CAPABILITY limit, not a protocol objection -
    # reassigning the Reviewer stays legitimate and simply routes to a manual turn.
    $reviewerAdapter = Get-AdapterProfile -Role "Reviewer" -Tool $boundReviewer
    if (-not $reviewerAdapter.Callable) {
        $ok = $false
        $errors.Add("No callable Reviewer adapter for '$boundReviewer'. The role assignment itself is valid - run 'handoff.ps1 next' and complete this Reviewer turn manually in $boundReviewer.")
    }
    if ($taskActors.ImplementerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Implementer.")
    }
    if ($taskActors.ReviewerCount -ne 1) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must include exactly one Task Actors Reviewer.")
    }
    if ($taskActors.Reviewer -ne "" -and -not (Get-AdapterProfile -Role "Reviewer" -Tool $taskActors.Reviewer).Callable) {
        $ok = $false
        $errors.Add("No callable Reviewer adapter for the actual task Reviewer '$($taskActors.Reviewer)'; complete this turn manually with 'handoff.ps1 next'.")
    }
    # v3.5.0: the bound Reviewer and the Reviewer the task actually records must be the
    # same tool. That was implied while both had to be Codex; once either tool can hold
    # the role, it has to be checked, or a swap mid-task would run one tool under the
    # other tool's authority.
    if ($taskActors.Reviewer -ne "" -and -not (Test-SameToolIdentity -First $taskActors.Reviewer -Second $boundReviewer)) {
        $ok = $false
        $errors.Add("The actual task Reviewer '$($taskActors.Reviewer)' is not the bound Reviewer '$boundReviewer'. Re-open the task with 'handoff.ps1 start' after changing the binding; never run a turn under another tool's authority.")
    }
    # v3.4.1: canonical identity, not display text. 'Codex' and 'Codex Window'
    # are the same tool and must not pass this gate as two different reviewers.
    if (Test-SameToolIdentity -First $taskActors.Reviewer -Second $taskActors.Implementer) {
        $ok = $false
        $errors.Add("Independent-review invariant: the actual Reviewer must not equal the actual Implementer.")
    }
    if (-not $gitState.Ok) {
        $ok = $false
        $errors.Add("Could not read git status.")
    }
    # v3.4.4: plan mode. The Master can route to PLAN_REQUIRED, which asks for a plan to
    # be reviewed before implementation - and until now the Reviewer could not open that
    # gate, because review-run refused whenever Changed Files was empty. The Master could
    # send you somewhere the Reviewer could not follow. This task was itself routed to
    # PLAN_REQUIRED, so the defect demonstrated itself on the attempt to fix it.
    #
    # Plan mode is entered only when there is genuinely a plan and genuinely no code.
    # Nothing to review is still nothing to review: an empty Changed Files list with no
    # Plan section keeps the original refusal.
    # "Genuinely no code" means the WORKING TREE is clean, not merely that Changed Files
    # was left empty. Deciding plan mode from the declared list alone would let undeclared
    # implementation pass as a plan-only review and skip code review entirely - declaring
    # nothing would become a way to review nothing. The declared list and git must agree
    # that there is no code.
    $planMode = $false
    if ($reviewFiles.Count -eq 0) {
        $planText = (Get-SectionLines -Lines $Lines -Heading "Plan") -join "`n"
        $treeIsClean = ($gitState.Ok -and $gitState.Files.Count -eq 0)
        if ([string]::IsNullOrWhiteSpace($planText)) {
            $ok = $false
            $errors.Add("AI_HANDOFF.md Changed Files has no reviewable files, and there is no '## Plan' section to review instead.")
        } elseif (-not $gitState.Ok) {
            $ok = $false
            $errors.Add("A plan review requires a verified-clean working tree, and git status could not be read. Refusing to treat an unknown tree as empty.")
        } elseif (-not $treeIsClean) {
            $ok = $false
            $errors.Add("A plan review requires no implementation, but the working tree has changes that AI_HANDOFF.md does not declare: $([string]::Join(', ', $gitState.Files)). Declare them under Changed Files for a code review, or revert them for a plan review. Undeclared work must never bypass code review.")
        } else {
            $planMode = $true
        }
    }
    if (-not $planMode -and $gitState.Ok -and -not (Test-SameFileSet -Expected $reviewFiles -Actual $gitState.Files)) {
        $ok = $false
        $errors.Add("AI_HANDOFF.md Changed Files does not match git status after excluding local coordination files. Paths must be spelled exactly as Git reports them: repository-relative, forward slashes, no quoting and no leading ./")
    }

    # v3.5.0: resolve the runner the BOUND REVIEWER needs, not the Codex CLI by reflex.
    # A Claude Code Reviewer needs npx and the Claude Code package; a Codex Reviewer needs
    # the Codex CLI. Probing for the wrong one would block a perfectly runnable turn.
    $reviewerIsCodex = (Test-SameToolIdentity -First $boundReviewer -Second "Codex")
    $cli = if (-not $RequireCli) {
        @{ Ok = $true; Path = ""; Source = "not required for review-apply"; Error = "" }
    } elseif ($reviewerIsCodex) {
        Resolve-CodexCli
    } elseif (Test-ClaudeAvailable) {
        @{ Ok = $true; Path = "npx @anthropic-ai/claude-code"; Source = "npx (Claude Code)"; Error = "" }
    } else {
        @{ Ok = $false; Path = ""; Source = ""; Error = "Claude Code is not runnable here: 'npx --yes @anthropic-ai/claude-code --version' did not succeed. Install Node.js and npx, or bind the Reviewer to a tool that is available." }
    }

    return @{
        Ok = $ok
        Errors = $errors
        ReviewFiles = $reviewFiles
        PlanMode    = $planMode
        GitFiles = $gitState.Files
        TaskActors = $taskActors
        BoundReviewer = $boundReviewer
        BoundImplementer = $boundImplementer
        ReviewerIsCodex = $reviewerIsCodex
        Cli = $cli
    }
}

function Show-ReviewPlan {
    param([hashtable]$Plan)
    $repoRoot = (Get-Location).Path
    Write-Host ""
    Write-Host "$($Plan.BoundReviewer) Reviewer plan (read-only; capture only)"
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
    Write-Host "$($Plan.BoundReviewer) runner resolution:"
    if ($Plan.Cli.Ok) {
        Write-Host "  Resolved: $($Plan.Cli.Path)"
        Write-Host "  Source:   $($Plan.Cli.Source)"
    } else {
        Write-Host "  Not resolved: $($Plan.Cli.Error)"
    }
    Write-Host ""
    Write-Host "Read-only invocation shape (review-run, after explicit confirmation):"
    if ($Plan.ReviewerIsCodex) {
        Write-Host "  codex exec --cd `"$repoRoot`" --sandbox read-only --ephemeral --json --output-last-message `"$ReviewLastName`" -   (review prompt via stdin)"
    } else {
        Write-Host "  npx --yes @anthropic-ai/claude-code --safe-mode --disallowed-tools `"Bash,Edit,Write,NotebookEdit`" -p `"<review prompt>`" --output-format text   (final message captured to $ReviewLastName)"
    }
    Write-Host "Captured artifacts (local, gitignored, never committed):"
    Write-Host "  $ReviewJsonlName  (event log)"
    Write-Host "  $ReviewLastName  (Reviewer final message)"
    Write-Host ""
    if ($Plan.ReviewerIsCodex) {
        Write-Host "Safety: read-only sandbox; no --ask-for-approval; no --dangerously-bypass-approvals-and-sandbox;"
    } else {
        Write-Host "Safety: file-writing tools disabled (Bash, Edit, Write, NotebookEdit) and the working tree is"
        Write-Host "        compared after the turn - any change fails the review and discards the capture;"
    }
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

# --- Protocol-run review evidence (v3.4.1) ---
#
# Runs the protocol suite from the harness - not from either agent - and binds the
# result to the exact bytes it was run against. The Reviewer recomputes the hashes
# in its own read-only sandbox, so the evidence is checkable rather than trusted.
#
# A suite that cannot be found or cannot complete produces an explicitly negative
# summary, never an optimistic one: the Reviewer must block on it.
function Get-ReviewTestEvidence {
    param([string[]]$Files)

    $suite = Join-Path (Get-Location) "scripts/protocol-tests.ps1"
    $summary = ""
    if (-not (Test-Path -LiteralPath $suite)) {
        $summary = "NOT RUN - scripts/protocol-tests.ps1 was not found in this repository. Treat readiness as unverified and return BLOCKED."
    } else {
        try {
            Write-Host "Running the protocol suite for review evidence (outside the sandbox)..."
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $suite 2>&1
            $suiteExit = $LASTEXITCODE
            $resultLine = @($output | Select-String -Pattern '^\s*Results:\s+\d+\s+passed,\s+\d+\s+failed' | Select-Object -Last 1)
            if ($resultLine.Count -eq 0) {
                $summary = "INCONCLUSIVE - the suite produced no Results line (exit code $suiteExit). Treat readiness as unverified and return BLOCKED."
            } else {
                $line = $resultLine[0].ToString().Trim()
                $failedNames = @($output | Select-String -Pattern '^\s+-\s+' | ForEach-Object { $_.ToString().Trim() })
                # The printed Results line is a claim by the suite about itself. The
                # process exit code is the independent signal: a run that crashes after
                # printing, or fails in a way the counter never sees, still exits
                # nonzero. Requiring BOTH keeps the evidence fail-closed - trusting the
                # printed line alone would report success for an unsuccessful run.
                if (($line -match 'Results:\s+(\d+)\s+passed,\s+0\s+failed') -and ($suiteExit -eq 0)) {
                    $summary = "$line (run by handoff.ps1; suite exit code 0)."
                } elseif ($line -match 'Results:\s+(\d+)\s+passed,\s+0\s+failed') {
                    $summary = "INCONSISTENT - the suite printed '$line' but exited with code $suiteExit. A nonzero exit means the run did not succeed regardless of the printed counters. Treat readiness as unverified and return BLOCKED."
                } else {
                    $summary = "$line (run by handoff.ps1; suite exit code $suiteExit). Failing checks: " + ([string]::Join(" | ", $failedNames))
                }
            }
            Write-Host "  $summary"
        } catch {
            $summary = "NOT RUN - the suite could not be executed: $($_.Exception.Message). Treat readiness as unverified and return BLOCKED."
        }
    }

    $pairs = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Files) {
        $full = Join-Path (Get-Location) $f
        if (Test-Path -LiteralPath $full) {
            try {
                $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
                $pairs.Add("$f = $h")
            } catch {
                $pairs.Add("$f = UNREADABLE")
            }
        } else {
            $pairs.Add("$f = MISSING")
        }
    }

    return @{ Summary = $summary; Hashes = [string]::Join(" ; ", $pairs) }
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
    # v3.5.0: this preflight verifies the CODEX exec path specifically, so it runs only
    # when Codex is the tool holding the Reviewer role. A Claude Code Reviewer was already
    # probed by Test-ClaudeAvailable during planning.
    if ($plan.ReviewerIsCodex) {
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
    # broad skill/protocol context and to inspect the handoff, git status, changed files'
    # diffs, and only the safe local read-only checks needed for technical readiness.
    # Keep it free of shell metacharacters; it is delivered on stdin.
    $reviewFileList = [string]::Join("; ", @($plan.ReviewFiles))

    # v3.4.1: the PROTOCOL runs the test suite, not the Implementer and not the Reviewer.
    #
    # The Reviewer executes in --sandbox read-only, which denies the temporary fixture
    # directory the suite needs, so every review that required running tests blocked
    # forever. Relaxing the sandbox was rejected: the only mode that grants a writable
    # temp also makes the repository writable, and a reviewer that can edit the work is
    # not a reviewer. Verified empirically - --add-dir does not grant write under
    # read-only.
    #
    # So the harness runs the suite itself, outside the sandbox, and hands the Reviewer
    # the result together with the SHA-256 of every file under review. The Reviewer
    # recomputes those hashes in its own read-only sandbox and compares. That keeps the
    # v3.1.6 rule intact - a handoff report is an untrusted claim - while making the
    # claim checkable: if the code changed after the tests ran, the hashes disagree and
    # the Reviewer blocks. Neither agent attests to its own work.
    # v3.4.4: reviewing a PLAN, not code. Evidence is the handoff itself, hashed the same
    # way, so a plan edited after the evidence was produced fails the same check.
    if ($plan.PlanMode) {
        $planEvidence = Get-ReviewTestEvidence -Files @("AI_HANDOFF.md")
        Write-Host ""
        Write-Host "PLAN REVIEW: Changed Files is empty and AI_HANDOFF.md carries a Plan section."
        Write-Host "Codex will judge the plan's scope and acceptance criteria, not code."
        Write-Host "An APPROVED plan authorizes implementation; it does not finish the task."
        $reviewPrompt = "Read-only PLAN review. There is no implementation yet and no changed files: do not look for code defects, and do not report their absence as a finding. " +
            "Read ONLY AI_HANDOFF.md. Judge the '## Plan' section on four things: whether its scope is bounded and unambiguous; whether its acceptance criteria are checkable rather than aspirational; whether the stated out-of-scope list is honest, meaning it does not quietly exclude work the task obviously requires; and what the plan's main risk is. " +
            "PROTOCOL-RUN EVIDENCE (produced by handoff.ps1 outside your sandbox): $($planEvidence.Summary) The file under review had this SHA-256 when the evidence was produced: $($planEvidence.Hashes) " +
            "Verify rather than trust it: recompute that hash with Get-FileHash and compare. If it differs, the plan changed after the evidence was produced and you must return BLOCKED. " +
            "Approving a plan authorizes implementation; it does not approve any code. Block if the scope is open-ended, if acceptance criteria cannot be checked, or if the out-of-scope list hides required work. " +
            "Never modify any file or mutate the working tree or git index. " +
            "End your reply with a verdict block of EXACTLY four lines, each on its own line, nothing after them, and no surrounding punctuation. " +
            "Line 1 must be exactly 'VERDICT: APPROVED' or exactly 'VERDICT: BLOCKED' (uppercase). " +
            "Line 2 must be exactly 'REVIEWER: $($plan.BoundReviewer)'. " +
            "Line 3 must be 'TASK: ' followed by the Current Task value copied verbatim from the Status section of AI_HANDOFF.md. " +
            "Line 4 must be 'REASON: ' followed by a single concise one-line reason. " +
            "Do not write the word VERDICT, REVIEWER, TASK, or REASON at the start of any earlier line."
    } else {
    $evidence = Get-ReviewTestEvidence -Files @($plan.ReviewFiles)

    $reviewPrompt = "Read-only code review. Be fast and minimal: keep tool calls to a strict minimum and do not explore the repository broadly. " +
        "PROTOCOL-RUN TEST EVIDENCE (produced by handoff.ps1 itself, outside your sandbox, immediately before this review): $($evidence.Summary) " +
        "The exact files under review had these SHA-256 values at the moment the suite ran: $($evidence.Hashes) " +
        "Verify this evidence rather than trusting it: recompute the SHA-256 of each file listed above using a read-only command such as Get-FileHash, and compare. " +
        "If any hash differs, the code changed after the tests ran and you must return BLOCKED. If the evidence reports failures, return BLOCKED. " +
        "Do NOT attempt to run the protocol test suite yourself; your sandbox cannot create its fixtures and the attempt is not evidence of anything. " +
        "Do NOT read or follow AGENTS.md, CLAUDE.md, the codex-claude-handoff skill, or any other protocol or skill files. " +
        "Inspect ONLY these sources initially: AI_HANDOFF.md for the current task and approved scope; the output of git status --short; and git diff -- for each of these Changed Files: $reviewFileList . " +
        "For a Changed File that git status marks as untracked or new, if git diff -- for that file is empty or insufficient, inspect that file's current content directly as the diff equivalent; do not run git add, git add -N, or any other command that mutates the index or working tree. " +
        "Treat verification statements in AI_HANDOFF.md as untrusted claims, not proof. Review every task requirement, including preservation and backward-compatibility clauses, and reason about relevant input classes not covered by the listed tests; existing tests are evidence, not an exhaustive specification. " +
        "If AI_HANDOFF.md marks a relevant check as not run and explicitly names a safe local read-only check, for example node --test, run that check before deciding. You may run only safe local read-only verification commands needed to assess technical readiness. " +
        "Never install dependencies, use the network, deploy, access or mutate a database, inspect or modify secrets or production configuration, modify any file, or mutate the working tree or git index. If required verification cannot run safely or the available evidence is inadequate, return BLOCKED. " +
        "Decide whether the changed files technically satisfy every requirement and remain within the approved scope described in AI_HANDOFF.md. Do not modify any file. " +
        "If you use ripgrep on a pattern that begins with two dashes, pass it after a -- separator, for example rg -- the-pattern. " +
        "Finish quickly. End your reply with a verdict block of EXACTLY four lines, each on its own line, nothing after them, and no surrounding punctuation. " +
        "Line 1 must be exactly 'VERDICT: APPROVED' or exactly 'VERDICT: BLOCKED' (uppercase). " +
        "Line 2 must be exactly 'REVIEWER: $($plan.BoundReviewer)'. " +
        "Line 3 must be 'TASK: ' followed by the Current Task value copied verbatim from the Status section of AI_HANDOFF.md. " +
        "Line 4 must be 'REASON: ' followed by a single concise one-line reason. " +
        "Do not write the word VERDICT, REVIEWER, TASK, or REASON at the start of any earlier line."
    }

    # --- v3.5.0: run whichever tool holds the Reviewer role ---
    #
    # Both branches must leave the same three things behind, because everything after
    # this point - the timeout report, the no-verdict report, the capture validation and
    # review-apply itself - is shared and must not learn which vendor ran:
    #   $lastPath   the final message, or absent if there is no complete verdict
    #   $timedOut   whether the turn was killed on the timeout
    #   $codexExit  the process exit code (-1 if it never produced one)
    # Read-only is not a promise either branch makes about itself: Codex is confined by
    # --sandbox read-only, Claude Code by disallowed write tools plus a working-tree
    # comparison after the turn. Both are checked, neither is trusted.
    $timedOut = $false
    $codexExit = -1
    $stderrText = ""

    Write-Host ""
    if ($plan.ReviewerIsCodex) {
        Write-Host "Running Codex read-only review (timeout: ${TimeoutSeconds}s)..."
        Write-Host "Invocation: codex exec --cd `"$repoRoot`" --sandbox read-only --ephemeral --json --output-last-message `"$ReviewLastName`" -   (prompt via stdin)"
    } else {
        Write-Host "Running $($plan.BoundReviewer) read-only review (timeout: ${TimeoutSeconds}s)..."
        Write-Host "Invocation: bounded runner -> npx --yes @anthropic-ai/claude-code --safe-mode --disallowed-tools `"Bash,Edit,Write,NotebookEdit`" -p `"<review prompt>`" --output-format text   (final message captured to $ReviewLastName)"
    }
    Write-Host ""

    # Clear any stale capture artifacts so old/partial output is never mistaken for this run.
    Remove-Item $jsonlPath, $lastPath -Force -ErrorAction SilentlyContinue

    if ($plan.ReviewerIsCodex) {
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
            Stop-ProcessTree -ProcessId $proc.Id
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        }

        # Preserve partial stdout (JSONL) and capture stderr for diagnostics, regardless of outcome.
        $partial = ""
        if (Test-Path $tmpOut) { $partial = (Get-Content -Raw -Path $tmpOut -ErrorAction SilentlyContinue) }
        if (-not [string]::IsNullOrEmpty($partial)) {
            Set-Content -Path $jsonlPath -Value $partial -Encoding utf8 -ErrorAction SilentlyContinue
        }
        if (Test-Path $tmpErr) { $stderrText = (Get-Content -Raw -Path $tmpErr -ErrorAction SilentlyContinue) }
        Remove-Item $tmpOut, $tmpErr, $promptFile -Force -ErrorAction SilentlyContinue
    } else {
        # Claude Code holds the Reviewer role. Invoke-ClaudeReadOnlyCapture writes the final
        # message to $lastPath itself, which is the contract codex exec satisfies with
        # --output-last-message, so the shared validation below is unchanged.
        $claudeReview = Invoke-ClaudeReadOnlyCapture -TurnRole "Reviewer" -Prompt $reviewPrompt `
            -LastPath $lastPath -JsonlPath $jsonlPath -TurnTimeoutSeconds $TimeoutSeconds -TurnBudgetUsd $BudgetUsd
        $timedOut = $claudeReview.TimedOut
        $codexExit = $claudeReview.ExitCode

        # A read-only turn that edited the repository is a protocol violation, not a
        # review. Fail closed and delete any capture it produced: a verdict from a
        # reviewer that touched the work is worth less than no verdict at all.
        if ($claudeReview.SourceChanged) {
            if (Test-Path $lastPath) { Remove-Item $lastPath -Force -ErrorAction SilentlyContinue }
            Write-Host ""
            Write-Host "review-run: blocked - the read-only Reviewer turn modified the working tree."
            Write-Host "Reason: $($claudeReview.Error)"
            Write-Host "Stop category: Protocol Repair - a Reviewer must never edit what it reviews."
            Write-Host "Any captured verdict from this run was discarded. No git changes were made and AI_HANDOFF.md was not modified."
            Write-Host ""
            exit 5
        }
        if (-not $claudeReview.Ok -and -not $timedOut -and $codexExit -eq 0) {
            # Exited cleanly but produced nothing usable; report it as the no-verdict case
            # the shared path already handles rather than inventing a second failure mode.
            $stderrText = $claudeReview.Error
        } elseif (-not [string]::IsNullOrWhiteSpace($claudeReview.Error)) {
            $stderrText = $claudeReview.Error
        }
    }

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

    # A TRUE non-zero process exit is a failure. A null/unavailable exit code is NOT treated
    # as non-zero here: PowerShell's ($null -ne 0) is $true, which would otherwise make a
    # captured-verdict run look like a non-zero failure. When a final verdict file WAS captured,
    # capture success is what matters - review-apply immediately performs the strict verdict
    # schema parse and all review guards. The no-capture + null/0 case already failed closed
    # above (exit 6), so reaching here with a null exit means a verdict file exists.
    if ($null -ne $codexExit -and $codexExit -ne 0) {
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
    # Codex writes UTF-8 without a BOM. Windows PowerShell 5.1 otherwise reads it
    # using the active ANSI code page and corrupts non-ASCII task text.
    Get-Content -Path $lastPath -Encoding utf8 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "This step captured the review only. It made no git changes and did not modify AI_HANDOFF.md."
    Write-Host "To apply the captured verdict's local handoff transition, run:"
    Write-Host "  handoff.ps1 review-apply"
    Write-Host "(review-apply parses this verdict and sets REVIEW_DONE for APPROVED or READY_FOR_IMPLEMENTATION for BLOCKED; it edits only AI_HANDOFF.md and runs no git.)"
    Write-Host "Stop category: Operator Manual Action - run review-apply, or apply the transition manually."
    Write-Host ""
}

# --- Automated Reviewer Turn (v1.3.0): review-apply applies a captured verdict ---
#
# review-apply consumes the verdict captured by review-run (CODEX_REVIEW_LAST.md) and
# applies the corresponding LOCAL AI_HANDOFF.md transition, fail-closed. It does NOT
# re-invoke Codex, runs no git, and edits only AI_HANDOFF.md. It is modeled on
# sequence-advance: guarded plan -> strict parse -> single local-file rewrite.

# Strict verdict parser. Returns @{ Ok; Verdict; Reviewer; Task; Reason; Error }.
# Fails closed unless the capture contains exactly one well-formed verdict block whose
# REVIEWER is Codex and whose TASK matches the current Current Task (anti-stale guard).
function Get-VerdictFromCapture {
    param([string]$Path, [string]$ExpectedTask)
    $result = @{ Ok = $false; Verdict = ""; Reviewer = ""; Task = ""; Reason = ""; Error = "" }
    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Error = "No captured verdict file ($ReviewLastName) found. Run 'handoff.ps1 review-run' first to capture a Codex review verdict."
        return $result
    }
    # Codex output-last-message is UTF-8 without a BOM. Read it explicitly so the
    # anti-stale TASK comparison works for Hebrew and other non-ASCII text on
    # Windows PowerShell 5.1.
    $raw = Get-Content -Raw -Path $Path -Encoding utf8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.Error = "Captured verdict file ($ReviewLastName) is empty; no verdict to apply."
        return $result
    }
    $captureLines = $raw -split "`r?`n"
    $verdictLines  = @($captureLines | Where-Object { $_ -match '^\s*VERDICT:\s*(.+?)\s*$' })
    $reviewerLines = @($captureLines | Where-Object { $_ -match '^\s*REVIEWER:\s*(.+?)\s*$' })
    $taskLines     = @($captureLines | Where-Object { $_ -match '^\s*TASK:\s*(.+?)\s*$' })
    $reasonLines   = @($captureLines | Where-Object { $_ -match '^\s*REASON:\s*(.+?)\s*$' })
    if ($verdictLines.Count  -ne 1) { $result.Error = "Captured verdict must contain exactly one VERDICT: line (found $($verdictLines.Count)). The capture is malformed or stale; re-run review-run."; return $result }
    if ($reviewerLines.Count -ne 1) { $result.Error = "Captured verdict must contain exactly one REVIEWER: line (found $($reviewerLines.Count))."; return $result }
    if ($taskLines.Count     -ne 1) { $result.Error = "Captured verdict must contain exactly one TASK: line (found $($taskLines.Count))."; return $result }
    if ($reasonLines.Count   -ne 1) { $result.Error = "Captured verdict must contain exactly one REASON: line (found $($reasonLines.Count))."; return $result }
    [void]($verdictLines[0]  -match '^\s*VERDICT:\s*(.+?)\s*$');  $verdict  = $Matches[1].Trim()
    [void]($reviewerLines[0] -match '^\s*REVIEWER:\s*(.+?)\s*$'); $reviewer = $Matches[1].Trim()
    [void]($taskLines[0]     -match '^\s*TASK:\s*(.+?)\s*$');     $task     = $Matches[1].Trim()
    [void]($reasonLines[0]   -match '^\s*REASON:\s*(.+?)\s*$');   $reason   = $Matches[1].Trim()
    # Case-sensitive: the verdict token must be exactly APPROVED or BLOCKED.
    if ($verdict -cne "APPROVED" -and $verdict -cne "BLOCKED") {
        $result.Error = "VERDICT must be exactly APPROVED or BLOCKED (found: '$verdict')."
        return $result
    }
    if (-not (Test-SameToolIdentity -First $reviewer -Second "Codex")) {
        $result.Error = "REVIEWER in the captured verdict must resolve to Codex (found: '$reviewer'). Only captures produced by the Codex Reviewer adapter can be applied."
        return $result
    }
    if ($task -ne $ExpectedTask) {
        $result.Error = "Captured verdict TASK does not match the current task (anti-stale guard). Verdict TASK: '$task'; current Current Task: '$ExpectedTask'. The capture may be stale - re-run review-run for this task."
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $result.Error = "REASON in the captured verdict must be a non-empty line."
        return $result
    }
    $result.Ok = $true; $result.Verdict = $verdict; $result.Reviewer = $reviewer; $result.Task = $task; $result.Reason = $reason
    return $result
}

# Replace the body of a single '## <Heading>' section (everything up to the next '## '
# heading or EOF) with $NewBody, preserving the heading line and all other sections.
# Returns @{ Ok = section found; Lines = rebuilt lines }. Fails closed (Ok=$false) when
# the heading is absent so a malformed handoff is never silently rewritten.
function Set-HandoffSectionBody {
    param([string[]]$Lines, [string]$Heading, [string[]]$NewBody)
    $out = [System.Collections.Generic.List[string]]::new()
    $found = $false
    $i = 0
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        if (-not $found -and $line.TrimEnd() -eq "## $Heading") {
            $found = $true
            $out.Add($line)
            foreach ($b in $NewBody) { $out.Add($b) }
            $i++
            while ($i -lt $Lines.Count -and $Lines[$i] -notmatch '^##\s') { $i++ }
            if ($i -lt $Lines.Count) { $out.Add("") }   # one blank line before the next heading
            continue
        }
        $out.Add($line)
        $i++
    }
    return @{ Ok = $found; Lines = $out.ToArray() }
}

# Validate the review-apply request: reuse ALL Get-ReviewPlan protocol guards (no Codex CLI
# needed) plus parse the captured verdict against the current task.
function Get-ReviewApplyPlan {
    $base = Get-ReviewPlan -RequireCli:$false
    # v3.5.0: read the role-named capture, falling back to the legacy vendor-named file
    # so an install carrying a verdict written by an earlier version still applies.
    $verdictPath = Resolve-CapturePath -RepoRoot (Get-Location).Path -Preferred $ReviewLastName -Legacy $LegacyReviewLastName
    $verdict = Get-VerdictFromCapture -Path $verdictPath -ExpectedTask $CurrentTask
    return @{ Base = $base; Verdict = $verdict }
}

function Show-ReviewApplyPlan {
    param([hashtable]$Base, [hashtable]$Verdict)
    Write-Host ""
    Write-Host "Review apply plan (consumes the captured verdict; edits only AI_HANDOFF.md; runs no git)"
    Write-Host "State:               $State"
    Write-Host "Waiting For:         $WaitingFor"
    Write-Host "Current Task:        $CurrentTask"
    Write-Host "Bound Reviewer:      $($Base.BoundReviewer)"
    Write-Host "Bound Implementer:   $($Base.BoundImplementer)"
    Write-Host "Actual Reviewer:     $(if ($Base.TaskActors.Reviewer -ne '') { $Base.TaskActors.Reviewer } else { '(missing or ambiguous)' })"
    Write-Host "Actual Implementer:  $(if ($Base.TaskActors.Implementer -ne '') { $Base.TaskActors.Implementer } else { '(missing or ambiguous)' })"
    Write-Host "Capture file:        $ReviewLastName (local, gitignored capture from review-run)"
    if ($Verdict.Ok) {
        # v3.4.4: an APPROVED PLAN authorizes implementation; it does not finish the
        # task. Only an approved code review reaches REVIEW_DONE.
        $target = if ($Verdict.Verdict -ne "APPROVED") { "READY_FOR_IMPLEMENTATION / Waiting For: Implementer" }
                  elseif ($Base.PlanMode) { "READY_FOR_IMPLEMENTATION / Waiting For: Implementer (approved PLAN)" }
                  else { "REVIEW_DONE / Waiting For: User" }
        Write-Host "Captured verdict:    $($Verdict.Verdict)"
        Write-Host "Captured reason:     $($Verdict.Reason)"
        Write-Host "Would transition to: $target"
    } else {
        Write-Host "Captured verdict:    (not usable) $($Verdict.Error)"
    }
    Write-Host ""
    Write-Host "Safety: edits only AI_HANDOFF.md (local, gitignored); no git add/commit/push/tag;"
    Write-Host "        no deploy/db/secrets; no release action; not auto-run by loop/cycle by default."
    Write-Host "        PowerShell loop may invoke it only when the operator passed -IncludeReviewer."
    Write-Host ""
}

function Invoke-ReviewApply {
    $plan = Get-ReviewApplyPlan
    $base = $plan.Base
    $verdict = $plan.Verdict
    Show-ReviewApplyPlan -Base $base -Verdict $verdict

    if (-not $base.Ok) {
        Write-Host "review-apply: blocked."
        foreach ($e in $base.Errors) { Write-Host "Reason: $e" }
        Write-Host "No files were changed and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 1
    }
    if (-not $verdict.Ok) {
        Write-Host "review-apply: blocked."
        Write-Host "Reason: $($verdict.Error)"
        Write-Host "Stop category: Environment/Preflight (no usable captured verdict) - not a user decision."
        Write-Host "No files were changed and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 1
    }

    $date = (Get-Date).ToString("yyyy-MM-dd")
    # v3.4.4: an approved PLAN authorizes implementation; it does not finish the task.
    # Sending an approved plan to REVIEW_DONE would put a task with no code written into
    # the state whose only remaining step is the user's commit authorization.
    if ($verdict.Verdict -eq "APPROVED" -and -not $plan.Base.PlanMode) {
        $newState = "REVIEW_DONE"; $newWaiting = "User"
    } else {
        $newState = "READY_FOR_IMPLEMENTATION"; $newWaiting = "Implementer"
    }

    Write-Host "This applies the captured $($verdict.Verdict) verdict as a LOCAL AI_HANDOFF.md transition to:"
    Write-Host "  State: $newState / Waiting For: $newWaiting"
    Write-Host "It makes NO git changes and performs NO release action."
    Write-Host ""
    if ($Yes) {
        Write-Host "Confirmation: -Yes supplied; applying without an interactive prompt (local AI_HANDOFF.md edit only)."
    } else {
        # Fail closed: only an explicit, non-null "yes" proceeds.
        $confirm = Read-Host 'Type "yes" to apply this verdict to AI_HANDOFF.md, or press Enter to cancel'
        if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
            Write-Host "Cancelled."
            Write-Host "AI_HANDOFF.md was not modified."
            exit 2
        }
    }

    $statusBody = @(
        "- State: $newState",
        "- Waiting For: $newWaiting",
        "- Last Updated By: Reviewer",
        "- Last Updated At: $date",
        "- Current Task: $CurrentTask",
        "- Model Profile: $HandoffModelProfile"
    )
    $lastUpdateBody = @(
        "- Actor: Reviewer (Codex), applied from the captured review verdict via review-apply",
        "- Date: $date",
        "- Task: Applied the captured Codex review verdict for '$CurrentTask'.",
        "- Verdict: $($verdict.Verdict)",
        "- Reason: $($verdict.Reason)",
        "- Source: $ReviewLastName (local, gitignored capture from review-run; not committed)"
    )
    if ($verdict.Verdict -eq "APPROVED") {
        $nextStepBody = @(
            "- User: the Reviewer (Codex) attested technical readiness (REVIEW_DONE). Grant commit",
            "  authorization, then use 'handoff.ps1 commit-approved' to commit only Changed Files.",
            "  Do not commit AI_HANDOFF.md. Push/release remains a separate user decision."
        )
    } else {
        $nextStepBody = @(
            "- Implementer (Claude Code): address the Reviewer's BLOCKED findings recorded under",
            "  Last Update (Reason), then set State: READY_FOR_REVIEW / Waiting For: Reviewer."
        )
    }

    # Section-preserving rewrite: Status, Last Update, and Next Recommended Step must all
    # exist or we fail closed without writing anything. Every other section is preserved.
    $cur = Get-Content -Path $HandoffFile
    $r1 = Set-HandoffSectionBody -Lines $cur       -Heading "Status"               -NewBody $statusBody
    $r2 = Set-HandoffSectionBody -Lines $r1.Lines  -Heading "Last Update"          -NewBody $lastUpdateBody
    $r3 = Set-HandoffSectionBody -Lines $r2.Lines  -Heading "Next Recommended Step" -NewBody $nextStepBody
    if (-not ($r1.Ok -and $r2.Ok -and $r3.Ok)) {
        $missing = @()
        if (-not $r1.Ok) { $missing += "Status" }
        if (-not $r2.Ok) { $missing += "Last Update" }
        if (-not $r3.Ok) { $missing += "Next Recommended Step" }
        Write-Host "review-apply: blocked."
        Write-Host "Reason: AI_HANDOFF.md is missing required section(s): $([string]::Join(', ', $missing)). The handoff is malformed; not rewriting."
        Write-Host "Stop category: Protocol Repair - a correction, not a product decision."
        Write-Host "AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 1
    }

    Set-Content -Path $HandoffFile -Value ($r3.Lines -join "`n") -Encoding utf8 -ErrorAction Stop

    Write-Host "review-apply: applied (local AI_HANDOFF.md only)."
    Write-Host "AI_HANDOFF.md: State -> $newState / Waiting For -> $newWaiting (from captured $($verdict.Verdict) verdict)."
    Write-Host ""
    Write-Host "Next steps:"
    if ($verdict.Verdict -eq "APPROVED") {
        Write-Host "  1. User: grant commit authorization; the Reviewer attested technical readiness."
        Write-Host "  2. Use handoff.ps1 commit-check, then commit-approved with the exact authorization token when ready."
    } else {
        Write-Host "  1. Implementer (Claude Code): address the BLOCKED findings, then return to READY_FOR_REVIEW."
    }
    Write-Host "  - This command made no git changes (no add/commit/push/tag) and no deploy/db/secrets actions."
    Write-Host "  - AI_HANDOFF.md remains local and gitignored - do not commit it."
    Write-Host ""
}

# --- Codex Master capture POC (v1.3.1): read-only Master analysis capture ---
#
# master-check / master-run are the Master-side equivalent of the v1.2.0 Reviewer capture
# Since v2.0.1, master-run + master-apply complete the Master/Codex NEEDS_ANALYSIS
# turn end-to-end via explicit commands. master-run remains read-only capture-only;
# master-apply consumes the capture and edits only local AI_HANDOFF.md.

# Validate the Master capture POC request. Always returns every key so callers can print a
# plan even when blocked. Task Actors may be TBD here: the Master turn is expected to
# recommend the actors/gate, so this POC does not require them to be set.
function Get-MasterPlan {
    $ok = $true
    $errors = [System.Collections.Generic.List[string]]::new()
    $boundMaster = Resolve-Actor -Role "Master" -Binding $Binding
    $taskActors = Get-TaskActors

    # Eligibility is the role name (Master), matched exactly rather than the bound tool name.
    if ($State -ne "NEEDS_ANALYSIS" -or $WaitingFor -ne "Master") {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must be State: NEEDS_ANALYSIS and Waiting For: Master to run a Master turn.")
    }
    # v3.4.1: identity first, capability second. Reassigning Master is a valid protocol
    # operation. v3.5.0: read the capability from the ADAPTER instead of asking whether
    # the tool is Codex - both tools have a Master adapter now, and the old question
    # would refuse a Claude Code Master that is fully callable.
    $masterAdapter = Get-AdapterProfile -Role "Master" -Tool $boundMaster
    if (-not $masterAdapter.Callable) {
        $ok = $false
        $errors.Add("No callable Master adapter for '$boundMaster'. The role assignment itself is valid - run 'handoff.ps1 next' and complete this Master turn manually in $boundMaster.")
    }

    # v3.5.0: resolve the runner the bound Master actually needs.
    $masterIsCodex = (Test-SameToolIdentity -First $boundMaster -Second "Codex")
    $cli = if ($masterIsCodex) {
        Resolve-CodexCli
    } elseif (Test-ClaudeAvailable) {
        @{ Ok = $true; Path = "npx @anthropic-ai/claude-code"; Source = "npx (Claude Code)"; Error = "" }
    } else {
        @{ Ok = $false; Path = ""; Source = ""; Error = "Claude Code is not runnable here: 'npx --yes @anthropic-ai/claude-code --version' did not succeed. Install Node.js and npx, or bind the Master to a tool that is available." }
    }

    return @{
        Ok = $ok
        Errors = $errors
        BoundMaster = $boundMaster
        TaskActors = $taskActors
        MasterIsCodex = $masterIsCodex
        Cli = $cli
    }
}

function Show-MasterPlan {
    param([hashtable]$Plan)
    $repoRoot = (Get-Location).Path
    Write-Host ""
    Write-Host "$($Plan.BoundMaster) Master analysis plan (read-only capture; apply via master-apply)"
    Write-Host "State:               $State"
    Write-Host "Waiting For:         $WaitingFor"
    Write-Host "Current Task:        $CurrentTask"
    Write-Host "Bound Master:        $($Plan.BoundMaster)"
    Write-Host "Actual Implementer:  $(if ($Plan.TaskActors.Implementer -ne '') { $Plan.TaskActors.Implementer } else { 'TBD (Master may recommend)' })"
    Write-Host "Actual Reviewer:     $(if ($Plan.TaskActors.Reviewer -ne '') { $Plan.TaskActors.Reviewer } else { 'TBD (Master may recommend)' })"
    Write-Host ""
    Write-Host "$($Plan.BoundMaster) runner resolution:"
    if ($Plan.Cli.Ok) {
        Write-Host "  Resolved: $($Plan.Cli.Path)"
        Write-Host "  Source:   $($Plan.Cli.Source)"
    } else {
        Write-Host "  Not resolved: $($Plan.Cli.Error)"
    }
    Write-Host ""
    Write-Host "Read-only invocation shape (master-run, after explicit confirmation):"
    if ($Plan.MasterIsCodex) {
        Write-Host "  codex exec --cd `"$repoRoot`" --sandbox read-only --ephemeral --json --output-last-message `"$MasterLastName`" -   (master prompt via stdin)"
    } else {
        Write-Host "  npx --yes @anthropic-ai/claude-code --safe-mode --disallowed-tools `"Bash,Edit,Write,NotebookEdit`" -p `"<master prompt>`" --output-format text   (final message captured to $MasterLastName)"
    }
    Write-Host "Captured artifacts (local, gitignored, never committed):"
    Write-Host "  $MasterJsonlName  (event log)"
    Write-Host "  $MasterLastName  (Master final message)"
    Write-Host ""
    if ($Plan.MasterIsCodex) {
        Write-Host "Safety: read-only sandbox; no --ask-for-approval; no --dangerously-bypass-approvals-and-sandbox;"
    } else {
        Write-Host "Safety: file-writing tools disabled (Bash, Edit, Write, NotebookEdit) and the working tree is"
        Write-Host "        compared after the turn - any change fails the turn and discards the capture;"
    }
    Write-Host "        no git add/commit/push/tag; no deploy/db/secrets; no AI_HANDOFF.md state change during capture."
    Write-Host "Apply step: handoff.ps1 master-apply consumes $MasterLastName and edits only local AI_HANDOFF.md."
    Write-Host ""
}

function Invoke-MasterCheck {
    $plan = Get-MasterPlan
    Show-MasterPlan -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "master-check: blocked."
        foreach ($e in $plan.Errors) { Write-Host "Reason: $e" }
        Write-Host "No files were changed and no Codex invocation was run."
        Write-Host ""
        exit 1
    }
    if (-not $plan.Cli.Ok) {
        Write-Host "master-check: protocol guards pass, but no runnable Codex CLI is available."
        Write-Host "Reason: $($plan.Cli.Error)"
        Write-Host "Stop category: Environment/Preflight - resolve the Codex CLI before master-run."
        Write-Host "No files were changed and no Codex invocation was run."
        Write-Host ""
        exit 1
    }
    Write-Host "master-check: ready for operator-confirmed master-run."
    Write-Host "To run the read-only Codex Master analysis, run:"
    Write-Host "  handoff.ps1 master-run"
    Write-Host "Stop category: Operator Manual Action - master-run requires an explicit 'yes' confirmation."
    Write-Host "No files were changed and no Codex invocation was run."
    Write-Host ""
}

function Invoke-MasterRun {
    if ($TimeoutSeconds -lt 1) {
        Write-Host ""
        Write-Host "master-run: blocked."
        Write-Host "Reason: -TimeoutSeconds must be at least 1 (got: $TimeoutSeconds)."
        Write-Host "No Codex invocation was run."
        Write-Host ""
        exit 1
    }
    $plan = Get-MasterPlan
    Show-MasterPlan -Plan $plan
    if (-not $plan.Ok) {
        Write-Host "master-run: blocked."
        foreach ($e in $plan.Errors) { Write-Host "Reason: $e" }
        Write-Host "No Codex invocation was run."
        Write-Host ""
        exit 1
    }
    if (-not $plan.Cli.Ok) {
        Write-Host "master-run: blocked."
        Write-Host "Reason: $($plan.Cli.Error)"
        Write-Host "Stop category: Environment/Preflight (Codex CLI unavailable) - not a user decision."
        Write-Host "No Codex invocation was run."
        Write-Host ""
        exit 3
    }
    # v3.5.0: the Codex exec probe applies only when Codex holds the Master role.
    if ($plan.MasterIsCodex) {
        $execHelp = Test-CodexExecHelp -CodexPath $plan.Cli.Path
        if (-not $execHelp.Ok) {
            Write-Host "master-run: blocked."
            Write-Host "Reason: The resolved Codex CLI did not accept 'exec --help'; cannot verify the read-only exec path. $($execHelp.Error)"
            Write-Host "Resolved: $($plan.Cli.Path)"
            Write-Host "Stop category: Environment/Preflight - not a user decision."
            Write-Host "No Codex Master invocation was run."
            Write-Host ""
            exit 3
        }
    }

    $repoRoot = (Get-Location).Path
    $jsonlPath = Join-Path $repoRoot $MasterJsonlName
    $lastPath  = Join-Path $repoRoot $MasterLastName

    Write-Host ""
    Write-Host "WARNING: This invokes the Codex CLI in a read-only sandbox to analyze the task as Master."
    Write-Host "         It captures Codex output locally and makes NO changes to git or AI_HANDOFF.md."
    Write-Host ""
    if ($Yes) {
        Write-Host "Confirmation: -Yes supplied; proceeding without an interactive prompt (read-only capture only)."
    } else {
        # Fail closed: only an explicit, non-null "yes" proceeds.
        $confirm = Read-Host 'Type "yes" to run the read-only Codex Master analysis, or press Enter to cancel'
        if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
            Write-Host "Cancelled."
            Write-Host "No Codex invocation was run."
            exit 2
        }
    }

    # Tightly scoped Master prompt delivered via STDIN (codex exec -), so a multi-word prompt
    # is never split into argv tokens. Keep it free of shell metacharacters. The recommendation
    # block is captured only; master-apply is the separate fail-closed apply step.
    $masterPrompt = "Read-only task analysis as the Master decision router. Be fast and minimal: keep tool calls to a strict minimum and do not explore the repository broadly. " +
        "Do NOT read or follow AGENTS.md, CLAUDE.md, the codex-claude-handoff skill, or any other protocol or skill files beyond those named here. " +
        "Inspect ONLY these sources, and only as needed: AI_HANDOFF.md for the current task; AI_SEQUENCE.md for current and next task ordering if it exists; the output of git status --short; and, only if needed to classify, the protocol docs .ai/skills/codex-claude-handoff/ADAPTERS.md and .ai/skills/codex-claude-handoff/PROTOCOL_METHOD.md. Do not modify any file. " +
        "Decide how the current NEEDS_ANALYSIS task should be routed (which gate it needs and which actors should hold it). " +
        "If you use ripgrep on a pattern that begins with two dashes, pass it after a -- separator, for example rg -- the-pattern. " +
        "Finish quickly. End your reply with a recommendation block of EXACTLY seven lines, each on its own line, nothing after them, and no surrounding punctuation. " +
        "Line 1 must be 'MASTER_RECOMMENDATION: ' followed by exactly one of READY_FOR_IMPLEMENTATION, PLAN_REQUIRED, NEEDS_INVESTIGATION, or BLOCKED. " +
        "Line 2 must be 'WAITING_FOR: ' followed by exactly one of Implementer or User. " +
        "Line 3 must be 'IMPLEMENTER: ' followed by a tool name or TBD. " +
        "Line 4 must be 'REVIEWER: ' followed by a tool name or TBD. " +
        "Line 5 must be 'TASK: ' followed by the current Current Task exactly. " +
        "Line 6 must be 'MODEL_PROFILE: ' followed by exactly one of inherit, economy, cheap_readonly, standard, or high_reasoning. Choose the least expensive profile that can reliably complete and verify the work; use high_reasoning only for expensive-to-get-wrong work. " +
        "Line 7 must be 'REASON: ' followed by a single concise one-line reason. " +
        "Do not write MASTER_RECOMMENDATION, WAITING_FOR, IMPLEMENTER, REVIEWER, TASK, MODEL_PROFILE, or REASON at the start of any earlier line."

    Write-Host ""
    Write-Host "Running Codex read-only Master analysis (timeout: ${TimeoutSeconds}s)..."
    if ($plan.MasterIsCodex) {
        Write-Host "Invocation: codex exec --cd `"$repoRoot`" --sandbox read-only --ephemeral --json --output-last-message `"$MasterLastName`" -   (prompt via stdin)"
    } else {
        Write-Host "Invocation: bounded runner -> npx --yes @anthropic-ai/claude-code --safe-mode --disallowed-tools `"Bash,Edit,Write,NotebookEdit`" -p `"<master prompt>`" --output-format text   (final message captured to $MasterLastName)"
    }
    Write-Host ""

    # --- v3.5.0: run whichever tool holds the Master role ---
    #
    # Same contract as review-run: both branches leave $lastPath, $timedOut and
    # $codexExit behind, and everything after this point is shared and vendor-blind.
    $timedOut = $false
    $codexExit = -1
    $stderrText = ""

    # Clear any stale capture artifacts so old/partial output is never mistaken for this run.
    Remove-Item $jsonlPath, $lastPath -Force -ErrorAction SilentlyContinue

    if ($plan.MasterIsCodex) {
        # Run Codex as a tracked child process with a hard timeout (same pattern as review-run):
        # prompt on stdin, stdout/stderr to temp files, real PID for a process-tree kill.
        $tmpOut = [System.IO.Path]::GetTempFileName()
        $tmpErr = [System.IO.Path]::GetTempFileName()
        $promptFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $promptFile -Value $masterPrompt -Encoding utf8 -ErrorAction SilentlyContinue
        $argList = @('exec', '--cd', $repoRoot, '--sandbox', 'read-only', '--ephemeral', '--json', '--output-last-message', $lastPath, '-')
        try {
            $proc = Start-Process -FilePath $plan.Cli.Path -ArgumentList $argList -NoNewWindow -PassThru `
                -RedirectStandardInput $promptFile -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        } catch {
            Write-Host "master-run: blocked."
            Write-Host "Reason: Failed to start the Codex CLI: $_"
            Write-Host "Stop category: Environment/Preflight - not a user decision."
            Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
            Remove-Item $tmpOut, $tmpErr, $promptFile -Force -ErrorAction SilentlyContinue
            exit 3
        }
        # Cache the handle so $proc.ExitCode is reliable after exit (a never-touched handle reads null).
        try { $null = $proc.Handle } catch { }

        if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
            $codexExit = $proc.ExitCode
        } else {
            $timedOut = $true
            Stop-ProcessTree -ProcessId $proc.Id
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        }

        $partial = ""
        if (Test-Path $tmpOut) { $partial = (Get-Content -Raw -Path $tmpOut -ErrorAction SilentlyContinue) }
        if (-not [string]::IsNullOrEmpty($partial)) {
            Set-Content -Path $jsonlPath -Value $partial -Encoding utf8 -ErrorAction SilentlyContinue
        }
        if (Test-Path $tmpErr) { $stderrText = (Get-Content -Raw -Path $tmpErr -ErrorAction SilentlyContinue) }
        Remove-Item $tmpOut, $tmpErr, $promptFile -Force -ErrorAction SilentlyContinue
    } else {
        # Claude Code holds the Master role. The Master routes work; it must not perform
        # it, so it runs under the same read-only enforcement as the Reviewer.
        $claudeMaster = Invoke-ClaudeReadOnlyCapture -TurnRole "Master" -Prompt $masterPrompt `
            -LastPath $lastPath -JsonlPath $jsonlPath -TurnTimeoutSeconds $TimeoutSeconds -TurnBudgetUsd $BudgetUsd
        $timedOut = $claudeMaster.TimedOut
        $codexExit = $claudeMaster.ExitCode

        if ($claudeMaster.SourceChanged) {
            if (Test-Path $lastPath) { Remove-Item $lastPath -Force -ErrorAction SilentlyContinue }
            Write-Host ""
            Write-Host "master-run: blocked - the read-only Master turn modified the working tree."
            Write-Host "Reason: $($claudeMaster.Error)"
            Write-Host "Stop category: Protocol Repair - a Master routes work and must never perform it."
            Write-Host "Any captured recommendation from this run was discarded. No git changes were made and AI_HANDOFF.md was not modified."
            Write-Host ""
            exit 5
        }
        if (-not [string]::IsNullOrWhiteSpace($claudeMaster.Error)) {
            $stderrText = $claudeMaster.Error
        }
    }

    Write-Host ""
    if ($timedOut) {
        Write-Host "master-run: TIMED OUT after $TimeoutSeconds seconds."
        Write-Host "The Codex process (and its children) were terminated. NO final recommendation was captured."
        if (Test-Path $jsonlPath) {
            Write-Host "Partial, INCOMPLETE Codex output was preserved (NOT a recommendation): $MasterJsonlName"
        }
        if (Test-Path $lastPath) { Remove-Item $lastPath -Force -ErrorAction SilentlyContinue }
        Write-Host "No $MasterLastName final recommendation exists for this run."
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Codex stderr (partial, before termination):"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight (Codex Master analysis timed out) - not a user decision."
        Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
        Write-Host "Re-run with a larger -TimeoutSeconds if the analysis legitimately needs more time."
        Write-Host ""
        exit 4
    }

    # Fail closed if Codex exited 0 but produced no final message: a capture command must only
    # report success when the artifact exists.
    $hasCapture = Test-Path $lastPath
    if (-not $hasCapture -and ($null -eq $codexExit -or $codexExit -eq 0)) {
        Write-Host "master-run: blocked."
        if ($null -eq $codexExit) {
            Write-Host "Reason: Codex wrote no final message ($MasterLastName), and no reliable process exit code was available; no recommendation was captured."
        } else {
            Write-Host "Reason: Codex exited 0 but wrote no final message ($MasterLastName); no recommendation was captured."
        }
        Write-Host "Captured JSONL (if any): $MasterJsonlName"
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Codex stderr:"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight (no recommendation captured) - not a user decision."
        Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 6
    }

    # Match review-run: a captured final recommendation is authoritative when the
    # process exit code is unavailable/null; only a concrete non-zero code fails.
    if ($null -ne $codexExit -and $codexExit -ne 0) {
        Write-Host "master-run: Codex exited with a non-zero code ($codexExit)."
        Write-Host "Captured JSONL (if any): $MasterJsonlName"
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "Codex stderr:"
            ($stderrText -split "`n") | ForEach-Object { Write-Host "  $($_.TrimEnd())" }
        }
        Write-Host "Stop category: Environment/Preflight - inspect the captured output."
        Write-Host "No git changes were made and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 5
    }

    Write-Host "master-run: complete (read-only capture)."
    Write-Host "Captured artifacts (local, gitignored - do not commit):"
    Write-Host "  $MasterJsonlName"
    Write-Host "  $MasterLastName"
    Write-Host ""
    Write-Host "Codex final message:"
    # Codex writes UTF-8 without a BOM. Windows PowerShell 5.1 otherwise reads it
    # using the active ANSI code page and corrupts non-ASCII task text.
    Get-Content -Path $lastPath -Encoding utf8 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "This captured the Master recommendation only. It made no git changes and did not modify AI_HANDOFF.md."
    Write-Host "To apply the recommendation locally, run:"
    Write-Host "  handoff.ps1 master-apply"
    Write-Host "Master/Codex is callable via explicit master-run + master-apply. PowerShell loop may include it only with -IncludeMaster; cycle never does."
    Write-Host "Stop category: Operator Manual Action - run master-apply, or apply the routing decision manually."
    Write-Host ""
}

# --- Automated Master Turn (v2.0.1): master-apply applies a captured recommendation ---
#
# master-apply consumes the recommendation captured by master-run (CODEX_MASTER_LAST.md)
# and applies the corresponding LOCAL AI_HANDOFF.md transition, fail-closed. It does NOT
# re-invoke Codex, runs no git, and edits only AI_HANDOFF.md.

function Get-MasterRecommendationFromCapture {
    param([string]$Path, [string]$ExpectedTask)
    $result = @{ Ok = $false; Recommendation = ""; WaitingFor = ""; Implementer = ""; Reviewer = ""; Task = ""; ModelProfile = ""; Reason = ""; Error = "" }
    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Error = "No captured Master recommendation file ($MasterLastName) found. Run 'handoff.ps1 master-run' first to capture a Codex Master recommendation."
        return $result
    }
    # Codex output-last-message is UTF-8 without a BOM. Read it explicitly so the
    # anti-stale TASK comparison works for Hebrew and other non-ASCII text on
    # Windows PowerShell 5.1.
    $raw = Get-Content -Raw -Path $Path -Encoding utf8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.Error = "Captured Master recommendation file ($MasterLastName) is empty; no recommendation to apply."
        return $result
    }
    $captureLines = $raw -split "`r?`n"
    $recLines         = @($captureLines | Where-Object { $_ -match '^\s*MASTER_RECOMMENDATION:\s*(.+?)\s*$' })
    $waitingLines     = @($captureLines | Where-Object { $_ -match '^\s*WAITING_FOR:\s*(.+?)\s*$' })
    $implementerLines = @($captureLines | Where-Object { $_ -match '^\s*IMPLEMENTER:\s*(.+?)\s*$' })
    $reviewerLines    = @($captureLines | Where-Object { $_ -match '^\s*REVIEWER:\s*(.+?)\s*$' })
    $taskLines        = @($captureLines | Where-Object { $_ -match '^\s*TASK:\s*(.+?)\s*$' })
    $modelProfileLines = @($captureLines | Where-Object { $_ -match '^\s*MODEL_PROFILE:\s*(.+?)\s*$' })
    $reasonLines      = @($captureLines | Where-Object { $_ -match '^\s*REASON:\s*(.+?)\s*$' })
    if ($recLines.Count         -ne 1) { $result.Error = "Captured recommendation must contain exactly one MASTER_RECOMMENDATION: line (found $($recLines.Count)). The capture is malformed or stale; re-run master-run."; return $result }
    if ($waitingLines.Count     -ne 1) { $result.Error = "Captured recommendation must contain exactly one WAITING_FOR: line (found $($waitingLines.Count))."; return $result }
    if ($implementerLines.Count -ne 1) { $result.Error = "Captured recommendation must contain exactly one IMPLEMENTER: line (found $($implementerLines.Count))."; return $result }
    if ($reviewerLines.Count    -ne 1) { $result.Error = "Captured recommendation must contain exactly one REVIEWER: line (found $($reviewerLines.Count))."; return $result }
    if ($taskLines.Count        -ne 1) { $result.Error = "Captured recommendation must contain exactly one TASK: line (found $($taskLines.Count))."; return $result }
    if ($modelProfileLines.Count -gt 1) { $result.Error = "Captured recommendation may contain at most one MODEL_PROFILE: line (found $($modelProfileLines.Count))."; return $result }
    if ($reasonLines.Count      -ne 1) { $result.Error = "Captured recommendation must contain exactly one REASON: line (found $($reasonLines.Count))."; return $result }
    [void]($recLines[0]         -match '^\s*MASTER_RECOMMENDATION:\s*(.+?)\s*$'); $rec         = $Matches[1].Trim()
    [void]($waitingLines[0]     -match '^\s*WAITING_FOR:\s*(.+?)\s*$');           $waiting     = $Matches[1].Trim()
    [void]($implementerLines[0] -match '^\s*IMPLEMENTER:\s*(.+?)\s*$');           $implementer = $Matches[1].Trim()
    [void]($reviewerLines[0]    -match '^\s*REVIEWER:\s*(.+?)\s*$');              $reviewer    = $Matches[1].Trim()
    [void]($taskLines[0]        -match '^\s*TASK:\s*(.+?)\s*$');                  $task        = $Matches[1].Trim()
    $capturedModelProfile = ""
    if ($modelProfileLines.Count -eq 1) {
        [void]($modelProfileLines[0] -match '^\s*MODEL_PROFILE:\s*(.+?)\s*$')
        $capturedModelProfile = Normalize-ModelProfile -Value $Matches[1].Trim()
    }
    [void]($reasonLines[0]      -match '^\s*REASON:\s*(.+?)\s*$');                $reason      = $Matches[1].Trim()

    $allowed = @("READY_FOR_IMPLEMENTATION", "PLAN_REQUIRED", "NEEDS_INVESTIGATION", "BLOCKED")
    if (-not ($allowed -contains $rec)) {
        $result.Error = "MASTER_RECOMMENDATION must be exactly one of READY_FOR_IMPLEMENTATION, PLAN_REQUIRED, NEEDS_INVESTIGATION, or BLOCKED (found: '$rec')."
        return $result
    }
    if ($waiting -ne "Implementer" -and $waiting -ne "User") {
        $result.Error = "WAITING_FOR must be exactly Implementer or User (found: '$waiting')."
        return $result
    }
    if ($task -ne $ExpectedTask) {
        $result.Error = "Captured recommendation TASK does not match the current task (anti-stale guard). Recommendation TASK: '$task'; current Current Task: '$ExpectedTask'. The capture may be stale - re-run master-run for this task."
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $result.Error = "REASON in the captured recommendation must be a non-empty line."
        return $result
    }
    $resolvedProfile = if (-not [string]::IsNullOrWhiteSpace($capturedModelProfile)) {
        $capturedModelProfile
    } elseif ($rec -eq "NEEDS_INVESTIGATION") {
        "cheap_readonly"
    } elseif ($rec -eq "BLOCKED") {
        "inherit"
    } else {
        "standard"
    }
    if (@("inherit", "economy", "cheap_readonly", "standard", "high_reasoning") -notcontains $resolvedProfile) {
        $result.Error = "MODEL_PROFILE must be exactly one of inherit, economy, cheap_readonly, standard, or high_reasoning (found: '$resolvedProfile')."
        return $result
    }
    if ($rec -eq "BLOCKED") {
        if ($waiting -ne "User") {
            $result.Error = "BLOCKED recommendations must set WAITING_FOR: User."
            return $result
        }
    } else {
        if ($waiting -ne "Implementer") {
            $result.Error = "$rec recommendations must set WAITING_FOR: Implementer."
            return $result
        }
        # v3.4.1: a captured recommendation must name concrete, recognized tools.
        # A sentinel or an unknown identity here would otherwise slip past the
        # collision check below, which is the capture-level independent-review guard.
        $implementerIdentity = Resolve-ToolIdentity -Tool $implementer
        if (-not $implementerIdentity.Ok -or $implementerIdentity.Kind -ne "tool") {
            $result.Error = "$rec recommendations must name a concrete, recognized IMPLEMENTER (found: '$implementer')."
            return $result
        }
        $reviewerIdentity = Resolve-ToolIdentity -Tool $reviewer
        if (-not $reviewerIdentity.Ok -or $reviewerIdentity.Kind -ne "tool") {
            $result.Error = "$rec recommendations must name a concrete, recognized REVIEWER (found: '$reviewer')."
            return $result
        }
        # Canonical comparison: two aliases of one tool are not two tools.
        if (Test-SameToolIdentity -First $implementer -Second $reviewer) {
            $result.Error = "IMPLEMENTER '$implementer' and REVIEWER '$reviewer' resolve to the same tool. An implementer cannot be the sole reviewer of its own work."
            return $result
        }
    }

    $result.Ok = $true
    $result.Recommendation = $rec
    $result.WaitingFor = $waiting
    $result.Implementer = $implementer
    $result.Reviewer = $reviewer
    $result.Task = $task
    $result.ModelProfile = $resolvedProfile
    $result.Reason = $reason
    return $result
}

function Get-MasterApplyPlan {
    $ok = $true
    $errors = [System.Collections.Generic.List[string]]::new()
    $boundMaster = Resolve-Actor -Role "Master" -Binding $Binding
    $boundImplementer = Resolve-Actor -Role "Implementer" -Binding $Binding
    $boundReviewer = Resolve-Actor -Role "Reviewer" -Binding $Binding
    if ($State -ne "NEEDS_ANALYSIS" -or $WaitingFor -ne "Master") {
        $ok = $false
        $errors.Add("AI_HANDOFF.md must be State: NEEDS_ANALYSIS and Waiting For: Master for master-apply.")
    }
    if (-not (Test-SameToolIdentity -First $boundMaster -Second "Codex")) {
        $ok = $false
        $errors.Add("No callable Master adapter for '$boundMaster'. master-apply only applies recommendations captured by the Codex Master adapter.")
    }
    # v3.5.0: role-named capture first, legacy vendor-named file as the fallback.
    $recommendationPath = Resolve-CapturePath -RepoRoot (Get-Location).Path -Preferred $MasterLastName -Legacy $LegacyMasterLastName
    $recommendation = Get-MasterRecommendationFromCapture -Path $recommendationPath -ExpectedTask $CurrentTask
    if ($recommendation.Ok -and $recommendation.Recommendation -ne "BLOCKED") {
        # v3.4.1: compare captures to the binding canonically. A capture naming
        # 'Codex Window' against a binding of 'Codex' is the same tool and must not
        # be rejected as an unapproved role swap.
        if (-not (Test-SameToolIdentity -First $recommendation.Implementer -Second $boundImplementer)) {
            $ok = $false
            $errors.Add("Captured IMPLEMENTER '$($recommendation.Implementer)' must match the current bound Implementer '$boundImplementer'. Role swaps require explicit user approval.")
        }
        if (-not (Test-SameToolIdentity -First $recommendation.Reviewer -Second $boundReviewer)) {
            $ok = $false
            $errors.Add("Captured REVIEWER '$($recommendation.Reviewer)' must match the current bound Reviewer '$boundReviewer'. Role swaps require explicit user approval.")
        }
    }
    return @{
        Ok = $ok
        Errors = $errors
        BoundMaster = $boundMaster
        BoundImplementer = $boundImplementer
        BoundReviewer = $boundReviewer
        Recommendation = $recommendation
    }
}

function Show-MasterApplyPlan {
    param([hashtable]$Plan)
    $rec = $Plan.Recommendation
    Write-Host ""
    Write-Host "Master apply plan (consumes the captured recommendation; edits only AI_HANDOFF.md; runs no git)"
    Write-Host "State:              $State"
    Write-Host "Waiting For:        $WaitingFor"
    Write-Host "Current Task:       $CurrentTask"
    Write-Host "Bound Master:       $($Plan.BoundMaster)"
    Write-Host "Bound Implementer:  $($Plan.BoundImplementer)"
    Write-Host "Bound Reviewer:     $($Plan.BoundReviewer)"
    Write-Host "Capture file:       $MasterLastName (local, gitignored capture from master-run)"
    if ($rec.Ok) {
        Write-Host "Recommendation:     $($rec.Recommendation)"
        Write-Host "Captured waiting:   $($rec.WaitingFor)"
        Write-Host "Captured actors:    Implementer=$($rec.Implementer); Reviewer=$($rec.Reviewer)"
        Write-Host "Model profile:      $($rec.ModelProfile)"
        Write-Host "Captured reason:    $($rec.Reason)"
        Write-Host "Would transition to: $($rec.Recommendation) / Waiting For: $($rec.WaitingFor)"
    } else {
        Write-Host "Recommendation:     (not usable) $($rec.Error)"
    }
    Write-Host ""
    Write-Host "Safety: edits only AI_HANDOFF.md (local, gitignored); no git add/commit/push/tag;"
    Write-Host "        no deploy/db/secrets; no role swap; not auto-run by default; loop may invoke it only with -IncludeMaster."
    Write-Host ""
}

function Invoke-MasterApply {
    $plan = Get-MasterApplyPlan
    $rec = $plan.Recommendation
    Show-MasterApplyPlan -Plan $plan

    if (-not $plan.Ok) {
        Write-Host "master-apply: blocked."
        foreach ($e in $plan.Errors) { Write-Host "Reason: $e" }
        Write-Host "No files were changed and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 1
    }
    if (-not $rec.Ok) {
        Write-Host "master-apply: blocked."
        Write-Host "Reason: $($rec.Error)"
        Write-Host "Stop category: Environment/Preflight (no usable captured recommendation) - not a user decision."
        Write-Host "No files were changed and AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 1
    }

    $date = (Get-Date).ToString("yyyy-MM-dd")
    Write-Host "This applies the captured Master recommendation as a LOCAL AI_HANDOFF.md transition to:"
    Write-Host "  State: $($rec.Recommendation) / Waiting For: $($rec.WaitingFor)"
    Write-Host "It makes NO git changes and performs NO release action."
    Write-Host ""
    if ($Yes) {
        Write-Host "Confirmation: -Yes supplied; applying without an interactive prompt (local AI_HANDOFF.md edit only)."
    } else {
        $confirm = Read-Host 'Type "yes" to apply this Master recommendation to AI_HANDOFF.md, or press Enter to cancel'
        if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
            Write-Host "Cancelled."
            Write-Host "AI_HANDOFF.md was not modified."
            exit 2
        }
    }

    $statusBody = @(
        "- State: $($rec.Recommendation)",
        "- Waiting For: $($rec.WaitingFor)",
        "- Last Updated By: Master",
        "- Last Updated At: $date",
        "- Current Task: $CurrentTask",
        "- Model Profile: $($rec.ModelProfile)"
    )
    $lastUpdateBody = @(
        "- Actor: Master (Codex), applied from the captured Master recommendation via master-apply",
        "- Date: $date",
        "- Task: Applied the captured Codex Master recommendation for '$CurrentTask'.",
        "- Recommendation: $($rec.Recommendation)",
        "- Reason: $($rec.Reason)",
        "- Source: $MasterLastName (local, gitignored capture from master-run; not committed)"
    )
    $taskActorsBody = if ($rec.Recommendation -eq "BLOCKED") {
        @(
            "- Implementer: $(if ([string]::IsNullOrWhiteSpace($rec.Implementer)) { 'TBD' } else { $rec.Implementer })",
            "- Reviewer: $(if ([string]::IsNullOrWhiteSpace($rec.Reviewer)) { 'TBD' } else { $rec.Reviewer })"
        )
    } else {
        @(
            "- Implementer: $($rec.Implementer)",
            "- Reviewer: $($rec.Reviewer)"
        )
    }
    switch ($rec.Recommendation) {
        "READY_FOR_IMPLEMENTATION" {
            $nextStepBody = @(
                "- Implementer ($($rec.Implementer)): implement the Master-approved scope. Do not modify",
                "  unrelated files. When finished, update Changed Files and set State: READY_FOR_REVIEW /",
                "  Waiting For: Reviewer."
            )
        }
        "NEEDS_INVESTIGATION" {
            $nextStepBody = @(
                "- Implementer ($($rec.Implementer)): investigate only. Do not modify source files. Report",
                "  findings and evidence, then set State: READY_FOR_REVIEW / Waiting For: Reviewer."
            )
        }
        "PLAN_REQUIRED" {
            $nextStepBody = @(
                "- Implementer ($($rec.Implementer)): write a plan only. Do not modify source files. When",
                "  the plan is ready, set State: PLAN_READY_FOR_REVIEW / Waiting For: Reviewer."
            )
        }
        default {
            $nextStepBody = @(
                "- User: resolve the blocker recorded under Last Update (Reason), then ask the Master",
                "  to re-route the task when ready."
            )
        }
    }

    $cur = Get-Content -Path $HandoffFile
    $r1 = Set-HandoffSectionBody -Lines $cur       -Heading "Status"                -NewBody $statusBody
    $r2 = Set-HandoffSectionBody -Lines $r1.Lines  -Heading "Last Update"           -NewBody $lastUpdateBody
    $r3 = Set-HandoffSectionBody -Lines $r2.Lines  -Heading "Task Actors"           -NewBody $taskActorsBody
    $r4 = Set-HandoffSectionBody -Lines $r3.Lines  -Heading "Next Recommended Step" -NewBody $nextStepBody
    if (-not ($r1.Ok -and $r2.Ok -and $r3.Ok -and $r4.Ok)) {
        $missing = @()
        if (-not $r1.Ok) { $missing += "Status" }
        if (-not $r2.Ok) { $missing += "Last Update" }
        if (-not $r3.Ok) { $missing += "Task Actors" }
        if (-not $r4.Ok) { $missing += "Next Recommended Step" }
        Write-Host "master-apply: blocked."
        Write-Host "Reason: AI_HANDOFF.md is missing required section(s): $([string]::Join(', ', $missing)). The handoff is malformed; not rewriting."
        Write-Host "Stop category: Protocol Repair - a correction, not a product decision."
        Write-Host "AI_HANDOFF.md was not modified."
        Write-Host ""
        exit 1
    }

    Set-Content -Path $HandoffFile -Value ($r4.Lines -join "`n") -Encoding utf8 -ErrorAction Stop

    Write-Host "master-apply: applied (local AI_HANDOFF.md only)."
    Write-Host "AI_HANDOFF.md: State -> $($rec.Recommendation) / Waiting For -> $($rec.WaitingFor)."
    Write-Host ""
    Write-Host "Next step:"
    if ($rec.WaitingFor -eq "Implementer") {
        Write-Host "  - Implementer ($($rec.Implementer)): follow AI_HANDOFF.md Next Recommended Step."
    } else {
        Write-Host "  - User: resolve the blocker recorded in AI_HANDOFF.md."
    }
    Write-Host "  - This command made no git changes (no add/commit/push/tag) and no deploy/db/secrets actions."
    Write-Host "  - AI_HANDOFF.md remains local and gitignored - do not commit it."
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
    Write-Host "1. Daily work view               - show state and the exact next human action"
    Write-Host "2. Doctor health check           - read-only local protocol health check"
    Write-Host "3. Start new request             - begin a new task from natural language"
    Write-Host "4. Continue next turn            - prepare prompt for the Master/Implementer if needed"
    Write-Host "5. Show status                   - show current state and next actor"
    Write-Host "6. Check commit                  - verify whether commit is allowed"
    Write-Host "7. Create approved commit        - commit reviewed files after explicit authorization"
    Write-Host "8. Run one handoff cycle         - one Implementer turn, then Reviewer handoff prep (cycle)"
    Write-Host "9. Run bounded loop session      - up to MaxTurns automated Implementer turns (loop)"
    Write-Host "10. Show adapter status           - callable/manual automation status"
    Write-Host "11. Check authorized release      - dry-run release plan (release-check)"
    Write-Host "12. Check sequence advance        - dry-run local sequence advance (sequence-check)"
    Write-Host "13. Check Codex review (POC)      - dry-run Codex Reviewer plan (review-check)"
    Write-Host "14. Apply captured Codex verdict  - apply review-run verdict to AI_HANDOFF.md (review-apply)"
    Write-Host "15. Check Codex Master            - dry-run Codex Master capture plan (master-check)"
    Write-Host "16. Apply captured Master route   - apply master-run recommendation to AI_HANDOFF.md (master-apply)"
    Write-Host "17. Exit"
    Write-Host ""
    $choice = Read-Host "Select"

    switch ($choice.Trim()) {
        "1" { Invoke-Work }
        "2" { Invoke-Doctor }
        "3" {
            $userRequest = Read-Host "Enter your request"
            Invoke-Start -Request $userRequest
        }
        "4" { Invoke-Next -MenuMode $true }
        "5" { Invoke-Status }
        "6" { Invoke-CommitCheck }
        "7" {
            $msg = Read-Host "Commit message"
            $auth = Read-Host 'Type I_AUTHORIZE_COMMIT to commit reviewed files'
            $script:Message = $msg
            $script:Authorize = $auth
            Invoke-CommitApproved
        }
        "8" { Invoke-Cycle }
        "9" { Invoke-Loop }
        "10" { Invoke-Adapters }
        "11" { Invoke-ReleaseCheck }
        "12" { Invoke-SequenceCheck }
        "13" { Invoke-ReviewCheck }
        "14" { Invoke-ReviewApply }
        "15" { Invoke-MasterCheck }
        "16" { Invoke-MasterApply }
        "17" { }
        default {
            Write-Host ""
            Write-Host "Invalid selection: $choice"
            Write-Host ""
        }
    }
}

# No-op / no-progress classifier for automated Implementer turns (v2.6.0).
# Called only after a clean (exit 0) Claude Code turn. Compares the pre-turn and
# post-turn handoff state and the working tree to decide whether the turn advanced
# the task. Reuses Get-WorkingTreeState, which already excludes local handoff
# artifacts, so only real source changes count as progress.
#   progressed - the handoff state changed (any legitimate transition, e.g.
#                READY_FOR_REVIEW, QUESTION_FOR_MASTER, BLOCKED). Route normally.
#   incomplete - state unchanged but non-exempt source files changed (edits made,
#                handoff not transitioned), or git could not be read. Fail closed.
#   noop       - state unchanged and no non-exempt source change. No progress at all.
function Get-TurnProgress {
    param([string]$PreState, [string]$PostState)
    if ($PostState -ne $PreState) {
        return @{ Kind = "progressed"; SourceChanged = $false; TreeOk = $true }
    }
    $tree = Get-WorkingTreeState
    if (-not $tree.Ok) {
        return @{ Kind = "incomplete"; SourceChanged = $false; TreeOk = $false }
    }
    if ($tree.Files.Count -gt 0) {
        return @{ Kind = "incomplete"; SourceChanged = $true; TreeOk = $true }
    }
    return @{ Kind = "noop"; SourceChanged = $false; TreeOk = $true }
}

# A NEEDS_INVESTIGATION Implementer turn may update only local handoff artifacts.
# The preflight requires a clean non-local tree, so any post-turn source change was
# created by the automated investigation and is a protocol violation even when the
# handoff state advanced successfully.
function Get-InvestigationSourceBoundary {
    param([string]$PreState)
    if ($PreState -ne "NEEDS_INVESTIGATION") {
        return @{ Ok = $true; Applies = $false; TreeOk = $true; Files = @() }
    }
    $tree = Get-WorkingTreeState
    if (-not $tree.Ok) {
        return @{ Ok = $false; Applies = $true; TreeOk = $false; Files = @() }
    }
    return @{ Ok = ($tree.Files.Count -eq 0); Applies = $true; TreeOk = $true; Files = @($tree.Files) }
}

function Write-InvestigationSourceBoundaryFailure {
    param([string]$CommandLabel, [hashtable]$Boundary)
    Write-Host ""
    Write-Host "${CommandLabel}: blocked - read-only investigation modified source files."
    if ($Boundary.TreeOk) {
        Write-Host "Changed files (local handoff artifacts excluded):"
        foreach ($f in $Boundary.Files) { Write-Host "  $f" }
    } else {
        Write-Host "Could not determine the post-investigation Git working tree state."
    }
    Write-Host "Stop category: Protocol Repair - NEEDS_INVESTIGATION must remain source-read-only."
    Write-Host "Next step: inspect and revert or review the unexpected source edits before continuing."
    Write-Host "No commit, push, tag, deploy, database, or secret action was run."
}

function Write-PartialProgressRepairGuidance {
    param(
        [string]$CommandLabel,
        [hashtable]$Progress,
        [string]$StateText,
        [string]$Reason
    )

    if ($Progress.Kind -ne "incomplete") { return }
    Write-Host ""
    Write-Host "${CommandLabel}: partial progress detected after $Reason."
    Write-Host "State:       $StateText"
    if ($Progress.TreeOk) {
        Write-Host "Changed:     non-exempt source files were modified, but AI_HANDOFF.md did not transition."
    } else {
        Write-Host "Changed:     could not read the git working tree to confirm the exact source changes."
    }
    Write-Host "Stop category: Protocol Repair - do not treat this as success or commit yet."
    Write-Host "Next step:   Open Codex as Reviewer/repair, inspect git diff and AI_HANDOFF.md, then approve, block, or repair the handoff state."
}

# When an already-scoped Reviewer correction changes its approved files but the
# Claude process is interrupted before updating AI_HANDOFF.md, move only the local
# handoff to READY_FOR_REVIEW. This is not an approval: the independent Reviewer
# must still inspect the exact diff and verification evidence.
function Invoke-InterruptedCorrectionRecovery {
    param([string]$Reason, [int]$ExitCode)

    $date = (Get-Date).ToString("yyyy-MM-dd")
    $statusBody = @(
        "- State: READY_FOR_REVIEW",
        "- Waiting For: Reviewer",
        "- Last Updated By: Automation Recovery",
        "- Last Updated At: $date",
        "- Current Task: $CurrentTask",
        "- Model Profile: $HandoffModelProfile"
    )
    $lastUpdateBody = @(
        "- Actor: Automation Recovery after interrupted Claude correction",
        "- Date: $date",
        "- Task: Preserved the Reviewer's existing correction scope after $Reason.",
        "- Claude Exit Code: $ExitCode",
        "- Evidence: the approved Changed Files set matches git status exactly and those files changed during this correction turn.",
        "- Verification: not attested here; the independent Reviewer must verify the diff and tests."
    )
    $nextStepBody = @(
        "- Reviewer (Codex): independently review the corrected Changed Files, run safe verification,",
        "  and approve or return focused changes. Do not rely on Automation Recovery as technical approval."
    )

    $cur = Get-Content -Path $HandoffFile
    $r1 = Set-HandoffSectionBody -Lines $cur      -Heading "Status"                -NewBody $statusBody
    $r2 = Set-HandoffSectionBody -Lines $r1.Lines -Heading "Last Update"           -NewBody $lastUpdateBody
    $r3 = Set-HandoffSectionBody -Lines $r2.Lines -Heading "Next Recommended Step" -NewBody $nextStepBody
    if (-not ($r1.Ok -and $r2.Ok -and $r3.Ok)) {
        Write-Host "Automation recovery blocked: AI_HANDOFF.md is missing a required section."
        Write-Host "AI_HANDOFF.md was not modified."
        return $false
    }

    Set-Content -Path $HandoffFile -Value ($r3.Lines -join "`n") -Encoding utf8 -ErrorAction Stop
    Write-Host "Automation recovery: interrupted Reviewer correction moved to READY_FOR_REVIEW."
    Write-Host "Safety: exact Changed Files scope only; this is not approval and no Git mutation or commit was run."
    return $true
}

function Invoke-Cycle {
    param([string]$CommandLabel = "cycle")

    $implementerTool = $Binding.Implementer
    $turnAdapter = Resolve-TurnAdapter -ForState $State -Role "Implementer" -Tool $implementerTool

    # Only the verified Claude Implementer states are eligible.
    $automatedImplementerStates = @("READY_FOR_IMPLEMENTATION", "NEEDS_INVESTIGATION")
    if ($automatedImplementerStates -notcontains $State) {
        Write-Host ""
        Write-Host "${CommandLabel}: blocked."
        Write-Host "State:       $State"
        Write-Host "Waiting For: $WaitingFor"
        $entry = $ActionMap[$State]
        $role  = if ($entry) { $entry.Role } else { "" }
        if ($State -eq "PLAN_REQUIRED") {
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

    # Gate on AutoLoopEligible, never on Callable: cycle automates only turns that are
    # explicitly auto-run-eligible (Implementer/Claude Code at READY_FOR_IMPLEMENTATION
    # or the source-read-only NEEDS_INVESTIGATION state).
    # An explicit-only callable adapter (e.g. Reviewer/Codex) must never be run by cycle.
    if (-not $turnAdapter.AutoLoopEligible) {
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
    if (Test-SameToolIdentity -First $Binding.Reviewer -Second $implementerTool) {
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

    $cycleResumePlan = Get-ReviewerBlockedResumePlan -Tree $tree
    if ($tree.Files.Count -gt 0 -and -not $cycleResumePlan.Allowed) {
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
    if ($cycleResumePlan.Allowed) {
        Write-Host "${CommandLabel}: resuming the Reviewer's BLOCKED correction on the exact approved Changed Files scope."
        Write-Host "Safety: unrelated dirty files would still block this turn."
    }
    if (-not (Test-ModelTurnPreflight)) { exit 1 }

    Write-Host ""
    Write-Host "Preparing assisted Implementer turn..."
    Write-Host ""
    Write-Host "State:        $State"
    Write-Host "Actor:        $implementerTool (Implementer)"
    Write-Host "Permission:   acceptEdits  (Bash explicitly disallowed)"
    Write-Host "Budget limit: `$$BudgetUsd"
    Write-Host "Model profile: $($script:ModelSelection.EffectiveProfile)"
    Write-Host "Claude model:  $($script:ModelSelection.ClaudeModel)  ($($script:ModelSelection.Source))"
    Write-Host "Adapter:      callable via ADAPTERS.md contract"
    Write-Host ""
    if ($State -eq "NEEDS_INVESTIGATION") {
        Write-Host "Mode:         read-only investigation (source edits are prohibited and checked after the turn)"
    } else {
        Write-Host "Note: Tests and lint cannot run during this turn (Bash is blocked). Run them manually after."
    }
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
    Write-Host "Command: bounded PowerShell runner -> $(Get-SanitizedClaudeInvocation)"
    Write-Host ""
    Write-Host "Timeout:     ${TimeoutSeconds}s (process tree is killed on timeout)"
    if ($State -eq "NEEDS_INVESTIGATION") {
        Write-Host "WARNING: This is a read-only investigation. Source edits are forbidden and fail closed."
    } else {
        Write-Host "WARNING: This state allows source file edits. Claude Code may modify approved source files."
    }
    Write-Host "         This tool does not commit, push, or deploy automatically."
    Write-Host ""
    # Fail closed: only an explicit yes proceeds. -Yes is treated as explicit operator authorization for automation/tests.
    if ($Yes) {
        Write-Host "Confirmation: -Yes supplied; proceeding without an interactive prompt."
    } else {
        $confirm = Read-Host 'Type "yes" to proceed, or press Enter to cancel'
        if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
            Write-Host "Cancelled."
            exit 2
        }
    }

    Write-Host ""
    Write-Host "Running $implementerTool assisted turn..."
    Write-Host ""

    $preTurnState = $State
    $claudeExit = Invoke-ImplementerTurn
    $investigationBoundary = Get-InvestigationSourceBoundary -PreState $preTurnState
    if (-not $investigationBoundary.Ok) {
        Write-InvestigationSourceBoundaryFailure -CommandLabel $CommandLabel -Boundary $investigationBoundary
        exit 6
    }

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

        # No-op / no-progress guard (v2.6.0): a turn that exits 0 but neither transitions
        # the handoff nor changes non-exempt source files must fail closed, not look like
        # progress. Legitimate transitions (READY_FOR_REVIEW, QUESTION_FOR_MASTER, BLOCKED,
        # etc.) change the state and pass through as "progressed".
        $progress = Get-TurnProgress -PreState $preTurnState -PostState $script:State
        if ($progress.Kind -eq "noop") {
            Write-Host "${CommandLabel}: no-op - the Implementer turn exited 0 but made no progress."
            Write-Host "State:       $($script:State) (unchanged)"
            Write-Host "Changed:     none (no non-exempt source files were created or modified)"
            Write-Host "Reason:      Claude Code exited 0 without transitioning the handoff or editing source files."
            Write-Host "Stop category: No-Op / No-Progress - fail closed; this turn did not advance the task."
            Write-Host "Next step:   Inspect AI_HANDOFF.md and the turn output; re-run only after the task or prompt is corrected."
            Write-Host "$CommandLabel stops here."
            Write-Host ""
            exit 7
        } elseif ($progress.Kind -eq "incomplete") {
            Write-Host "${CommandLabel}: incomplete - source changed but the handoff did not transition."
            Write-Host "State:       $($script:State) (unchanged)"
            if ($progress.TreeOk) {
                Write-Host "Changed:     non-exempt source files were modified, but AI_HANDOFF.md was not moved to READY_FOR_REVIEW."
            } else {
                Write-Host "Changed:     could not read the git working tree to confirm progress."
            }
            Write-Host "Stop category: Protocol Repair - the turn did not complete a valid handoff transition; do not treat as success."
            Write-Host "Next step:   Inspect the changes and AI_HANDOFF.md; complete the transition or revert before continuing."
            Write-Host "$CommandLabel stops here."
            Write-Host ""
            exit 6
        }

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
        if ($claudeExit -eq 3) {
            Write-Host "Claude Code runner failed before the turn could start (exit 3)."
            Write-Host "AI_HANDOFF.md was not intentionally transitioned by handoff.ps1."
            exit 3
        } elseif ($claudeExit -eq 4) {
            Write-Host "Claude Code turn timed out (exit 4)."
            $script:Lines       = Get-Content -Path $HandoffFile
            $freshStatus        = Read-HandoffState -Lines $script:Lines
            $script:State       = $freshStatus.State
            $script:WaitingFor  = $freshStatus.WaitingFor
            $script:CurrentTask = $freshStatus.CurrentTask
            $progress = Get-TurnProgress -PreState $preTurnState -PostState $script:State
            Write-PartialProgressRepairGuidance -CommandLabel $CommandLabel -Progress $progress -StateText "$($script:State) / Waiting For: $($script:WaitingFor)" -Reason "timeout"
            Write-Host "AI_HANDOFF.md may be incomplete. Verify manually."
            exit 4
        } else {
            Write-Host "Claude Code exited with error (code: $claudeExit)."
            Write-Host "AI_HANDOFF.md may be incomplete. Verify manually."
            exit 5
        }
    }
    Write-Host ""
}

# Bounded loop manager. Runs automated turns until a hard stop.
# Default auto-loop turns: READY_FOR_IMPLEMENTATION and source-read-only
# NEEDS_INVESTIGATION / Implementer bound to Claude Code.
# Explicit per-session opt-ins may add Codex Master/Reviewer turns; User/release
# actions are never automated.
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
    if (Test-SameToolIdentity -First $Binding.Reviewer -Second $Binding.Implementer) {
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
    # v1.4.0: when the session begins directly at the Codex Reviewer's READY_FOR_REVIEW turn,
    # the working tree is EXPECTED to carry the changes under review, so the clean-tree session
    # gate does not apply to that first turn - in BOTH modes:
    #   - default (no -IncludeReviewer): the loop simply STOPS cleanly at this non-auto-loop
    #     Reviewer turn (exit 0, Operator Manual Action). There is no automated turn for the
    #     gate to protect, so blocking here on the very changes under review would be wrong -
    #     it would turn a clean stop into a spurious Environment/Preflight failure.
    #   - -IncludeReviewer: the opt-in Reviewer handler runs review-run/review-apply, which
    #     enforce the stricter scope guard (Changed Files must equal git status) on those exact
    #     changes. That opt-in path checks $IncludeReviewer itself, so this gate does not.
    # The clean-tree requirement is unchanged for every normal (Implementer-first) session and
    # for the per-iteration recheck before each automated Implementer turn.
    # v3.4.1: canonical identity here too. A binding written with a legacy alias must
    # take the same session-start path as the canonical display name.
    $startsAtReviewerTurn = ($State -eq "READY_FOR_REVIEW") -and
        (($WaitingFor -eq "Reviewer") -or ($WaitingFor -eq (Resolve-Actor -Role "Reviewer" -Binding $Binding))) -and
        (Test-SameToolIdentity -First (Resolve-Actor -Role "Reviewer" -Binding $Binding) -Second "Codex")

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
    $initialBlockedResume = Get-ReviewerBlockedResumePlan -Tree $tree
    if ($tree.Files.Count -gt 0 -and -not $startsAtReviewerTurn -and -not $initialBlockedResume.Allowed) {
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
    if ($initialBlockedResume.Allowed) {
        Write-Host "loop: resuming the Reviewer's BLOCKED correction on the exact approved Changed Files scope."
        Write-Host "Safety: unrelated dirty files would still block the Implementer turn."
    }

    # --- Budget info + single session confirmation ---
    $worstCase = [Math]::Min($MaxTurns * $BudgetUsd, $SessionBudgetUsd)
    Write-Host ""
    Write-Host "Preparing bounded loop session..."
    Write-Host ""
    Write-Host "Max turns:          $MaxTurns"
    Write-Host "Per-turn budget:    `$$BudgetUsd (passed to --max-budget-usd)"
    Write-Host "Session budget cap: `$$SessionBudgetUsd (worst-case authorized spend this session: `$$worstCase)"
    Write-Host "Default turns:      Resolved through ADAPTERS.md; READY_FOR_IMPLEMENTATION and read-only NEEDS_INVESTIGATION when Implementer is Claude Code."
    if ($IncludeMaster) {
        Write-Host "Master mode:        -IncludeMaster ON - the Codex Master's NEEDS_ANALYSIS turn will be auto-run in-session (read-only master-run capture + master-apply). READY_FOR_IMPLEMENTATION continues to the Implementer; BLOCKED stops at User."
    } else {
        Write-Host "Master mode:        -IncludeMaster OFF (default) - loop stops at the Master turn and every other non-enabled explicit-command turn."
    }
    if ($IncludeReviewer) {
        Write-Host "Reviewer mode:      -IncludeReviewer ON - the Codex Reviewer's READY_FOR_REVIEW turn will be auto-run in-session (read-only review-run capture + review-apply). APPROVED stops at REVIEW_DONE / Waiting For: User; BLOCKED returns to READY_FOR_IMPLEMENTATION and the loop continues under MaxTurns/budget."
        Write-Host "Never automated:    User turns, push/tag/deploy/db/secrets. Commit requires explicit commit-approved authorization."
    } else {
        Write-Host "Reviewer mode:      -IncludeReviewer OFF (default) - loop stops at the Reviewer turn and every other non-Implementer turn."
        Write-Host "Never automated:    User turns, push/tag/deploy/db/secrets. Commit requires explicit commit-approved authorization."
    }
    Write-Host ""
    Write-Host "WARNING: Implementation turns allow approved source edits; NEEDS_INVESTIGATION remains source-read-only. Bash is disallowed during both."
    Write-Host ""
    if ($Yes) {
        Write-Host "Confirmation: -Yes supplied; starting the loop session without an interactive prompt."
    } else {
        # Fail closed: only an explicit, non-null "yes" starts the session.
        $confirm = Read-Host 'Type "yes" to start the loop session, or press Enter to cancel'
        if ($null -eq $confirm -or $confirm.Trim() -ne "yes") {
            Write-Host "Cancelled."
            exit 2
        }
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
        $script:HandoffModelProfile = $freshStatus.ModelProfile
        $script:ModelSelection = Resolve-ModelSelection -ForState $script:State -HandoffProfile $script:HandoffModelProfile -CommandProfile $ModelProfile -CommandModel $Model
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
        # Gate on AutoLoopEligible, NOT Callable. A turn that is callable only via an
        # explicit command (e.g. Reviewer/Codex via review-run + review-apply) must make the
        # loop STOP, never auto-run. This keeps loop from ever invoking a Reviewer turn unless
        # the operator explicitly opted in with -IncludeReviewer (handled just below).
        $loopEligible = $turnAdapter.AutoLoopEligible

        # --- v2.1.0: opt-in in-session Master automation ---
        # Master/Codex stays AutoLoopEligible:$false, so by default the loop still stops at
        # NEEDS_ANALYSIS. ONLY when the operator passed -IncludeMaster AND the next turn is
        # the Codex Master's NEEDS_ANALYSIS turn do we run the already-proven master-run +
        # master-apply sequence in-session. master-run is read-only capture; master-apply
        # edits only AI_HANDOFF.md and runs no git. Both fail closed through their existing
        # guards, including stale TASK, role-binding mismatch, invalid actors, and bad state.
        # v3.5.0: gate on the ADAPTER being callable, not on the tool being Codex.
        # master-run/master-apply now complete this turn for either tool, and both run it
        # read-only, so restricting the opt-in to one vendor would withhold the automation
        # from a turn that is equally bounded.
        if (-not $loopEligible -and $IncludeMaster -and
            ($script:State -eq "NEEDS_ANALYSIS") -and ($role -eq "Master") -and
            (Get-AdapterProfile -Role "Master" -Tool $tool).Callable) {

            # A Master turn counts against MaxTurns like any other automated protocol turn.
            if ($turnsRun -ge $MaxTurns) {
                Write-Host ""
                Write-Host "loop: stop - MaxTurns ($MaxTurns) reached before the Master turn."
                Write-Host "Stop category: Operator Manual Action - re-run loop to continue if desired; no user decision required."
                Write-Host "Turns run:  $turnsRun  (authorized spend cap used: `$$authorized of `$$SessionBudgetUsd)"
                Write-LoopLog "turn=$turnsRun stop reason=max-turns-before-master exit=0"
                Write-Host ""
                exit 0
            }

            $turnNo = $turnsRun + 1
            Write-Host ""
            Write-Host "loop: turn $turnNo of $MaxTurns - opt-in automated Codex Master turn (read-only master-run capture + master-apply)..."
            Write-LoopLog "turn=$turnNo action=automated-master-turn preState=$($script:State) preWaitingFor=$($script:WaitingFor) actor=Codex(Master)"
            $turnsRun = $turnNo

            # master-run / master-apply gate their own confirmation on the script-level -Yes.
            # The operator already authorized this loop session, so force their non-interactive
            # path. Any guard/capture/recommendation failure exits the process fail-closed.
            $script:Yes = $true
            Invoke-MasterRun
            Invoke-MasterApply

            Write-LoopLog "turn=$turnNo master-applied"
            # Loop continues: the next iteration re-reads AI_HANDOFF.md. READY_FOR_IMPLEMENTATION
            # proceeds to the Implementer; BLOCKED stops at User; planning/investigation states
            # stop as non-loop-eligible Implementer turns unless a future opt-in handles them.
            continue
        }

        # --- v1.4.0: opt-in in-session Reviewer automation ---
        # Reviewer/Codex stays AutoLoopEligible:$false, so by default the next block stops the
        # loop here exactly as in v1.3.0. ONLY when the operator passed -IncludeReviewer AND the
        # next turn is the Codex Reviewer's READY_FOR_REVIEW turn do we run the already-proven
        # review-run + review-apply sequence in-session instead of stopping. This opt-in path is
        # the single exception, and only for Codex: review-run/review-apply re-validate every
        # protocol guard (bound + actual Reviewer is Codex and != actual Implementer; Changed
        # Files == git status; strict captured-verdict schema) and fail closed (they exit the
        # process), so a malformed/stale/missing verdict or any guard violation stops the loop
        # with no handoff transition. They edit only AI_HANDOFF.md and run no git.
        # v3.5.0: same change as the Master gate above - the opt-in follows the adapter,
        # not the vendor. Every guard review-run and review-apply enforce is unchanged.
        if (-not $loopEligible -and $IncludeReviewer -and
            ($script:State -eq "READY_FOR_REVIEW") -and ($role -eq "Reviewer") -and
            (Get-AdapterProfile -Role "Reviewer" -Tool $tool).Callable) {

            # A Reviewer turn counts against MaxTurns like any other automated turn.
            if ($turnsRun -ge $MaxTurns) {
                Write-Host ""
                Write-Host "loop: stop - MaxTurns ($MaxTurns) reached before the Reviewer turn."
                Write-Host "Stop category: Operator Manual Action - re-run loop to continue if desired; no user decision required."
                Write-Host "Turns run:  $turnsRun  (authorized spend cap used: `$$authorized of `$$SessionBudgetUsd)"
                Write-LoopLog "turn=$turnsRun stop reason=max-turns-before-reviewer exit=0"
                Write-Host ""
                exit 0
            }

            $turnNo = $turnsRun + 1
            Write-Host ""
            Write-Host "loop: turn $turnNo of $MaxTurns - opt-in automated Codex Reviewer turn (read-only review-run capture + review-apply)..."
            Write-LoopLog "turn=$turnNo action=automated-reviewer-turn preState=$($script:State) preWaitingFor=$($script:WaitingFor) actor=Codex(Reviewer)"
            $turnsRun = $turnNo

            # review-run / review-apply gate their own confirmation on the script-level -Yes.
            # The operator already authorized this loop session, so force their non-interactive
            # path regardless of whether -Yes was passed to loop. Each fails closed by exiting
            # the whole process on any guard/capture/verdict error (no handoff transition).
            $script:Yes = $true
            Invoke-ReviewRun
            Invoke-ReviewApply

            Write-LoopLog "turn=$turnNo reviewer-applied"
            # Loop continues: the next iteration re-reads AI_HANDOFF.md. APPROVED ->
            # REVIEW_DONE / Waiting For: User stops as a non-loop-eligible User turn; BLOCKED ->
            # READY_FOR_IMPLEMENTATION / Waiting For: Implementer continues under MaxTurns/budget.
            # Neither path involves the user in this loop step.
            continue
        }

        if (-not $loopEligible) {
            try {
                Invoke-Next -Silent $true
            } catch {
                Write-Host "Failed to refresh NEXT_TURN.md: $_"
            Write-Host "Stop category: Environment/Preflight - not a user decision."
                Write-LoopLog "turn=$turnsRun stop reason=next-turn-refresh-failed exit=4"
                exit 4
            }
            Write-Host ""
            if ($turnAdapter.Callable) {
                Write-Host "loop: stop - next actor is callable only via an explicit command, not inside loop."
            } else {
                Write-Host "loop: stop - next actor is not callable."
            }
            Write-Host "State:      $($script:State)"
            Write-Host "Next actor: $tool ($role)"
            if ($tool -eq "User") {
                Write-Host (Get-StopCategoryLine -ForState $script:State -ActorTool $tool -Automation $true)
            } elseif ($turnAdapter.Callable) {
                Write-Host "Reason:     $($turnAdapter.Reason)"
                Write-Host "Stop category: Operator Manual Action - this actor is callable only via its explicit command(s); loop never auto-runs it. Run it manually."
            } else {
                Write-Host "Reason:     $($turnAdapter.Reason)"
                Write-Host "Stop category: $($turnAdapter.StopCategory) (automation limitation) - next step is an Operator Manual Action."
            }
            if ($tool -ne "User") {
                Write-Host "Paste:      Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
            }
            Write-Host "Turns run:  $turnsRun  (authorized spend cap used: `$$authorized of `$$SessionBudgetUsd)"
            Write-LoopLog "turn=$turnsRun stop reason=not-loop-eligible state=$($script:State) nextActor=$tool($role) callable=$($turnAdapter.Callable) exit=0"
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
        if (Test-SameToolIdentity -First $script:Binding.Reviewer -Second $script:Binding.Implementer) {
            Write-Host ""
            Write-Host "loop: blocked."
            Write-Host "Reason:      Role invariant violation detected mid-session (Reviewer == Implementer)."
            Write-Host "Next step:   Fix the binding in .ai/roles/ROLE_ASSIGNMENT.md so Reviewer and Implementer are different tools."
            Write-LoopLog "turn=$turnsRun stop reason=role-invariant exit=1"
            Write-Host ""
            exit 1
        }
        $tree = Get-WorkingTreeState
        $blockedResumePlan = Get-ReviewerBlockedResumePlan -Tree $tree -StateValue $script:State -WaitingForValue $script:WaitingFor -HandoffLines $script:Lines
        if (-not $tree.Ok -or ($tree.Files.Count -gt 0 -and -not $blockedResumePlan.Allowed)) {
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
        if ($blockedResumePlan.Allowed) {
            Write-Host "loop: continuing the Reviewer's BLOCKED correction on the exact approved Changed Files scope."
            Write-Host "Safety: the pre-turn file fingerprint will be compared before any interrupted-turn recovery."
        }
        $preCorrectionFingerprint = if ($blockedResumePlan.Allowed) {
            Get-FileSetFingerprint -Files $blockedResumePlan.ExpectedFiles
        } else { "" }

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

        if (-not (Test-ModelTurnPreflight)) {
            Write-LoopLog "turn=$turnsRun stop reason=model-routing-preflight exit=1"
            exit 1
        }

        # Preflight: the tool that holds the Implementer role must be runnable.
        # v3.5.0: probe the BOUND tool, not Claude Code by reflex. Probing the wrong one
        # would stop a loop whose Implementer is perfectly available.
        $loopImplementerTool = Resolve-Actor -Role "Implementer" -Binding $script:Binding
        if (Test-SameToolIdentity -First $loopImplementerTool -Second "Codex") {
            $loopCli = Resolve-CodexCli
            if (-not $loopCli.Ok) {
                Write-Host "Codex is not available: $($loopCli.Error)"
                Write-Host "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
                Write-LoopLog "turn=$turnsRun stop reason=codex-unavailable exit=3"
                exit 3
            }
        } elseif (-not (Test-ClaudeAvailable)) {
            Write-Host "Claude Code is not available. Check network or install globally: npm install -g @anthropic-ai/claude-code"
            Write-Host "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
            Write-LoopLog "turn=$turnsRun stop reason=claude-unavailable exit=3"
            exit 3
        }

        # Run one automated Implementer turn
        $turnNo = $turnsRun + 1
        Write-Host ""
        Write-Host "loop: turn $turnNo of $MaxTurns - automated $loopImplementerTool Implementer turn (per-turn budget `$$BudgetUsd)..."
        Write-LoopLog "turn=$turnNo action=automated-implementer-turn preState=$($script:State) preWaitingFor=$($script:WaitingFor) actor=$loopImplementerTool(Implementer) budget=$BudgetUsd"
        $authorized += $BudgetUsd
        $turnsRun    = $turnNo

        $preImplementerState = $script:State
        $claudeExit = Invoke-ImplementerTurn
        Write-LoopLog "turn=$turnNo claudeExit=$claudeExit authorizedSoFar=$authorized"

        $investigationBoundary = Get-InvestigationSourceBoundary -PreState $preImplementerState
        if (-not $investigationBoundary.Ok) {
            Write-InvestigationSourceBoundaryFailure -CommandLabel "loop" -Boundary $investigationBoundary
            Write-LoopLog "turn=$turnNo stop reason=investigation-source-edit exit=6"
            exit 6
        }

        if ($claudeExit -ne 0) {
            $postLines = Get-Content -Path $HandoffFile
            $postStatus = Read-HandoffState -Lines $postLines
            $script:Lines = $postLines
            $script:State = $postStatus.State
            $script:WaitingFor = $postStatus.WaitingFor
            $script:CurrentTask = $postStatus.CurrentTask
            $interruptedReason = if ($claudeExit -eq 4) { "timeout" } else { "Claude Code exit $claudeExit" }
            $recoveredToReview = $false

            # If Claude completed a protocol-valid READY_FOR_REVIEW handoff before
            # the process was interrupted, allow the independent Reviewer to decide.
            # Exact Changed Files == git status is mandatory; extra helper files fail closed.
            if ($script:State -eq "READY_FOR_REVIEW") {
                $interruptedReviewPlan = Get-ReviewPlan -RequireCli:$false
                if ($interruptedReviewPlan.Ok) {
                    Write-Host "loop: Claude was interrupted after producing a valid exact-scope review handoff."
                    Write-Host "Recovery: continuing to the independent Reviewer; this is not an implementation approval."
                    Write-LoopLog "turn=$turnNo recovery=valid-review-handoff reason=$interruptedReason"
                    $recoveredToReview = $true
                }
            }

            # A Reviewer BLOCKED correction may update the exact approved files but
            # stop at a budget/timeout before rewriting AI_HANDOFF.md. Prove both
            # exact scope and an actual content change, then create a review-only
            # recovery transition. The Reviewer still owns technical approval.
            if (-not $recoveredToReview -and $blockedResumePlan.Allowed -and
                ($script:State -eq "READY_FOR_IMPLEMENTATION")) {
                $postTree = Get-WorkingTreeState
                $postExpected = @(Get-ReleaseChangedFiles -FromLines $script:Lines)
                $postExact = $postTree.Ok -and ($postExpected.Count -gt 0) -and
                    (Test-SameFileSet -Expected $postExpected -Actual $postTree.Files)
                $postFingerprint = if ($postExact) { Get-FileSetFingerprint -Files $postExpected } else { "" }
                if ($postExact -and $postFingerprint -ne $preCorrectionFingerprint) {
                    if (Invoke-InterruptedCorrectionRecovery -Reason $interruptedReason -ExitCode $claudeExit) {
                        $script:Lines = Get-Content -Path $HandoffFile
                        $freshRecoveryStatus = Read-HandoffState -Lines $script:Lines
                        $script:State = $freshRecoveryStatus.State
                        $script:WaitingFor = $freshRecoveryStatus.WaitingFor
                        $script:CurrentTask = $freshRecoveryStatus.CurrentTask
                        Write-LoopLog "turn=$turnNo recovery=interrupted-blocked-correction reason=$interruptedReason"
                        $recoveredToReview = $true
                    }
                }
            }

            if ($recoveredToReview) { continue }

            if ($claudeExit -eq 3) {
                Write-Host "Claude Code runner failed before the turn could start (exit 3)."
                Write-LoopLog "turn=$turnNo stop reason=claude-runner-start-failed exit=3"
                exit 3
            } elseif ($claudeExit -eq 4) {
                Write-Host "Claude Code turn timed out (exit 4)."
                $loopProgress = Get-TurnProgress -PreState $preImplementerState -PostState $postStatus.State
                Write-PartialProgressRepairGuidance -CommandLabel "loop" -Progress $loopProgress -StateText "$($postStatus.State) / Waiting For: $($postStatus.WaitingFor)" -Reason "timeout"
                Write-Host "AI_HANDOFF.md may be incomplete. Verify manually."
                Write-LoopLog "turn=$turnNo stop reason=claude-timeout exit=4"
                exit 4
            } else {
                Write-Host "Claude Code exited with error (code: $claudeExit)."
                Write-Host "AI_HANDOFF.md may be incomplete. Verify manually."
                Write-LoopLog "turn=$turnNo stop reason=claude-error exit=5"
                exit 5
            }
        }

        # Log the post-turn state; the next iteration re-reads and routes it
        $postStatus = Read-HandoffState -Lines (Get-Content -Path $HandoffFile)
        Write-LoopLog "turn=$turnNo post state=$($postStatus.State) waitingFor=$($postStatus.WaitingFor)"

        # No-op / no-progress guard (v2.6.0): if the turn exited 0 but the handoff did not
        # transition, stop the loop instead of re-running the identical turn and burning budget.
        # $script:State here is still the pre-turn state read at the top of this iteration.
        $loopProgress = Get-TurnProgress -PreState $script:State -PostState $postStatus.State
        if ($loopProgress.Kind -eq "noop") {
            Write-Host ""
            Write-Host "loop: stop - no-op turn (exit 0 but no progress)."
            Write-Host "State:      $($postStatus.State) (unchanged from before the turn)"
            Write-Host "Reason:     Claude Code exited 0 without transitioning the handoff or editing non-exempt source files."
            Write-Host "Stop category: No-Op / No-Progress - fail closed; re-running would repeat the same no-op."
            Write-Host "Turns run:  $turnsRun  (authorized spend cap used: `$$authorized of `$$SessionBudgetUsd)"
            Write-LoopLog "turn=$turnNo stop reason=no-op state=$($postStatus.State) exit=7"
            Write-Host ""
            exit 7
        } elseif ($loopProgress.Kind -eq "incomplete") {
            Write-Host ""
            Write-Host "loop: stop - incomplete turn (source changed but no handoff transition)."
            Write-Host "State:      $($postStatus.State) (unchanged from before the turn)"
            Write-Host "Stop category: Protocol Repair - the turn did not complete a valid handoff transition; do not treat as success."
            Write-Host "Turns run:  $turnsRun  (authorized spend cap used: `$$authorized of `$$SessionBudgetUsd)"
            Write-LoopLog "turn=$turnNo stop reason=incomplete state=$($postStatus.State) exit=6"
            Write-Host ""
            exit 6
        }
    }
}

# --- Dispatch ---

switch ($Command) {
    "work"         { Invoke-Work }
    "doctor"      { Invoke-Doctor }
    "models"      { Invoke-Models }
    "status"       { Invoke-Status }
    "stop"         { Invoke-Stop }
    "user-next"    { Invoke-UserNext }
    "adapters"     { Invoke-Adapters }
    "next"         { Invoke-Next }
    "start"        { Invoke-Start -Request $Request }
    "commit-check" { Invoke-CommitCheck }
    "commit-approved" { Invoke-CommitApproved }
    "release-check" { Invoke-ReleaseCheck }
    "release"      { Invoke-Release }
    "sequence-check"   { Invoke-SequenceCheck }
    "sequence-advance" { Invoke-SequenceAdvance }
    "review-check" { Invoke-ReviewCheck }
    "review-run"   { Invoke-ReviewRun }
    "review-apply" { Invoke-ReviewApply }
    "master-check" { Invoke-MasterCheck }
    "master-run"   { Invoke-MasterRun }
    "master-apply" { Invoke-MasterApply }
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
            Write-Host "  work                      Show the daily workflow view and exact next action. Read-only."
            Write-Host "  stop                      Stop an automated turn that is running now. No git, deploy, database or secret action."
            Write-Host "  doctor                    Run a read-only local protocol health check; add -CheckUpdates for GitHub version comparison."
            Write-Host "  models [-ModelProfile P] [-Model M]"
            Write-Host "                            Show the effective capability profile and Claude model resolution. Read-only."
            Write-Host "  status                    Show current handoff state, role binding, and commit status."
            Write-Host "  user-next                 Show the single next user action, including commit-approved when ready."
            Write-Host "  adapters                  Show adapter callable/manual status for each role."
            Write-Host "  next [-Clip]              Generate NEXT_TURN.md and print the paste instruction."
            Write-Host '  start "<request>" [-Clip]  Save request and print a Master entry prompt.'
            Write-Host "  commit-check [-Message `"<msg>`"]"
            Write-Host "                            Dry-run the guarded commit plan after REVIEW_DONE. Never mutates git."
            Write-Host "  commit-approved -Message `"<msg>`" -Authorize `"I_AUTHORIZE_COMMIT`""
            Write-Host "                            Create the approved local commit after REVIEW_DONE. No push/tag/release."
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
            Write-Host "  review-apply [-Yes]       Apply the captured review-run verdict (CODEX_REVIEW_LAST.md) as a local AI_HANDOFF.md transition: APPROVED -> REVIEW_DONE/User, BLOCKED -> READY_FOR_IMPLEMENTATION/Implementer. Fails closed on missing/malformed/stale verdict or any guard. Edits only AI_HANDOFF.md; runs no git; not auto-run by default; PowerShell loop may invoke it only with -IncludeReviewer."
            Write-Host "  master-check              Dry-run the Codex Master capture plan for NEEDS_ANALYSIS / Waiting For: Master. Mutates nothing."
            Write-Host "  master-run [-TimeoutSeconds N] [-Yes]"
            Write-Host "                            Run a read-only Codex Master analysis (explicit confirmation, or -Yes) and capture the routing recommendation locally. Capture-only: never changes AI_HANDOFF.md or git. Same fail-closed timeout/no-capture behavior as review-run."
            Write-Host "  master-apply [-Yes]       Apply the captured master-run recommendation (CODEX_MASTER_LAST.md) as a local AI_HANDOFF.md transition. Fails closed on missing/malformed/stale recommendation or actor mismatch. Edits only AI_HANDOFF.md; runs no git; not auto-run by default; PowerShell loop may invoke it only with -IncludeMaster."
            Write-Host "  cycle [-BudgetUsd N] [-TimeoutSeconds N] [-ModelProfile P] [-Model M] [-AllowModelEscalation] [-Yes]"
            Write-Host "                            Run one bounded handoff cycle for a loop-eligible adapter turn, then prepare the next handoff."
            Write-Host "  run-next [-BudgetUsd N] [-TimeoutSeconds N] [-Yes]"
            Write-Host "                            Alias of cycle (kept for backward compatibility)."
            Write-Host "  loop [-MaxTurns N] [-BudgetUsd N] [-SessionBudgetUsd N] [-TimeoutSeconds N] [-ModelProfile P] [-Model M] [-AllowModelEscalation] [-IncludeMaster] [-IncludeReviewer] [-Yes]"
            Write-Host "                            Run a bounded loop of loop-eligible adapter turns; stops at any non-loop-eligible actor unless that actor is explicitly included for this session. With -IncludeMaster, also auto-runs the Codex Master's NEEDS_ANALYSIS turn in-session (master-run capture + master-apply, fail-closed). With -IncludeReviewer, also auto-runs the Codex Reviewer's READY_FOR_REVIEW turn in-session (review-run capture + review-apply, fail-closed). User turns and commit/push/tag/deploy are never automated. Writes HANDOFF_LOOP.log."
            Write-Host ""
        }
    }
}

