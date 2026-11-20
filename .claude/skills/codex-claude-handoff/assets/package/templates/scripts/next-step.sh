#!/usr/bin/env bash
# next-step.sh - Codex-Claude Handoff next-step helper (Bash version, v0.15.0)
# Prints current handoff state and a ready-to-paste prompt.
# Use --prepare-file to also write NEXT_TURN.md.

set -euo pipefail

# v3.18.0: byte-wise readers, so a UTF-8 locale on another machine cannot change a match.
export LC_ALL=C

COPY_PROMPT=false
PREPARE_FILE=false
for _arg in "$@"; do
    case "$_arg" in
        --copy-prompt|-CopyPrompt) COPY_PROMPT=true ;;
        --prepare-file|-PrepareFile) PREPARE_FILE=true ;;
    esac
done
unset _arg

HANDOFF_FILE="$(pwd)/AI_HANDOFF.md"
if [ ! -f "$HANDOFF_FILE" ]; then
    echo "No AI_HANDOFF.md found in the current directory."
    echo "Run this script from your project root, or install the handoff protocol first."
    exit 0
fi

# ---------------------------------------------------------------------------
# Helpers (self-contained - same logic as handoff.sh)
# ---------------------------------------------------------------------------

_section_content() {
    # v3.18.0: the same port of handoff.ps1's Get-SectionLines as handoff.sh: a repeated
    # heading is skipped, any other "##" heading ends the reading, "###" is content.
    local h; h="$(printf '## %s' "$1" | tr '[:upper:]' '[:lower:]')"
    tr -d '\r' < "$HANDOFF_FILE" | \
    awk -v h="$h" -v bom="$(printf '\357\273\277')" '
        done { next }
        { l = $0; if (NR == 1 && index(l, bom) == 1) l = substr(l, length(bom) + 1); t = l; sub(/[[:space:]]+$/, "", t) }
        tolower(t) == h { s = 1; next }
        s { if (l ~ /^##[[:space:]]/) { done = 1; next } print l }'
}

# One Status field, read as handoff.ps1's Read-HandoffState reads it (see handoff.sh).
_status_field() {
    printf '%s\n' "$1" | awk -v k="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '
        { low = tolower($0) }
        index(low, "- " k ":") == 1 && length($0) > length(k) + 3 { v = substr($0, length(k) + 4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); val = v; found = 1 }
        END { if (found) printf "%s", val; else exit 1 }'
}

_parse_status() {
    STATE="(unknown)" WAITING_FOR="(unknown)" CURRENT_TASK="(unknown)"
    local status v
    status="$(_section_content "Status")"
    if v="$(_status_field "$status" "State")"; then STATE="$v"; fi
    if v="$(_status_field "$status" "Waiting For")"; then WAITING_FOR="$v"; fi
    if v="$(_status_field "$status" "Current Task")"; then CURRENT_TASK="$v"; fi
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
    # v3.18.0 (review fix): role names without regard to case, as handoff.ps1 reads them.
    parsed=$(tr -d '\r' < "$rf" | awk -F'|' '
        tolower($0) ~ /^\|[[:space:]]*(master|reviewer|implementer)[[:space:]]*\|/{
            r=tolower($2); t=$3
            gsub(/^[[:space:]]+|[[:space:]]+$/,"",r)
            gsub(/^[[:space:]]+|[[:space:]]+$/,"",t)
            if(r!=""&&t!="") print r"="t
        }')
    while IFS='=' read -r role tool; do
        case "$role" in
            master)      MASTER_TOOL="$tool" ;;
            reviewer)    REVIEWER_TOOL="$tool" ;;
            implementer) IMPLEMENTER_TOOL="$tool" ;;
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
        REVIEW_DONE)               echo "Release authorization: the Reviewer attested technical readiness. Approve and run the commit/push yourself. Do not commit AI_HANDOFF.md." ;;
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

_parse_status

# v3.18.0 (review fix): the Setup line, read the way handoff.sh reads it. While setup is
# pending nothing is prepared for a binding nobody chose; an unreadable line fails closed.
_setup_file="$(pwd)/.ai/roles/ROLE_ASSIGNMENT.md"
if [ -f "$_setup_file" ]; then
    _setup_lines="$(tr -d '\r' < "$_setup_file" | awk -v bom="$(printf '\357\273\277')" -v nbsp="$(printf '\302\240')" '{ l = $0; if (NR == 1 && index(l, bom) == 1) l = substr(l, length(bom) + 1); gsub(nbsp, " ", l) } tolower(l) ~ /^[[:space:]]*([-*][[:space:]]+)?setup[[:space:]]*:/ { v = l; sub(/^[^:]*:/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print "<" tolower(v) ">" }')"
    _setup_count="$(printf '%s' "$_setup_lines" | grep -c '^<' || true)"
    if [ "$_setup_count" -gt 1 ] || { [ "$_setup_count" -eq 1 ] && [ "$_setup_lines" != "<pending>" ] && [ "$_setup_lines" != "<complete>" ]; }; then
        echo ""
        echo "Role checkpoint: BLOCKED - the 'Setup:' line in .ai/roles/ROLE_ASSIGNMENT.md must appear once and read pending or complete."
        echo "Repair it with: bash scripts/handoff.sh setup. NEXT_TURN.md was not written."
        exit 12
    fi
    if [ "$_setup_lines" = "<pending>" ]; then
        echo ""
        echo "Setup required: this project has not chosen its players and its Master yet."
        echo "Run:  bash scripts/handoff.sh setup --players \"<Claude Code, Codex, or both>\" --master \"<one of the players>\""
        echo "An agent must ask the user which players and which Master; it never chooses for them."
        echo "Nothing was started and nothing was changed."
        exit 14
    fi
fi

_get_role_binding

# v3.17.0: the review rule, read the way handoff.ps1 reads it (absent = separate-tool).
# Only a valid, single fresh-context line counts; nothing here relaxes a gate.
_canonical_tool() {
    local key; key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$key" in
        "codex"|"codex window"|"codex cli"|"codex desktop"|"openai codex") echo "codex" ;;
        "claude code"|"claude-code"|"claudecode"|"claude code cli"|"claude code window") echo "claude-code" ;;
        *) echo "" ;;
    esac
}
SINGLE_VENDOR_LINE=""
_ri_file="$(pwd)/.ai/roles/ROLE_ASSIGNMENT.md"
if [ -f "$_ri_file" ]; then
    # v3.17.0 (review fix): read without regard to case, as handoff.ps1 does.
    _ri_lines="$(tr -d '\r' < "$_ri_file" | awk -v bom="$(printf '\357\273\277')" -v nbsp="$(printf '\302\240')" '{ l = $0; if (NR == 1 && index(l, bom) == 1) l = substr(l, length(bom) + 1); gsub(nbsp, " ", l) } tolower(l) ~ /^[[:space:]]*([-*][[:space:]]+)?review independence[[:space:]]*:/ { v = l; sub(/^[^:]*:/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print "<" v ">" }')"
    _ri_count="$(printf '%s' "$_ri_lines" | grep -c '^<' || true)"
    _ri_values="${_ri_lines#<}"; _ri_values="${_ri_values%>}"
    _ri_values="$(printf '%s' "$_ri_values" | tr '[:upper:]' '[:lower:]')"
    _rc="$(_canonical_tool "$REVIEWER_TOOL")"
    if [ "$_ri_count" -eq 1 ] && [ "$_ri_values" = "fresh-context" ] && [ -n "$_rc" ] && [ "$_rc" = "$(_canonical_tool "$IMPLEMENTER_TOOL")" ]; then
        if [ "$_rc" = "codex" ]; then _rd="Codex"; else _rd="Claude Code"; fi
        SINGLE_VENDOR_LINE="Single-vendor review: $_rd is both Implementer and Reviewer. It reviews in a separate read-only run started by the harness (review-run, then review-apply), never in the Implementer's context."
    fi
fi

# Determine expected role and resolve mismatch
EXP_ROLE=$(_expected_role "$STATE")
EXP_TOOL=$(_resolve_actor "$EXP_ROLE")
ACTOR_TOOL="$EXP_TOOL"
ACTOR_ROLE="$EXP_ROLE"
MISMATCH=false

if [ "$WAITING_FOR" != "(unknown)" ] && \
   [ "$WAITING_FOR" != "$EXP_ROLE" ] && \
   [ "$WAITING_FOR" != "$EXP_TOOL" ]; then
    MISMATCH=true
    ACTOR_TOOL="User"
    ACTOR_ROLE="handoff mismatch"
fi

echo ""
echo "=== Handoff Status ==="
echo "State:        $STATE"
echo "Waiting For:  $WAITING_FOR"
echo "Current Task: $CURRENT_TASK"
echo "Roles:        Master=$MASTER_TOOL, Reviewer=$REVIEWER_TOOL, Implementer=$IMPLEMENTER_TOOL"
[ -n "$SINGLE_VENDOR_LINE" ] && echo "Review:       $SINGLE_VENDOR_LINE"
echo ""

if $MISMATCH; then
    echo "WARNING: State $STATE normally expects Waiting For: $EXP_ROLE ($EXP_TOOL) but found: $WAITING_FOR."
    echo ""
fi

# Check READY_FOR_REVIEW: warn if Changed Files lists only AI_HANDOFF.md
if [ "$STATE" = "READY_FOR_REVIEW" ]; then
    local_cf=$(_section_content "Changed Files")
    real_files=$(echo "$local_cf" | grep -E '^- ' | grep -v 'AI_HANDOFF\.md' | grep -v '^- None yet' || true)
    if [ -n "$local_cf" ] && [ -z "$real_files" ]; then
        echo "WARNING: Changed Files lists only AI_HANDOFF.md. No tracked source file is listed for review."
        echo ""
    fi
fi

PROMPT_TEXT=""
ACTION_LINE=""
AFTER_LINE=""

if $MISMATCH; then
    echo "=== Next Action ==="
    echo "Actor:  User"
    echo "Action: Resolve handoff mismatch. State $STATE normally expects Waiting For: $EXP_ROLE ($EXP_TOOL), but found: $WAITING_FOR."
    echo "Commit: Blocked - handoff state is inconsistent."
    echo "Stop:   Protocol Repair - a correction, not a product decision."
    ACTION_LINE="Resolve handoff mismatch. State $STATE normally expects Waiting For: $EXP_ROLE ($EXP_TOOL)."
    AFTER_LINE="Correct Waiting For in AI_HANDOFF.md to match the expected role for this state."
elif [ "$STATE" = "REVIEW_DONE" ]; then
    echo "=== Next Action ==="
    echo "Actor:  User"
    echo "Action: Release authorization: the Reviewer attested technical readiness. Approve and run the commit/push yourself. Do not commit AI_HANDOFF.md."
    echo "Commit: ALLOWED - the Reviewer attested technical readiness; the remaining step is your release authorization. Commit only the files listed under Changed Files."
    echo "Stop:   User Release Authorization - approval only; technical verification was attested by the Reviewer."
    ACTION_LINE="Release authorization: the Reviewer attested technical readiness. Approve and run the commit/push yourself. Do not commit AI_HANDOFF.md."
    AFTER_LINE="No handoff update required. Commit only the files listed under Changed Files."
elif [ "$STATE" = "IMPLEMENTED" ]; then
    echo "=== Next Action ==="
    echo "Actor:  User"
    echo "Action: Review the work. Commit if satisfied, or ask the Reviewer to review first."
    echo "Commit: ALLOWED - no Reviewer review was required for this task."
    echo "Stop:   User Release Authorization - approve the release; running the commit is an Operator Manual Action."
    ACTION_LINE="Review the work. Commit if satisfied, or ask the Reviewer to review first."
    AFTER_LINE="No handoff update required. Commit only the files listed under Changed Files."
elif [ "$STATE" = "BLOCKED" ]; then
    echo "=== Next Action ==="
    echo "Actor:  User"
    echo "Action: Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md."
    echo "Commit: Blocked - work is blocked."
    echo "Stop:   User Decision - resolve the documented blocker."
    _section_content "Open Issues" | grep -v '^$' | while IFS= read -r l; do echo "$l"; done
    ACTION_LINE="Resolve the blocking issue documented under Open Issues in AI_HANDOFF.md."
    AFTER_LINE="Resolve the blocker, update AI_HANDOFF.md, and set State and Waiting For appropriately."
elif [ "$STATE" = "WAITING_FOR_USER" ]; then
    echo "=== Next Action ==="
    echo "Actor:  User"
    echo "Action: Review AI_HANDOFF.md and decide the next step or provide approval."
    echo "Commit: Blocked - waiting for user decision."
    echo "Stop:   User Decision - product, scope, or risk decision required."
    ACTION_LINE="Review AI_HANDOFF.md and decide the next step or provide approval."
    AFTER_LINE="Update AI_HANDOFF.md with your decision and set State and Waiting For accordingly."
elif [ "$EXP_ROLE" = "Master" ] || [ "$EXP_ROLE" = "Reviewer" ] || [ "$EXP_ROLE" = "Implementer" ]; then
    ACTOR_LABEL="$ACTOR_TOOL ($EXP_ROLE)"
    ACTION_LINE=$(_action_text "$STATE")
    AFTER_LINE=$(_after_text "$STATE")
    COMMIT_BLOCKED="Blocked - waiting for $EXP_ROLE review/action after implementation."

    case "$STATE" in
        NEEDS_ANALYSIS|PLAN_READY_FOR_REVIEW|RE_GATE_REQUESTED|QUESTION_FOR_MASTER)
            PROMPT_TEXT="Use the codex-claude-handoff skill. Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the $EXP_ROLE role.
$ACTION_LINE
Current task: $CURRENT_TASK"
            ;;
        NEEDS_INVESTIGATION|PLAN_REQUIRED|QUESTION_FOR_IMPLEMENTER)
            PROMPT_TEXT="Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the $EXP_ROLE role. $ACTION_LINE
Set State: $([ "$STATE" = "NEEDS_INVESTIGATION" ] && echo "READY_FOR_REVIEW" || echo "PLAN_READY_FOR_REVIEW") when done.
Current task: $CURRENT_TASK"
            ;;
        READY_FOR_IMPLEMENTATION)
            PROMPT_TEXT="Read .ai/roles/ROLE_ASSIGNMENT.md and AI_HANDOFF.md. You hold the Implementer role. Continue the protocol from the current state.
Current task: $CURRENT_TASK"
            ;;
        READY_FOR_REVIEW)
            PROMPT_TEXT="Use the codex-claude-handoff skill. Read AI_HANDOFF.md and review Changed Files. You hold the Reviewer role.
Run git status and git diff before approving. Check Changed Files match.
Current task: $CURRENT_TASK"
            ;;
    esac

    echo "=== Next Action ==="
    echo "Actor:  $ACTOR_LABEL"
    echo "Action: $ACTION_LINE"
    echo "Commit: Blocked - no approved implementation yet."
    if [ -n "$PROMPT_TEXT" ]; then
        echo ""
        echo "=== Prompt ==="
        echo "$PROMPT_TEXT"
        ACTION_LINE="$ACTION_LINE"
    fi
else
    echo "WARNING: Unrecognized state: $STATE."
    echo ""
    echo "=== Next Action ==="
    echo "Actor:  User"
    echo "Action: Inspect AI_HANDOFF.md and decide the next step."
    echo "Commit: Blocked - state is unknown."
    echo "Stop:   Protocol Repair (unrecognized state) - a correction, not a product decision."
    ACTION_LINE="Inspect AI_HANDOFF.md and decide the next step."
    AFTER_LINE="Update AI_HANDOFF.md with the correct State and Waiting For."
fi

if $COPY_PROMPT; then
    if [ -n "$PROMPT_TEXT" ]; then
        echo ""
        echo "(--copy-prompt: clipboard auto-copy is not supported in next-step.sh; copy the Prompt section manually.)"
    else
        echo ""
        echo "No prompt to copy."
    fi
fi

if $PREPARE_FILE; then
    nt_path="$(pwd)/NEXT_TURN.md"
    next_step=$(_section_content "Next Recommended Step")
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    key_context=""
    case "$STATE" in
        READY_FOR_REVIEW|PLAN_READY_FOR_REVIEW)
            cf=$(_section_content "Changed Files")
            [ -n "$cf" ] && key_context="Changed Files:
$cf"
            ;;
    esac

    {   echo "# Next Turn Entry Brief"
        echo "Generated: $timestamp"
        echo "Actor: $ACTOR_TOOL ($ACTOR_ROLE)"
        echo "State: $STATE"
        echo "Current Task: $CURRENT_TASK"
        echo ""
        echo "NOTE: This file is a convenience summary. Read AI_HANDOFF.md before acting."
        echo ""
        echo "## Your Action This Turn"
        echo "$ACTION_LINE"
        echo ""
        echo "## Next Recommended Step (from AI_HANDOFF.md)"
        if [ -n "$next_step" ]; then echo "$next_step"; else echo "(none - see AI_HANDOFF.md)"; fi
        if [ -n "$key_context" ]; then echo ""; echo "## Key Context"; echo "$key_context"; fi
        # v3.17.0: same section as handoff.ps1 next writes for a single-vendor Reviewer turn.
        if ! $MISMATCH && [ "$ACTOR_ROLE" = "Reviewer" ] && [ -n "$SINGLE_VENDOR_LINE" ]; then
            echo ""
            echo "## Review Independence"
            echo "$SINGLE_VENDOR_LINE"
            echo "Take this turn with handoff.ps1 review-run, then handoff.ps1 review-apply. A verdict written by hand in this window is refused by commit-check, commit-approved and release-check."
        fi
        if [ -n "$AFTER_LINE" ];  then echo ""; echo "## After You Finish"; echo "$AFTER_LINE"; fi
    } > "$nt_path"

    echo ""
    echo "NEXT_TURN.md written."
    echo "Paste to $ACTOR_TOOL: Read NEXT_TURN.md, then read AI_HANDOFF.md, and continue according to the handoff state."
    echo ""
fi

echo ""
