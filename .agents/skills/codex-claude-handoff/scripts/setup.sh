#!/usr/bin/env bash

set -euo pipefail

TARGET_PATH="${1:-$PWD}"
REFRESH="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_ROOT="$SKILL_ROOT/assets/package"
INSTALLER="$PACKAGE_ROOT/scripts/install.sh"

if [ ! -d "$TARGET_PATH/.git" ]; then
    echo "Setup requires a Git repository. Run 'git init' and create a clean baseline commit first: $TARGET_PATH" >&2
    exit 2
fi

if [ ! -f "$INSTALLER" ]; then
    echo "Bundled installer is missing from the skill package: $INSTALLER" >&2
    exit 3
fi

if [ -f "$TARGET_PATH/.ai/skills/codex-claude-handoff/VERSION" ] && [ "$REFRESH" != "--refresh" ]; then
    INSTALLED_VERSION="$(tr -d '\r\n' < "$TARGET_PATH/.ai/skills/codex-claude-handoff/VERSION")"
    echo "codex-claude-handoff is already installed (version $INSTALLED_VERSION)."
    echo "Re-run with --refresh only when the user explicitly approves refreshing managed protocol files."
    exit 0
fi

bash "$INSTALLER" "$TARGET_PATH" --force
# v3.18.0: handoff.sh has no doctor command, so this step used to fail every setup with
# "Unknown command: doctor". status is the read-only Bash health view.
(
    cd "$TARGET_PATH"
    bash scripts/handoff.sh status
)

# v3.18.0: a fresh install has not chosen its players and its Master. Say so; never choose.
if tr -d '\r' < "$TARGET_PATH/.ai/roles/ROLE_ASSIGNMENT.md" | grep -Eiq '^[[:space:]]*([-*][[:space:]]+)?setup[[:space:]]*:[[:space:]]*pending[[:space:]]*$'; then
    echo ""
    echo "Setup: NOT CONFIGURED. Work commands are blocked (exit 14) until the players and the Master are chosen."
    echo "Ask the user which tools work on this project and which one is the Master, then run in the project:"
    echo "  bash scripts/handoff.sh setup --players \"<Claude Code, Codex, or both>\" --master \"<one of the players>\""
fi

echo ""
echo "Skill setup complete. Review the installed files before committing them."
echo "No git commit, push, tag, release, deploy, database, or secret action was run."
echo ""
echo "After review, the usual stable install commit is:"
if [ -f "$TARGET_PATH/skills-lock.json" ]; then
    echo "  git add .agents .ai .claude scripts .gitignore skills-lock.json"
else
    echo "  git add .agents .ai .claude scripts .gitignore"
fi
echo '  git commit -m "Install codex-claude-handoff"'
