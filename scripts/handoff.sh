#!/usr/bin/env bash
# handoff.sh - Codex-Claude Handoff operator (Bash version, v3.18.0)
# Commands: status, adapters, setup, next, start, commit-check
# commit-approved, cycle, run-next, loop, release-check, release, sequence-check, sequence-advance,
# review-check, review-run, review-apply, master-check, master-run, and master-apply require
# PowerShell; use handoff.ps1.

set -euo pipefail

# v3.18.0 (review fix): every reader here works byte by byte, so a UTF-8 locale on another
# machine cannot change what awk, grep, tr or sed match. This also gives the child git
# processes the C locale; only their porcelain output is parsed, never their messages.
export LC_ALL=C

COMMAND="${1:-}"
CLIP=false
REQUEST=""
PLAYERS=""
PLAYERS_SET=false
MASTER_ARG=""
YES=false
ARG_ERROR=""
[ $# -gt 0 ] && shift  # consume COMMAND
if [ "$COMMAND" = "setup" ]; then
    # v3.18.0: setup takes values, so its options are parsed strictly. Every other command
    # keeps the old rule: options are ignored and the first bare word is the request.
    while [ $# -gt 0 ]; do
        case "$1" in
            --players|-Players)
                if [ $# -lt 2 ]; then ARG_ERROR="$1 needs a value: $1 \"<Claude Code, Codex, or both>\""; break; fi
                PLAYERS="$2"; PLAYERS_SET=true; shift ;;
            --players=*) PLAYERS="${1#--players=}"; PLAYERS_SET=true ;;
            --master|-Master)
                if [ $# -lt 2 ]; then ARG_ERROR="$1 needs a value: $1 \"<one of the players>\""; break; fi
                MASTER_ARG="$2"; shift ;;
            --master=*) MASTER_ARG="${1#--master=}" ;;
            --yes|-y|-Yes) YES=true ;;
            *) ARG_ERROR="unknown setup option '$1'. setup takes --players, --master and --yes."; break ;;
        esac
        shift
    done
else
    for _arg in "$@"; do
        case "$_arg" in
            -c|--clip) CLIP=true ;;
            -*)        ;;
            *)         [ -z "$REQUEST" ] && REQUEST="$_arg" ;;
        esac
    done
    unset _arg
fi

HANDOFF_FILE="$(pwd)/AI_HANDOFF.md"
if [ ! -f "$HANDOFF_FILE" ]; then
    echo "No AI_HANDOFF.md found. Run from your project root."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# v3.18.0 (review fix): characters handoff.sh cannot read the way handoff.ps1 reads them.
# handoff.ps1 reads AI_HANDOFF.md and the role file with Get-Content -Encoding UTF8, as .NET
# strings: a lone CR ends a line there, .NET regex \s and Trim() take Unicode whitespace,
# and its case-insensitive -eq / -match fold a few non-ASCII letters to ASCII. awk does
# none of that, so instead of guessing, commit-check and setup refuse a file that contains
# one of these, and point to handoff.ps1. This is the one list; each group says why it is in.
# Prints "<line>|<U+XXXX>" for the first such character, or nothing. Byte-wise (od), so it
# sees NUL and lone CRs, and no locale can change it.
_first_unreadable_char() {
    od -An -v -tu1 "$1" | awk '
        function hit(cp) { if (!found) { found = 1; printf "%d|U+%04X", line, cp } }
        function check(cp) {
            # Unicode whitespace: .NET Char.IsWhiteSpace and regex \s accept these; awk does not.
            # U+180E was whitespace in older .NET Unicode tables; it is listed either way.
            if (cp == 133 || cp == 160 || cp == 5760 || cp == 6158 || (cp >= 8192 && cp <= 8202) || cp == 8232 || cp == 8233 || cp == 8239 || cp == 8287 || cp == 12288) { hit(cp); return }
            # Zero-width: U+200B everywhere, U+FEFF anywhere but as the BOM at the start of the
            # file (.NET Trim() removes U+FEFF; a mid-file one is kept as a character).
            if (cp == 65279 && cpstart == 1) return
            if (cp == 8203 || cp == 65279) { hit(cp); return }
            # Letters .NET case-insensitive comparison can fold to ASCII: Kelvin sign (k),
            # long s (s), dotted capital I and dotless i (i).
            if (cp == 8490 || cp == 383 || cp == 304 || cp == 305) { hit(cp); return }
        }
        BEGIN { line = 1; pos = 0; need = 0 }
        {
            for (i = 1; i <= NF; i++) {
                b = $i + 0; pos++
                if (pendcr) { pendcr = 0; if (b != 10) hit(13) }
                if (need > 0) {
                    if (b >= 128 && b < 192) { cp = cp * 64 + (b - 128); need--; if (need == 0) check(cp); continue }
                    need = 0
                }
                if (b == 10) { line++; continue }
                if (b == 13) { pendcr = 1; continue }
                # C0 controls but TAB, LF and the CR of a CRLF; DEL; NUL. .NET Trim() removes some
                # of them (NUL, VT, FF), so awk and .NET disagree on where a value ends.
                if (b < 32 && b != 9) { hit(b); continue }
                if (b == 127) { hit(b); continue }
                if (b < 128) continue
                # A UTF-8 lead byte; cpstart remembers where, so a BOM at byte 1 is allowed.
                if (b >= 194 && b <= 223) { cp = b - 192; need = 1; cpstart = pos; continue }
                if (b >= 224 && b <= 239) { cp = b - 224; need = 2; cpstart = pos; continue }
                if (b >= 240 && b <= 244) { cp = b - 240; need = 3; cpstart = pos; continue }
                # An invalid byte: handoff.ps1 reads it as U+FFFD, which no reader treats as a
                # space or a letter, so both shells agree on it.
            }
        }
        END { if (pendcr) hit(13) }'
}

# commit-check and setup refuse, before anything else is read, a file that carries one of
# the characters above. Other commands (status, next, start, adapters) only route, and run.
_unreadable_guard() {
    local rel hit line cp
    for rel in AI_HANDOFF.md .ai/roles/ROLE_ASSIGNMENT.md; do
        [ -f "$(pwd)/$rel" ] || continue
        hit="$(_first_unreadable_char "$(pwd)/$rel")"
        [ -n "$hit" ] || continue
        line="${hit%%|*}"; cp="${hit#*|}"
        echo ""
        if [ "$COMMAND" = "setup" ]; then echo "setup: blocked."; else echo "Commit: BLOCKED - handoff.sh cannot verify this file."; fi
        echo "Reason:      $rel line $line contains $cp, a character handoff.sh does not read the way"
        echo "             handoff.ps1 does (a Unicode space, a control character, a lone CR, a zero-width"
        echo "             character, or a letter .NET folds to ASCII). handoff.sh cannot verify this file."
        echo "Either:      run pwsh scripts/handoff.ps1 $COMMAND, which is the authority,"
        echo "Or:          remove the character from $rel and run this again."
        echo "Nothing was changed."
        echo ""
        exit 1
    done
}

# Print lines from a named ## section; CRLF-safe.
# v3.18.0 (review fix): a line-by-line port of handoff.ps1's Get-SectionLines:
#   foreach line:
#     if line.TrimEnd() -eq "## <Heading>" (without regard to case): in section; next line
#     elseif in section: a line matching ^##\s ends the reading for good; else the line is kept
# So a repeated heading, adjacent or not, is skipped and reading goes on; any other "##"
# heading ends the section, and nothing after it is read, even a later repeat of the heading;
# a "###" line is content. Get-Content drops a UTF-8 BOM and the CR of a CRLF; so does this.
# After the section closes the reader still goes on to the end, printing nothing: an early
# awk "exit" let tr die of SIGPIPE on a large file, and pipefail then ended the script with
# exit 141 and no output.
_section_content() {
    local h; h="$(printf '## %s' "$1" | tr '[:upper:]' '[:lower:]')"
    tr -d '\r' < "$HANDOFF_FILE" | \
    awk -v h="$h" -v bom="$(printf '\357\273\277')" '
        done { next }
        { l = $0; if (NR == 1 && index(l, bom) == 1) l = substr(l, length(bom) + 1); t = l; sub(/[[:space:]]+$/, "", t) }
        tolower(t) == h { s = 1; next }
        s { if (l ~ /^##[[:space:]]/) { done = 1; next } print l }'
}

# One Status field, read as handoff.ps1's Read-HandoffState reads it: '^- <Key>:\s*(.+)'
# without regard to case, the value trimmed, the last matching line winning.
_status_field() {
    printf '%s\n' "$1" | awk -v k="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '
        { low = tolower($0) }
        index(low, "- " k ":") == 1 && length($0) > length(k) + 3 { v = substr($0, length(k) + 4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); val = v; found = 1 }
        END { if (found) printf "%s", val; else exit 1 }'
}

_parse_status() {
    STATE="(unknown)" WAITING_FOR="(unknown)" CURRENT_TASK="(unknown)" MODEL_PROFILE="auto"
    # v3.18.0 (review fix): the exact "- State: " prefix was read here, so a later
    # "- state: IMPLEMENTING" that handoff.ps1 reads was invisible to Bash.
    local status v
    status="$(_section_content "Status")"
    if v="$(_status_field "$status" "State")"; then STATE="$v"; fi
    if v="$(_status_field "$status" "Waiting For")"; then WAITING_FOR="$v"; fi
    if v="$(_status_field "$status" "Current Task")"; then CURRENT_TASK="$v"; fi
    if v="$(_status_field "$status" "Model Profile")"; then MODEL_PROFILE="$v"; fi
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
    # v3.18.0 (review fix): the role name is matched without regard to case, as
    # handoff.ps1 matches it; "| implementer | Codex |" was skipped here before.
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

# v3.17.0: the review rule from ROLE_ASSIGNMENT.md, read the way handoff.ps1 reads it. An
# absent line is separate-tool; two lines or any other value leave the strict rule in force
# and set REVIEW_INDEPENDENCE_ERROR, which blocks at the role checkpoint.
# v3.18.0: one reader for the 'Review Independence:' and 'Setup:' lines, as in handoff.ps1:
# a BOM on line 1 and a non-breaking space are ignored, an optional bullet is allowed, and
# the key (given here in lower case) and the value are read without regard to case. Prints
# every value as <value>, one per line, so a caller refuses a duplicate instead of choosing.
_role_file_values() {
    local rf="$(pwd)/.ai/roles/ROLE_ASSIGNMENT.md"
    [ -f "$rf" ] || return 0
    tr -d '\r' < "$rf" | awk -v key="$1" -v bom="$(printf '\357\273\277')" -v nbsp="$(printf '\302\240')" '{ l = $0; if (NR == 1 && index(l, bom) == 1) l = substr(l, length(bom) + 1); gsub(nbsp, " ", l) } tolower(l) ~ ("^[[:space:]]*([-*][[:space:]]+)?" key "[[:space:]]*:") { v = l; sub(/^[^:]*:/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print "<" v ">" }'
}

_get_review_independence() {
    REVIEW_INDEPENDENCE="separate-tool" REVIEW_INDEPENDENCE_ERROR=""
    local rf="$(pwd)/.ai/roles/ROLE_ASSIGNMENT.md"
    [ -f "$rf" ] || return 0
    local count value raw lines
    # v3.17.0 (review fix): key and value are read without regard to case, as handoff.ps1
    # reads them; a mis-cased line is never mistaken for an absent one.
    lines="$(_role_file_values "review independence")"
    count="$(printf '%s' "$lines" | grep -c '^<' || true)"
    [ "$count" -eq 0 ] && return 0
    if [ "$count" -gt 1 ]; then
        REVIEW_INDEPENDENCE_ERROR="ROLE_ASSIGNMENT.md declares 'Review Independence:' $count times. Keep exactly one line: 'Review Independence: separate-tool' or 'Review Independence: fresh-context'."
        return 0
    fi
    raw="${lines#<}"; raw="${raw%>}"
    value="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        separate-tool|fresh-context) REVIEW_INDEPENDENCE="$value" ;;
        *) REVIEW_INDEPENDENCE_ERROR="ROLE_ASSIGNMENT.md declares 'Review Independence: $raw'. The value must be separate-tool or fresh-context." ;;
    esac
}

# v3.18.0: the Setup line, with handoff.ps1's meaning. No line = configured (SETUP_STATE
# empty); pending blocks every command but status and setup; anything else, or a
# second line, sets SETUP_ERROR, which blocks at the role checkpoint.
_get_setup_state() {
    SETUP_STATE="" SETUP_ERROR=""
    local count value raw lines
    lines="$(_role_file_values "setup")"
    count="$(printf '%s' "$lines" | grep -c '^<' || true)"
    [ "$count" -eq 0 ] && return 0
    if [ "$count" -gt 1 ]; then
        SETUP_ERROR="ROLE_ASSIGNMENT.md declares 'Setup:' $count times. Keep exactly one line, 'Setup: pending' or 'Setup: complete'."
        return 0
    fi
    raw="${lines#<}"; raw="${raw%>}"
    value="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        pending|complete) SETUP_STATE="$value" ;;
        *) SETUP_ERROR="ROLE_ASSIGNMENT.md declares 'Setup: $raw'. The value must be pending or complete." ;;
    esac
}

# Canonical tool identity, the same alias list as handoff.ps1's registry. v3.18.0: this is
# the only definition; a second copy further down was removed.
_canonical_tool() {
    local key; key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$key" in
        "codex"|"codex window"|"codex cli"|"codex desktop"|"openai codex") echo "codex" ;;
        "claude code"|"claude-code"|"claudecode"|"claude code cli"|"claude code window") echo "claude-code" ;;
        *) echo "" ;;
    esac
}

# A placeholder actor of a task that has not bound its actors yet; never a tool.
_is_sentinel_actor() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" in
        tbd|"(unknown)"|unknown) return 0 ;;
        *) return 1 ;;
    esac
}

_is_user_actor() {
    [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" = "user" ]
}

# The message handoff.ps1's registry gives for an identity it does not know.
_unknown_tool_reason() {
    echo "Unrecognized tool identity '$1'. Known tools: Codex, Claude Code. Add an explicit alias to the canonical registry rather than relying on a display name."
}

_display_tool() {
    case "$(_canonical_tool "$1")" in
        codex) echo "Codex" ;;
        claude-code) echo "Claude Code" ;;
        *) echo "$1" ;;
    esac
}

# True when fresh-context is declared and the two given tools are one tool.
_single_vendor_review() {
    [ -z "$REVIEW_INDEPENDENCE_ERROR" ] && [ "$REVIEW_INDEPENDENCE" = "fresh-context" ] || return 1
    local a b
    a="$(_canonical_tool "$1")"; b="$(_canonical_tool "$2")"
    [ -n "$a" ] && [ "$a" = "$b" ]
}

_single_vendor_line() {
    echo "Single-vendor review: $(_display_tool "$1") is both Implementer and Reviewer. It reviews in a separate read-only run started by the harness (review-run, then review-apply), never in the Implementer's context."
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
    # v3.17.0 (review fix): agree with commit-check, which refuses a single-vendor
    # REVIEW_DONE here and leaves the harness-verdict check to handoff.ps1.
    if [ "$STATE" = "REVIEW_DONE" ] && _single_vendor_review "$REVIEWER_TOOL" "$IMPLEMENTER_TOOL"; then
        echo "Blocked in handoff.sh - a single-vendor review is verified only by pwsh scripts/handoff.ps1 commit-check, which checks that the verdict came from review-run."
        return 0
    fi
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

    if [ "$role" = "Implementer" ]; then
        ADAPTER_CALLABLE="yes"
        ADAPTER_AUTOLOOP="yes"
        ADAPTER_STATES="READY_FOR_IMPLEMENTATION, NEEDS_INVESTIGATION"
        ADAPTER_INVOCATION="PowerShell only: handoff.ps1 cycle or handoff.ps1 loop invokes npx --yes @anthropic-ai/claude-code with Bash disallowed, a budget cap, and no session persistence."
        ADAPTER_SAFETY="Explicit yes confirmation in PowerShell; Reviewer != Implementer; clean tree except local handoff files; Bash disallowed; budget cap; no commit/push/tag/deploy/db/secrets automation."
        ADAPTER_AUTH="yes, before cycle or loop session"
        ADAPTER_REASON="READY_FOR_IMPLEMENTATION and read-only NEEDS_INVESTIGATION are automated; planning and question turns remain manual."
        ADAPTER_NEXT="Use pwsh scripts/handoff.ps1 cycle or loop for READY_FOR_IMPLEMENTATION; use bash scripts/handoff.sh next + paste for other turns."
    elif [ "$role" = "Master" ]; then
        # Callable in PowerShell only (since v2.0.1) via master-run + master-apply, and never
        # auto-run by loop/cycle. Bash itself never invokes Codex or applies a recommendation.
        ADAPTER_CALLABLE="yes (PowerShell only: master-run + master-apply)"
        ADAPTER_AUTOLOOP="no"
        ADAPTER_STATES="NEEDS_ANALYSIS"
        ADAPTER_INVOCATION="PowerShell only: pwsh scripts/handoff.ps1 master-run (capture) then pwsh scripts/handoff.ps1 master-apply (apply the captured recommendation's local AI_HANDOFF.md transition)."
        ADAPTER_SAFETY="Explicit yes per command; NEEDS_ANALYSIS only; bound Master holds the Master role; captured TASK must match Current Task; recommendation/Waiting For pair must be valid; non-BLOCKED routing must use the current bound Implementer and Reviewer and preserve Reviewer != Implementer; master-apply edits only AI_HANDOFF.md; not auto-run by loop/cycle; no commit/push/tag/deploy/db/secrets."
        ADAPTER_STOP="Operator Manual Action"
        ADAPTER_AUTH="yes, explicit yes before master-run and master-apply"
        ADAPTER_REASON="master-run + master-apply complete the Master's NEEDS_ANALYSIS routing turn end-to-end (PowerShell only); callable via these explicit commands only - never inside loop or cycle."
        ADAPTER_NEXT="Use pwsh scripts/handoff.ps1 master-run then master-apply; Bash cannot invoke Codex or apply the recommendation."
    elif [ "$role" = "Reviewer" ]; then
        # Callable in PowerShell only (since v1.3.0) via review-run + review-apply, and never
        # auto-run by loop/cycle (Auto-loop stays no). Bash itself never invokes Codex.
        ADAPTER_CALLABLE="yes (PowerShell only: review-run + review-apply)"
        ADAPTER_AUTOLOOP="no"
        ADAPTER_STATES="READY_FOR_REVIEW"
        ADAPTER_INVOCATION="PowerShell only: pwsh scripts/handoff.ps1 review-run (capture) then pwsh scripts/handoff.ps1 review-apply (apply the captured verdict's local AI_HANDOFF.md transition)."
        ADAPTER_SAFETY="Explicit yes per command; READY_FOR_REVIEW only; bound and actual Reviewer match and Reviewer != Implementer; Changed Files == git status; Codex read-only; review-apply edits only AI_HANDOFF.md; not auto-run by default; only PowerShell loop -IncludeReviewer may opt in; Bash/cycle never do; no commit/push/tag/deploy/db/secrets; no release action."
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
    echo "Model Profile: $MODEL_PROFILE"
    if [ "$SETUP_STATE" = "pending" ]; then
        # v3.18.0: the template's binding is not shown as if someone had chosen it.
        echo "Setup:        NOT CONFIGURED - this project has not chosen its players and its Master yet."
        echo "              Run:  bash scripts/handoff.sh setup --players \"<Claude Code, Codex, or both>\" --master \"<one of the players>\""
        echo "              An agent must ask the user which players and which Master; it never chooses for them."
        echo "Roles:       not chosen yet; work commands are blocked until setup is done."
    else
        echo "Roles:        Master=$MASTER_TOOL, Reviewer=$REVIEWER_TOOL, Implementer=$IMPLEMENTER_TOOL"
    fi
    if _single_vendor_review "$REVIEWER_TOOL" "$IMPLEMENTER_TOOL"; then
        echo "Review:       $(_single_vendor_line "$REVIEWER_TOOL")"
    fi
    [ "$SETUP_STATE" = "pending" ] || echo "Adapters:     run 'bash scripts/handoff.sh adapters' for callable/manual automation status"
    echo "Commit:       $(_commit_status_text)"
    [ -f "$(pwd)/.agents/skills/codex-claude-handoff/SKILL.md" ] && \
        echo "Protocol:     installed (canonical: .ai/skills/codex-claude-handoff/; roles: .ai/roles/ROLE_ASSIGNMENT.md)"
    _push_reminder
    echo ""
}

# v3.12.0: the protocol never pushes, so say how many local commits wait for the user's push.
# Compares with the local upstream ref only; no network command.
_push_reminder() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    [ -n "$(git remote 2>/dev/null)" ] || return 0
    local branch upstream ahead
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    { [ -z "$branch" ] || [ "$branch" = "HEAD" ]; } && return 0
    if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" && [ -n "$upstream" ]; then
        ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null)"
        [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null || return 0
        echo "Not pushed:   $ahead local commit(s) on $branch are not pushed to $upstream. Pushing is yours: git push"
    else
        ahead="$(git rev-list --count HEAD 2>/dev/null)"
        [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null || return 0
        echo "Not pushed:   Branch $branch has never been pushed ($ahead commit(s)). Pushing is yours: git push -u origin $branch"
    fi
    echo "              If this project deploys on push, the push also publishes. The count is from the last fetch."
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
    echo "Role/tool matrix (every combination, independent of today's binding)"
    echo "Permission is a property of the ROLE. The tool holding it does not change it."
    echo ""
    echo "  Role         Tool         Callable  Permission  Automated states"
    echo "  Master       Codex        yes       read-only   NEEDS_ANALYSIS"
    echo "  Master       Claude Code  yes       read-only   NEEDS_ANALYSIS"
    echo "  Implementer  Codex        yes       write       READY_FOR_IMPLEMENTATION, NEEDS_INVESTIGATION"
    echo "  Implementer  Claude Code  yes       write       READY_FOR_IMPLEMENTATION, NEEDS_INVESTIGATION"
    echo "  Reviewer     Codex        yes       read-only   READY_FOR_REVIEW"
    echo "  Reviewer     Claude Code  yes       read-only   READY_FOR_REVIEW"
    echo ""
    echo "Every turn above runs from PowerShell; Bash reports status and never invokes a tool."
    if [ -z "$REVIEW_INDEPENDENCE_ERROR" ] && [ "$REVIEW_INDEPENDENCE" = "fresh-context" ]; then
        echo "Swapping roles: handoff.ps1 roles -SetRole <role> -SetTool <tool>. Review Independence is fresh-context, so"
        echo "Reviewer and Implementer may be one tool; its verdict then counts only from review-run + review-apply."
    else
        echo "Swapping roles: edit .ai/roles/ROLE_ASSIGNMENT.md, keeping Reviewer != Implementer."
    fi
    echo ""
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

# v3.10.0: the model this turn should run on, resolved the same way as handoff.ps1:
# HANDOFF_<TOOL>_MODEL_<PROFILE>, then the profile's claudeModel/codexModel in
# MODEL_ROUTING.json, then inherit. handoff.ps1 models remains the full view.
# (_canonical_tool is defined once, near the top of this file.)

_effective_profile() {
    local p
    p="$(printf '%s' "$MODEL_PROFILE" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$p" in
        "") p="auto" ;;
        economical|cheap) p="economy" ;;
        readonly) p="cheap_readonly" ;;
        deep_reasoning|strongest_available) p="high_reasoning" ;;
    esac
    case "$p" in
        auto) if [ "$STATE" = "NEEDS_INVESTIGATION" ]; then echo "cheap_readonly"; else echo "standard"; fi ;;
        inherit|economy|cheap_readonly|standard|high_reasoning|explicit_user_choice) echo "$p" ;;
        *) echo "" ;;
    esac
}

# Prints the value of <key> inside the "<profile>": { ... } object of MODEL_ROUTING.json.
# Reads one key per line (the shipped layout and the models -Activate layout) or a
# single-line object.
_routing_value() {
    local file="$1" profile="$2" key="$3"
    [ -f "$file" ] || return 0
    # v3.18.0 (review fix): no early "exit" while tr is still writing: under pipefail a
    # SIGPIPE in tr would end the whole script. A done flag reads to the end instead.
    tr -d '\r' < "$file" | awk -v prof="$profile" -v key="$key" '
        done { next }
        {
            if (!inb) {
                opener = "\"" prof "\"[ \t]*:[ \t]*\\{"
                if (match($0, opener)) { inb = 1; rest = substr($0, RSTART + RLENGTH) } else { next }
            } else { rest = $0 }
            cut = index(rest, "}")
            seg = (cut > 0) ? substr(rest, 1, cut - 1) : rest
            pat = "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\""
            if (match(seg, pat)) {
                v = substr(seg, RSTART, RLENGTH)
                sub("^\"" key "\"[ \t]*:[ \t]*\"", "", v); sub("\"$", "", v)
                print v; done = 1; next
            }
            if (cut > 0) done = 1
        }'
}

# Sets TOOL_MODEL and TOOL_SOURCE for one tool: environment, then MODEL_ROUTING.json, then inherit.
_resolve_tool_model() {
    local env_prefix="$1" key="$2" profile="$3" file="$4" env_name env_value file_value
    TOOL_MODEL="inherit"; TOOL_SOURCE="built-in fallback"
    env_name="${env_prefix}$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')"
    env_value="${!env_name:-}"
    env_value="$(printf '%s' "$env_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$env_value" ]; then
        TOOL_MODEL="$env_value"; TOOL_SOURCE="environment $env_name"
    else
        file_value="$(_routing_value "$file" "$profile" "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [ -n "$file_value" ]; then TOOL_MODEL="$file_value"; TOOL_SOURCE="MODEL_ROUTING.json"; fi
    fi
    if [ "$TOOL_MODEL" = "default" ]; then TOOL_MODEL="inherit"; fi
}

_safe_model() {
    [ "$1" = "inherit" ] || printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/@-]*$'
}

# handoff.ps1 parses MODEL_ROUTING.json strictly and blocks on any error. Without a JSON
# parser this catches what can be checked by counting: the schema version, balanced
# braces and brackets, and an even number of quotes.
_routing_file_usable() {
    local file="$1" opens closes
    [ -f "$file" ] || return 0
    grep -Eq '"schemaVersion"[[:space:]]*:[[:space:]]*1([^0-9]|$)' "$file" || return 1
    opens="$(tr -cd '{' < "$file" | wc -c | tr -d ' ')"; closes="$(tr -cd '}' < "$file" | wc -c | tr -d ' ')"
    [ "$opens" = "$closes" ] || return 1
    opens="$(tr -cd '[' < "$file" | wc -c | tr -d ' ')"; closes="$(tr -cd ']' < "$file" | wc -c | tr -d ' ')"
    [ "$opens" = "$closes" ] || return 1
    [ $(( $(tr -cd '"' < "$file" | wc -c | tr -d ' ') % 2 )) -eq 0 ]
}

# The closed list handoff.ps1 uses for the Codex reasoning effort.
_safe_effort() {
    case "$1" in
        inherit|minimal|low|medium|high|xhigh) return 0 ;;
        *) return 1 ;;
    esac
}

_model_lines() {
    local canonical label profile file claude_model claude_source codex_model codex_source effort effort_source model source
    canonical="$(_canonical_tool "$1")"
    case "$canonical" in
        codex)       label="Codex model" ;;
        claude-code) label="Claude model" ;;
        *) return 0 ;;
    esac
    echo ""
    echo "## Model For This Turn"
    file="$(pwd)/.ai/skills/codex-claude-handoff/MODEL_ROUTING.json"
    profile="$(_effective_profile)"
    if [ -z "$profile" ] || ! _routing_file_usable "$file"; then
        echo "Model routing is BLOCKED - run handoff.ps1 models before this turn."
        return 0
    fi
    # Both tools are resolved and checked, as handoff.ps1 does: one unsafe value blocks the turn.
    _resolve_tool_model "HANDOFF_CLAUDE_MODEL_" "claudeModel" "$profile" "$file"
    claude_model="$TOOL_MODEL"; claude_source="$TOOL_SOURCE"
    _resolve_tool_model "HANDOFF_CODEX_MODEL_" "codexModel" "$profile" "$file"
    codex_model="$TOOL_MODEL"; codex_source="$TOOL_SOURCE"
    # v3.16.0: the Codex reasoning effort follows the same profile and the same order.
    _resolve_tool_model "HANDOFF_CODEX_EFFORT_" "codexEffort" "$profile" "$file"
    effort="$(printf '%s' "$TOOL_MODEL" | tr '[:upper:]' '[:lower:]')"; effort_source="$TOOL_SOURCE"
    if [ "$effort" = "default" ]; then effort="inherit"; fi
    if ! _safe_model "$claude_model" || ! _safe_model "$codex_model" || ! _safe_effort "$effort"; then
        echo "Model routing is BLOCKED - run handoff.ps1 models before this turn."
        return 0
    fi
    if [ "$canonical" = "codex" ]; then
        model="$codex_model"; source="$codex_source"
    else
        model="$claude_model"; source="$claude_source"
    fi
    echo "Profile: $profile"
    echo "$label: $model ($source)"
    if [ "$canonical" = "codex" ] && [ "$effort" != "inherit" ]; then
        echo "Codex reasoning effort: $effort ($effort_source)"
    fi
    if [ "$model" = "inherit" ]; then
        echo "No model is mapped for this profile: keep the model your window already uses."
    else
        echo "If your open window runs a different model, start a new window on this one instead of switching inside the conversation. A switch resends the whole conversation to the new model without its cache; a new window loses nothing, because the state is in AI_HANDOFF.md and this file."
    fi
    echo "One window, one protocol turn: from an agent window, cycle, loop, review-run and master-run start in the background and return at once. End your turn then; do not check on the run. Open a new window for the next task."
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

    # v3.8.0: a line-numbered map of AI_HANDOFF.md, so the next actor reads the sections its
    # turn needs instead of the whole file. Same format as handoff.ps1.
    local section_map
    section_map=$(tr -d '\r' < "$HANDOFF_FILE" | awk '/^## /{sub(/[ \t]+$/, ""); print "- line " NR ": " $0}')

    {   echo "# Next Turn Entry Brief"
        echo "Generated: $timestamp"
        echo "Actor: $actor ($role_label)"
        echo "State: $STATE"
        echo "Current Task: $CURRENT_TASK"
        echo ""
        echo "NOTE: This file is a convenience summary. Read the AI_HANDOFF.md sections this turn needs (see the section map below) before acting."
        echo ""
        echo "## Your Action This Turn"
        echo "$action_line"
        echo ""
        echo "## Next Recommended Step (from AI_HANDOFF.md)"
        if [ -n "$next_step" ]; then echo "$next_step"; else echo "(none - see AI_HANDOFF.md)"; fi
        if [ -n "$key_context" ]; then echo ""; echo "## Key Context"; echo "$key_context"; fi
        # v3.17.0: same section as handoff.ps1 writes for a single-vendor Reviewer turn.
        if ! $is_mismatch && [ "$exp_role" = "Reviewer" ] && _single_vendor_review "$REVIEWER_TOOL" "$IMPLEMENTER_TOOL"; then
            echo ""
            echo "## Review Independence"
            _single_vendor_line "$REVIEWER_TOOL"
            echo "Take this turn with handoff.ps1 review-run, then handoff.ps1 review-apply. A verdict written by hand in this window is refused by commit-check, commit-approved and release-check."
        fi
        if ! $is_mismatch && [ "$actor" != "User" ]; then _model_lines "$actor"; fi
        if [ -n "$section_map" ]; then echo ""; echo "## AI_HANDOFF.md Sections (line numbers)"; echo "$section_map"; fi
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
Read .agents/skills/codex-claude-handoff/SKILL.md as local protocol instructions, and follow the Context Budget in MASTER.md: look protocol rules up by section instead of reading protocol documents in full, and delegate repository investigation to the Implementer.
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

_warn_credential_paths() {
    local risky=() f
    for f in .mcp.json .codex/config.toml .env; do
        git ls-files --error-unmatch "$f" >/dev/null 2>&1 && risky+=("$f")
    done
    [ ${#risky[@]} -eq 0 ] && return 0
    echo "WARNING: these tracked files normally hold API keys or access tokens:"
    for f in "${risky[@]}"; do echo "  $f"; done
    echo "Git keeps every version, so editing one later does not remove the value."
    echo "Add them to .gitignore and run: git rm --cached <path>"
    echo ""
}

cmd_commit_check() {
    echo ""
    # v3.6.0: warn before the operator commits an agent credential file. This is the
    # only Bash command that inspects what is about to be committed, and a bulk
    # "git add -A" to clear a protocol stop is exactly how a live token reaches
    # history. Name-based only: Bash does not read file contents here.
    _warn_credential_paths
    if [ "$STATE" = "REVIEW_DONE" ] && [ "$WAITING_FOR" = "User" ] && _single_vendor_review "$REVIEWER_TOOL" "$IMPLEMENTER_TOOL"; then
        # v3.17.0: a single-vendor verdict counts only when the harness produced it, and that
        # is verified by the PowerShell commit check, which reads the harness evidence.
        _single_vendor_line "$REVIEWER_TOOL"
        echo "Commit: BLOCKED in handoff.sh - a single-vendor review is verified only by pwsh scripts/handoff.ps1 commit-check, which checks that the verdict came from review-run."
        echo "Stop category: Environment/Preflight (tool unavailable) - not a user decision."
        echo ""
        # v3.18.0 (review fix): a blocked commit-check exits non-zero, as handoff.ps1 does.
        exit 1
    fi
    if [ "$STATE" = "REVIEW_DONE" ] && [ "$WAITING_FOR" = "User" ]; then
        # v3.18.0 (review fix): the commit audit of handoff.ps1's Get-CommitPlan, on the lines
        # Get-TaskActors reads ("-" bullets only): exactly one distinct Implementer and one
        # distinct Reviewer, and the Reviewer is not the Implementer's tool under
        # separate-tool. Under fresh-context one tool in both is a single-vendor review,
        # which only handoff.ps1 can verify.
        local audit_role audit audit_count audit_failed=false audit_impl="" audit_rev=""
        for audit_role in Implementer Reviewer; do
            audit="$(_task_actor_audit "$audit_role")"
            audit_count="${audit%%|*}"
            if [ "$audit_count" != "1" ]; then
                echo "Commit: BLOCKED - AI_HANDOFF.md must include exactly one Task Actors $audit_role for commit audit (found $audit_count)."
                audit_failed=true
            fi
            if [ "$audit_role" = "Implementer" ]; then audit_impl="${audit#*|}"; else audit_rev="${audit#*|}"; fi
        done
        if ! $audit_failed && [ -n "$(_canonical_tool "$audit_rev")" ] && [ "$(_canonical_tool "$audit_rev")" = "$(_canonical_tool "$audit_impl")" ]; then
            if _fresh_context_active; then
                _single_vendor_line "$audit_rev"
                echo "Commit: BLOCKED in handoff.sh - a single-vendor review is verified only by pwsh scripts/handoff.ps1 commit-check, which checks that the verdict came from review-run."
            else
                echo "Commit: BLOCKED - commit audit invariant violation: actual Reviewer must not equal actual Implementer ('$audit_rev' / '$audit_impl')."
            fi
            audit_failed=true
        fi
        if $audit_failed; then
            echo "No commit is authorized while who implemented and who reviewed is unclear."
            echo ""
            exit 1
        fi
        local LOCAL_IGNORED="AI_HANDOFF.md NEXT_TURN.md USER_REQUEST.md HANDOFF_LOOP.log AI_SEQUENCE.md HANDOFF_RUN.json REVIEW.jsonl REVIEW_LAST.md MASTER.jsonl MASTER_LAST.md IMPLEMENTER.jsonl IMPLEMENTER_LAST.md IMPLEMENTER_COMMAND.md CODEX_REVIEW.jsonl CODEX_REVIEW_LAST.md CODEX_MASTER.jsonl CODEX_MASTER_LAST.md CLAUDE_IMPLEMENTER.jsonl CLAUDE_IMPLEMENTER_LAST.md CLAUDE_IMPLEMENTER_COMMAND.md .ai/roles/ROLE_ASSIGNMENT.md"
        local commit_files=() actual_files=()
        local line entry in_cf=false
        local status_suffix_re='^(.*[^[:space:]])[[:space:]]+\((new|new file|added|modified|updated|changed|deleted|removed|renamed)\)$'

        while IFS= read -r line; do
            [ "$line" = "## Changed Files" ] && { in_cf=true; continue; }
            $in_cf || continue
            case "$line" in "## "*) break ;; esac
            case "$line" in
                "- "*)
                    entry="${line#- }"
                    if [[ "$entry" == \`*\`* ]]; then
                        # v3.10.1: "- `path` (a note)" - the path is what the backticks hold.
                        entry="${entry#\`}"
                        entry="${entry%%\`*}"
                    else
                        entry="${entry//\`/}"
                        entry="${entry%% - *}"
                    fi
                    entry="${entry#"${entry%%[! ]*}"}"
                    entry="${entry%"${entry##*[! ]}"}"
                    # v3.10.1: a trailing status such as "(new)" describes the change, not the path.
                    shopt -s nocasematch
                    if [[ "$entry" =~ $status_suffix_re ]]; then entry="${BASH_REMATCH[1]}"; fi
                    shopt -u nocasematch
                    if [ -n "$entry" ] && [ "$entry" != "None yet" ]; then
                        case " $LOCAL_IGNORED " in
                            *" $entry "*) ;;
                            *) commit_files+=("$entry") ;;
                        esac
                    fi
                    ;;
            esac
        done < <(tr -d '\r' < "$HANDOFF_FILE")

        # v3.4.1: read Git's NUL-delimited porcelain instead of --short.
        #
        # With the default core.quotePath, --short QUOTES and octal-escapes any path
        # containing non-ASCII characters or spaces, so the parsed value could never
        # equal a path written by hand under Changed Files and the exact-scope check
        # failed closed on every such repository.
        #
        # Command substitution cannot carry NUL bytes, so the -z stream is written to a
        # temporary file and consumed with `read -d ''`. A process substitution would be
        # shorter, but it discards Git's exit status: Git can emit a partial record set
        # and THEN fail, and the parser would accept that truncated set as the exact
        # scope. Staging the stream lets the exit status be checked before a single
        # field is trusted, so a failed status blocks instead of approving a subset.
        #
        # For a rename or copy the SOURCE path follows as its own field and must be
        # discarded, or the pre-rename path is counted as an extra changed file. The old
        # " -> " split is meaningless under -z.
        #
        # Paths are used exactly as Git spells them - forward slashes, no normalization.
        local gl fp xy gtmp
        gtmp=$(mktemp 2>/dev/null) || gtmp=""
        if [ -z "$gtmp" ]; then
            echo "Commit: BLOCKED - could not stage git status output for verification."
            echo "Exact scope cannot be verified, so no commit is authorized."
            echo ""
            exit 1
        fi
        if ! git status --porcelain=v1 -z --untracked-files=all >"$gtmp" 2>/dev/null; then
            rm -f "$gtmp"
            echo "Commit: BLOCKED - git status failed; exact scope cannot be verified."
            echo "No commit is authorized while the changed-file set is unknown."
            echo ""
            exit 1
        fi
        while IFS= read -r -d '' gl; do
            [ ${#gl} -lt 4 ] && continue
            xy="${gl:0:2}"
            fp="${gl:3}"
            case "$xy" in
                R?|C?|?R|?C) IFS= read -r -d '' _ || true ;;
            esac
            [ -z "$fp" ] && continue
            case " $LOCAL_IGNORED " in
                *" $fp "*) ;;
                *) actual_files+=("$fp") ;;
            esac
        done < "$gtmp"
        rm -f "$gtmp"

        if [ ${#actual_files[@]} -eq 0 ]; then
            echo "Commit: No tracked changes to commit."
            echo "Working tree is clean."
            echo ""
            exit 1
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
        echo ""
        # v3.18.0 (review fix): not allowed is a non-zero exit, as in handoff.ps1.
        exit 1
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

# v3.18.0 (review fix): the one Task Actors reader. Every Bash function that looks at Task
# Actors goes through it. It prints one "<role>|<bullet>|<value>" line per Task Actors line,
# parsed as handoff.ps1 parses them: the line trimmed, a "-" or "*" bullet, optional spaces,
# the key without regard to case, at least one character after the colon, the value trimmed.
# handoff.ps1 itself reads those lines in two ways, and Bash keeps both, so it refuses
# whenever either PowerShell path refuses:
#   Test-RoleCheckpoint: '^[-*]\s*Implementer:\s*(.+)$', the last match wins  -> _task_actor
#   Get-TaskActors (commit audit): '^-\s*Implementer:\s*(.+)$', "-" only, distinct values
#     without regard to case, exactly one required                             -> _task_actor_audit
_task_actor_entries() {
    _section_content "Task Actors" | awk '
        { l = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", l); low = tolower(l) }
        low ~ /^[-*][[:space:]]*(implementer|reviewer):[[:space:]]*[^[:space:]]/ {
            b = substr(l, 1, 1); r = low; sub(/^[-*][[:space:]]*/, "", r); sub(/:.*/, "", r)
            v = l; sub(/^[^:]*:/, "", v); gsub(/^[[:space:]]+/, "", v)
            print r "|" b "|" v
        }'
}

_task_actor() {
    # _task_actor <Implementer|Reviewer> -> the value the checkpoint reads ("-" or "*", last wins).
    local wanted; wanted="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    _task_actor_entries | awk -F'|' -v w="$wanted" '$1 == w { v = substr($0, length($1) + length($2) + 3) } END { printf "%s", v }'
}

_task_actor_audit() {
    # _task_actor_audit <Implementer|Reviewer> -> "<count>|<value>" as the commit audit reads it:
    # "-" lines only, distinct values without regard to case, the first one as the value.
    local wanted; wanted="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    _task_actor_entries | awk -F'|' -v w="$wanted" '
        $1 == w && $2 == "-" { v = substr($0, length($1) + length($2) + 3); k = tolower(v); if (!(k in seen)) { seen[k] = 1; n++; if (n == 1) first = v } }
        END { printf "%d|%s", n, first }'
}

_fresh_context_active() {
    [ -z "$REVIEW_INDEPENDENCE_ERROR" ] && [ "$REVIEW_INDEPENDENCE" = "fresh-context" ]
}

# v3.18.0 (security scan fix): the checkpoint compares canonical identities and rejects an
# unknown one, as handoff.ps1's Test-RoleCheckpoint does. Before this, an unrecognized name
# that was identical for Reviewer and Implementer passed under fresh-context: raw strings
# matched, _single_vendor_review answered "not single vendor", and commit-check said ALLOWED.
CHECKPOINT_ERRORS=""
CHECKPOINT_COUNT=0
CHECKPOINT_SETUP_ERRORS=0
_checkpoint_add() {
    CHECKPOINT_ERRORS="${CHECKPOINT_ERRORS}${CHECKPOINT_ERRORS:+$'\n'}$1"
    CHECKPOINT_COUNT=$((CHECKPOINT_COUNT + 1))
}

_role_checkpoint() {
    local implementer reviewer role bound actual canonical_bound canonical_actual
    implementer="$(_task_actor Implementer)"
    reviewer="$(_task_actor Reviewer)"
    CHECKPOINT_ERRORS="" CHECKPOINT_COUNT=0 CHECKPOINT_SETUP_ERRORS=0
    for role in Implementer Reviewer Master; do
        case "$role" in
            Implementer) bound="$IMPLEMENTER_TOOL" ;;
            Reviewer)    bound="$REVIEWER_TOOL" ;;
            Master)      bound="$MASTER_TOOL" ;;
        esac
        if [ -z "$(_canonical_tool "$bound")" ] && ! _is_sentinel_actor "$bound" && ! _is_user_actor "$bound"; then
            _checkpoint_add "Invalid role binding: $role='$bound'. $(_unknown_tool_reason "$bound")"
        fi
    done
    # v3.17.0: an unreadable review rule blocks; fresh-context lets one tool hold both roles.
    [ -n "$REVIEW_INDEPENDENCE_ERROR" ] && _checkpoint_add "Invalid review independence: $REVIEW_INDEPENDENCE_ERROR"
    # v3.18.0: an unreadable Setup line is never read as configured or as pending.
    if [ -n "$SETUP_ERROR" ]; then
        _checkpoint_add "Invalid setup line: $SETUP_ERROR"
        CHECKPOINT_SETUP_ERRORS=1
    fi
    if [ -n "$(_canonical_tool "$REVIEWER_TOOL")" ] && [ "$(_canonical_tool "$REVIEWER_TOOL")" = "$(_canonical_tool "$IMPLEMENTER_TOOL")" ] && ! _fresh_context_active; then
        _checkpoint_add "Invalid role binding: Reviewer and Implementer both resolve to the same tool ('$REVIEWER_TOOL' / '$IMPLEMENTER_TOOL'). An implementer cannot be the sole reviewer of its own work."
    fi
    for role in Implementer Reviewer; do
        if [ "$role" = "Implementer" ]; then actual="$implementer"; bound="$IMPLEMENTER_TOOL"; else actual="$reviewer"; bound="$REVIEWER_TOOL"; fi
        [ -n "$actual" ] || continue
        _is_sentinel_actor "$actual" && continue
        canonical_actual="$(_canonical_tool "$actual")"
        if [ -z "$canonical_actual" ] && ! _is_user_actor "$actual"; then
            _checkpoint_add "Unrecognized Task Actors $role='$actual'. $(_unknown_tool_reason "$actual")"
            continue
        fi
        canonical_bound="$(_canonical_tool "$bound")"
        # Canonical identity, not display text: 'Codex Window' is the bound 'Codex', not drift.
        if [ -z "$canonical_actual" ] || [ "$canonical_actual" != "$canonical_bound" ]; then
            _checkpoint_add "Role drift: AI_HANDOFF.md Task Actors $role='$actual' but ROLE_ASSIGNMENT.md binds $role='$bound'."
        fi
    done
    if [ -n "$(_canonical_tool "$implementer")" ] && [ "$(_canonical_tool "$implementer")" = "$(_canonical_tool "$reviewer")" ] && ! _fresh_context_active; then
        _checkpoint_add "Independent-review invariant: Task Actors Implementer='$implementer' and Reviewer='$reviewer' resolve to the same tool."
    fi
    [ -n "$CHECKPOINT_ERRORS" ] || return 0
    [ "$COMMAND" = "status" ] && return 0
    [ "$COMMAND" = "adapters" ] && return 0
    # In the pending state setup rewrites the binding wholesale; a broken Setup line that is
    # the only problem is repaired by setup and by nothing else.
    if [ "$COMMAND" = "setup" ]; then
        [ "$SETUP_STATE" = "pending" ] && return 0
        [ "$CHECKPOINT_SETUP_ERRORS" -gt 0 ] && [ "$CHECKPOINT_COUNT" -eq "$CHECKPOINT_SETUP_ERRORS" ] && return 0
    fi
    echo ""
    echo "Role checkpoint: BLOCKED - the current role binding and AI_HANDOFF.md are out of sync."
    printf 'Reason: %s\n' "$CHECKPOINT_ERRORS"
    echo "Repair: synchronize derived Task Actors in AI_HANDOFF.md with .ai/roles/ROLE_ASSIGNMENT.md, then run the command again."
    if [ -n "$SETUP_ERROR" ]; then
        echo "The 'Setup:' line must appear once and read pending or complete. setup repairs it when it is the only problem:"
        echo "  bash scripts/handoff.sh setup --players \"<Claude Code, Codex, or both>\" --master \"<one of the players>\""
        echo "An agent must ask the user which players and which Master; it never chooses for them."
    fi
    echo "No role-dependent action was performed."
    exit 12
}

# v3.18.0: until the players and the Master are chosen, nothing runs on a binding nobody chose.
_setup_gate() {
    [ "$SETUP_STATE" = "pending" ] || return 0
    # v3.18.0 (review fix): adapters too, as in handoff.ps1: it would show the template binding.
    case "$COMMAND" in status|setup) return 0 ;; esac
    echo ""
    echo "Setup required: this project has not chosen its players and its Master yet."
    echo "Run:  bash scripts/handoff.sh setup --players \"<Claude Code, Codex, or both>\" --master \"<one of the players>\""
    echo "      (with PowerShell, .\\scripts\\handoff.ps1 setup can open a window)"
    echo "An agent must ask the user which players and which Master; it never chooses for them."
    echo "Nothing was started and nothing was changed."
    echo ""
    exit 14
}

_setup_blocked() {
    echo ""
    echo "setup: blocked."
    printf 'Reason:      %s\n' "$@"
    echo "Nothing was changed."
    echo ""
    exit 1
}

# A real write test: permissions on Windows are ACLs, which [ -w ] does not read reliably.
_setup_probe_dir() {
    local probe="$1/.handoff-setup-probe-$$"
    if ( : > "$probe" ) 2>/dev/null; then rm -f "$probe"; return 0; fi
    return 1
}

# Every move setup makes goes through here. HANDOFF_TEST_SETUP_FAIL is a TEST-ONLY seam, used
# by protocol-tests to reach the failure paths deterministically. It can only make setup
# fail, never pass. A comma list of:
#   role       the move of the new role file fails (nothing has changed yet)
#   handoff    the move of the new AI_HANDOFF.md fails (the role file is then restored)
#   restore    putting the original role file back fails; only has an effect together with
#              handoff or interrupt, since a restore happens only then - alone it is a no-op
#   interrupt  setup sends itself TERM between the two moves
_setup_mv() {
    case ",${HANDOFF_TEST_SETUP_FAIL:-}," in *",$1,"*) return 1 ;; esac
    mv -f "$2" "$3" 2>/dev/null
}

SETUP_TMP_FILES=()
SETUP_PHASE=""
SETUP_RF=""
SETUP_ORIG=""
_setup_cleanup() {
    local f
    [ ${#SETUP_TMP_FILES[@]} -gt 0 ] || return 0
    for f in "${SETUP_TMP_FILES[@]}"; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done
    return 0
}

# Called with the role file already replaced and AI_HANDOFF.md not. Puts the original back;
# if even that fails, keeps the saved original and says exactly how to restore it.
_setup_restore_or_report() {
    if _setup_mv restore "$SETUP_ORIG" "$SETUP_RF"; then
        SETUP_PHASE="restored"
        _setup_blocked "$1, so the role file was restored; run setup again."
    fi
    # The saved original is now the only copy: keep it out of the cleanup.
    local kept=() f
    for f in "${SETUP_TMP_FILES[@]}"; do [ "$f" = "$SETUP_ORIG" ] || kept+=("$f"); done
    SETUP_TMP_FILES=("${kept[@]}")
    local rel_orig="${SETUP_ORIG#"$(pwd)"/}"
    echo ""
    echo "setup: FAILED part-way."
    echo "Reason:      $1, and putting the original role file back failed too."
    echo "Now:         .ai/roles/ROLE_ASSIGNMENT.md may already be the new one while AI_HANDOFF.md is still the old one,"
    echo "             so the next command can stop on role drift."
    echo "Saved:       the original role file is $rel_orig (ignored by Git)."
    echo "Restore it:  mv -f \"$rel_orig\" \".ai/roles/ROLE_ASSIGNMENT.md\""
    echo ""
    exit 1
}

_setup_on_signal() {
    trap - INT TERM
    if [ "$SETUP_PHASE" = "role-replaced" ]; then
        _setup_restore_or_report "setup was interrupted between its two writes"
    fi
    if [ "$SETUP_PHASE" = "done" ]; then
        echo ""
        echo "setup: interrupted after both files were written. The new setup is in place; run status to see it."
        echo ""
        exit 130
    fi
    echo ""
    echo "setup: interrupted. Nothing was changed."
    echo ""
    exit 130
}

_setup_usage() {
    echo ""
    echo "setup: choose the players and the Master. handoff.sh takes the choice as flags."
    echo "Examples only - the choice is the user's; an agent asks the user and never chooses:"
    echo ""
    echo "  bash scripts/handoff.sh setup --players \"Claude Code,Codex\" --master \"Claude Code\" --yes"
    echo "  bash scripts/handoff.sh setup --players \"Claude Code,Codex\" --master \"Codex\" --yes"
    echo "  bash scripts/handoff.sh setup --players \"Codex\" --yes"
    echo ""
    echo "Players: one or both of Claude Code, Codex."
    echo "Two players: --master is required. The Master's tool implements; the other tool reviews."
    echo "One player:  that tool holds every role and reviews in a separate read-only run (fresh-context)."
    echo "An agent installing this protocol asks the user; it never chooses for them."
    echo "Nothing was changed."
    echo ""
}

_display_of_canonical() {
    case "$1" in
        codex) echo "Codex" ;;
        claude-code) echo "Claude Code" ;;
    esac
}

# The same rules as handoff.ps1's Resolve-SetupChoice and the same apply: binding rows,
# Review Independence, Setup: complete, a history row, and Task Actors in the untouched
# install state only. No window and no prompt for the choice itself.
cmd_setup() {
    [ -z "$ARG_ERROR" ] || _setup_blocked "$ARG_ERROR"
    if ! $PLAYERS_SET; then
        [ -z "$MASTER_ARG" ] || _setup_blocked "--master needs --players: --players \"<Claude Code, Codex, or both>\" --master \"$MASTER_ARG\"."
        _setup_usage
        exit 1
    fi
    # Guards first: never while a turn may be running, and a configured project only between tasks.
    local guard_errors=()
    if [ -f "$(pwd)/HANDOFF_RUN.json" ] || { [ -f "$(pwd)/HANDOFF_BACKGROUND.json" ] && ! grep -Eq '"finishedUtc"[[:space:]]*:[[:space:]]*"' "$(pwd)/HANDOFF_BACKGROUND.json"; }; then
        guard_errors+=("A turn may be running now (a run marker is present). Wait for it, or stop it with pwsh scripts/handoff.ps1 stop; pwsh scripts/handoff.ps1 status clears a stale marker.")
    fi
    local initial=false
    [ "$STATE" = "WAITING_FOR_USER" ] && [ "$WAITING_FOR" = "User" ] && [ "$CURRENT_TASK" = "Initial setup" ] && initial=true
    # v3.18.0 (review fix): Bash runs setup only on the untouched install state. Pending and
    # anything else: the record was written before the players were chosen, and setup does
    # not adopt it. Configured and anything else: the finished task has to be retired by the
    # start drift recovery afterwards, which exists only in handoff.ps1.
    if ! $initial; then
        if [ "$SETUP_STATE" = "pending" ]; then
            guard_errors+=("AI_HANDOFF.md is not the untouched install state ('$CURRENT_TASK', $STATE / Waiting For: $WAITING_FOR). setup does not adopt a record written before the players were chosen. To keep it, move AI_HANDOFF.md into .ai/handoff-history/ (local and gitignored there); then re-run the installer with --force (install.ps1 -Force) to restore a clean AI_HANDOFF.md, and run setup.")
        else
            guard_errors+=("'$CURRENT_TASK' is not the untouched install state. Reconfiguring a project after its first task requires PowerShell: pwsh scripts/handoff.ps1 setup (at a finished task; start then retires the record). To change one role: handoff.ps1 roles -SetRole <role> -SetTool <tool>.")
        fi
    fi
    [ ${#guard_errors[@]} -eq 0 ] || _setup_blocked "${guard_errors[@]}"

    # The choice.
    local known="Claude Code, Codex" name canonical chosen="" displays="" count=0 IFS_SAVE
    local -a names=()
    IFS_SAVE="$IFS"; IFS=','; read -r -a names <<< "$PLAYERS"; IFS="$IFS_SAVE"
    local errors=()
    # An empty array is never expanded: Bash before 4.4 calls that unbound under set -u.
    [ ${#names[@]} -gt 0 ] || names=("")
    for name in "${names[@]}"; do
        name="$(printf '%s' "$name" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -n "$name" ] || continue
        canonical="$(_canonical_tool "$name")"
        if [ -z "$canonical" ]; then errors+=("Unknown player '$name'. Known tools: $known."); continue; fi
        case " $chosen " in *" $canonical "*) continue ;; esac
        chosen="${chosen}${chosen:+ }$canonical"
        displays="${displays}${displays:+, }$(_display_of_canonical "$canonical")"
        count=$((count + 1))
    done
    [ ${#errors[@]} -eq 0 ] || _setup_blocked "${errors[@]}"
    [ "$count" -gt 0 ] || _setup_blocked "Choose at least one player. Known tools: $known. For example: --players \"<Claude Code, Codex, or both>\"."
    [ "$count" -le 2 ] || _setup_blocked "setup binds one player or two; $count were given ($displays)."
    local master_c="" master_d="" impl_d="" rev_d="" mode
    if [ -n "$MASTER_ARG" ]; then
        master_c="$(_canonical_tool "$MASTER_ARG")"
        [ -n "$master_c" ] || _setup_blocked "Unknown Master '$MASTER_ARG'. Known tools: $known."
        case " $chosen " in *" $master_c "*) ;; *) _setup_blocked "The Master must be one of the players. '$(_display_of_canonical "$master_c")' is not in the players ($displays)." ;; esac
    fi
    if [ "$count" -eq 1 ]; then
        master_d="$(_display_of_canonical "$chosen")"; impl_d="$master_d"; rev_d="$master_d"; mode="fresh-context"
    else
        if [ -z "$master_c" ]; then
            local first="${chosen%% *}" second="${chosen##* }"
            _setup_blocked "With two players, choose the Master: --master \"$(_display_of_canonical "$first")\" or --master \"$(_display_of_canonical "$second")\". No Master is chosen for you."
        fi
        local other
        for other in $chosen; do [ "$other" = "$master_c" ] || break; done
        master_d="$(_display_of_canonical "$master_c")"; impl_d="$master_d"; rev_d="$(_display_of_canonical "$other")"; mode="separate-tool"
    fi

    local current_mode current_setup
    if [ -n "$REVIEW_INDEPENDENCE_ERROR" ]; then current_mode="invalid"; else current_mode="$REVIEW_INDEPENDENCE"; fi
    if [ -n "$SETUP_ERROR" ]; then current_setup="invalid"; elif [ -n "$SETUP_STATE" ]; then current_setup="$SETUP_STATE"; else current_setup="none"; fi
    if [ "$current_setup" = "complete" ] && [ "$current_mode" = "$mode" ] && \
       [ "$(_canonical_tool "$MASTER_TOOL")" = "$(_canonical_tool "$master_d")" ] && \
       [ "$(_canonical_tool "$REVIEWER_TOOL")" = "$(_canonical_tool "$rev_d")" ] && \
       [ "$(_canonical_tool "$IMPLEMENTER_TOOL")" = "$(_canonical_tool "$impl_d")" ]; then
        echo ""
        echo "setup: this project already has these players and this Master. Nothing to change."
        echo ""
        return 0
    fi

    echo ""
    if [ "$SETUP_STATE" = "pending" ]; then echo "First setup: the players and the Master for this project."; else echo "Reconfiguring the players and the Master for this project."; fi
    echo "  Players:     $displays"
    echo "  Master:      $master_d   (decides the next task and routes it)"
    echo "  Implementer: $impl_d   (writes the code)"
    echo "  Reviewer:    $rev_d   (checks it and gives the verdict)"
    if [ "$mode" = "fresh-context" ]; then
        echo "  Review:      fresh-context - $rev_d reviews in a separate read-only run the harness starts (review-run, then review-apply), never in the Implementer's context."
        echo "  Weaker:      one vendor reviewing its own vendor's work misses what a second vendor would catch."
        echo "               Two tools remain the recommended setup."
    else
        echo "  Review:      separate-tool - $rev_d reviews what $impl_d writes; the Reviewer is never the Implementer's tool."
    fi
    if $initial; then
        echo "  Changes:     .ai/roles/ROLE_ASSIGNMENT.md (binding, Review Independence, Setup: complete, a history row), and AI_HANDOFF.md Task Actors."
    else
        echo "  Changes:     .ai/roles/ROLE_ASSIGNMENT.md (binding, Review Independence, Setup: complete, a history row)."
    fi
    echo "  Never:       no git, deploy, database or secret action; no turn is started."
    echo ""
    if $YES; then
        echo "Confirmation: --yes supplied; applying without an interactive prompt."
    else
        local answer=""
        read -r -p 'Type "yes" to save this setup, or press Enter to cancel: ' answer || answer=""
        if [ "$(printf '%s' "$answer" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" != "yes" ]; then
            echo "Cancelled. Nothing was changed."
            [ "$SETUP_STATE" = "pending" ] && echo "Setup is still pending."
            exit 2
        fi
    fi

    local rf="$(pwd)/.ai/roles/ROLE_ASSIGNMENT.md" tmp tmp2 today before after
    [ -f "$rf" ] || _setup_blocked "ROLE_ASSIGNMENT.md is missing. Re-run the installer."
    # v3.18.0 (review fix): a folder that cannot be written is named as such, up front. A
    # write-denied .ai/roles used to be reported as a malformed binding table, and a
    # write-denied project folder as an unreadable AI_HANDOFF.md.
    _setup_probe_dir "$(pwd)/.ai/roles" || _setup_blocked "ROLE_ASSIGNMENT.md could not be written: the folder .ai/roles is not writable."
    if $initial; then
        _setup_probe_dir "$(pwd)" || _setup_blocked "AI_HANDOFF.md could not be written: the project folder is not writable."
    fi
    # Setup's own files live in .ai/handoff-history/: inside the project, so every move is a
    # rename on one filesystem, and ignored by Git (the installers' .gitignore snippet lists
    # it), so a file left behind can never be committed with 'git add -A'.
    local work="$(pwd)/.ai/handoff-history"
    { mkdir -p "$work" 2>/dev/null && _setup_probe_dir "$work"; } || _setup_blocked "setup could not write its work folder .ai/handoff-history."
    today="$(date '+%Y-%m-%d')"
    before="Master=$MASTER_TOOL, Reviewer=$REVIEWER_TOOL, Implementer=$IMPLEMENTER_TOOL, Review Independence=$current_mode, Setup=$current_setup"
    after="Master=$master_d, Reviewer=$rev_d, Implementer=$impl_d, Review Independence=$mode, Setup=complete"
    tmp="$work/ROLE_ASSIGNMENT.md.setup-$$"; tmp2="$work/ROLE_ASSIGNMENT.md.setup2-$$"
    local htmp="$work/AI_HANDOFF.md.setup-$$" orig="$work/ROLE_ASSIGNMENT.md.setup-orig-$$"
    SETUP_RF="$rf"; SETUP_ORIG="$orig"; SETUP_PHASE="prepare"
    SETUP_TMP_FILES=("$tmp" "$tmp2" "$htmp" "$orig")
    trap '_setup_cleanup' EXIT
    trap '_setup_on_signal' INT TERM
    # Pass 1: binding rows, the Review Independence line and the Setup line (one of each).
    if ! tr -d '\r' < "$rf" | awk -v master="$master_d" -v reviewer="$rev_d" -v implementer="$impl_d" -v mode="$mode" -v nbsp="$(printf '\302\240')" '
        {
            line = $0; probe = line; gsub(nbsp, " ", probe); low = tolower(probe)
            if (low ~ /^[[:space:]]*([-*][[:space:]]+)?review independence[[:space:]]*:/) { if (!rw) { out[++n] = "Review Independence: " mode; rw = 1; ri = n }; next }
            if (low ~ /^[[:space:]]*([-*][[:space:]]+)?setup[[:space:]]*:/) { if (!sw) { out[++n] = "Setup: complete"; sw = 1; si = n }; next }
            if (tolower(line) ~ /^\|[[:space:]]*(master|reviewer|implementer)[[:space:]]*\|[[:space:]]*[^|[:space:]]/) {
                split(line, cells, "|"); r = tolower(cells[2]); gsub(/^[[:space:]]+|[[:space:]]+$/, "", r)
                if (r == "master") { out[++n] = "| Master | " master " |" } else if (r == "reviewer") { out[++n] = "| Reviewer | " reviewer " |" } else { out[++n] = "| Implementer | " implementer " |" }
                seen[r]++; last = n; next
            }
            out[++n] = line
        }
        END {
            if (seen["master"] != 1 || seen["reviewer"] != 1 || seen["implementer"] != 1) exit 3
            # A missing review line goes just above an existing Setup line, as in handoff.ps1.
            before_setup = (!rw && sw && si > last)
            for (i = 1; i <= n; i++) {
                if (before_setup && i == si) print "Review Independence: " mode
                print out[i]
                if (!rw && !before_setup && i == last) { print ""; print "Review Independence: " mode; if (!sw) print "Setup: complete" }
                if (rw && !sw && i == ri) print "Setup: complete"
            }
        }' > "$tmp"; then
        rm -f "$tmp"
        _setup_blocked "ROLE_ASSIGNMENT.md must have exactly one '| Master |', '| Reviewer |' and '| Implementer |' row. Repair the table, or re-run the installer with --force."
    fi
    # Pass 2: the history row, in the existing table or in a new one at the end.
    local row="| $today | $before | $after | User (handoff.sh setup) |"
    if ! awk -v row="$row" '
        { lines[++n] = $0 }
        END {
            inh = 0; done = 0; prev = ""
            for (i = 1; i <= n; i++) {
                l = lines[i]
                if (l ~ /^## Role Swap History[[:space:]]*$/) { inh = 1; print l; prev = l; continue }
                if (inh && !done && l ~ /^[[:space:]]*$/ && prev ~ /^[[:space:]]*\|/) { print row; done = 1 }
                if (inh && !done && l ~ /^## / && l !~ /^## Role Swap History/) { print row; done = 1 }
                print l; prev = l
            }
            if (inh && !done) print row
            if (!inh) exit 4
        }' "$tmp" > "$tmp2"; then
        # No history section yet: rebuild without trailing blanks and append one.
        awk '{ lines[++n] = $0 } END { m = n; while (m > 0 && lines[m] ~ /^[[:space:]]*$/) m--; for (i = 1; i <= m; i++) print lines[i] }' "$tmp" > "$tmp2"
        { echo ""; echo "## Role Swap History"; echo ""; echo "| Date | Before | After | Decided by |"; echo "|---|---|---|---|"; echo "$row"; } >> "$tmp2"
    fi
    rm -f "$tmp"
    # v3.18.0 (review fix): the same contract as handoff.ps1. Both new files are prepared
    # first, the original role file is kept, and if any step after the first replace
    # fails the role file is restored byte for byte. The EXIT trap removes every temp
    # file; INT and TERM between the two moves restore too. Only a failed restore keeps
    # the saved original, because then it is the only copy, and says so.
    if $initial; then
        if ! tr -d '\r' < "$HANDOFF_FILE" | awk -v impl="$impl_d" -v rev="$rev_d" '
            { t = $0; sub(/[[:space:]]+$/, "", t) }
            tolower(t) == "## task actors" { ina = 1; print; next }
            ina && /^##[[:space:]]/ { ina = 0 }
            ina && /^-[[:space:]]*[Ii][Mm][Pp][Ll][Ee][Mm][Ee][Nn][Tt][Ee][Rr]:/ { print "- Implementer: " impl; next }
            ina && /^-[[:space:]]*[Rr][Ee][Vv][Ii][Ee][Ww][Ee][Rr]:/ { print "- Reviewer: " rev; next }
            { print }' > "$htmp"; then
            _setup_blocked "AI_HANDOFF.md could not be read to move its Task Actors."
        fi
    fi
    if ! cp -p "$rf" "$orig" 2>/dev/null; then
        _setup_blocked "ROLE_ASSIGNMENT.md could not be copied aside before the change."
    fi
    # v3.18.0 (review fix): the phase is set before the move, so a signal that lands during
    # it restores (an identical copy, at worst) instead of claiming nothing changed.
    SETUP_PHASE="role-replaced"
    if ! _setup_mv role "$tmp2" "$rf"; then
        # The rename did not happen, so the role file is the original.
        SETUP_PHASE="prepare"
        _setup_blocked "ROLE_ASSIGNMENT.md could not be replaced."
    fi
    case ",${HANDOFF_TEST_SETUP_FAIL:-}," in *",interrupt,"*) kill -TERM $$ ;; esac
    if $initial && ! _setup_mv handoff "$htmp" "$HANDOFF_FILE"; then
        _setup_restore_or_report "AI_HANDOFF.md could not be written (is it open in another program?)"
    fi
    SETUP_PHASE="done"
    echo ""
    echo "setup: complete."
    echo "  Master:      $master_d"
    echo "  Implementer: $impl_d"
    echo "  Reviewer:    $rev_d"
    echo "  Review:      Review Independence: $mode"
    [ "$mode" = "fresh-context" ] && echo "  $(_single_vendor_line "$rev_d")"
    echo ""
    echo "Recorded in the Role Swap History table. No turn was started and no git action was run."
    if ! $initial; then
        echo "A finished task keeps its Task Actors as the record of who did it; open the next task with start."
    fi
    echo "Next: bash scripts/handoff.sh status"
    echo ""
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

cmd_models_blocked() {
    echo ""
    echo "Model resolution is implemented by the PowerShell adapter."
    echo "Run: pwsh scripts/handoff.ps1 models"
    echo "This is a read-only command and does not run an AI turn."
    echo ""
    exit 1
}

# ---------------------------------------------------------------------------
# Init and dispatch
# ---------------------------------------------------------------------------

case "$COMMAND" in commit-check|setup) _unreadable_guard ;; esac
_parse_status
_get_role_binding
_get_review_independence
_get_setup_state
_setup_gate
_role_checkpoint

case "$COMMAND" in
    status)       cmd_status ;;
    models)       cmd_models_blocked ;;
    adapters)     cmd_adapters ;;
    setup)        cmd_setup ;;
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
        echo "  models                    Read-only model routing view; requires PowerShell (pwsh)."
        echo "  adapters                  Show adapter callable/manual status for each role."
        echo "  setup --players <list> [--master <tool>] [--yes]"
        echo "                            Choose the players and the Master. A fresh install is 'Setup: pending' and every"
        echo "                            other command but status stops with exit 14 until this is done."
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
