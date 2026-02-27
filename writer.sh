#!/usr/bin/env bash
# writer.sh — Session state writer for Multiplex
# Called by Claude Code hooks and status line to maintain session state files.
# Usage: writer.sh <event_type>
# Event types: status_line, notification, stop, session_start, session_end
# Reads JSON from stdin for status_line, notification, and stop events.

set -euo pipefail

SESSIONS_DIR="$HOME/workplace/multiplex/sessions"
mkdir -p "$SESSIONS_DIR"

EVENT="$1"

find_claude_pid() {
    local pid="${PPID:-0}"
    while [[ "$pid" -gt 1 ]]; do
        local comm
        comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
        if [[ "$comm" == "claude" ]]; then
            echo "$pid"
            return
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
    done
    echo "0"
}

get_tmux_info() {
    local pane="${TMUX_PANE:-}"
    local tmux_session="" tmux_window=""
    if [[ -n "$pane" ]]; then
        local info
        info=$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null) || true
        if [[ -n "$info" ]]; then
            tmux_session="${info%%:*}"
            tmux_window="${info##*:}"
        fi
    fi
    echo "$pane" "$tmux_session" "$tmux_window"
}

case "$EVENT" in
    status_line)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        if [[ -z "$SESSION_ID" ]]; then
            exit 0
        fi

        CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
        MODEL=$(echo "$INPUT" | jq -r '.model.display_name // .model.id // empty')
        CONTEXT_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
        PROJECT=$(echo "${CWD:-unknown}" | sed 's|.*/\([^/]*/[^/]*\)$|\1|')
        PID=$(find_claude_pid)
        NOW=$(date +%s)

        read -r PANE TSESS TWIN <<< "$(get_tmux_info)"

        jq -n \
            --arg sid "$SESSION_ID" \
            --arg project "$PROJECT" \
            --arg cwd "$CWD" \
            --arg model "$MODEL" \
            --argjson ctx "$CONTEXT_PCT" \
            --arg status "active" \
            --argjson ts "$NOW" \
            --argjson pid "$PID" \
            --arg pane "$PANE" \
            --arg tsess "$TSESS" \
            --arg twin "$TWIN" \
            '{
                session_id: $sid,
                project: $project,
                cwd: $cwd,
                model: $model,
                context_pct: $ctx,
                status: $status,
                last_update: $ts,
                pid: $pid,
                tmux_pane: $pane,
                tmux_session: $tsess,
                tmux_window: $twin
            }' > "$SESSIONS_DIR/${SESSION_ID}.json"

        # Output status line text for Claude Code
        CTX_INT=${CONTEXT_PCT%.*}
        echo "${MODEL:-?} │ ctx ${CTX_INT:-0}% │ ${PROJECT}"
        ;;

    notification)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        if [[ -z "$SESSION_ID" ]]; then
            exit 0
        fi

        FILE="$SESSIONS_DIR/${SESSION_ID}.json"
        if [[ -f "$FILE" ]]; then
            NOW=$(date +%s)
            jq --argjson ts "$NOW" '.status = "waiting" | .last_update = $ts' "$FILE" > "${FILE}.tmp" \
                && mv "${FILE}.tmp" "$FILE"
        fi
        ;;

    stop)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        if [[ -z "$SESSION_ID" ]]; then
            exit 0
        fi

        FILE="$SESSIONS_DIR/${SESSION_ID}.json"
        if [[ -f "$FILE" ]]; then
            NOW=$(date +%s)
            jq --argjson ts "$NOW" '.status = "done" | .last_update = $ts' "$FILE" > "${FILE}.tmp" \
                && mv "${FILE}.tmp" "$FILE"
        fi
        ;;

    session_start)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        if [[ -z "$SESSION_ID" ]]; then
            exit 0
        fi

        CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
        PROJECT=$(echo "${CWD:-unknown}" | sed 's|.*/\([^/]*/[^/]*\)$|\1|')
        PID=$(find_claude_pid)
        NOW=$(date +%s)

        read -r PANE TSESS TWIN <<< "$(get_tmux_info)"

        jq -n \
            --arg sid "$SESSION_ID" \
            --arg project "$PROJECT" \
            --arg cwd "$CWD" \
            --arg model "" \
            --argjson ctx 0 \
            --arg status "waiting" \
            --argjson ts "$NOW" \
            --argjson pid "$PID" \
            --arg pane "$PANE" \
            --arg tsess "$TSESS" \
            --arg twin "$TWIN" \
            '{
                session_id: $sid,
                project: $project,
                cwd: $cwd,
                model: $model,
                context_pct: $ctx,
                status: $status,
                last_update: $ts,
                pid: $pid,
                tmux_pane: $pane,
                tmux_session: $tsess,
                tmux_window: $twin
            }' > "$SESSIONS_DIR/${SESSION_ID}.json"
        ;;

    session_end)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        if [[ -z "$SESSION_ID" ]]; then
            exit 0
        fi

        rm -f "$SESSIONS_DIR/${SESSION_ID}.json"
        ;;

    *)
        echo "Unknown event: $EVENT" >&2
        exit 1
        ;;
esac
