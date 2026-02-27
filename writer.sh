#!/usr/bin/env bash
# writer.sh — Session state writer for Multiplex
# Called by Claude Code hooks and status line to maintain session state files.
# Usage: writer.sh <event_type>
# Event types: status_line, notification, stop, session_start, session_end, tool_use
# Reads JSON from stdin for status_line, notification, stop, and tool_use events.

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

        # Read existing session state (activity + protect done/waiting)
        FILE="$SESSIONS_DIR/${SESSION_ID}.json"
        ACTIVITY=""
        NEW_STATUS="active"
        if [[ -f "$FILE" ]]; then
            PREV_STATUS=$(jq -r '.status // "active"' "$FILE" 2>/dev/null) || true
            PREV_CTX=$(jq -r '.context_pct // -1' "$FILE" 2>/dev/null) || true
            ACTIVITY=$(jq -r '.activity // empty' "$FILE" 2>/dev/null) || true
            if [[ "$PREV_STATUS" == "done" || "$PREV_STATUS" == "waiting" ]]; then
                if [[ "${CONTEXT_PCT%.*}" == "${PREV_CTX%.*}" ]]; then
                    NEW_STATUS="$PREV_STATUS"
                fi
            fi
        fi

        jq -n \
            --arg sid "$SESSION_ID" \
            --arg project "$PROJECT" \
            --arg cwd "$CWD" \
            --arg model "$MODEL" \
            --argjson ctx "$CONTEXT_PCT" \
            --arg status "$NEW_STATUS" \
            --argjson ts "$NOW" \
            --argjson pid "$PID" \
            --arg pane "$PANE" \
            --arg tsess "$TSESS" \
            --arg twin "$TWIN" \
            --arg activity "$ACTIVITY" \
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
                tmux_window: $twin,
                activity: $activity
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
            jq --argjson ts "$NOW" '.status = "waiting" | .last_update = $ts | .activity = "Waiting for input"' "$FILE" > "${FILE}.tmp" \
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
            CURRENT_STATUS=$(jq -r '.status // "active"' "$FILE" 2>/dev/null) || true
            if [[ "$CURRENT_STATUS" == "waiting" ]]; then
                jq --argjson ts "$NOW" '.last_update = $ts' "$FILE" > "${FILE}.tmp" \
                    && mv "${FILE}.tmp" "$FILE"
            else
                jq --argjson ts "$NOW" '.status = "done" | .last_update = $ts | .activity = "Done"' "$FILE" > "${FILE}.tmp" \
                    && mv "${FILE}.tmp" "$FILE"
            fi
        fi
        ;;

    session_start)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        if [[ -z "$SESSION_ID" ]]; then
            exit 0
        fi

        # Clean up ghost sessions from the same tmux pane
        PANE="${TMUX_PANE:-}"
        if [[ -n "$PANE" ]]; then
            for old_file in "$SESSIONS_DIR"/*.json; do
                [[ -f "$old_file" ]] || continue
                old_pane=$(jq -r '.tmux_pane // empty' "$old_file" 2>/dev/null) || continue
                old_sid=$(jq -r '.session_id // empty' "$old_file" 2>/dev/null) || continue
                if [[ "$old_pane" == "$PANE" && "$old_sid" != "$SESSION_ID" ]]; then
                    rm -f "$old_file"
                fi
            done
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
            --arg activity "Starting..." \
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
                tmux_window: $twin,
                activity: $activity
            }' > "$SESSIONS_DIR/${SESSION_ID}.json"
        ;;

    tool_use)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        if [[ -z "$SESSION_ID" ]]; then
            exit 0
        fi

        FILE="$SESSIONS_DIR/${SESSION_ID}.json"
        if [[ ! -f "$FILE" ]]; then
            exit 0
        fi

        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

        # Map tool name to short activity description
        case "$TOOL_NAME" in
            Read)
                FNAME=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
                ACTIVITY="Reading ${FNAME##*/}"
                ;;
            Edit)
                FNAME=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
                ACTIVITY="Editing ${FNAME##*/}"
                ;;
            Write)
                FNAME=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
                ACTIVITY="Writing ${FNAME##*/}"
                ;;
            Bash)
                CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
                if [[ ${#CMD} -gt 30 ]]; then
                    CMD="${CMD:0:30}…"
                fi
                ACTIVITY="$ ${CMD}"
                ;;
            Grep)
                PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty' 2>/dev/null)
                ACTIVITY="Searching: ${PATTERN}"
                ;;
            Glob)
                PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty' 2>/dev/null)
                ACTIVITY="Finding: ${PATTERN}"
                ;;
            Task)
                DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null)
                ACTIVITY="Agent: ${DESC}"
                ;;
            WebSearch)
                QUERY=$(echo "$INPUT" | jq -r '.tool_input.query // empty' 2>/dev/null)
                ACTIVITY="Searching: ${QUERY}"
                ;;
            WebFetch)
                ACTIVITY="Fetching web page"
                ;;
            *)
                ACTIVITY="$TOOL_NAME"
                ;;
        esac

        NOW=$(date +%s)
        jq --arg activity "$ACTIVITY" --argjson ts "$NOW" \
            '.activity = $activity | .last_update = $ts' "$FILE" > "${FILE}.tmp" \
            && mv "${FILE}.tmp" "$FILE"
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
