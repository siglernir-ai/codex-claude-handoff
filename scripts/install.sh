#!/usr/bin/env bash
# Project-local installer. Default activation is opt-in; pass --always-on explicitly
# to install root AGENTS.md and CLAUDE.md instructions.

set -euo pipefail

TARGET_PATH="${1:-}"
if [ -z "$TARGET_PATH" ]; then
    echo "Usage: bash scripts/install.sh <target-project-path> [--force] [--always-on|--disable-always-on]"
    exit 1
fi
shift

FORCE=false
ALWAYS_ON=false
DISABLE_ALWAYS_ON=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --always-on) ALWAYS_ON=true ;;
        --disable-always-on) DISABLE_ALWAYS_ON=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

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
    mkdir -p "$(dirname "$TARGET_PATH/$rel")"
    cp -f "$src" "$TARGET_PATH/$rel"
done < <(find "$TEMPLATES_DIR" -type f -print0)

GITIGNORE_PATH="$TARGET_PATH/.gitignore"
if ! grep -qFx "AI_HANDOFF.md" "$GITIGNORE_PATH" 2>/dev/null; then
    printf '\n%s\n' "$(cat "$TEMPLATES_DIR/gitignore-snippet.txt")" >> "$GITIGNORE_PATH"
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
echo ""
echo "Check the installation:"
echo "  cd \"$TARGET_PATH\""
echo "  bash scripts/handoff.sh doctor"
echo ""

if $ALWAYS_ON; then
    echo "Always-on mode is enabled. Root agent instructions were installed."
else
    echo "Use it for one task in Codex:"
    echo '  $codex-claude-handoff'
    echo "  Describe the task you want completed through the full protocol."
    echo ""
    echo "For normal Codex work, do not select or mention the skill."
fi
