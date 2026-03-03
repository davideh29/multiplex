#!/usr/bin/env bash
# writer.sh — Session state writer for Multiplex
# Called by Claude Code hooks and status line to maintain session state files.
# Usage: writer.sh <event_type>
# Event types: status_line, notification, stop, session_start, session_end,
#              tool_use, permission_request, post_tool_use, post_tool_use_failure,
#              user_prompt, subagent_start, subagent_stop
#
# State machine: turn field tracks internal state, status is always derived.
# All handlers call update_session() which atomically updates state and derives status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SESSIONS_DIR="${SESSIONS_DIR:-$SCRIPT_DIR/sessions}"
mkdir -p "$SESSIONS_DIR"

EVENT="$1"

# Status derivation: single source of truth for status field
DERIVE_STATUS='
if .waiting_for_permission then .status = "waiting"
elif .turn == "done" then .status = "done"
elif .turn == "idle" then .status = "done"
elif .turn == "waiting" then .status = "waiting"
else .status = "active"
end'

# Ensure new schema fields exist (handles pre-v2 session files)
ENSURE_FIELDS='.waiting_for_permission = (.waiting_for_permission // false) | .subagents = (.subagents // {}) | .schema_version = 2'

# Atomic read-modify-write with flock. Applies expression, ensures schema fields, derives status.
# Usage: update_session <session_id> <jq_expr> [extra jq args...]
update_session() {
    local session_id="$1" jq_expr="$2"
    shift 2
    local file="$SESSIONS_DIR/${session_id}.json"
    [[ -f "$file" ]] || return 0
    (
        flock -w 1 200 || exit 0
        now=$(date +%s)
        jq --argjson ts "$now" "$@" \
            "($jq_expr) | .last_update = \$ts | $ENSURE_FIELDS | $DERIVE_STATUS" \
            "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    ) 200>"${file}.lock" || true
}

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
        # Metadata-only: update model, context%, cwd, pid, tmux. Never touch turn/activity/status.
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
        MODEL=$(echo "$INPUT" | jq -r '.model.display_name // .model.id // empty')
        CONTEXT_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
        CONTEXT_PCT="${CONTEXT_PCT:-0}"
        PROJECT=$(basename "${CWD:-unknown}")
        PID=$(find_claude_pid)
        PID="${PID:-0}"

        read -r PANE TSESS TWIN <<< "$(get_tmux_info)"

        update_session "$SESSION_ID" \
            '.model = $model | .context_pct = $ctx | .cwd = $cwd | .project = $project | .pid = $pid | .tmux_pane = $pane | .tmux_session = $tsess | .tmux_window = $twin' \
            --arg model "$MODEL" \
            --argjson ctx "$CONTEXT_PCT" \
            --arg cwd "$CWD" \
            --arg project "$PROJECT" \
            --argjson pid "$PID" \
            --arg pane "$PANE" \
            --arg tsess "$TSESS" \
            --arg twin "$TWIN"

        # Output status line text for Claude Code
        CTX_INT=${CONTEXT_PCT%.*}
        echo "${MODEL:-?} │ ctx ${CTX_INT:-0}% │ ${PROJECT}"
        ;;

    permission_request)
        # Fires immediately when permission dialog appears. Sets waiting state.
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        update_session "$SESSION_ID" \
            '.turn = "waiting" | .waiting_for_permission = true'
        ;;

    tool_use)
        # PreToolUse: update activity, set turn=tool. For interactive tools, set waiting.
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        FILE="$SESSIONS_DIR/${SESSION_ID}.json"
        [[ -f "$FILE" ]] || exit 0

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
                CMD="${CMD//$'\n'/ }"
                CMD="${CMD//$'\r'/}"
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
            Agent)
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

        # Detect interactive tools that block on user input
        case "$TOOL_NAME" in
            AskUserQuestion|EnterPlanMode|ExitPlanMode)
                update_session "$SESSION_ID" \
                    '.turn = "waiting" | .waiting_for_permission = true | .activity = $activity' \
                    --arg activity "$ACTIVITY"
                ;;
            *)
                update_session "$SESSION_ID" \
                    '.turn = "tool" | .activity = $activity' \
                    --arg activity "$ACTIVITY"
                ;;
        esac
        ;;

    post_tool_use)
        # PostToolUse: tool completed, clear waiting, resume thinking.
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        update_session "$SESSION_ID" \
            '.turn = "thinking" | .waiting_for_permission = false'
        ;;

    post_tool_use_failure)
        # Tool permission denied or failed: clear waiting, resume thinking.
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        update_session "$SESSION_ID" \
            '.turn = "thinking" | .waiting_for_permission = false'
        ;;

    user_prompt)
        # UserPromptSubmit: new turn boundary. Clear all transient state.
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        update_session "$SESSION_ID" \
            '.turn = "thinking" | .waiting_for_permission = false | .subagents = {}'
        ;;

    stop)
        # Turn ended. Set done (or waiting if Claude ended with a question).
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        FILE="$SESSIONS_DIR/${SESSION_ID}.json"
        [[ -f "$FILE" ]] || exit 0

        # Check if Claude ended with a question
        TURN="done"
        CWD=$(jq -r '.cwd // empty' "$FILE" 2>/dev/null) || CWD=""
        if [[ -n "$CWD" ]]; then
            ENCODED=$(echo "$CWD" | sed 's|^/||; s|/|-|g')
            JSONL="$HOME/.claude/projects/-${ENCODED}/${SESSION_ID}.jsonl"
            if [[ -f "$JSONL" ]]; then
                LAST_TEXT=$(tail -50 "$JSONL" 2>/dev/null | \
                    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null | \
                    tail -1) || LAST_TEXT=""
                if [[ -n "$LAST_TEXT" && "${LAST_TEXT: -1}" == "?" ]]; then
                    TURN="waiting"
                fi
            fi
        fi

        update_session "$SESSION_ID" \
            '.turn = $turn' \
            --arg turn "$TURN"

        # Trigger summary generation in background
        nohup "$SCRIPT_DIR/mpx-summarize-one" "$SESSION_ID" &>/dev/null &
        ;;

    notification)
        # Fallback: only set waiting if not already waiting. Self-healing for edge cases.
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        update_session "$SESSION_ID" \
            'if .turn != "waiting" then .turn = "waiting" | .waiting_for_permission = true | .activity = "Waiting for input" else . end'
        ;;

    session_start)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

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
        PROJECT=$(basename "${CWD:-unknown}")
        PID=$(find_claude_pid)
        NOW=$(date +%s)
        FILE="$SESSIONS_DIR/${SESSION_ID}.json"

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
            --arg summary "" \
            '{
                session_id: $sid,
                project: $project,
                cwd: $cwd,
                model: $model,
                context_pct: $ctx,
                status: $status,
                last_update: $ts,
                created_at: $ts,
                pid: $pid,
                tmux_pane: $pane,
                tmux_session: $tsess,
                tmux_window: $twin,
                activity: $activity,
                summary: $summary,
                turn: "waiting",
                waiting_for_permission: false,
                subagents: {},
                schema_version: 2
            }' > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
        ;;

    session_end)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        FILE="$SESSIONS_DIR/${SESSION_ID}.json"
        if [[ -f "$FILE" ]]; then
            NOW=$(date +%s)
            (
                flock -w 1 200 || exit 0
                jq --argjson ts "$NOW" \
                    '.status = "inactive" | .last_update = $ts | .activity = "Exited" | .pid = 0 | .turn = "done" | .waiting_for_permission = false | .subagents = {}' \
                    "$FILE" > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
            ) 200>"${FILE}.lock" || true
        fi
        ;;

    subagent_start)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        AGENT_ID=$(echo "$INPUT" | jq -r '.subagent_id // .agent_id // empty')
        AGENT_TYPE=$(echo "$INPUT" | jq -r '.subagent_type // .agent_type // "agent"')
        [[ -z "$AGENT_ID" ]] && exit 0

        update_session "$SESSION_ID" \
            '.subagents[$aid] = {type: $atype, activity: "Starting..."}' \
            --arg aid "$AGENT_ID" \
            --arg atype "$AGENT_TYPE"
        ;;

    subagent_stop)
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
        [[ -z "$SESSION_ID" ]] && exit 0

        AGENT_ID=$(echo "$INPUT" | jq -r '.subagent_id // .agent_id // empty')
        [[ -z "$AGENT_ID" ]] && exit 0

        update_session "$SESSION_ID" \
            'del(.subagents[$aid])' \
            --arg aid "$AGENT_ID"
        ;;

    *)
        echo "Unknown event: $EVENT" >&2
        exit 1
        ;;
esac
