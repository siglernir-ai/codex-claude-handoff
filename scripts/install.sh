#!/usr/bin/env bash
# Project-local installer. Default activation is opt-in; pass --always-on explicitly
# to install root AGENTS.md and CLAUDE.md instructions.

set -euo pipefail

# v3.18.0: byte-wise readers, so a UTF-8 locale on another machine cannot change a match.
export LC_ALL=C

TARGET_PATH="${1:-}"
if [ -z "$TARGET_PATH" ]; then
    echo "Usage: bash scripts/install.sh <target-project-path> [--force] [--always-on|--disable-always-on] [--players <list> [--master <tool>]]"
    exit 1
fi
shift

FORCE=false
ALWAYS_ON=false
DISABLE_ALWAYS_ON=false
# v3.18.0: the first-setup choice, for a scripted install.
SETUP_PLAYERS=""
SETUP_PLAYERS_SET=false
SETUP_MASTER=""
SETUP_MASTER_SET=false
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=true ;;
        --always-on) ALWAYS_ON=true ;;
        --disable-always-on) DISABLE_ALWAYS_ON=true ;;
        --players)
            [ $# -ge 2 ] || { echo "--players needs a value: --players \"<Claude Code, Codex, or both>\""; exit 1; }
            SETUP_PLAYERS="$2"; SETUP_PLAYERS_SET=true; shift ;;
        --master)
            [ $# -ge 2 ] || { echo "--master needs a value: --master \"<one of the players>\""; exit 1; }
            SETUP_MASTER="$2"; SETUP_MASTER_SET=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done
if $SETUP_MASTER_SET && ! $SETUP_PLAYERS_SET; then
    echo "--master needs --players: --players \"<Claude Code, Codex, or both>\" --master \"$SETUP_MASTER\""
    exit 1
fi

if $ALWAYS_ON && $DISABLE_ALWAYS_ON; then
    echo "Choose either --always-on or --disable-always-on, not both."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates"

if [ ! -d "$TEMPLATES_DIR" ]; then
    echo "Error: Templates folder not found: $TEMPLATES_DIR"
    exit 1
fi

mkdir -p "$TARGET_PATH"
TARGET_PATH="$(cd "$TARGET_PATH" && pwd)"

if [ ! -d "$TARGET_PATH/.git" ]; then
    echo "WARNING: target is not a Git repository yet: $TARGET_PATH"
    echo "Run 'git init' and create a baseline commit before using review/commit guards."
fi

# Validate and preserve the live role binding before any target mutation.
PRESERVE_ROLE_BINDING=false
PRESERVED_MASTER=""
PRESERVED_REVIEWER=""
PRESERVED_IMPLEMENTER=""
ROLE_FILE="$TARGET_PATH/.ai/roles/ROLE_ASSIGNMENT.md"
if $FORCE && [ -f "$ROLE_FILE" ]; then
    master_count=0 reviewer_count=0 implementer_count=0
    while IFS='=' read -r role tool; do
        case "$role" in
            master) master_count=$((master_count + 1)); PRESERVED_MASTER="$tool" ;;
            reviewer) reviewer_count=$((reviewer_count + 1)); PRESERVED_REVIEWER="$tool" ;;
            implementer) implementer_count=$((implementer_count + 1)); PRESERVED_IMPLEMENTER="$tool" ;;
        esac
    # v3.18.0 (review fix): role names without regard to case, as install.ps1 reads them.
    done < <(tr -d '\r' < "$ROLE_FILE" | awk -F'|' '
        tolower($0) ~ /^\|[[:space:]]*(master|reviewer|implementer)[[:space:]]*\|/ {
            role=tolower($2); tool=$3
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", role)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", tool)
            if (role != "" && tool != "") print role "=" tool
        }
    ')
    if [ "$master_count" -ne 1 ] || [ "$reviewer_count" -ne 1 ] || [ "$implementer_count" -ne 1 ]; then
        echo "Refusing --force update: existing ROLE_ASSIGNMENT.md cannot be parsed exactly. Repair it before updating: $ROLE_FILE"
        exit 1
    fi
    # v3.17.0: the review rule is part of the binding. An absent line is separate-tool;
    # two lines or any other value refuse the upgrade, as handoff.ps1 refuses to run.
    # v3.17.0 (review fix): key and value without regard to case, as install.ps1 reads them.
    ri_lines="$(tr -d '\r' < "$ROLE_FILE" | awk -v bom="$(printf '\357\273\277')" -v nbsp="$(printf '\302\240')" '{ l = $0; if (NR == 1 && index(l, bom) == 1) l = substr(l, length(bom) + 1); gsub(nbsp, " ", l) } tolower(l) ~ /^[[:space:]]*([-*][[:space:]]+)?review independence[[:space:]]*:/ { v = l; sub(/^[^:]*:/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print "<" v ">" }')"
    ri_count="$(printf '%s' "$ri_lines" | grep -c '^<' || true)"
    ri_values="${ri_lines#<}"; ri_values="${ri_values%>}"
    ri_values="$(printf '%s' "$ri_values" | tr '[:upper:]' '[:lower:]')"
    PRESERVED_REVIEW_INDEPENDENCE=""
    if [ "$ri_count" -gt 1 ]; then
        echo "Refusing --force update: existing ROLE_ASSIGNMENT.md is invalid: the 'Review Independence:' line must appear once and read separate-tool or fresh-context. Repair it before updating: $ROLE_FILE"
        exit 1
    elif [ "$ri_count" -eq 1 ]; then
        case "$ri_values" in
            separate-tool|fresh-context) PRESERVED_REVIEW_INDEPENDENCE="$ri_values" ;;
            *)
                echo "Refusing --force update: existing ROLE_ASSIGNMENT.md is invalid: the 'Review Independence:' line must appear once and read separate-tool or fresh-context. Repair it before updating: $ROLE_FILE"
                exit 1
                ;;
        esac
    fi
    if [ "$PRESERVED_REVIEWER" = "$PRESERVED_IMPLEMENTER" ] && [ "$PRESERVED_REVIEW_INDEPENDENCE" != "fresh-context" ]; then
        echo "Refusing --force update: existing role binding violates Reviewer != Implementer. Repair it before updating: $ROLE_FILE"
        exit 1
    fi
    # v3.18.0: the Setup line is carried across too. No line (an install made before
    # v3.18.0) stays no line, so the upgrade cannot turn a configured project pending.
    setup_lines="$(tr -d '\r' < "$ROLE_FILE" | awk -v bom="$(printf '\357\273\277')" -v nbsp="$(printf '\302\240')" '{ l = $0; if (NR == 1 && index(l, bom) == 1) l = substr(l, length(bom) + 1); gsub(nbsp, " ", l) } tolower(l) ~ /^[[:space:]]*([-*][[:space:]]+)?setup[[:space:]]*:/ { v = l; sub(/^[^:]*:/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print "<" v ">" }')"
    setup_count="$(printf '%s' "$setup_lines" | grep -c '^<' || true)"
    setup_value="${setup_lines#<}"; setup_value="${setup_value%>}"
    setup_value="$(printf '%s' "$setup_value" | tr '[:upper:]' '[:lower:]')"
    PRESERVED_SETUP=""
    if [ "$setup_count" -gt 1 ]; then
        echo "Refusing --force update: existing ROLE_ASSIGNMENT.md is invalid: the 'Setup:' line must appear once and read pending or complete. Repair it with handoff.sh setup before updating: $ROLE_FILE"
        exit 1
    elif [ "$setup_count" -eq 1 ]; then
        case "$setup_value" in
            pending|complete) PRESERVED_SETUP="$setup_value" ;;
            *)
                echo "Refusing --force update: existing ROLE_ASSIGNMENT.md is invalid: the 'Setup:' line must appear once and read pending or complete. Repair it with handoff.sh setup before updating: $ROLE_FILE"
                exit 1
                ;;
        esac
    fi
    PRESERVE_ROLE_BINDING=true
fi

if $DISABLE_ALWAYS_ON; then
    REMOVAL_CANDIDATES=()
    for rel in AGENTS.md CLAUDE.md; do
        target_file="$TARGET_PATH/$rel"
        template_file="$TEMPLATES_DIR/$rel"
        if [ ! -f "$target_file" ]; then
            continue
        fi
        if ! cmp -s "$target_file" "$template_file"; then
            echo "Refusing to remove customized root instructions: $target_file"
            exit 1
        fi
        REMOVAL_CANDIDATES+=("$target_file")
    done

    for target_file in "${REMOVAL_CANDIDATES[@]}"; do
        rm -f -- "$target_file"
        echo "Removed unmodified bundled root instruction: $target_file"
    done
fi

should_install() {
    local rel="$1"
    case "$rel" in
        gitignore-snippet.txt|scripts/protocol-tests.ps1|scripts/protocol-tests.sh)
            return 1
            ;;
        AGENTS.md|CLAUDE.md)
            $ALWAYS_ON
            return
            ;;
        *)
            return 0
            ;;
    esac
}

EXISTING=()
while IFS= read -r -d '' src; do
    rel="${src#"$TEMPLATES_DIR"/}"
    if should_install "$rel" && [ -e "$TARGET_PATH/$rel" ] && ! $FORCE; then
        EXISTING+=("$rel")
    fi
done < <(find "$TEMPLATES_DIR" -type f -print0)

if [ ${#EXISTING[@]} -gt 0 ]; then
    echo "install.sh: blocked to avoid overwriting existing files."
    echo "Existing target files:"
    printf '  %s\n' "${EXISTING[@]}"
    echo ""
    echo "Re-run with --force only when you intentionally want to refresh installed protocol files."
    exit 1
fi

while IFS= read -r -d '' src; do
    rel="${src#"$TEMPLATES_DIR"/}"
    if ! should_install "$rel"; then
        continue
    fi
    # v3.7.0: DECISIONS.md accumulates across tasks; an upgrade must not overwrite it.
    if $FORCE && { [ "$rel" = "AI_HANDOFF.md" ] || [ "$rel" = "AI_SEQUENCE.md" ] || [ "$rel" = "DECISIONS.md" ]; } && [ -f "$TARGET_PATH/$rel" ]; then
        echo "Preserved local coordination state: $rel"
        continue
    fi
    mkdir -p "$(dirname "$TARGET_PATH/$rel")"
    if [ "$rel" = ".ai/roles/ROLE_ASSIGNMENT.md" ] && $PRESERVE_ROLE_BINDING; then
        role_tmp="$TARGET_PATH/$rel.update.$$"
        awk -F'|' -v master="$PRESERVED_MASTER" -v reviewer="$PRESERVED_REVIEWER" -v implementer="$PRESERVED_IMPLEMENTER" '
            /^\|[[:space:]]*(Master|Reviewer|Implementer)[[:space:]]*\|/ {
                role=$2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", role)
                if (role == "Master") { print "| Master | " master " |"; next }
                if (role == "Reviewer") { print "| Reviewer | " reviewer " |"; next }
                if (role == "Implementer") { print "| Implementer | " implementer " |"; next }
            }
            { print }
        ' "$src" > "$role_tmp"
        # v3.7.0: carry across sections the project added of its own.
        #
        # The awk above rebuilds the file from the template and substitutes only the
        # three role rows, so a Role Swap History table - which the protocol itself
        # asks the user to keep here - was deleted on every --force upgrade, silently.
        # Plain shell rather than nested awk: the sections carry real newlines, and a
        # newline inside an embedded awk string is exactly how the first attempt broke.
        # PowerShell does the same in Add-PreservedRoleSections; both must agree.
        if [ -f "$TARGET_PATH/$rel" ]; then
            _CR=$'\r'   # carriage return, for CRLF files
            _tmpl_headings="$role_tmp.headings.$$"
            grep -E '^##[[:space:]]+' "$src" | tr -d "$_CR" | sed -E 's/^##[[:space:]]+//; s/[[:space:]]+$//' > "$_tmpl_headings"
            _extra_dir="$role_tmp.extra.$$"
            mkdir -p "$_extra_dir"
            _cur=""; _anchor=""; _n=0
            while IFS= read -r _line || [ -n "$_line" ]; do
                _line="${_line%"$_CR"}"
                case "$_line" in
                    "## "*)
                        _h="${_line#\#\# }"
                        if grep -Fxq "$_h" "$_tmpl_headings"; then
                            _anchor="$_h"; _cur=""
                        else
                            _n=$((_n + 1)); _cur="$_extra_dir/$_n"
                            printf '%s
' "$_anchor" > "$_cur.anchor"
                            printf '%s
' "$_line" > "$_cur.body"
                        fi
                        ;;
                    *)
                        [ -n "$_cur" ] && printf '%s
' "$_line" >> "$_cur.body"
                        ;;
                esac
            done < "$TARGET_PATH/$rel"

            if [ "$_n" -gt 0 ]; then
                _merged="$role_tmp.merged.$$"
                : > "$_merged"
                _seen=""
                while IFS= read -r _line || [ -n "$_line" ]; do
                    _line="${_line%"$_CR"}"
                    case "$_line" in
                        "## "*)
                            if [ -n "$_seen" ]; then
                                for _i in $(seq 1 "$_n"); do
                                    [ -f "$_extra_dir/$_i.anchor" ] || continue
                                    if [ "$(cat "$_extra_dir/$_i.anchor")" = "$_seen" ]; then
                                        cat "$_extra_dir/$_i.body" >> "$_merged"
                                        echo "" >> "$_merged"
                                        rm -f "$_extra_dir/$_i.anchor"
                                    fi
                                done
                            fi
                            _seen="${_line#\#\# }"
                            ;;
                    esac
                    printf '%s
' "$_line" >> "$_merged"
                done < "$role_tmp"
                for _i in $(seq 1 "$_n"); do
                    [ -f "$_extra_dir/$_i.anchor" ] || continue
                    cat "$_extra_dir/$_i.body" >> "$_merged"
                    echo "" >> "$_merged"
                done
                mv -f -- "$_merged" "$role_tmp"
            fi
            rm -rf -- "$_extra_dir" "$_tmpl_headings"
        fi

        # v3.17.0: keep one 'Review Independence:' line - the template's, the first - with
        # the installed project's value. PowerShell does the same in Set-MergedReviewIndependence.
        if [ -n "${PRESERVED_REVIEW_INDEPENDENCE:-}" ]; then
            _ri_tmp="$role_tmp.ri.$$"
            awk -v mode="$PRESERVED_REVIEW_INDEPENDENCE" -v bom="$(printf '\357\273\277')" -v nbsp="$(printf '\302\240')" '
                { line=$0; sub(/\r$/, "", line); if (NR == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1); gsub(nbsp, " ", line) }
                tolower(line) ~ /^[[:space:]]*([-*][[:space:]]+)?review independence[[:space:]]*:/ {
                    if (!done) { cr = ($0 ~ /\r$/) ? "\r" : ""; print "Review Independence: " mode cr; done=1 }
                    next
                }
                { print }
            ' "$role_tmp" > "$_ri_tmp"
            mv -f -- "$_ri_tmp" "$role_tmp"
        fi
        # v3.18.0: the installed project's own Setup line, or none; never the template's
        # 'pending'. PowerShell does the same in Set-MergedSetupLine.
        _setup_tmp="$role_tmp.setup.$$"
        awk -v value="${PRESERVED_SETUP:-}" -v nbsp="$(printf '\302\240')" '
            { line=$0; sub(/\r$/, "", line); gsub(nbsp, " ", line) }
            tolower(line) ~ /^[[:space:]]*([-*][[:space:]]+)?setup[[:space:]]*:/ {
                if (!done && value != "") { cr = ($0 ~ /\r$/) ? "\r" : ""; print "Setup: " value cr }
                done=1
                next
            }
            { print }
        ' "$role_tmp" > "$_setup_tmp"
        mv -f -- "$_setup_tmp" "$role_tmp"
        mv -f -- "$role_tmp" "$TARGET_PATH/$rel"
        echo "Preserved current role binding while refreshing role instructions."
    else
        cp -f "$src" "$TARGET_PATH/$rel"
    fi
done < <(find "$TEMPLATES_DIR" -type f -print0)

GITIGNORE_PATH="$TARGET_PATH/.gitignore"
if ! grep -qFx "AI_HANDOFF.md" "$GITIGNORE_PATH" 2>/dev/null; then
    printf '\n%s\n' "$(cat "$TEMPLATES_DIR/gitignore-snippet.txt")" >> "$GITIGNORE_PATH"
fi

# v3.9.0: keep Claude Code's file tools out of files that hold credentials. Same rules
# file and same messages as install.ps1 (Add-CredentialReadGuard); both must agree.
# An existing settings file is merged with Python when it is available, and is never
# rewritten by hand-rolled JSON editing: without Python the rules are only reported.
RULES_FILE="$TEMPLATES_DIR/.ai/skills/codex-claude-handoff/CREDENTIAL_READ_DENY.txt"
SETTINGS_PATH="$TARGET_PATH/.claude/settings.json"
if [ -f "$RULES_FILE" ]; then
    RULES=()
    while IFS= read -r _rule || [ -n "$_rule" ]; do
        _rule="${_rule%$'\r'}"
        _rule="$(printf '%s' "$_rule" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        case "$_rule" in ""|\#*) continue ;; esac
        RULES+=("$_rule")
    done < "$RULES_FILE"

    if [ ${#RULES[@]} -gt 0 ]; then
        if [ ! -f "$SETTINGS_PATH" ]; then
            mkdir -p "$TARGET_PATH/.claude"
            {
                printf '{\n  "permissions": {\n    "deny": [\n'
                _last=$((${#RULES[@]} - 1))
                for _i in "${!RULES[@]}"; do
                    _sep=","; [ "$_i" -eq "$_last" ] && _sep=""
                    printf '      "%s"%s\n' "${RULES[$_i]}" "$_sep"
                done
                printf '    ]\n  }\n}\n'
            } > "$SETTINGS_PATH"
            echo "Credential read guard: created .claude/settings.json with ${#RULES[@]} deny rules."
        else
            _py=""
            for _candidate in python3 python; do
                if command -v "$_candidate" >/dev/null 2>&1 && "$_candidate" -c 'import json' >/dev/null 2>&1; then
                    _py="$_candidate"; break
                fi
            done
            _guard_out=""
            if [ -n "$_py" ] && _guard_out="$("$_py" - "$SETTINGS_PATH" "${RULES[@]}" <<'PYEOF'
import json, sys
path, rules = sys.argv[1], sys.argv[2:]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
data = json.loads(text) if text.strip() else {}
if not isinstance(data, dict):
    raise SystemExit("settings.json is not a JSON object")
permissions = data.setdefault("permissions", {})
if not isinstance(permissions, dict):
    raise SystemExit("permissions is not a JSON object")
deny = permissions.setdefault("deny", [])
if not isinstance(deny, list):
    raise SystemExit("permissions.deny is not a list")
missing = [rule for rule in rules if rule not in deny]
if missing:
    deny.extend(missing)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(data, indent=2) + "\n")
print(len(missing))
PYEOF
)"; then
                if [ "$_guard_out" = "0" ]; then
                    echo "Credential read guard: already present in .claude/settings.json."
                else
                    echo "Credential read guard: added $_guard_out deny rules to .claude/settings.json."
                fi
            else
                echo "WARNING: the credential read guard was not added, because .claude/settings.json could not be merged safely."
                echo "The file was left unchanged. Add these entries to permissions.deny by hand: ${RULES[*]}"
            fi
        fi
    fi
fi

if $ALWAYS_ON; then
    MODE="always-on"
else
    MODE="opt-in"
fi

if ! $ALWAYS_ON && ! $DISABLE_ALWAYS_ON; then
    LEGACY_BUNDLED=()
    for rel in AGENTS.md CLAUDE.md; do
        if [ -f "$TARGET_PATH/$rel" ] && cmp -s "$TARGET_PATH/$rel" "$TEMPLATES_DIR/$rel"; then
            LEGACY_BUNDLED+=("$rel")
        fi
    done
    if [ ${#LEGACY_BUNDLED[@]} -gt 0 ]; then
        echo "WARNING: bundled always-on root instructions are still present: ${LEGACY_BUNDLED[*]}"
        echo "To migrate an unmodified older install to opt-in mode, re-run with --force --disable-always-on."
    fi
fi

echo ""
echo "codex-claude-handoff installed into:"
echo "  $TARGET_PATH"
echo "Activation mode: $MODE"

# v3.18.0: the first choice is the user's. A fresh install is 'Setup: pending' and work
# commands stop until the players and the Master are chosen, by the installed handoff.sh.
INSTALLED_SETUP="$(tr -d '\r' < "$ROLE_FILE" | awk -v nbsp="$(printf '\302\240')" '{ l = $0; gsub(nbsp, " ", l) } tolower(l) ~ /^[[:space:]]*([-*][[:space:]]+)?setup[[:space:]]*:/ { v = l; sub(/^[^:]*:/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print tolower(v) }')"
setup_pending_notice() {
    echo ""
    echo "Setup: NOT CONFIGURED. The players and the Master have not been chosen, so work commands"
    echo "are blocked (exit 14) until you run, in the project:"
    echo "  bash scripts/handoff.sh setup --players \"<Claude Code, Codex, or both>\" --master \"<one of the players>\""
    echo "An agent must ask the user which players and which Master; it never chooses for them."
    echo "With PowerShell, .\\scripts\\handoff.ps1 setup can open a window."
}
if $SETUP_PLAYERS_SET && [ "$INSTALLED_SETUP" != "pending" ]; then
    echo ""
    echo "--players ignored: this project has already chosen its players and its Master."
    echo "To change them: bash scripts/handoff.sh setup --players <list> --master <tool>"
elif $SETUP_PLAYERS_SET; then
    setup_args=(setup --players "$SETUP_PLAYERS")
    $SETUP_MASTER_SET && setup_args+=(--master "$SETUP_MASTER")
    setup_args+=(--yes)
    if ! ( cd "$TARGET_PATH" && bash scripts/handoff.sh "${setup_args[@]}" ); then
        echo ""
        echo "install.sh: the files are installed, but setup refused the choice; the reason is above."
        echo "The project is NOT CONFIGURED. Run: bash scripts/handoff.sh setup --players <list> --master <tool>"
        exit 1
    fi
elif [ "$INSTALLED_SETUP" = "pending" ]; then
    setup_pending_notice
fi

echo ""
echo "Check the installation:"
echo "  cd \"$TARGET_PATH\""
echo "  bash scripts/handoff.sh status"
echo ""

if $ALWAYS_ON; then
    echo "Always-on mode is enabled. Root agent instructions were installed."
else
    echo "Use it for one task in Codex:"
    echo "  1. Enter /skills in the Codex composer."
    echo "  2. Select codex-claude-handoff."
    echo "  3. Describe the task you want completed through the full protocol."
    echo ""
    echo "For normal Codex work, do not select or mention the skill."
fi
