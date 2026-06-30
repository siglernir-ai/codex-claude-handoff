#!/usr/bin/env bash
# handoff.sh - Codex-Claude Handoff operator (Bash version, v1.3.1)
# Commands: status, adapters, next, start, commit-check
# commit-approved, cycle, run-next, loop, release-check, release, sequence-check, sequence-advance,
# review-check, review-run, review-apply, master-check, master-run, and master-apply require
# PowerShell; use handoff.ps1.

set -euo pipefail

COMMAND="${1:-}"
CLIP=false
REQUEST=""
[ $# -gt 0 ] && shift  # consume COMMAND
for _arg in "$@"; do
    case "$_arg" in
        -c|--clip) CLIP=true ;;
        -*)        ;;
        *)         [ -z "$REQUEST" ] && REQUEST="$_arg" ;;
    esac
done
unset _arg

HANDOFF_FILE="$(pwd)/AI_HANDOFF.md"
if [ ! -f "$HANDOFF_FILE" ]; then
    echo "No AI_HANDOFF.md found. Run from your project root."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print lines from a named ## section; CRLF-safe.
_section_content() {
    local h="## $1"
    tr -d '\r' < "$HANDOFF_FILE" | \
    awk -v h="$h" '$0==h{s=1;next} s&&/^## /{s=0} s{print}'
}

_parse_status() {
    STATE="(unknown)" WAITING_FOR="(unknown)" CURRENT_TASK="(unknown)"
    local line
    while IFS= read -r line; do
        case "$line" in
            "- State: "*)        STATE="${line#- State: }" ;;
            "- Waiting For: "*)  WAITING_FOR="${line#- Waiting For: }" ;;
            "- Current Task: "*) CURRENT_TASK="${line#- Current Task: }" ;;
        esac
    done < <(_section_content "Status")
    case "$STATE" in
        QUESTION_FOR_CODEX)  STATE="QUESTION_FOR_MASTER" ;;
        QUESTION_FOR_CLAUDE) STATE="QUESTION_FOR_IMPLEMENTER" ;;
    esac
}

_get_role_binding() {
    MASTER_TOOL="Codex" REVIEWER_TOOL="Codex" IMPLEMENTER_TOOL="Claude Code"
    local rf="$(pwd)/.ai/roles/ROLE_ASSIGNMENT.md"
    [ -f "$rf" ] || return 0
    local parsed role tool
    parsed=$(tr -d '\r' < "$rf" | awk -F'|' '
        /^\|[[:space:]]*(Master|Reviewer|Implementer)[[:space:]]*\|/{
            r=$2; t=$3
            gsub(/^[[:space:]]+|[[:space:]]+$/,"",r)
            gsub(/^[[:space:]]+|[[:space:]]+$/,"",t)
            if(r!=""&&t!="") print r"="t
        }')
    while IFS='=' read -r role tool; do
        case "$role" in
            Master)      MASTER_TOOL="$tool" ;;
            Reviewer)    REVIEWER_TOOL="$tool" ;;
            Implementer) IMPLEMENTER_TOOL="$tool" ;;
        esac
    done <<< "$parsed"
}

_resolve_actor() {
    case "$1" in
        User)        echo "User" ;;
        Master)      echo "$MASTER_TOOL" ;;
        Reviewer)    echo "$REVIEWER_TOOL" ;;
        Implementer) echo "$IMPLEMENTER_TOOL" ;;
        *)           echo "$1" ;;
    esac
}

_expected_role() {
    case "$1" in
        NEEDS_ANALYSIS)            echo "Master" ;;
        NEEDS_INVESTIGATION)       echo "Implementer" ;;
        PLAN_REQUIRED)             echo "Implementer" ;;
        PLAN_READY_FOR_REVIEW)     echo "Reviewer" ;;
        READY_FOR_IMPLEMENTATION)  echo "Implementer" ;;
        READY_FOR_REVIEW)          echo "Reviewer" ;;
        REVIEW_DONE)               echo "User" ;;
        QUESTION_FOR_MASTER)       echo "Master" ;;
        QUESTION_FOR_IMPLEMENTER)  echo "Implementer" ;;
        RE_GATE_REQUESTED)         echo "Master" ;;
        BLOCKED)                   echo "User" ;;
        WAITING_FOR_USER)          echo "User" ;;
        *)                         echo "User" ;;
    esac
}

_action_text() {
    case "$1" in
        NEEDS_ANALYSIS)            echo "Classify the task and set the correct State and Waiting For." ;;
        NEEDS_INVESTIGATION)       echo "Investigate only. Do not modify source files." ;;
        PLAN_REQUIRED)             echo "Write a plan only. Do not modify source files." ;;
        PLAN_READY_FOR_REVIEW)     echo "Review the plan. Approve or request changes before implementation begins." ;;
        READY_FOR_IMPLEMENTATION)  echo "Implement the approved scope. Do not modify unrelated files." ;;
        READY_FOR_REVIEW)          echo "Review Changed Files. Run git status and git diff before approving." ;;
        REVIEW_DONE)               echo "Commit authorization: the Reviewer attested technical readiness. Approve the guarded commit if satisfied. Do not commit AI_HANDOFF.md." ;;
        QUESTION_FOR_MASTER)       echo "Answer the Implementer's question under Dialogue / Open Questions, then return the working state." ;;
        QUESTION_FOR_IMPLEMENTER)  echo "Answer the Master's question read-only under Dialogue / Open Questions. No source edits." ;;
        RE_GATE_REQUESTED)         echo "Re-route the task; the Implementer found it riskier/larger than scoped." ;;
        BLOCKED)                   echo "Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md." ;;
        WAITING_FOR_USER)          echo "Review AI_HANDOFF.md and decide the next step or provide approval." ;;
        *)                         echo "Inspect AI_HANDOFF.md and decide the next step." ;;
    esac
}

_after_text() {
    case "$1" in
        NEEDS_ANALYSIS)            echo "Set State to the appropriate gate and Waiting For to the correct role. Update AI_HANDOFF.md." ;;
        NEEDS_INVESTIGATION)       echo "Set State: READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md." ;;
        PLAN_REQUIRED)             echo "Set State: PLAN_READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md." ;;
        PLAN_READY_FOR_REVIEW)     echo "Set State: READY_FOR_IMPLEMENTATION or PLAN_REQUIRED. Set Waiting For accordingly. Update AI_HANDOFF.md." ;;
        READY_FOR_IMPLEMENTATION)  echo "Set State: READY_FOR_REVIEW and Waiting For: Reviewer. Update AI_HANDOFF.md." ;;
        READY_FOR_REVIEW)          echo "Set State: REVIEW_DONE and Waiting For: User, or READY_FOR_IMPLEMENTATION if changes are needed. Update AI_HANDOFF.md." ;;
        REVIEW_DONE)               echo "No handoff update required. Commit only the files listed under Changed Files." ;;
        QUESTION_FOR_MASTER)       echo "Set State back to the Implementer's working state and Waiting For: Implementer. Update AI_HANDOFF.md." ;;
        QUESTION_FOR_IMPLEMENTER)  echo "Set State back to the value the Master specified and Waiting For: Master. Update AI_HANDOFF.md." ;;
        RE_GATE_REQUESTED)         echo "Re-classify through the Decision Router and set State/Waiting For accordingly. Update AI_HANDOFF.md." ;;
        BLOCKED)                   echo "Resolve the blocker, update AI_HANDOFF.md, and set State and Waiting For appropriately." ;;
        WAITING_FOR_USER)          echo "Update AI_HANDOFF.md with your decision and set State and Waiting For accordingly." ;;
        *)                         echo "Update AI_HANDOFF.md with the correct State and Waiting For." ;;
    esac
}

_commit_status_text() {
    case "$STATE" in
        REVIEW_DONE) echo "ALLOWED - the Reviewer attested technical readiness; the remaining step is your commit authorization. Commit only the files listed under Changed Files." ;;
        IMPLEMENTED) echo "ALLOWED - no Reviewer review required. Review the work before committing." ;;
        *)           echo "Blocked - $STATE requires action before committing." ;;
    esac
}

# Stop-category label (v0.18.2 controlled stop routing). See PROTOCOL_METHOD.md, "Stop Routing".
_stop_category() {
    local for_state="$1" actor_tool="$2" automation="${3:-no}"
    if [ "$actor_tool" = "User" ]; then
        case "$for_state" in
            REVIEW_DONE)
                echo "Stop category: User Commit Authorization - approve the guarded commit; technical readiness was attested by the Reviewer." ;;
            IMPLEMENTED)
                echo "Stop category: User Commit Authorization - this work did not require Reviewer review; check it yourself before approving the commit." ;;
            *)
                echo "Stop category: User Decision - see AI_HANDOFF.md." ;;
        esac
    elif [ "$automation" = "yes" ]; then
        echo "Stop category: Non-callable Actor (automation limitation) - next step is an Operator Manual Action: paste the prompt into $actor_tool."
    else
        echo "Stop category: Operator Manual Action - paste the prompt into $actor_tool."
    fi
}

_adapter_profile() {
    local role="$1" tool="$2"
    ADAPTER_CALLABLE="no"
    ADAPTER_AUTOLOOP="no"
    ADAPTER_STATES="none"
    ADAPTER_INVOCATION="Run 'handoff.sh next' then paste the generated prompt into $tool."
    ADAPTER_SAFETY="Manual prompt handoff only; no commit/push/tag/deploy/db/secrets automation."
    ADAPTER_STOP="Non-callable Actor"
    ADAPTER_AUTH="no for paste; yes for protected actions"
    ADAPTER_REASON="$tool has no verified local callable adapter for the $role role."
    ADAPTER_NEXT="Add and verify a real local adapter before marking this role callable."

    if [ "$role" = "Implementer" ] && [ "$tool" = "Claude Code" ]; then
        ADAPTER_CALLABLE="yes"
        ADAPTER_AUTOLOOP="yes"
        ADAPTER_STATES="READY_FOR_IMPLEMENTATION"
        ADAPTER_INVOCATION="PowerShell only: handoff.ps1 cycle or handoff.ps1 loop invokes npx --yes @anthropic-ai/claude-code with Bash disallowed, a budget cap, and no session persistence."
        ADAPTER_SAFETY="Explicit yes confirmation in PowerShell; Reviewer != Implementer; clean tree except local handoff files; Bash disallowed; budget cap; no commit/push/tag/deploy/db/secrets automation."
        ADAPTER_AUTH="yes, before cycle or loop session"
        ADAPTER_REASON="Only READY_FOR_IMPLEMENTATION is automated; investigation, planning, and questions remain manual."
        ADAPTER_NEXT="Use pwsh scripts/handoff.ps1 cycle or loop for READY_FOR_IMPLEMENTATION; use bash scripts/handoff.sh next + paste for other turns."
    elif [ "$role" = "Master" ] && [ "$tool" = "Codex" ]; then
        # Callable in PowerShell only (since v2.0.1) via master-run + master-apply, and never
        # auto-run by loop/cycle. Bash itself never invokes Codex or applies a recommendation.
        ADAPTER_CALLABLE="yes (PowerShell only: master-run + master-apply)"
        ADAPTER_AUTOLOOP="no"
        ADAPTER_STATES="NEEDS_ANALYSIS"
        ADAPTER_INVOCATION="PowerShell only: pwsh scripts/handoff.ps1 master-run (capture) then pwsh scripts/handoff.ps1 master-apply (apply the captured recommendation's local AI_HANDOFF.md transition)."
        ADAPTER_SAFETY="Explicit yes per command; NEEDS_ANALYSIS only; bound Master is Codex; captured TASK must match Current Task; recommendation/Waiting For pair must be valid; non-BLOCKED routing must use the current bound Implementer and Reviewer and preserve Reviewer != Implementer; master-apply edits only AI_HANDOFF.md; not auto-run by loop/cycle; no commit/push/tag/deploy/db/secrets."
        ADAPTER_STOP="Operator Manual Action"
        ADAPTER_AUTH="yes, explicit yes before master-run and master-apply"
        ADAPTER_REASON="master-run + master-apply complete the Master's NEEDS_ANALYSIS routing turn end-to-end (PowerShell only); callable via these explicit commands only - never inside loop or cycle."
        ADAPTER_NEXT="Use pwsh scripts/handoff.ps1 master-run then master-apply; Bash cannot invoke Codex or apply the recommendation."
    elif [ "$role" = "Reviewer" ] && [ "$tool" = "Codex" ]; then
        # Callable in PowerShell only (since v1.3.0) via review-run + review-apply, and never
        # auto-run by loop/cycle (Auto-loop stays no). Bash itself never invokes Codex.
        ADAPTER_CALLABLE="yes (PowerShell only: review-run + review-apply)"
        ADAPTER_AUTOLOOP="no"
        ADAPTER_STATES="READY_FOR_REVIEW"
        ADAPTER_INVOCATION="PowerShell only: pwsh scripts/handoff.ps1 review-run (capture) then pwsh scripts/handoff.ps1 review-apply (apply the captured verdict's local AI_HANDOFF.md transition)."
        ADAPTER_SAFETY="Explicit yes per command; READY_FOR_REVIEW only; bound and actual Reviewer is Codex and != actual Implementer; Changed Files == git status; Codex read-only; review-apply edits only AI_HANDOFF.md; not auto-run by default; only PowerShell loop -IncludeReviewer may opt in; Bash/cycle never do; no commit/push/tag/deploy/db/secrets; no release action."
        ADAPTER_STOP="Operator Manual Action"
        ADAPTER_AUTH="yes, explicit yes before review-run and review-apply"
        ADAPTER_REASON="review-run + review-apply complete the Reviewer's READY_FOR_REVIEW turn end-to-end (PowerShell only); callable via these explicit commands only - never inside loop or cycle."
        ADAPTER_NEXT="Use pwsh scripts/handoff.ps1 review-run then review-apply; Bash cannot invoke Codex."
    elif [ "$tool" = "Codex" ]; then
        ADAPTER_REASON="No callable local adapter is present for $tool in the $role role in this repository."
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_status() {
    echo ""
    echo "State:        $STATE"
    echo "Waiting For:  $WAITING_FOR"
    echo "Task:         $CURRENT_TASK"
    echo "Roles:        Master=$MASTER_TOOL, Reviewer=$REVIEWER_TOOL, Implementer=$IMPLEMENTER_TOOL"
    echo "Adapters:     run 'bash scripts/handoff.sh adapters' for callable/manual automation status"
    echo "Commit:       $(_commit_status_text)"
    [ -f "$(pwd)/.agents/skills/codex-claude-handoff/SKILL.md" ] && \
        echo "Protocol:     installed (canonical: .ai/skills/codex-claude-handoff/; roles: .ai/roles/ROLE_ASSIGNMENT.md)"
    echo ""
}

cmd_adapters() {
    echo ""
    echo "Adapter status"
    echo "Contract: .ai/skills/codex-claude-handoff/ADAPTERS.md"
    echo ""
    local role tool
    for role in Master Implementer Reviewer; do
        tool=$(_resolve_actor "$role")
        _adapter_profile "$role" "$tool"
        echo "Role:        $role"
        echo "Tool:        $tool"
        echo "Callable:    $ADAPTER_CALLABLE"
        echo "Auto-loop:   $ADAPTER_AUTOLOOP  (yes only if loop/cycle may auto-run this turn)"
        echo "States:      $ADAPTER_STATES"
        echo "Reason:      $ADAPTER_REASON"
        echo "Invocation:  $ADAPTER_INVOCATION"
        echo "Safety:      $ADAPTER_SAFETY"
        echo "Stop:        $ADAPTER_STOP"
        echo "User auth:   $ADAPTER_AUTH"
        echo "Enable next: $ADAPTER_NEXT"
        echo ""
    done
    echo "Capability:  Authorized release executor"
    echo "Callable:    no in Bash (PowerShell only)"
    echo "States:      REVIEW_DONE with Waiting For: User"
    echo "Invocation:  pwsh scripts/handoff.ps1 release-check -Version vX.Y.Z; pwsh scripts/handoff.ps1 release -Version vX.Y.Z -Message \"<msg>\" -Authorize \"I_AUTHORIZE_RELEASE_vX.Y.Z\""
    echo "Safety:      Exact user authorization token; Reviewer != Implementer; Changed Files == git status; pre-release checks; commit before tag; no deploy/db/secrets/production-config actions."
    echo "Stop:        Environment/Preflight in Bash; use PowerShell for the guarded executor."
    echo "User auth:   yes, exact token required for execution"
    echo "Enable next: Use PowerShell release-check for dry run; use release only after independent review has set REVIEW_DONE."
    echo ""
}

cmd_next() {
    local exp_role exp_tool actor role_label action_line after_line is_mismatch=false
    exp_role=$(_expected_role "$STATE")
    exp_tool=$(_resolve_actor "$exp_role")

    if [ "$WAITING_FOR" != "(unknown)" ] && \
       [ "$WAITING_FOR" != "$exp_role" ] && \
       [ "$WAITING_FOR" != "$exp_tool" ]; then
        is_mismatch=true
        actor="User" role_label="handoff mismatch"
        action_line="Resolve handoff mismatch. State $STATE normally expects Waiting For: $exp_role ($exp_tool), but found: $WAITING_FOR."
        after_line="Correct Waiting For in AI_HANDOFF.md to match the expected role for this state."
    else
        actor="$exp_tool" role_label="$exp_role"
        action_line=$(_action_text "$STATE")
        after_line=$(_after_text "$STATE")
    fi

    local next_step key_context=""
    next_step=$(_section_content "Next Recommended Step")
    case "$STATE" in
        READY_FOR_REVIEW|PLAN_READY_FOR_REVIEW)
            local cf; cf=$(_section_content "Changed Files")
            [ -n "$cf" ] && key_context="Changed Files:
$cf"
            ;;
    esac

    local timestamp; timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    local nt_path; nt_path="$(pwd)/NEXT_TURN.md"

    {   echo "# Next Turn Entry Brief"
        echo "Generated: $timestamp"
        echo "Actor: $actor ($role_label)"
        echo "State: $STATE"
        echo "Current Task: $CURRENT_TASK"
        echo ""
        echo "NOTE: This file is a convenience summary. Read AI_HANDOFF.md before acting."
        echo ""
        echo "## Your Action This Turn"
        echo "$action_line"
        echo ""
        echo "## Next Recommended Step (from AI_HANDOFF.md)"
        if [ -n "$next_step" ]; then echo "$next_step"; else echo "(none - see AI_HANDOFF.md)"; fi
        if [ -n "$key_context" ]; then echo ""; echo "## Key Context"; echo "$key_context"; fi
        if [ -n "$after_line" ];  then echo ""; echo "## After You Finish"; echo "$after_line"; fi
    } > "$nt_path"

    local paste="Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
    echo ""
    echo "NEXT_TURN.md written."
    if $is_mismatch; then
        echo "WARNING: State $STATE expects Waiting For: $exp_role ($exp_tool), but found: $WAITING_FOR."
        echo "Next actor: User - resolve the handoff mismatch in AI_HANDOFF.md before continuing."
        echo "Stop category: Protocol Repair - a correction, not a product decision."
    elif [ "$actor" = "User" ]; then
        echo "Next actor: User"
        _stop_category "$STATE" "User"
        echo "No tool handoff needed."
        echo "Review the status, start a new request, or run commit-check if you are about to commit."
    else
        echo "Open:  $actor  (role: $role_label)"
        echo "Paste: $paste"
        _stop_category "$STATE" "$actor"
        echo ""
        if $CLIP; then
            echo "(--clip: clipboard auto-copy is not supported in handoff.sh; copy the Paste line manually.)"
        else
            echo "Copy the Paste line manually."
        fi
    fi
    echo ""
}

cmd_start() {
    if [ -z "$REQUEST" ]; then
        echo 'Usage: bash handoff.sh start "<natural user request>"'
        exit 1
    fi
    local rp; rp="$(pwd)/USER_REQUEST.md"
    printf '%s\n' "$REQUEST" > "$rp"
    echo ""
    echo "USER_REQUEST.md written."
    local gi; gi="$(pwd)/.gitignore"
    if [ -f "$gi" ]; then
        grep -qxF "USER_REQUEST.md" "$gi" 2>/dev/null || \
            echo "WARNING: USER_REQUEST.md is not in .gitignore. Add it to avoid committing user requests."
    fi
    local prompt
    prompt="Use the codex-claude-handoff skill.
Read USER_REQUEST.md for the user's request.
Read AI_HANDOFF.md for current handoff state.
Read .ai/roles/ROLE_ASSIGNMENT.md to confirm you hold the Master role.
Read .agents/skills/codex-claude-handoff/SKILL.md as local protocol instructions.
Route the request through the Decision Router.
When correctness depends on current repo behavior, local implementation details, or verification constraints, default to a read-only Implementer investigation pass (NEEDS_INVESTIGATION) before finalizing the task.
If the request is advisory-only, answer directly and do not update AI_HANDOFF.md.
Update AI_HANDOFF.md only if the protocol requires investigation, planning, implementation, user decision tracking, or review."
    echo ""
    echo "=== Master Entry Prompt (open: $MASTER_TOOL) ==="
    echo "$prompt"
    echo ""
    if $CLIP; then
        echo "(--clip: clipboard auto-copy is not supported in handoff.sh; copy the prompt manually.)"
    fi
}

cmd_commit_check() {
    echo ""
    if [ "$STATE" = "REVIEW_DONE" ] && [ "$WAITING_FOR" = "User" ]; then
        local LOCAL_IGNORED="AI_HANDOFF.md NEXT_TURN.md USER_REQUEST.md HANDOFF_LOOP.log AI_SEQUENCE.md CODEX_REVIEW.jsonl CODEX_REVIEW_LAST.md CODEX_MASTER.jsonl CODEX_MASTER_LAST.md CLAUDE_IMPLEMENTER.jsonl CLAUDE_IMPLEMENTER_LAST.md"
        local commit_files=() actual_files=()
        local line entry in_cf=false

        while IFS= read -r line; do
            [ "$line" = "## Changed Files" ] && { in_cf=true; continue; }
            $in_cf || continue
            case "$line" in "## "*) break ;; esac
            case "$line" in
                "- "*)
                    entry="${line#- }"
                    entry="${entry//\`/}"
                    entry="${entry%% - *}"
                    entry="${entry#"${entry%%[! ]*}"}"
                    entry="${entry%"${entry##*[! ]}"}"
                    if [ -n "$entry" ] && [ "$entry" != "None yet" ]; then
                        case " $LOCAL_IGNORED " in
                            *" $entry "*) ;;
                            *) commit_files+=("$entry") ;;
                        esac
                    fi
                    ;;
            esac
        done < <(tr -d '\r' < "$HANDOFF_FILE")

        local gstatus gl fp
        gstatus=$(git status --short --untracked-files=all 2>/dev/null) || gstatus=""
        if [ -n "$gstatus" ]; then
            while IFS= read -r gl; do
                [ ${#gl} -lt 3 ] && continue
                fp="${gl:3}"
                fp="${fp#"${fp%%[! ]*}"}"
                case "$fp" in *" -> "*) fp="${fp##* -> }" ;; esac
                [ -z "$fp" ] && continue
                case " $LOCAL_IGNORED " in
                    *" $fp "*) ;;
                    *) actual_files+=("$fp") ;;
                esac
            done <<< "$gstatus"
        fi

        if [ ${#actual_files[@]} -eq 0 ]; then
            echo "Commit: No tracked changes to commit."
            echo "Working tree is clean."
            echo ""
            return
        fi

        echo "Commit: ALLOWED - the Reviewer attested technical readiness."
        echo "Stop category: User Commit Authorization - you approve the guarded commit; running the command is an Operator Manual Action."
        echo ""

        local mismatch=false x y found
        if [ ${#commit_files[@]} -ne ${#actual_files[@]} ]; then
            mismatch=true
        else
            for x in "${commit_files[@]}"; do
                found=false
                for y in "${actual_files[@]}"; do
                    [ "$(printf '%s' "$x" | tr '[:upper:]' '[:lower:]')" = \
                      "$(printf '%s' "$y" | tr '[:upper:]' '[:lower:]')" ] && found=true && break
                done
                $found || { mismatch=true; break; }
            done
        fi

        if $mismatch; then
            echo "Handoff suggested files:"
            if [ ${#commit_files[@]} -eq 0 ]; then
                echo "  (none - handoff only lists AI_HANDOFF.md)"
            else
                for f in "${commit_files[@]}"; do echo "  $f"; done
            fi
            echo ""
            echo "Actual changed tracked files:"
            for f in "${actual_files[@]}"; do echo "  $f"; done
            echo ""
            echo "WARNING:"
            echo "The handoff file list does not match git status."
            echo "Confirm the correct commit scope manually before committing."
        else
            echo "Files to commit:"
            for f in "${commit_files[@]}"; do echo "  $f"; done
            echo ""
            local file_args="${commit_files[*]}"
            echo "Suggested commands (reference only - prefer PowerShell commit-approved for the guarded executor):"
            echo "  git add $file_args"
            echo '  git commit -m "<your commit message>"'
            echo ""
            echo "PowerShell executor:"
            echo '  pwsh scripts/handoff.ps1 commit-approved -Message "<msg>" -Authorize "I_AUTHORIZE_COMMIT"'
        fi
    else
        echo "Commit: Not yet allowed."
        echo "State: $STATE - Waiting For: $WAITING_FOR"
        local reason
        case "$STATE" in
            READY_FOR_REVIEW)          reason="Waiting for the Reviewer to review." ;;
            PLAN_READY_FOR_REVIEW)     reason="Waiting for the Reviewer to review the plan." ;;
            READY_FOR_IMPLEMENTATION)  reason="Waiting for the Implementer to implement." ;;
            PLAN_REQUIRED)             reason="Waiting for the Implementer to write a plan." ;;
            NEEDS_INVESTIGATION)       reason="Waiting for the Implementer to investigate." ;;
            NEEDS_ANALYSIS)            reason="Waiting for the Master to analyze." ;;
            BLOCKED)                   reason="Work is blocked. Resolve the issue in AI_HANDOFF.md." ;;
            WAITING_FOR_USER)          reason="User decision or approval required. See AI_HANDOFF.md." ;;
            *)                         reason="Inspect AI_HANDOFF.md for details." ;;
        esac
        echo "Reason: $reason"
    fi
    echo ""
}

# Shared blocked message for automation commands (cycle, run-next).
# Bash automation is not implemented; PowerShell (pwsh) is required.
cmd_automation_blocked() {
    local cmd_name="$1"
    echo ""
    echo "$cmd_name is not available in handoff.sh."
    echo "To use $cmd_name: install PowerShell (pwsh) and run handoff.ps1 $cmd_name."
    echo "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
    echo "On macOS/Linux without pwsh: run 'bash handoff.sh next', then paste the prompt manually."
    echo ""
    exit 1
}

cmd_release_blocked() {
    local cmd_name="$1"
    echo ""
    echo "$cmd_name is not available in handoff.sh."
    echo "The guarded release executor is implemented in PowerShell only so one path owns the git mutation safety checks."
    echo "To dry-run:  pwsh scripts/handoff.ps1 release-check -Version vX.Y.Z"
    echo "To execute:  pwsh scripts/handoff.ps1 release -Version vX.Y.Z -Message \"<message>\" -Authorize \"I_AUTHORIZE_RELEASE_vX.Y.Z\""
    echo "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
    echo ""
    exit 1
}

cmd_commit_approved_blocked() {
    echo ""
    echo "commit-approved is not available in handoff.sh."
    echo "The guarded commit executor is implemented in PowerShell only so one path owns the git mutation safety checks."
    echo 'To dry-run:  pwsh scripts/handoff.ps1 commit-check -Message "<message>"'
    echo 'To execute:  pwsh scripts/handoff.ps1 commit-approved -Message "<message>" -Authorize "I_AUTHORIZE_COMMIT"'
    echo "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
    echo ""
    exit 1
}

# sequence-check / sequence-advance are PowerShell-only (one path owns the local
# coordination edits + checkpoint verification). Bash never mutates AI_SEQUENCE.md.
cmd_sequence_blocked() {
    local cmd_name="$1"
    echo ""
    echo "$cmd_name is not available in handoff.sh."
    echo "The sequence advance command is implemented in PowerShell only so one path owns the local coordination edits and release-checkpoint verification."
    echo "To dry-run:  pwsh scripts/handoff.ps1 sequence-check -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z"
    echo "To apply:    pwsh scripts/handoff.ps1 sequence-advance -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z -NextTask \"<next task>\""
    echo "It edits only local AI_SEQUENCE.md / AI_HANDOFF.md and never runs git add/commit/push/tag."
    echo "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
    echo ""
    exit 1
}

# review-check / review-run / review-apply are PowerShell-only (one path owns the
# read-only Codex invocation, the fail-closed guards, local artifact capture, and the
# captured-verdict AI_HANDOFF.md transition). Bash never invokes Codex or applies a verdict.
cmd_review_blocked() {
    local cmd_name="$1"
    echo ""
    echo "$cmd_name is not available in handoff.sh."
    echo "The Codex Reviewer automation is implemented in PowerShell only so one path owns the read-only Codex invocation, the fail-closed guards, local artifact capture, and the captured-verdict AI_HANDOFF.md transition."
    echo "To dry-run:  pwsh scripts/handoff.ps1 review-check"
    echo "To capture:  pwsh scripts/handoff.ps1 review-run"
    echo "To apply:    pwsh scripts/handoff.ps1 review-apply"
    echo "review-run runs Codex read-only and captures output locally; review-apply edits only AI_HANDOFF.md. Neither ever runs git add/commit/push/tag."
    echo "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
    echo ""
    exit 1
}

# master-check / master-run / master-apply are PowerShell-only (one path owns the read-only
# Codex invocation, the fail-closed guards, local artifact capture, and local handoff apply).
# Bash never invokes Codex or applies a recommendation.
cmd_master_blocked() {
    local cmd_name="$1"
    echo ""
    echo "$cmd_name is not available in handoff.sh."
    echo "The Codex Master automation is implemented in PowerShell only so one path owns the read-only Codex invocation, the fail-closed guards, local artifact capture, and the recommendation-to-AI_HANDOFF.md transition."
    echo "To dry-run:  pwsh scripts/handoff.ps1 master-check"
    echo "To capture:  pwsh scripts/handoff.ps1 master-run"
    echo "To apply:    pwsh scripts/handoff.ps1 master-apply"
    echo "master-run runs Codex read-only and captures the routing recommendation locally; master-apply edits only AI_HANDOFF.md. Neither ever runs git add/commit/push/tag."
    echo "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
    echo ""
    exit 1
}

# ---------------------------------------------------------------------------
# Init and dispatch
# ---------------------------------------------------------------------------

_parse_status
_get_role_binding

case "$COMMAND" in
    status)       cmd_status ;;
    adapters)     cmd_adapters ;;
    next)         cmd_next ;;
    start)        cmd_start ;;
    commit-check) cmd_commit_check ;;
    commit-approved) cmd_commit_approved_blocked ;;
    release-check) cmd_release_blocked "release-check" ;;
    release)      cmd_release_blocked "release" ;;
    sequence-check)   cmd_sequence_blocked "sequence-check" ;;
    sequence-advance) cmd_sequence_blocked "sequence-advance" ;;
    review-check) cmd_review_blocked "review-check" ;;
    review-run)   cmd_review_blocked "review-run" ;;
    review-apply) cmd_review_blocked "review-apply" ;;
    master-check) cmd_master_blocked "master-check" ;;
    master-run)   cmd_master_blocked "master-run" ;;
    master-apply) cmd_master_blocked "master-apply" ;;
    cycle)        cmd_automation_blocked "cycle" ;;
    run-next)     cmd_automation_blocked "run-next" ;;
    loop)         cmd_automation_blocked "loop" ;;
    "")
        echo ""
        echo "Usage: bash handoff.sh <command> [options]"
        echo ""
        echo "Commands:"
        echo "  status                    Show current handoff state, role binding, and commit status."
        echo "  adapters                  Show adapter callable/manual status for each role."
        echo "  next [--clip]             Generate NEXT_TURN.md and print the paste instruction."
        echo '  start "<request>"         Save request and print a Master entry prompt.'
        echo "  commit-check              Show whether a commit is allowed and what to commit."
        echo "  commit-approved           Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  release-check             Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  release                   Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  sequence-check            Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  sequence-advance          Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  review-check              Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  review-run                Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  review-apply              Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  master-check              Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  master-run                Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  master-apply              Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  cycle                     Not available in handoff.sh; requires PowerShell (pwsh)."
        echo "  run-next                  Alias of cycle; not available in handoff.sh."
        echo "  loop                      Not available in handoff.sh; requires PowerShell (pwsh)."
        echo ""
        ;;
    *)
        echo ""
        echo "Unknown command: $COMMAND"
        echo "Run 'bash handoff.sh' with no arguments to see usage."
        echo ""
        exit 1
        ;;
esac
