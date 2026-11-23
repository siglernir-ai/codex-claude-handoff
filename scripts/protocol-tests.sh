#!/usr/bin/env bash
# Protocol Test Harness (Bash companion) - codex-claude-handoff v3.1.11
#
# The protocol test harness is PowerShell-first: scripts/protocol-tests.ps1 holds the
# full fixture-driven suite (state routing, adapter decisions, stop categories, release
# and sequence guards, mirror parity, safety boundaries). This Bash companion does NOT
# re-run that suite. It honestly verifies the Bash-side behavior that handoff.sh is
# actually responsible for:
#   - the PowerShell-only release/sequence/review/master executors are refused honestly in Bash, and
#   - the canonical/template script mirrors are in sync.
# Run scripts/protocol-tests.ps1 (pwsh) for the complete protocol suite.
#
# Usage: bash scripts/protocol-tests.sh
# Exit:  0 = all passed, 1 = one or more failures or a harness error.

set -u

# v3.10.0: test the code, not the machine. A user who activated model routing through the
# environment must not see these fixtures resolve to their own models.
while IFS='=' read -r _model_var _; do
    case "$_model_var" in HANDOFF_CLAUDE_MODEL_*|HANDOFF_CODEX_MODEL_*) unset "$_model_var" ;; esac
done < <(env)
unset _model_var

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HANDOFF_SH="$SCRIPT_DIR/handoff.sh"

if [ ! -f "$HANDOFF_SH" ]; then
    echo "Harness error: cannot find $HANDOFF_SH"
    exit 1
fi

PASS=0
FAIL=0
FAILURES=""

check() {
    # check <name> <condition-exit-code> [detail]
    local name="$1"; local cond="$2"; local detail="${3:-}"
    if [ "$cond" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "  PASS  $name"
    else
        FAIL=$((FAIL + 1))
        FAILURES="$FAILURES\n  - $name"
        if [ -n "$detail" ]; then echo "  FAIL  $name - $detail"; else echo "  FAIL  $name"; fi
    fi
}

role_tool() {
    # role_tool <role-file> <role> -> prints the single matching tool
    local file="$1" role_wanted="$2"
    awk -F'|' -v wanted="$role_wanted" '
        /^\|[[:space:]]*(Master|Reviewer|Implementer)[[:space:]]*\|/ {
            role=$2; tool=$3
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", role)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", tool)
            if (role == wanted) print tool
        }
    ' "$file"
}

# Portable file hash. Prefers sha256sum, then shasum -a 256, then md5sum, then BSD md5
# (macOS). Prints the hex hash and returns 0 on success; prints nothing and returns
# non-zero if no hash tool is available or the file is missing - so callers can fail
# closed instead of silently comparing two empty strings.
HASH_TOOL=""
if   command -v sha256sum >/dev/null 2>&1; then HASH_TOOL="sha256sum"
elif command -v shasum    >/dev/null 2>&1; then HASH_TOOL="shasum -a 256"
elif command -v md5sum    >/dev/null 2>&1; then HASH_TOOL="md5sum"
elif command -v md5       >/dev/null 2>&1; then HASH_TOOL="md5"
fi

hash_file() {
    # hash_file <path> -> prints hash on success, returns non-zero otherwise
    local path="$1"
    [ -n "$HASH_TOOL" ] || return 1
    [ -f "$path" ] || return 1
    case "$HASH_TOOL" in
        md5) md5 -q "$path" ;;                       # BSD/macOS: -q prints only the hash
        *)   $HASH_TOOL "$path" | awk '{print $1}' ;;
    esac
}

# Disposable fixture project (never touches the real coordination files).
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/handoff-protocol-tests.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

make_fixture() {
    # make_fixture <state> <waiting_for> -> prints fixture dir path
    local state="$1"; local waiting="$2"
    local dir; dir="$(mktemp -d "$FIXTURE_ROOT/fx.XXXXXX")"
    mkdir -p "$dir/.ai/roles"
    cat > "$dir/.ai/roles/ROLE_ASSIGNMENT.md" <<'EOF'
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Codex |
| Implementer | Claude Code |
EOF
    cat > "$dir/AI_HANDOFF.md" <<EOF
# AI Handoff

## Status
- State: $state
- Waiting For: $waiting
- Last Updated By: Test
- Last Updated At: 2026-06-14
- Current Task: v0.20.0 - Protocol Test Harness

## Changed Files
- None yet

## Next Recommended Step
- See AI_HANDOFF.md.
EOF
    echo "$dir"
}

run_handoff() {
    # run_handoff <fixture_dir> <args...> -> sets RH_OUT and RH_CODE
    local dir="$1"; shift
    RH_OUT="$(cd "$dir" && bash "$HANDOFF_SH" "$@" 2>&1)"
    RH_CODE=$?
}

echo ""
echo "Protocol Test Harness (Bash companion) - codex-claude-handoff"
echo "Handoff under test: $HANDOFF_SH"
echo ""

# === Bash honestly refuses the PowerShell-only executors ===
echo "[bash] PowerShell-only executors are refused honestly"
fx="$(make_fixture REVIEW_DONE User)"
run_handoff "$fx" release-check -Version v0.20.0
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "release-check is honestly refused in Bash" $?

run_handoff "$fx" sequence-check
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "sequence-check is honestly refused in Bash" $?

run_handoff "$fx" review-check
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "review-check is honestly refused in Bash" $?

run_handoff "$fx" review-run
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "review-run is honestly refused in Bash" $?

run_handoff "$fx" review-apply
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "review-apply is honestly refused in Bash" $?

run_handoff "$fx" master-check
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "master-check is honestly refused in Bash" $?

run_handoff "$fx" master-run
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "master-run is honestly refused in Bash" $?

run_handoff "$fx" master-apply
echo "$RH_OUT" | grep -qiE "powershell|blocked|not (available|supported)"
check "master-apply is honestly refused in Bash" $?

# v3.19.0: the Bash usage points at the command card, in one line.
run_handoff "$fx"
[ "$RH_CODE" -eq 0 ] && [ "$(printf '%s\n' "$RH_OUT" | grep -c 'COMMANDS\.md')" -eq 1 ]
check "the Bash usage names COMMANDS.md in one line" $? "$RH_OUT"

# Refusal must not create a git commit or mutate the handoff file.
# Fail closed: require a real hash tool and a non-empty hash, so two empty strings
# (e.g. no hash tool present) can never count as an unchanged file.
if [ -z "$HASH_TOOL" ]; then
    check "Bash refusal does not modify AI_HANDOFF.md" 1 "no portable hash tool (sha256sum/shasum/md5sum/md5) found"
else
    before="$(hash_file "$fx/AI_HANDOFF.md")"
    run_handoff "$fx" release-check -Version v0.20.0
    after="$(hash_file "$fx/AI_HANDOFF.md")"
    if [ -n "$before" ] && [ "$before" = "$after" ]; then unmodified=0; else unmodified=1; fi
    check "Bash refusal does not modify AI_HANDOFF.md" $unmodified
fi

# === Safe in-place update ===
echo "[bash] --force preserves live state and refreshes managed files"
install_target="$FIXTURE_ROOT/bash-install-target"
mkdir -p "$install_target"
git -C "$install_target" init -q
install_out="$(bash "$SCRIPT_DIR/install.sh" "$install_target" 2>&1)"
install_code=$?
check "fresh Bash install succeeds" $install_code "$install_out"

# v3.19.0: HANDOFF.cmd is the Windows launcher. install.sh copies the template tree, and the
# launcher sits in it, so the generic copy must skip it by name. COMMANDS.md does install.
[ -f "$REPO_ROOT/templates/HANDOFF.cmd" ] && [ ! -e "$install_target/HANDOFF.cmd" ]
check "install.sh does not install the Windows launcher HANDOFF.cmd" $?
cmp -s "$install_target/COMMANDS.md" "$REPO_ROOT/templates/COMMANDS.md"
check "install.sh installs COMMANDS.md as shipped" $?

cat > "$install_target/AI_HANDOFF.md" <<'EOF'
# AI Handoff

## Status
- State: READY_FOR_IMPLEMENTATION
- Waiting For: Implementer
- Last Updated By: Claude Code
- Last Updated At: 2026-07-19
- Current Task: Verify safe in-place update

## Task Actors
- Implementer: Codex
- Reviewer: Claude Code

## Changed Files
- None yet

## Next Recommended Step
- Codex: report the current Implementer turn without changing source files.
EOF
printf '%s\n' 'SEQUENCE-SENTINEL-MUST-SURVIVE' > "$install_target/AI_SEQUENCE.md"
cat > "$install_target/.ai/roles/ROLE_ASSIGNMENT.md" <<'EOF'
# STALE ROLE DOCUMENT TO BE REFRESHED

## Current Binding

| Role | Tool |
|---|---|
| Master | Claude Code |
| Reviewer | Claude Code |
| Implementer | Codex |

## Role Swap History

| 2026-09-09 | custom row must survive |

EOF
printf '%s\n' 'STALE MANAGED SCRIPT' > "$install_target/scripts/handoff.ps1"
printf '%s
' '## 2026-09-09 - a durable decision' > "$install_target/DECISIONS.md"

if [ -z "$HASH_TOOL" ]; then
    check "--force state preservation can be verified" 1 "no portable hash tool found"
else
    handoff_before="$(hash_file "$install_target/AI_HANDOFF.md")"
    sequence_before="$(hash_file "$install_target/AI_SEQUENCE.md")"
    update_out="$(bash "$SCRIPT_DIR/install.sh" "$install_target" --force 2>&1)"
    update_code=$?
    check "Bash --force update succeeds" $update_code "$update_out"

    handoff_after="$(hash_file "$install_target/AI_HANDOFF.md")"
    sequence_after="$(hash_file "$install_target/AI_SEQUENCE.md")"
    [ -n "$handoff_before" ] && [ "$handoff_before" = "$handoff_after" ]
    check "--force preserves AI_HANDOFF.md byte-for-byte" $?
    [ -n "$sequence_before" ] && [ "$sequence_before" = "$sequence_after" ]
    check "--force preserves AI_SEQUENCE.md byte-for-byte" $?

    [ "$(role_tool "$install_target/.ai/roles/ROLE_ASSIGNMENT.md" Master)" = "Claude Code" ] && \
        [ "$(role_tool "$install_target/.ai/roles/ROLE_ASSIGNMENT.md" Reviewer)" = "Claude Code" ] && \
        [ "$(role_tool "$install_target/.ai/roles/ROLE_ASSIGNMENT.md" Implementer)" = "Codex" ]
    check "--force preserves the active swapped role binding" $?

    ! grep -q "STALE ROLE DOCUMENT" "$install_target/.ai/roles/ROLE_ASSIGNMENT.md" && \
        grep -q "The swap is atomic" "$install_target/.ai/roles/ROLE_ASSIGNMENT.md"
    check "--force refreshes role instructions around the preserved binding" $?

    # v3.7.0: the protocol asks the user to record swaps in this file, and --force
    # rebuilt it from the template, deleting the record. Both installers preserve
    # unknown sections now; this asserts the Bash one keeps content AND position, and
    # that it does not duplicate the file while doing it.
    [ "$(grep -c "^| Master |" "$install_target/.ai/roles/ROLE_ASSIGNMENT.md")" = "1" ]
    check "--force does not duplicate the role file" $?

    grep -q "custom row must survive" "$install_target/.ai/roles/ROLE_ASSIGNMENT.md"
    check "--force preserves a section the project added to the role file" $?

    tr -d '' < "$install_target/.ai/roles/ROLE_ASSIGNMENT.md" | tr '
' ' ' |         grep -q "## Current Binding.*## Role Swap History.*## Role Meanings"
    check "--force keeps the preserved section in its original position" $?

    [ -f "$install_target/DECISIONS.md" ] && grep -q "a durable decision" "$install_target/DECISIONS.md"
    check "--force preserves an accumulated decision log" $?

    cmp -s "$install_target/scripts/handoff.ps1" "$REPO_ROOT/templates/scripts/handoff.ps1"
    check "--force refreshes stale managed scripts" $?

    [ ! -e "$install_target/HANDOFF.cmd" ]
    check "install.sh --force does not install the Windows launcher either" $?

    next_out="$(cd "$install_target" && bash scripts/handoff.sh next 2>&1)"
    next_code=$?
    [ "$next_code" -eq 0 ] && echo "$next_out" | grep -qE "Open:[[:space:]]+Codex[[:space:]]+\(role: Implementer\)"
    check "updated install routes the live turn to Codex Implementer" $? "$next_out"
fi

# A malformed live binding must fail before any managed target file changes.
malformed_target="$FIXTURE_ROOT/bash-malformed-update-target"
mkdir -p "$malformed_target"
git -C "$malformed_target" init -q
bash "$SCRIPT_DIR/install.sh" "$malformed_target" >/dev/null 2>&1
cat > "$malformed_target/.ai/roles/ROLE_ASSIGNMENT.md" <<'EOF'
# Malformed role assignment: Reviewer row is missing
| Role | Tool |
|---|---|
| Master | Claude Code |
| Implementer | Codex |
EOF
if [ -z "$HASH_TOOL" ]; then
    check "malformed update preflight can be verified" 1 "no portable hash tool found"
else
    malformed_handoff_before="$(hash_file "$malformed_target/AI_HANDOFF.md")"
    malformed_script_before="$(hash_file "$malformed_target/scripts/handoff.ps1")"
    malformed_out="$(bash "$SCRIPT_DIR/install.sh" "$malformed_target" --force 2>&1)"
    malformed_code=$?
    [ "$malformed_code" -ne 0 ] && echo "$malformed_out" | grep -q "cannot be parsed exactly"
    check "malformed role binding blocks --force" $? "$malformed_out"
    [ "$malformed_handoff_before" = "$(hash_file "$malformed_target/AI_HANDOFF.md")" ] && \
        [ "$malformed_script_before" = "$(hash_file "$malformed_target/scripts/handoff.ps1")" ]
    check "blocked malformed update changes no coordination or managed files" $?
fi

# === Mirror parity ===
echo "[bash] Mirror parity (canonical <-> template)"
mirror_match() {
    # mirror_match <left> <right> -> 0 if identical
    [ -f "$REPO_ROOT/$1" ] && [ -f "$REPO_ROOT/$2" ] && cmp -s "$REPO_ROOT/$1" "$REPO_ROOT/$2"
}
for f in scripts/handoff.ps1 scripts/handoff.sh scripts/protocol-tests.ps1 scripts/protocol-tests.sh; do
    if [ -f "$REPO_ROOT/$f" ] && [ -f "$REPO_ROOT/templates/$f" ]; then
        mirror_match "$f" "templates/$f"
        check "mirror: $f" $?
    fi
done
can="$REPO_ROOT/.ai/skills/codex-claude-handoff"
tpl="$REPO_ROOT/templates/.ai/skills/codex-claude-handoff"
if [ -d "$can" ]; then
    ok=0
    for cf in "$can"/*; do
        [ -f "$cf" ] || continue
        name="$(basename "$cf")"
        cmp -s "$cf" "$tpl/$name" || ok=1
    done
    check "canonical/template .ai skill files match" $ok
fi

# Shell scripts must keep LF: a Windows clone with core.autocrlf=true checks them out as
# CRLF, and the release package is built from the working tree.
grep -Eq '^\*\.sh[[:space:]]+text[[:space:]]+eol=lf[[:space:]]*$' "$REPO_ROOT/.gitattributes" 2>/dev/null
check ".gitattributes pins shell scripts to LF" $?
cr_files=""
for f in scripts/handoff.sh scripts/install.sh templates/scripts/handoff.sh \
         .agents/skills/codex-claude-handoff/assets/package/templates/scripts/handoff.sh \
         .agents/skills/codex-claude-handoff/scripts/setup.sh; do
    [ -f "$REPO_ROOT/$f" ] || continue
    if [ "$(tr -cd '\r' < "$REPO_ROOT/$f" | wc -c)" -gt 0 ]; then cr_files="$cr_files $f"; fi
done
[ -z "$cr_files" ]
check "shell scripts in the working tree have LF line endings" $? "CRLF in:$cr_files"

# v3.9.0: the Bash installer writes the same Claude Code deny rules as install.ps1.
echo "[bash] Credential read guard"
guard_target="$FIXTURE_ROOT/bash-guard-target"
mkdir -p "$guard_target"
git -C "$guard_target" init -q
guard_out="$(bash "$SCRIPT_DIR/install.sh" "$guard_target" 2>&1)"
guard_ok=0
while IFS= read -r rule || [ -n "$rule" ]; do
    rule="${rule%$'\r'}"
    case "$rule" in ""|\#*) continue ;; esac
    grep -qF "\"$rule\"" "$guard_target/.claude/settings.json" 2>/dev/null || guard_ok=1
done < "$REPO_ROOT/templates/.ai/skills/codex-claude-handoff/CREDENTIAL_READ_DENY.txt"
printf '%s' "$guard_out" | grep -q "Credential read guard: created" || guard_ok=1
check "bash fresh install writes every Claude Code deny rule" $guard_ok "$guard_out"

guard_again="$(bash "$SCRIPT_DIR/install.sh" "$guard_target" --force 2>&1)"
dup_ok=0
if ! printf '%s' "$guard_again" | grep -q "could not be merged safely"; then
    printf '%s' "$guard_again" | grep -q "Credential read guard: already present" || dup_ok=1
fi
[ "$(grep -cF '"Read(.mcp.json)"' "$guard_target/.claude/settings.json")" -eq 1 ] || dup_ok=1
check "bash --force upgrade adds no duplicate deny rules" $dup_ok "$guard_again"

# --- v3.4.3: execute the Bash exact-scope parser against a real repository ----------
# Until now the Bash parser was covered only by source-level assertions inside the
# PowerShell suite: nobody ran it. It carries the same exact-scope semantics as
# PowerShell, and v3.4.1 rewrote it for NUL-delimited parsing, so it needs to be
# exercised, not read.

scope_fixture() {
    # scope_fixture <dir> <declared-list-file> ; creates a repo whose Changed Files
    # section names exactly the paths it creates.
    local d="$1"
    mkdir -p "$d/.ai/roles"
    ( cd "$d" && git init -q . && git config user.email t@e.com && git config user.name T ) >/dev/null 2>&1
    cat > "$d/.ai/roles/ROLE_ASSIGNMENT.md" <<'ROLES'
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Codex |
| Implementer | Claude Code |
ROLES
    printf 'x\n' > "$d/baseline.md"
    ( cd "$d" && git add -A && git commit -q -m base ) >/dev/null 2>&1
}

write_handoff() {
    # write_handoff <dir> <path...> ; REVIEW_DONE/User with the given Changed Files
    local d="$1"; shift
    {
        printf '# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n'
        printf -- '- Last Updated By: Test\n- Last Updated At: 2026-08-31\n- Current Task: bash scope fixture\n\n'
        printf '## Task Actors\n- Implementer: Claude Code\n- Reviewer: Codex\n\n## Changed Files\n'
        for f in "$@"; do printf -- '- %s\n' "$f"; done
        printf '\n'
    } > "$d/AI_HANDOFF.md"
}

BASH_TMP="$(mktemp -d 2>/dev/null || echo "")"
if [ -z "$BASH_TMP" ]; then
    check "bash exact-scope: temp directory available" 1 "mktemp failed"
else
    # A spaced path, a non-ASCII path built from UTF-8 bytes, a nested path, and a rename.
    HEB=$(printf '\xd7\x9e\xd7\xa1\xd7\x9e\xd7\x9a')

    FX="$BASH_TMP/ok"; mkdir -p "$FX"; scope_fixture "$FX"
    printf 'a\n' > "$FX/a space.md"
    printf 'b\n' > "$FX/$HEB.md"
    mkdir -p "$FX/nested/deeper"; printf 'c\n' > "$FX/nested/deeper/$HEB.md"
    ( cd "$FX" && git mv baseline.md "renamed file.md" ) >/dev/null 2>&1
    write_handoff "$FX" "a space.md" "$HEB.md" "nested/deeper/$HEB.md" "renamed file.md"
    out="$( cd "$FX" && bash "$HANDOFF_SH" commit-check 2>&1 )"
    printf '%s' "$out" | grep -q "Commit: ALLOWED"
    check "bash exact-scope accepts spaced, non-ASCII, nested and renamed paths" $?

    printf '%s' "$out" | grep -q "does not match"
    if [ $? -eq 0 ]; then check "bash exact-scope reports no mismatch for a matching set" 1 "$out"; else check "bash exact-scope reports no mismatch for a matching set" 0; fi

    # An undeclared file must still block.
    FX2="$BASH_TMP/extra"; mkdir -p "$FX2"; scope_fixture "$FX2"
    printf 'a\n' > "$FX2/a space.md"
    printf 'z\n' > "$FX2/undeclared.md"
    write_handoff "$FX2" "a space.md"
    out2="$( cd "$FX2" && bash "$HANDOFF_SH" commit-check 2>&1 )"
    printf '%s' "$out2" | grep -q "does not match"
    check "bash exact-scope still blocks an undeclared file" $?

    # v3.10.1: agents annotate entries. "- `path` (a note)" and "- path (new)" name the path;
    # a filename that really ends in a parenthesis, such as "Copy (2).md", is kept whole.
    FXA="$BASH_TMP/annotated"; mkdir -p "$FXA"; scope_fixture "$FXA"
    printf 'a\n' > "$FXA/a space.md"
    printf 'n\n' > "$FXA/new.md"
    printf 'c\n' > "$FXA/Copy (2).md"
    write_handoff "$FXA" '`a space.md` (2-line change; see Done)' 'new.md (new)' 'Copy (2).md'
    outa="$( cd "$FXA" && bash "$HANDOFF_SH" commit-check 2>&1 )"
    printf '%s' "$outa" | grep -q "Commit: ALLOWED"
    check "bash exact-scope reads annotated Changed Files entries" $? "$outa"

    # git status failing must block, never approve a partial set.
    FX3="$BASH_TMP/nogit"; mkdir -p "$FX3/.ai/roles"
    cp "$FX/.ai/roles/ROLE_ASSIGNMENT.md" "$FX3/.ai/roles/ROLE_ASSIGNMENT.md"
    write_handoff "$FX3" "a space.md"
    out3="$( cd "$FX3" && bash "$HANDOFF_SH" commit-check 2>&1 )"
    printf '%s' "$out3" | grep -q "BLOCKED - git status failed"
    check "bash exact-scope blocks when git status fails" $?

    # v3.8.0: NEXT_TURN.md carries a line-numbered section map of AI_HANDOFF.md so the
    # next actor reads only the sections its turn needs. The numbers must be right.
    FX4="$BASH_TMP/map"; mkdir -p "$FX4"; scope_fixture "$FX4"
    write_handoff "$FX4" "a space.md"
    ( cd "$FX4" && bash "$HANDOFF_SH" next ) >/dev/null 2>&1
    grep -q '^## AI_HANDOFF.md Sections (line numbers)$' "$FX4/NEXT_TURN.md" 2>/dev/null
    check "bash next writes a section map of AI_HANDOFF.md" $?

    map_ok=0
    map_count=0
    while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | tr -d '\r')"
        n="${entry#- line }"; n="${n%%:*}"
        heading="${entry#*: }"
        actual="$(sed -n "${n}p" "$FX4/AI_HANDOFF.md" | tr -d '\r')"
        [ "$actual" = "$heading" ] || map_ok=1
        map_count=$((map_count + 1))
    done < <(grep '^- line [0-9][0-9]*: ## ' "$FX4/NEXT_TURN.md" 2>/dev/null)
    expected_count="$(grep -c '^## ' "$FX4/AI_HANDOFF.md")"
    if [ "$map_count" -eq 0 ] || [ "$map_count" -ne "$expected_count" ]; then map_ok=1; fi
    check "bash section map points at every AI_HANDOFF.md heading" $map_ok "mapped $map_count of $expected_count"

    # v3.10.0: NEXT_TURN.md names the model for the turn, resolved the way handoff.ps1
    # resolves it: environment, then MODEL_ROUTING.json, then inherit.
    model_section() {
        # model_section <fixture> -> prints the lines under "## Model For This Turn"
        tr -d '\r' < "$1/NEXT_TURN.md" | awk '/^## Model For This Turn$/{s=1;next} s&&/^$/{exit} s{print}'
    }
    set_routing() {
        mkdir -p "$1/.ai/skills/codex-claude-handoff"
        printf '%s\n' "$2" > "$1/.ai/skills/codex-claude-handoff/MODEL_ROUTING.json"
    }
    set_profile() {
        awk -v p="$2" '{print} /^- Current Task: /{print "- Model Profile: " p}' "$1/AI_HANDOFF.md" > "$1/AI_HANDOFF.tmp" && mv "$1/AI_HANDOFF.tmp" "$1/AI_HANDOFF.md"
    }

    FX5="$(make_fixture NEEDS_ANALYSIS Master)"
    set_routing "$FX5" '{
  "schemaVersion": 1,
  "profiles": {
    "standard": {
      "claudeModel": "test-claude-standard",
      "codexModel": "test-codex-standard"
    },
    "high_reasoning": {
      "claudeModel": "inherit",
      "codexModel": "test-codex-high"
    }
  }
}'
    ( cd "$FX5" && bash "$HANDOFF_SH" next ) >/dev/null 2>&1
    model_section "$FX5" | grep -qx 'Codex model: test-codex-standard (MODEL_ROUTING.json)'
    check "bash next names the Codex model from codexModel" $?
    model_section "$FX5" | grep -q 'start a new window on this one instead of switching inside the conversation'
    check "bash next says to start a new window rather than switch models" $?

    ( cd "$FX5" && HANDOFF_CODEX_MODEL_STANDARD=test-env-codex bash "$HANDOFF_SH" next ) >/dev/null 2>&1
    model_section "$FX5" | grep -qx 'Codex model: test-env-codex (environment HANDOFF_CODEX_MODEL_STANDARD)'
    check "bash next lets HANDOFF_CODEX_MODEL_<PROFILE> override the file" $?

    set_profile "$FX5" high_reasoning
    ( cd "$FX5" && bash "$HANDOFF_SH" next ) >/dev/null 2>&1
    model_section "$FX5" | grep -qx 'Codex model: test-codex-high (MODEL_ROUTING.json)'
    check "bash next reads the high_reasoning profile, not its neighbour" $?

    FX6="$(make_fixture NEEDS_ANALYSIS Master)"
    set_routing "$FX6" '{"schemaVersion":1,"profiles":{"standard":{"claudeModel":"inherit"},"economy":{"codexModel":"wrong-neighbour"}}}'
    ( cd "$FX6" && bash "$HANDOFF_SH" next ) >/dev/null 2>&1
    model_section "$FX6" | grep -qx 'Codex model: inherit (built-in fallback)'
    check "bash next never reads a single-line neighbour profile's value" $?
    model_section "$FX6" | grep -qx 'No model is mapped for this profile: keep the model your window already uses.'
    check "bash next says to keep the window's model when none is mapped" $?

    FX7="$(make_fixture READY_FOR_IMPLEMENTATION Implementer)"
    set_routing "$FX7" '{
    "schemaVersion":  1,
    "profiles":  {
                     "standard":  {
                                      "claudeModel":  "test-claude-layout"
                                  }
                 }
}'
    ( cd "$FX7" && bash "$HANDOFF_SH" next ) >/dev/null 2>&1
    model_section "$FX7" | grep -qx 'Claude model: test-claude-layout (MODEL_ROUTING.json)'
    check "bash next names the Claude model for a Claude Code turn (models -Activate layout)" $?

    FX8="$(make_fixture REVIEW_DONE User)"
    ( cd "$FX8" && bash "$HANDOFF_SH" next ) >/dev/null 2>&1
    ! grep -q '^## Model For This Turn$' "$FX8/NEXT_TURN.md"
    check "bash next writes no model section for a User turn" $?

    rm -rf "$BASH_TMP"
fi

# --- v3.17.0: review independence - handoff.sh, next-step.sh and install.sh agree ---
echo "[bash] Review independence (v3.17.0)"
ri_roles() {
    # ri_roles <fixture> <tool> <mode-line or empty>: one tool in all three roles
    cat > "$1/.ai/roles/ROLE_ASSIGNMENT.md" <<EOF
# Role Assignment

## Current Binding

| Role | Tool |
|---|---|
| Master | $2 |
| Reviewer | $2 |
| Implementer | $2 |

$3
EOF
    {
        printf '# AI Handoff\n\n## Status\n- State: READY_FOR_REVIEW\n- Waiting For: Reviewer\n'
        printf -- '- Last Updated By: Test\n- Last Updated At: 2026-11-18\n- Current Task: solo review task\n\n'
        printf '## Last Update\n- Actor: %s (Implementer)\n\n## Task Actors\n- Implementer: %s\n- Reviewer: %s\n\n' "$2" "$2" "$2"
        printf '## Changed Files\n- src/app.txt\n\n## Next Recommended Step\n- Review.\n'
    } > "$1/AI_HANDOFF.md"
}

RI_FX="$(make_fixture READY_FOR_REVIEW Reviewer)"
ri_roles "$RI_FX" "Codex" ""
run_handoff "$RI_FX" next
[ "$RH_CODE" -eq 12 ] && printf '%s' "$RH_OUT" | grep -q "Invalid role binding"
check "bash refuses one tool in both roles when no rule is declared" $? "$RH_OUT"

ri_roles "$RI_FX" "Codex" "Review Independence: fresh-context"
run_handoff "$RI_FX" next
[ "$RH_CODE" -eq 0 ] && grep -q '^## Review Independence$' "$RI_FX/NEXT_TURN.md" && \
    grep -q '^Single-vendor review: Codex is both Implementer and Reviewer\. It reviews in a separate read-only run started by the harness' "$RI_FX/NEXT_TURN.md"
check "bash next writes the single-vendor section under fresh-context" $? "$RH_OUT"

run_handoff "$RI_FX" status
printf '%s' "$RH_OUT" | grep -q "^Review:       Single-vendor review: Codex"
check "bash status names a single-vendor review" $? "$RH_OUT"

ri_done="$(mktemp -d "$FIXTURE_ROOT/fx.XXXXXX")"
mkdir -p "$ri_done/.ai/roles"
cp "$RI_FX/.ai/roles/ROLE_ASSIGNMENT.md" "$ri_done/.ai/roles/ROLE_ASSIGNMENT.md"
sed 's/^- State: READY_FOR_REVIEW$/- State: REVIEW_DONE/; s/^- Waiting For: Reviewer$/- Waiting For: User/' "$RI_FX/AI_HANDOFF.md" > "$ri_done/AI_HANDOFF.md"
run_handoff "$ri_done" status
printf '%s' "$RH_OUT" | grep -q "^Commit:       Blocked in handoff.sh - a single-vendor review" && ! printf '%s' "$RH_OUT" | grep -q "^Commit:       ALLOWED"
check "bash status does not call a single-vendor REVIEW_DONE ALLOWED" $? "$RH_OUT"

( cd "$RI_FX" && bash "$SCRIPT_DIR/next-step.sh" --prepare-file ) >/dev/null 2>&1
grep -q '^## Review Independence$' "$RI_FX/NEXT_TURN.md"
check "next-step.sh writes the same section" $?

ri_roles "$RI_FX" "Codex" "Review Independence: relaxed"
run_handoff "$RI_FX" next
[ "$RH_CODE" -eq 12 ] && printf '%s' "$RH_OUT" | grep -q "Invalid review independence"
check "bash fails closed on an unknown Review Independence value" $? "$RH_OUT"

printf 'Review Independence: fresh-context\nReview Independence: fresh-context\n' >> "$RI_FX/.ai/roles/ROLE_ASSIGNMENT.md"
sed -i 's/^Review Independence: relaxed$//' "$RI_FX/.ai/roles/ROLE_ASSIGNMENT.md"
run_handoff "$RI_FX" next
[ "$RH_CODE" -eq 12 ] && printf '%s' "$RH_OUT" | grep -q "declares 'Review Independence:' 2 times"
check "bash fails closed on a duplicated Review Independence line" $? "$RH_OUT"

# install.sh carries the declaration, and the binding it allows, across an upgrade.
RI_TARGET="$FIXTURE_ROOT/ri-install-target"
mkdir -p "$RI_TARGET"
git -C "$RI_TARGET" init -q
bash "$SCRIPT_DIR/install.sh" "$RI_TARGET" >/dev/null 2>&1
RI_ROLE_FILE="$RI_TARGET/.ai/roles/ROLE_ASSIGNMENT.md"
[ "$(tr -d '\r' < "$RI_ROLE_FILE" | grep -c '^Review Independence: separate-tool$')" -eq 1 ]
check "bash fresh install writes the separate-tool declaration once" $?
sed -i 's/^Review Independence: separate-tool/Review Independence: fresh-context/; s/^| Implementer | Claude Code |/| Implementer | Codex |/' "$RI_ROLE_FILE"
ri_up="$(bash "$SCRIPT_DIR/install.sh" "$RI_TARGET" --force 2>&1)"
ri_code=$?
[ "$ri_code" -eq 0 ] && [ "$(tr -d '\r' < "$RI_ROLE_FILE" | grep -c '^Review Independence:')" -eq 1 ] && \
    tr -d '\r' < "$RI_ROLE_FILE" | grep -q '^Review Independence: fresh-context$' && \
    tr -d '\r' < "$RI_ROLE_FILE" | grep -q '^| Implementer | Codex |$'
check "bash --force upgrade keeps fresh-context and the one-tool binding it allows" $? "$ri_up"
sed -i 's/^Review Independence: fresh-context/Review Independence: sometimes/' "$RI_ROLE_FILE"
ri_up="$(bash "$SCRIPT_DIR/install.sh" "$RI_TARGET" --force 2>&1)"
ri_code=$?
[ "$ri_code" -ne 0 ] && printf '%s' "$ri_up" | grep -q "Review Independence"
check "bash --force upgrade refuses an invalid declaration" $? "$ri_up"

# v3.17.0 review fix: the line is read without regard to case, as handoff.ps1 reads it.
ri_roles "$RI_FX" "Codex" "review independence: Fresh-Context"
run_handoff "$RI_FX" next
[ "$RH_CODE" -eq 0 ] && grep -q '^## Review Independence$' "$RI_FX/NEXT_TURN.md"
check "bash reads a mis-cased fresh-context line, as handoff.ps1 does" $? "$RH_OUT"
RI_TARGET2="$FIXTURE_ROOT/ri-install-miscase"
mkdir -p "$RI_TARGET2"
git -C "$RI_TARGET2" init -q
bash "$SCRIPT_DIR/install.sh" "$RI_TARGET2" >/dev/null 2>&1
RI_ROLE_FILE2="$RI_TARGET2/.ai/roles/ROLE_ASSIGNMENT.md"
sed -i 's/^Review Independence: separate-tool/review independence: Fresh-Context/' "$RI_ROLE_FILE2"
ri_up="$(bash "$SCRIPT_DIR/install.sh" "$RI_TARGET2" --force 2>&1)"
ri_code=$?
[ "$ri_code" -eq 0 ] && [ "$(tr -d '\r' < "$RI_ROLE_FILE2" | grep -ci '^review independence:')" -eq 1 ] && \
    tr -d '\r' < "$RI_ROLE_FILE2" | grep -q '^Review Independence: fresh-context$'
check "bash --force upgrade keeps a mis-cased fresh-context line with two tools bound" $? "$ri_up"

# --- v3.18.0: first setup - the gate, setup, the installer, and the unknown-tool fix ---
echo "[bash] First setup (v3.18.0)"
su_fixture() {
    # su_fixture <setup-line or empty> [master reviewer implementer] -> fixture with the shipped handoff
    local dir; dir="$(mktemp -d "$FIXTURE_ROOT/su.XXXXXX")"
    mkdir -p "$dir/.ai/roles"
    {
        printf '# Role Assignment\n\n## Current Binding\n\n| Role | Tool |\n|---|---|\n'
        printf '| Master | %s |\n| Reviewer | %s |\n| Implementer | %s |\n\n' "${2:-Codex}" "${3:-Codex}" "${4:-Claude Code}"
        printf 'Review Independence: separate-tool\n'
        if [ -n "$1" ]; then printf '%s\n' "$1"; fi
        printf '\nThe User is always the approval point and is never one of these roles.\n'
    } > "$dir/.ai/roles/ROLE_ASSIGNMENT.md"
    tr -d '\r' < "$REPO_ROOT/templates/AI_HANDOFF.md" > "$dir/AI_HANDOFF.md"
    echo "$dir"
}
su_hashes() { printf '%s/%s' "$(hash_file "$1/.ai/roles/ROLE_ASSIGNMENT.md")" "$(hash_file "$1/AI_HANDOFF.md")"; }

SU_FX="$(su_fixture "Setup: pending")"
su_before="$(su_hashes "$SU_FX")"
su_miss=""
for su_cmd in next start commit-check cycle doctor release-check adapters ""; do
    if [ -n "$su_cmd" ]; then run_handoff "$SU_FX" "$su_cmd" </dev/null; else run_handoff "$SU_FX" </dev/null; fi
    if ! { [ "$RH_CODE" -eq 14 ] && printf '%s' "$RH_OUT" | grep -q "Setup required: this project has not chosen its players and its Master yet." && printf '%s' "$RH_OUT" | grep -q "Nothing was started and nothing was changed."; }; then
        su_miss="$su_miss [$su_cmd -> $RH_CODE]"
    fi
done
[ -z "$su_miss" ] && [ "$(su_hashes "$SU_FX")" = "$su_before" ]
check "bash: pending stops every command but status and setup with exit 14" $? "$su_miss"
run_handoff "$SU_FX" status
[ "$RH_CODE" -eq 0 ] && printf '%s' "$RH_OUT" | grep -q "^Setup:        NOT CONFIGURED" && ! printf '%s' "$RH_OUT" | grep -q "^Roles:        Master="
check "bash: pending status says NOT CONFIGURED and hides the template binding" $? "$RH_OUT"
run_handoff "$SU_FX" adapters
[ "$RH_CODE" -eq 14 ] && ! printf '%s' "$RH_OUT" | grep -q "^Role:"
check "bash: adapters is gated while pending, as in handoff.ps1" $? "$RH_OUT"
run_handoff "$SU_FX" setup </dev/null
[ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -q 'setup --players "Claude Code,Codex" --master "Claude Code" --yes' && [ "$(su_hashes "$SU_FX")" = "$su_before" ]
check "bash: setup without flags prints the flag form and changes nothing" $? "$RH_OUT"
run_handoff "$SU_FX" setup --players "Codex" </dev/null
[ "$RH_CODE" -eq 2 ] && [ "$(su_hashes "$SU_FX")" = "$su_before" ]
check "bash: setup without --yes and nothing on input cancels with exit 2" $? "$RH_OUT"
su_ref_fail=""
while IFS='|' read -r su_p su_m su_want; do
    if [ -n "$su_m" ]; then run_handoff "$SU_FX" setup --players "$su_p" --master "$su_m" --yes; else run_handoff "$SU_FX" setup --players "$su_p" --yes; fi
    { [ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -qF "$su_want"; } || su_ref_fail="$su_ref_fail [$su_p/$su_m]"
done <<'REFUSALS'
Gemini||Unknown player 'Gemini'
Codex|Claude Code|The Master must be one of the players
Claude Code,Codex||No Master is chosen for you
Claude Code,Codex|Gemini|Unknown Master 'Gemini'
 , ||Choose at least one player
REFUSALS
[ -z "$su_ref_fail" ] && [ "$(su_hashes "$SU_FX")" = "$su_before" ]
check "bash: setup refuses an unknown tool, a Master who is not a player, a missing Master and an empty list" $? "$su_ref_fail"

run_handoff "$SU_FX" setup --players "Claude Code,Codex" --master "Claude Code" --yes
su_text="$(tr -d '\r' < "$SU_FX/.ai/roles/ROLE_ASSIGNMENT.md")"
[ "$RH_CODE" -eq 0 ] && [ "$(role_tool "$SU_FX/.ai/roles/ROLE_ASSIGNMENT.md" Master)" = "Claude Code" ] && \
    [ "$(role_tool "$SU_FX/.ai/roles/ROLE_ASSIGNMENT.md" Implementer)" = "Claude Code" ] && \
    [ "$(role_tool "$SU_FX/.ai/roles/ROLE_ASSIGNMENT.md" Reviewer)" = "Codex" ] && \
    [ "$(printf '%s\n' "$su_text" | grep -c '^Setup:')" -eq 1 ] && printf '%s\n' "$su_text" | grep -q '^Setup: complete$' && \
    printf '%s\n' "$su_text" | grep -q '| User (handoff.sh setup) |$'
check "bash: setup writes the binding, Setup: complete and a history row" $? "$RH_OUT"
grep -q '^- Implementer: Claude Code$' "$SU_FX/AI_HANDOFF.md" && grep -q '^- Reviewer: Codex$' "$SU_FX/AI_HANDOFF.md"
check "bash: setup moves the install's Task Actors" $?
run_handoff "$SU_FX" next
[ "$RH_CODE" -eq 0 ]
check "bash: next runs clean right after setup" $? "$RH_OUT"

SU_SOLO="$(su_fixture "Setup: pending")"
run_handoff "$SU_SOLO" setup --players "Codex" --yes
[ "$RH_CODE" -eq 0 ] && tr -d '\r' < "$SU_SOLO/.ai/roles/ROLE_ASSIGNMENT.md" | grep -q '^Review Independence: fresh-context$' && \
    [ "$(role_tool "$SU_SOLO/.ai/roles/ROLE_ASSIGNMENT.md" Reviewer)" = "Codex" ] && printf '%s' "$RH_OUT" | grep -q "Two tools remain the recommended setup"
check "bash: one player is fresh-context, and the plan says it is weaker" $? "$RH_OUT"

SU_BAD="$(su_fixture "Setup: maybe")"
run_handoff "$SU_BAD" next
[ "$RH_CODE" -eq 12 ] && printf '%s' "$RH_OUT" | grep -q "Invalid setup line: ROLE_ASSIGNMENT.md declares 'Setup: maybe'"
check "bash: an unknown Setup value blocks through the role checkpoint" $? "$RH_OUT"
run_handoff "$SU_BAD" setup --players "Codex" --yes
[ "$RH_CODE" -eq 0 ] && [ "$(tr -d '\r' < "$SU_BAD/.ai/roles/ROLE_ASSIGNMENT.md" | grep -c '^Setup:')" -eq 1 ]
check "bash: setup repairs a broken Setup line that is the only problem" $? "$RH_OUT"
SU_DUP="$(su_fixture "Setup: complete")"
printf 'Setup: complete\n' >> "$SU_DUP/.ai/roles/ROLE_ASSIGNMENT.md"
run_handoff "$SU_DUP" next
[ "$RH_CODE" -eq 12 ] && printf '%s' "$RH_OUT" | grep -q "declares 'Setup:' 2 times"
check "bash: a duplicated Setup line fails closed" $? "$RH_OUT"

# Security scan fix: an unknown tool fails the checkpoint, as in handoff.ps1.
SU_GEM="$(su_fixture "" Gemini Gemini Gemini)"
sed -i 's/^Review Independence: separate-tool$/Review Independence: fresh-context/' "$SU_GEM/.ai/roles/ROLE_ASSIGNMENT.md"
printf '# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n- Current Task: t\n\n## Task Actors\n- Implementer: Gemini\n- Reviewer: Gemini\n\n## Changed Files\n- a.txt\n' > "$SU_GEM/AI_HANDOFF.md"
run_handoff "$SU_GEM" commit-check
[ "$RH_CODE" -eq 12 ] && ! printf '%s' "$RH_OUT" | grep -q "ALLOWED" && printf '%s' "$RH_OUT" | grep -q "Unrecognized tool identity 'Gemini'"
check "bash: one unknown tool in every role under fresh-context is refused, never ALLOWED" $? "$RH_OUT"
SU_ALIAS="$(su_fixture "")"
sed -i 's/^- Reviewer: Codex$/- Reviewer: Codex Window/' "$SU_ALIAS/AI_HANDOFF.md"
run_handoff "$SU_ALIAS" next
[ "$RH_CODE" -eq 0 ]
check "bash: an alias Task Actor that is the bound tool is not drift" $? "$RH_OUT"
SU_UNK="$(su_fixture "")"
sed -i 's/^- Implementer: Claude Code$/- Implementer: Gemini/' "$SU_UNK/AI_HANDOFF.md"
run_handoff "$SU_UNK" next
[ "$RH_CODE" -eq 12 ] && printf '%s' "$RH_OUT" | grep -q "Unrecognized Task Actors Implementer='Gemini'"
check "bash: an unknown Task Actor is refused" $? "$RH_OUT"

# The installer: fresh is pending, flags configure it, an upgrade carries the line.
SU_T1="$FIXTURE_ROOT/su-bash-target"
su_out="$(bash "$SCRIPT_DIR/install.sh" "$SU_T1" 2>&1)"
su_code=$?
[ "$su_code" -eq 0 ] && printf '%s' "$su_out" | grep -q "Setup: NOT CONFIGURED" && tr -d '\r' < "$SU_T1/.ai/roles/ROLE_ASSIGNMENT.md" | grep -q '^Setup: pending$'
check "bash: a fresh install is pending and says so" $? "$su_out"
bash "$SCRIPT_DIR/install.sh" "$SU_T1" --force >/dev/null 2>&1
[ "$(tr -d '\r' < "$SU_T1/.ai/roles/ROLE_ASSIGNMENT.md" | grep -c '^Setup: pending$')" -eq 1 ]
check "bash: an upgrade of a pending install stays pending" $?
sed -i '/^Setup:/d' "$SU_T1/.ai/roles/ROLE_ASSIGNMENT.md"
bash "$SCRIPT_DIR/install.sh" "$SU_T1" --force >/dev/null 2>&1
! tr -d '\r' < "$SU_T1/.ai/roles/ROLE_ASSIGNMENT.md" | grep -qi '^[[:space:]]*setup[[:space:]]*:'
check "bash: an upgrade of a v3.17.0-shaped install gains no Setup line" $?
SU_T2="$FIXTURE_ROOT/su-bash-target-flags"
su_out="$(bash "$SCRIPT_DIR/install.sh" "$SU_T2" --players "Claude Code,Codex" --master "Codex" 2>&1)"
su_code=$?
[ "$su_code" -eq 0 ] && tr -d '\r' < "$SU_T2/.ai/roles/ROLE_ASSIGNMENT.md" | grep -q '^Setup: complete$' && [ "$(role_tool "$SU_T2/.ai/roles/ROLE_ASSIGNMENT.md" Master)" = "Codex" ]
check "bash: install.sh --players --master configures the project" $? "$su_out"
# "Claude Code" alone would bind Claude Code everywhere, so these values tell the two apart.
su_out="$(bash "$SCRIPT_DIR/install.sh" "$SU_T2" --force --players "Claude Code" 2>&1)"
printf '%s' "$su_out" | grep -q -- "--players ignored" && [ "$(role_tool "$SU_T2/.ai/roles/ROLE_ASSIGNMENT.md" Master)" = "Codex" ] && \
    [ "$(role_tool "$SU_T2/.ai/roles/ROLE_ASSIGNMENT.md" Reviewer)" = "Claude Code" ] && [ "$(role_tool "$SU_T2/.ai/roles/ROLE_ASSIGNMENT.md" Implementer)" = "Codex" ]
check "bash: --players on a configured project is ignored, with the way to change it" $? "$su_out"
su_out="$(bash "$SCRIPT_DIR/install.sh" "$FIXTURE_ROOT/su-bash-target-bad" --players "Gemini" 2>&1)"
su_code=$?
[ "$su_code" -eq 1 ] && printf '%s' "$su_out" | grep -q "Unknown player 'Gemini'"
check "bash: install.sh with an unknown player fails and says why" $? "$su_out"
su_out="$(bash "$SCRIPT_DIR/install.sh" "$FIXTURE_ROOT/su-bash-target-m" --master "Codex" 2>&1)"
su_code=$?
[ "$su_code" -eq 1 ] && printf '%s' "$su_out" | grep -q -- "--master needs --players" && [ ! -d "$FIXTURE_ROOT/su-bash-target-m/.ai" ]
check "bash: install.sh --master alone fails before anything is copied" $? "$su_out"

# --- v3.18.0 review fixes ---
echo "[bash] First setup: review fixes (v3.18.0)"
SU_ADOPT="$(su_fixture "Setup: pending")"
printf '# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n- Current Task: hand made\n\n## Last Update\n- Verdict: APPROVED\n\n## Task Actors\n- Implementer: Codex\n- Reviewer: Claude Code\n\n## Changed Files\n- foo.txt\n' > "$SU_ADOPT/AI_HANDOFF.md"
su_before="$(su_hashes "$SU_ADOPT")"
run_handoff "$SU_ADOPT" setup --players "Claude Code,Codex" --master "Codex" --yes
[ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -q "setup does not adopt a record" && [ "$(su_hashes "$SU_ADOPT")" = "$su_before" ]
check "bash: pending setup refuses to adopt a hand-written record" $? "$RH_OUT"
SU_DONE="$(su_fixture "Setup: complete")"
sed -i 's/^- State: .*/- State: REVIEW_DONE/; s/^- Current Task: .*/- Current Task: Finished/' "$SU_DONE/AI_HANDOFF.md"
run_handoff "$SU_DONE" setup --players "Codex" --yes
[ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -q "requires PowerShell: pwsh scripts/handoff.ps1 setup"
check "bash: reconfiguring after the first task is left to PowerShell" $? "$RH_OUT"
su_miss=""
for su_form in '* Implementer: Codex' '-Implementer: Codex' '  - Implementer: Codex' '- implementer: Codex'; do
    SU_ACT="$(su_fixture "")"
    printf '# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n- Current Task: t\n\n## Task Actors\n%s\n- Reviewer: Codex\n\n## Changed Files\n- foo.txt\n' "$su_form" > "$SU_ACT/AI_HANDOFF.md"
    run_handoff "$SU_ACT" commit-check
    { [ "$RH_CODE" -eq 12 ] && ! printf '%s' "$RH_OUT" | grep -q "ALLOWED"; } || su_miss="$su_miss [$su_form]"
done
[ -z "$su_miss" ]
check "bash: every Task Actors form handoff.ps1 reads is read, and a self-review is refused" $? "$su_miss"
SU_LOW="$(su_fixture "")"
printf '| Role | Tool |\n|---|---|\n| master | Codex |\n| reviewer | Claude Code |\n| implementer | Codex |\n' > "$SU_LOW/.ai/roles/ROLE_ASSIGNMENT.md"
sed -i 's/^- Implementer: .*/- Implementer: Codex/; s/^- Reviewer: .*/- Reviewer: Claude Code/; s/^- State: .*/- State: READY_FOR_IMPLEMENTATION/; s/^- Waiting For: .*/- Waiting For: Implementer/' "$SU_LOW/AI_HANDOFF.md"
run_handoff "$SU_LOW" next
[ "$RH_CODE" -eq 0 ] && grep -q '^Actor: Codex (Implementer)$' "$SU_LOW/NEXT_TURN.md"
check "bash: lower-case role rows are read, not replaced by the built-in default" $? "$RH_OUT"
SU_NS="$(su_fixture "Setup: pending")"
( cd "$SU_NS" && bash "$SCRIPT_DIR/next-step.sh" --prepare-file ) >/dev/null 2>&1
su_code=$?
[ "$su_code" -eq 14 ] && [ ! -f "$SU_NS/NEXT_TURN.md" ]
check "bash: next-step.sh stops with exit 14 while setup is pending and writes nothing" $?
run_handoff "$SU_NS" next
printf '%s' "$RH_OUT" | grep -q "never chooses for them" && ! printf '%s' "$RH_OUT" | grep -q -- '--players "Claude Code,Codex" --master "Claude Code"'
check "bash: the exit-14 block shows placeholders, not a ready-made choice" $? "$RH_OUT"

# --- v3.18.0 second review ---
echo "[bash] First setup: second review (v3.18.0)"
SU_DUP2="$(su_fixture "Setup: pending")"
printf 'Setup: pending\n' >> "$SU_DUP2/.ai/roles/ROLE_ASSIGNMENT.md"
run_handoff "$SU_DUP2" next
[ "$RH_CODE" -eq 12 ] && printf '%s' "$RH_OUT" | grep -q "<one of the players>" && printf '%s' "$RH_OUT" | grep -q "never chooses for them" && \
    ! printf '%s' "$RH_OUT" | grep -Eq -- '--master "(Claude Code|Codex)"'
check "bash: the exit-12 block for a broken Setup line shows placeholders and says an agent must ask" $? "$RH_OUT"
su_miss=""
while IFS='|' read -r su_name su_head su_extra su_want; do
    SU_SEC="$(su_fixture "")"
    printf '# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n- Current Task: t\n\n%s\n- Implementer: Claude Code\n- Reviewer: Claude Code\n%s\n\n## Changed Files\n- foo.txt\n' "$su_head" "$su_extra" > "$SU_SEC/AI_HANDOFF.md"
    run_handoff "$SU_SEC" commit-check
    { [ "$RH_CODE" -eq "$su_want" ] && ! printf '%s' "$RH_OUT" | grep -q "ALLOWED"; } || su_miss="$su_miss [$su_name -> $RH_CODE]"
done <<'SECTIONS'
trailing space|## Task Actors ||12
lower case|## task actors||12
renamed|## Actors||1
two Reviewers|## Task Actors|- Reviewer: Codex|1
SECTIONS
[ -z "$su_miss" ]
check "bash: commit-check refuses a self-review however the Task Actors section is spelled, never ALLOWED" $? "$su_miss"
SU_AD="$(su_fixture "Setup: pending")"
run_handoff "$SU_AD" status
! printf '%s' "$RH_OUT" | grep -q "Adapters:"
check "bash: pending status does not offer the gated adapters command" $? "$RH_OUT"

# --- v3.18.0 third review: the section reader and the commit audit (the full table runs in
# protocol-tests.ps1, against handoff.ps1; these are the three reported cases) ---
echo "[bash] First setup: third review (v3.18.0)"
su_miss=""
while IFS='|' read -r su_name su_want su_body; do
    SU_T3="$(su_fixture "")"
    printf '| Role | Tool |\n|---|---|\n| Master | Claude Code |\n| Reviewer | Codex |\n| Implementer | Claude Code |\n' > "$SU_T3/.ai/roles/ROLE_ASSIGNMENT.md"
    printf "$su_body" > "$SU_T3/AI_HANDOFF.md"
    run_handoff "$SU_T3" commit-check
    { [ "$RH_CODE" -eq "$su_want" ] && ! printf '%s' "$RH_OUT" | grep -q "ALLOWED"; } || su_miss="$su_miss [$su_name -> $RH_CODE]"
done <<'ROWS'
adjacent duplicate Task Actors|12|# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n\n## Task Actors\n- Implementer: Claude Code\n- Reviewer: Codex\n## Task Actors\n- Reviewer: Claude Code\n\n## Changed Files\n- foo.txt\n
adjacent duplicate Status|1|# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n## Status\n- State: IMPLEMENTING\n- Waiting For: Implementer\n\n## Task Actors\n- Implementer: Claude Code\n- Reviewer: Codex\n\n## Changed Files\n- foo.txt\n
mixed bullets|1|# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n\n## Task Actors\n- Implementer: Claude Code\n- Reviewer: Claude Code\n* Reviewer: Codex\n\n## Changed Files\n- foo.txt\n
ROWS
[ -z "$su_miss" ]
check "bash: the three cases of the third review are refused, never ALLOWED" $? "$su_miss"

# --- v3.18.0 fourth review ---
echo "[bash] First setup: fourth review (v3.18.0)"
# The refuse set, kept HERE as a second, independent list (the guard in handoff.sh has its
# own), so this test does not trust the code under test. Each entry: UTF-8 bytes as printf
# octal escapes, then the code point the guard must name. C0 controls are generated below.
su_set=""
for su_n in 0 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 127; do
    su_set="$su_set$(printf '\\%03o' "$su_n")|$(printf 'U+%04X' "$su_n")
"
done
su_set="$su_set\\302\\205|U+0085
\\302\\240|U+00A0
\\341\\232\\200|U+1680
\\341\\240\\216|U+180E
\\342\\200\\200|U+2000
\\342\\200\\201|U+2001
\\342\\200\\202|U+2002
\\342\\200\\203|U+2003
\\342\\200\\204|U+2004
\\342\\200\\205|U+2005
\\342\\200\\206|U+2006
\\342\\200\\207|U+2007
\\342\\200\\210|U+2008
\\342\\200\\211|U+2009
\\342\\200\\212|U+200A
\\342\\200\\213|U+200B
\\342\\200\\250|U+2028
\\342\\200\\251|U+2029
\\342\\200\\257|U+202F
\\342\\201\\237|U+205F
\\343\\200\\200|U+3000
\\357\\273\\277|U+FEFF
\\342\\204\\252|U+212A
\\305\\277|U+017F
\\304\\260|U+0130
\\304\\261|U+0131
\\r|U+000D"
SU_G="$(su_fixture "")"
su_miss=""; su_count=0
while IFS='|' read -r su_esc su_cp; do
    [ -n "$su_esc" ] || continue
    for su_pos in line hash value; do
        case "$su_pos" in
            line)  su_line="$su_esc- Reviewer: Codex" ;;
            hash)  su_line="##${su_esc}x" ;;
            value) if [ "$su_cp" = "U+000D" ]; then su_line="- Reviewer: ${su_esc}Codex"; else su_line="- Reviewer: $su_esc"; fi ;;
        esac
        printf "# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n- Current Task: t\n\n## Task Actors\n- Implementer: Claude Code\n- Reviewer: Codex\n$su_line\n\n## Changed Files\n- foo.txt\n" > "$SU_G/AI_HANDOFF.md"
        run_handoff "$SU_G" commit-check </dev/null
        su_count=$((su_count + 1))
        { [ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -q "contains $su_cp, a character handoff.sh does not read" && ! printf '%s' "$RH_OUT" | grep -q "Commit: ALLOWED"; } || su_miss="$su_miss [$su_cp $su_pos -> $RH_CODE]"
    done
done <<EOF
$su_set
EOF
[ -z "$su_miss" ] && [ "$su_count" -eq 171 ]
check "bash: commit-check refuses every refuse-set character in three positions, naming it, never ALLOWED ($su_count runs)" $? "$su_miss"

# The role file is guarded too, for commit-check and for setup; nothing is written.
su_miss=""
for su_role_line in 'binding|| Master |\302\240Claude Code |' 'setup|Setup:\343\200\200pending'; do
    SU_R="$(su_fixture "Setup: pending")"
    su_what="${su_role_line%%|*}"; su_txt="${su_role_line#*|}"
    if [ "$su_what" = "binding" ]; then
        printf "# Role Assignment\n\n| Role | Tool |\n|---|---|\n$su_txt\n| Reviewer | Codex |\n| Implementer | Claude Code |\n\nSetup: pending\n" > "$SU_R/.ai/roles/ROLE_ASSIGNMENT.md"
    else
        printf "# Role Assignment\n\n| Role | Tool |\n|---|---|\n| Master | Codex |\n| Reviewer | Codex |\n| Implementer | Claude Code |\n\n$su_txt\n" > "$SU_R/.ai/roles/ROLE_ASSIGNMENT.md"
    fi
    su_before="$(su_hashes "$SU_R")"
    run_handoff "$SU_R" commit-check </dev/null
    { [ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -q ".ai/roles/ROLE_ASSIGNMENT.md line [0-9]* contains U+" && ! printf '%s' "$RH_OUT" | grep -q "Commit: ALLOWED"; } || su_miss="$su_miss [$su_what commit-check -> $RH_CODE]"
    run_handoff "$SU_R" setup --players "Codex" --yes </dev/null
    { [ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -q "setup: blocked" && printf '%s' "$RH_OUT" | grep -q "contains U+" && [ "$(su_hashes "$SU_R")" = "$su_before" ]; } || su_miss="$su_miss [$su_what setup -> $RH_CODE]"
done
[ -z "$su_miss" ]
check "bash: a refuse-set character in the role file blocks commit-check and setup, and nothing is written" $? "$su_miss"

# A lone CR that makes handoff.ps1 read a non-initial State, while Bash would read the install state.
SU_CR="$(su_fixture "Setup: pending")"
awk '{ print } /^- Current Task: Initial setup$/ { printf "- Note: x\r- State: REVIEW_DONE\n" }' "$SU_CR/AI_HANDOFF.md" > "$SU_CR/AI_HANDOFF.tmp" && mv "$SU_CR/AI_HANDOFF.tmp" "$SU_CR/AI_HANDOFF.md"
su_before="$(su_hashes "$SU_CR")"
run_handoff "$SU_CR" setup --players "Codex" --yes </dev/null
[ "$RH_CODE" -eq 1 ] && printf '%s' "$RH_OUT" | grep -q "AI_HANDOFF.md line [0-9]* contains U+000D" && [ "$(su_hashes "$SU_CR")" = "$su_before" ] && [ ! -d "$SU_CR/.ai/handoff-history" ]
check "bash: pending setup refuses a handoff PowerShell would read as non-initial through a lone CR; nothing written" $? "$RH_OUT"

# A large handoff file (a long tail section) gets the same answers as a small one.
SU_BIG="$(su_fixture "")"
printf '| Role | Tool |\n|---|---|\n| Master | Claude Code |\n| Reviewer | Codex |\n| Implementer | Claude Code |\n' > "$SU_BIG/.ai/roles/ROLE_ASSIGNMENT.md"
printf '# AI Handoff\n\n## Status\n- State: REVIEW_DONE\n- Waiting For: User\n- Current Task: t\n\n## Task Actors\n- Implementer: Claude Code\n- Reviewer: Codex\n\n## Changed Files\n- foo.txt\n' > "$SU_BIG/AI_HANDOFF.md"
( cd "$SU_BIG" && git init -q && git config user.email t@e && git config user.name t && git add -A && git commit -qm base ) >/dev/null 2>&1
printf 'x\n' > "$SU_BIG/foo.txt"
su_answers() {
    local c out
    for c in status next commit-check; do
        out="$(cd "$SU_BIG" && bash "$HANDOFF_SH" "$c" </dev/null 2>&1)"
        printf '%s=%s|%s\n' "$c" "$?" "$(printf '%s\n' "$out" | grep -E '^(State:|Commit:|Open:|Next actor:)' | head -n 3 | tr '\n' ';')"
    done
    out="$(cd "$SU_BIG" && bash "$SCRIPT_DIR/next-step.sh" --prepare-file </dev/null 2>&1)"
    printf 'next-step=%s|%s\n' "$?" "$(grep -E '^(Actor|State):' "$SU_BIG/NEXT_TURN.md" 2>/dev/null | tr '\n' ';')"
}
su_small="$(su_answers)"
{ printf '\n## Notes\n'; su_i=0; while [ $su_i -lt 7000 ]; do printf -- '- note line %05d padded with enough text to make the file large\n' "$su_i"; su_i=$((su_i + 1)); done; } >> "$SU_BIG/AI_HANDOFF.md"
su_size="$(wc -c < "$SU_BIG/AI_HANDOFF.md" | tr -d ' ')"
su_large="$(su_answers)"
[ "$su_size" -ge 400000 ] && [ "$su_small" = "$su_large" ] && printf '%s' "$su_large" | grep -q 'commit-check=0|'
check "bash: a ${su_size}-byte handoff gives the same answers and exit codes as a small one (status, next, commit-check, next-step.sh)" $? "small=[$su_small] large=[$su_large]"

# The test-only seam: 'restore' alone is a documented no-op, so setup succeeds.
SU_SEAM="$(su_fixture "Setup: pending")"
( cd "$SU_SEAM" && HANDOFF_TEST_SETUP_FAIL=restore bash "$HANDOFF_SH" setup --players "Codex" --yes </dev/null >/dev/null 2>&1 )
su_code=$?
[ "$su_code" -eq 0 ] && tr -d '\r' < "$SU_SEAM/.ai/roles/ROLE_ASSIGNMENT.md" | grep -q '^Setup: complete$'
check "bash: HANDOFF_TEST_SETUP_FAIL=restore alone is a no-op, as documented" $?

echo ""
echo "Results: $PASS passed, $FAIL failed."
if [ "$FAIL" -gt 0 ]; then
    echo "Failed checks:"
    printf '%b\n' "$FAILURES"
    exit 1
fi
exit 0
