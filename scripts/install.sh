#!/usr/bin/env bash
# install.sh - Codex-Claude Handoff installer (Bash version, v0.15.0)
# Installs the handoff protocol into a target project.
# Usage: bash install.sh <target-project-path>

set -euo pipefail

TARGET_PATH="${1:-}"
if [ -z "$TARGET_PATH" ]; then
    echo "Usage: bash install.sh <target-project-path>"
    echo "Example: bash install.sh ~/projects/my-project"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates"

echo "Codex-Claude Handoff Installer"
echo "Target project: $TARGET_PATH"
echo ""

if [ ! -d "$TARGET_PATH" ]; then
    echo "Error: Target path does not exist: $TARGET_PATH"
    exit 1
fi

if [ ! -d "$TEMPLATES_DIR" ]; then
    echo "Error: Templates folder not found: $TEMPLATES_DIR"
    exit 1
fi

# Copy a file without overwriting an existing one.
copy_if_absent() {
    local src="$1" dst="$2" label="$3"
    local dst_dir; dst_dir="$(dirname "$dst")"
    if [ ! -f "$src" ]; then
        echo "Warning: Missing template file: $label"
        return
    fi
    if [ -f "$dst" ]; then
        echo "Skipped existing file: $label"
    else
        mkdir -p "$dst_dir"
        cp "$src" "$dst"
        echo "Copied: $label"
    fi
}

# Root protocol files
for f in AGENTS.md CLAUDE.md AI_HANDOFF.md AI_SEQUENCE.md; do
    copy_if_absent "$TEMPLATES_DIR/$f" "$TARGET_PATH/$f" "$f"
done

# Shared canonical skill files
SKILL_FILES=(
    ".ai/roles/ROLE_ASSIGNMENT.md"
    ".ai/skills/codex-claude-handoff/VERSION"
    ".ai/skills/codex-claude-handoff/README.md"
    ".ai/skills/codex-claude-handoff/SKILL.md"
    ".ai/skills/codex-claude-handoff/MASTER.md"
    ".ai/skills/codex-claude-handoff/IMPLEMENTER.md"
    ".ai/skills/codex-claude-handoff/PROTOCOL_METHOD.md"
    ".ai/skills/codex-claude-handoff/ADAPTERS.md"
    ".ai/skills/codex-claude-handoff/CODEX.md"
    ".ai/skills/codex-claude-handoff/CLAUDE.md"
    ".ai/skills/codex-claude-handoff/CAPABILITIES.md"
    ".agents/skills/codex-claude-handoff/SKILL.md"
    ".claude/skills/codex-claude-handoff/SKILL.md"
)

for rel in "${SKILL_FILES[@]}"; do
    copy_if_absent "$TEMPLATES_DIR/$rel" "$TARGET_PATH/$rel" "$rel"
done

# Workflow scripts
WORKFLOW_SCRIPTS=(
    "scripts/handoff.ps1"
    "scripts/next-step.ps1"
    "scripts/handoff.sh"
    "scripts/next-step.sh"
    "scripts/protocol-tests.ps1"
    "scripts/protocol-tests.sh"
)

for rel in "${WORKFLOW_SCRIPTS[@]}"; do
    copy_if_absent "$TEMPLATES_DIR/$rel" "$TARGET_PATH/$rel" "$rel"
done

# .gitignore: create or update
GITIGNORE_PATH="$TARGET_PATH/.gitignore"
RULES=("AI_HANDOFF.md" "NEXT_TURN.md" "USER_REQUEST.md" "HANDOFF_LOOP.log" "AI_SEQUENCE.md")

if [ ! -f "$GITIGNORE_PATH" ]; then
    printf '# Local AI handoff context\nAI_HANDOFF.md\nNEXT_TURN.md\nUSER_REQUEST.md\nHANDOFF_LOOP.log\nAI_SEQUENCE.md\n' > "$GITIGNORE_PATH"
    echo "Created .gitignore with AI_HANDOFF.md, NEXT_TURN.md, USER_REQUEST.md, HANDOFF_LOOP.log, and AI_SEQUENCE.md rules"
else
    ADDED=()
    for rule in "${RULES[@]}"; do
        if ! grep -qxF "$rule" "$GITIGNORE_PATH" 2>/dev/null; then
            printf '\n# Local AI handoff context\n%s\n' "$rule" >> "$GITIGNORE_PATH"
            ADDED+=("$rule")
        fi
    done
    if [ ${#ADDED[@]} -gt 0 ]; then
        echo "Added to .gitignore: ${ADDED[*]}"
    else
        echo ".gitignore already contains AI_HANDOFF.md, NEXT_TURN.md, USER_REQUEST.md, HANDOFF_LOOP.log, and AI_SEQUENCE.md"
    fi
fi

echo ""
echo "Install complete."
echo "Next steps:"
echo "1. Open AGENTS.md and customize the project context."
echo "2. Review CLAUDE.md."
echo "3. Use AI_HANDOFF.md to start the first task."
echo "4. Run workflow commands from the target project root:"
echo "   PowerShell (Windows / pwsh):  .\\scripts\\handoff.ps1 status"
echo "   Bash (macOS / Linux):         bash scripts/handoff.sh status"
echo ""
echo "On macOS/Linux, mark scripts executable after install:"
echo "   chmod +x scripts/handoff.sh scripts/next-step.sh scripts/protocol-tests.sh"
