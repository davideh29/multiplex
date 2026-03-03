#!/usr/bin/env bash
# setup.sh — Install and configure Multiplex
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}!${RESET} $1"; }
fail() { echo -e "${RED}✗${RESET} $1"; }

echo -e "${BOLD}Multiplex Setup${RESET}"
echo ""

# -------------------------------------------------------------------
# 1. Check dependencies
# -------------------------------------------------------------------
echo -e "${BOLD}Checking dependencies...${RESET}"
missing=0
for cmd in bash jq tmux python3 flock; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd"
    else
        fail "$cmd — required"
        missing=1
    fi
done

if command -v ollama &>/dev/null; then
    ok "ollama"
else
    warn "ollama — not found (optional, needed for session summaries)"
fi

if [[ "$missing" -eq 1 ]]; then
    echo ""
    fail "Missing required dependencies. Install them and re-run."
    exit 1
fi
echo ""

# -------------------------------------------------------------------
# 2. Make scripts executable
# -------------------------------------------------------------------
echo -e "${BOLD}Making scripts executable...${RESET}"
chmod +x "$SCRIPT_DIR"/{mpx,mpx-switch,mpx-kill,tmpx,writer.sh,mpx-summarize,mpx-summarize-one}
ok "All scripts marked executable"
echo ""

# -------------------------------------------------------------------
# 3. Create sessions directory
# -------------------------------------------------------------------
mkdir -p "$SCRIPT_DIR/sessions"
ok "Sessions directory ready"
echo ""

# -------------------------------------------------------------------
# 4. Configure Claude Code hooks
# -------------------------------------------------------------------
echo -e "${BOLD}Configuring Claude Code hooks...${RESET}"

SETTINGS_FILE="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

WRITER="$SCRIPT_DIR/writer.sh"

# Build the hooks JSON that Multiplex needs
MPX_HOOKS=$(cat <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "$WRITER status_line"
  },
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "$WRITER notification" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "$WRITER stop" }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "$WRITER session_start" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "$WRITER session_end" }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "$WRITER tool_use" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "$WRITER permission_request" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "$WRITER post_tool_use" }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "$WRITER post_tool_use_failure" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$WRITER user_prompt" }] }],
    "SubagentStart": [{ "hooks": [{ "type": "command", "command": "$WRITER subagent_start" }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "command": "$WRITER subagent_stop" }] }]
  }
}
EOF
)

if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "$MPX_HOOKS" | jq '.' > "$SETTINGS_FILE"
    ok "Created $SETTINGS_FILE"
else
    # Merge hooks into existing settings
    EXISTING=$(cat "$SETTINGS_FILE")

    # statusLine: overwrite (can only have one)
    MERGED=$(echo "$EXISTING" | jq --argjson sl "$(echo "$MPX_HOOKS" | jq '.statusLine')" \
        '.statusLine = $sl')

    # hooks: merge per-event, avoiding duplicates
    HOOK_EVENTS=("Notification" "Stop" "SessionStart" "SessionEnd" "PreToolUse" "PermissionRequest" "PostToolUse" "PostToolUseFailure" "UserPromptSubmit" "SubagentStart" "SubagentStop")

    for event in "${HOOK_EVENTS[@]}"; do
        hook_cmd="$WRITER $(echo "$MPX_HOOKS" | jq -r ".hooks.${event}[0].hooks[0].command" | awk '{print $NF}')"
        # Get the new hook entry for this event
        new_entry=$(echo "$MPX_HOOKS" | jq ".hooks.${event}[0]")

        # Check if this writer.sh command is already present
        existing_cmds=$(echo "$MERGED" | jq -r ".hooks.${event}[]?.hooks[]?.command // empty" 2>/dev/null)
        if echo "$existing_cmds" | grep -qF "writer.sh"; then
            # Already has a writer.sh hook for this event — skip
            continue
        fi

        # Append the new hook entry to the event array
        MERGED=$(echo "$MERGED" | jq --argjson entry "$new_entry" \
            ".hooks.${event} = ((.hooks.${event} // []) + [\$entry])")
    done

    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
    ok "Merged hooks into $SETTINGS_FILE"
fi
echo ""

# -------------------------------------------------------------------
# 5. Configure tmux keybindings
# -------------------------------------------------------------------
echo -e "${BOLD}Tmux keybindings${RESET}"
echo ""
echo "Add these to ~/.tmux.conf for quick session switching:"
echo ""
for i in $(seq 1 9); do
    echo "  bind $i run-shell -b \"$SCRIPT_DIR/mpx-switch $i\""
done
echo "  bind Q run-shell -b \"$SCRIPT_DIR/mpx-kill\""
echo ""

TMUX_CONF="$HOME/.tmux.conf"
if [[ -f "$TMUX_CONF" ]] && grep -qF "mpx-switch" "$TMUX_CONF"; then
    ok "Keybindings already present in $TMUX_CONF"
else
    read -rp "Append keybindings to ~/.tmux.conf? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo "" >> "$TMUX_CONF"
        echo "# Multiplex session switching" >> "$TMUX_CONF"
        for i in $(seq 1 9); do
            echo "bind $i run-shell -b \"$SCRIPT_DIR/mpx-switch $i\"" >> "$TMUX_CONF"
        done
        echo "bind Q run-shell -b \"$SCRIPT_DIR/mpx-kill\"" >> "$TMUX_CONF"
        ok "Appended keybindings to $TMUX_CONF"
    else
        warn "Skipped — add them manually when ready"
    fi
fi
echo ""

# -------------------------------------------------------------------
# 6. PATH setup
# -------------------------------------------------------------------
echo -e "${BOLD}PATH setup${RESET}"
echo ""
echo "Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
echo ""
echo "  export PATH=\"$SCRIPT_DIR:\$PATH\""
echo ""

echo -e "${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo "Quick start:"
echo "  tmpx           — launch a new workspace"
echo "  mpx            — open the dashboard standalone"
