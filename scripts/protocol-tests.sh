#!/usr/bin/env bash
# Protocol Test Harness (Bash companion) - codex-claude-handoff v2.1.0
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

echo ""
echo "Results: $PASS passed, $FAIL failed."
if [ "$FAIL" -gt 0 ]; then
    echo "Failed checks:"
    printf '%b\n' "$FAILURES"
    exit 1
fi
exit 0
