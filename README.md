# Multiplex

A tmux-based session manager for Claude Code. Monitors all active Claude sessions in a real-time dashboard, tracks their status, and lets you switch between them instantly.

## What it does

- **Real-time dashboard** (`mpx`) showing all Claude Code sessions with status, context usage, and activity
- **Workspace launcher** (`tmpx`) creating standardized 3-pane tmux layouts
- **Session switching** via number keys or tmux keybindings
- **LLM-powered summaries** of what each session is working on (via ollama)
- **Automatic lifecycle management** — stale/exited sessions are cleaned up automatically

## Prerequisites

- `tmux`
- `jq`
- `bash` (4.0+)
- `python3`
- `ollama` (optional, for session summaries)

## Setup

### 1. Configure Claude Code hooks

Add the following to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/workplace/multiplex/writer.sh status_line"
  },
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh notification" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh stop" }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh session_start" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh session_end" }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh tool_use" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh permission_request" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh post_tool_use" }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh post_tool_use_failure" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh user_prompt" }] }],
    "SubagentStart": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh subagent_start" }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "command": "~/workplace/multiplex/writer.sh subagent_stop" }] }]
  }
}
```

### 2. Optional: tmux keybindings

Add to `~/.tmux.conf` for quick session switching and killing:

```tmux
bind Q run-shell -b "~/workplace/multiplex/mpx-kill"
bind 1 run-shell -b "~/workplace/multiplex/mpx-switch 1"
bind 2 run-shell -b "~/workplace/multiplex/mpx-switch 2"
bind 3 run-shell -b "~/workplace/multiplex/mpx-switch 3"
# ... up to 9
```

### 3. Optional: session summaries

Install ollama and pull a model:

```bash
ollama pull qwen2.5:3b
```

Summaries are generated automatically after each turn completes. No daemon required — `writer.sh` triggers `mpx-summarize-one` on the `stop` event.

## Usage

### `tmpx [name]`

Create a new workspace session with a 3-pane layout:
- **Left pane**: Claude Code (focused)
- **Top-right pane**: dagflow-tui
- **Bottom-right pane**: mpx monitor

Auto-names sessions `tmpx-1`, `tmpx-2`, etc. if no name given.

### `mpx`

Interactive dashboard showing all active sessions.

| Key | Action |
|-----|--------|
| `1`-`9` | Switch to numbered session |
| `n` | Launch new tmpx workspace |
| `q` | Quit monitor |

Sessions are sorted by status priority (active/waiting first), then by creation time.

**Status indicators:**
- `● active` (green) — Claude is working
- `● waiting` (red) — needs user input (permission dialog, question, plan approval)
- `● done` (blue) — turn completed
- `○ inactive` (dim) — session exited, auto-removed after 60s

### `mpx-switch <N>`

Switch to the Nth session (matches mpx dashboard ordering). Designed for tmux keybindings.

### `mpx-kill`

Kill the current tmux session and switch to the next available one. Designed for tmux keybindings.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MPX_SUMMARY_MODEL` | `qwen2.5:3b` | Ollama model for generating summaries |
| `MPX_OLLAMA_URL` | `http://localhost:11434` | Ollama API endpoint |

## How it works

**Session state** is stored as JSON files in `sessions/`, one per Claude session. The `writer.sh` script is called by Claude Code hooks on every lifecycle event and updates these files atomically using `flock`.

**Status tracking** uses an internal state machine. The `turn` field tracks Claude's internal state (`waiting`, `thinking`, `tool`, `done`), and the displayed `status` is always derived from `turn` + `waiting_for_permission`. This ensures consistent, predictable status without race conditions.

**Summaries** are generated event-driven: when a turn completes (`stop` event), `writer.sh` spawns `mpx-summarize-one` in the background, which extracts key user messages from the JSONL transcript and sends them to ollama. A file-size cache prevents redundant summarization.

## Files

| File | Purpose |
|------|---------|
| `mpx` | Interactive session dashboard (TUI) |
| `tmpx` | Workspace launcher (creates 3-pane tmux layout) |
| `writer.sh` | Session state writer (called by Claude Code hooks) |
| `mpx-switch` | Switch to Nth session (for tmux keybindings) |
| `mpx-kill` | Kill current session and switch to next |
| `mpx-summarize-one` | Generate summary for a single session (event-driven) |
| `mpx-summarize` | Legacy polling daemon for summaries (superseded by mpx-summarize-one) |
| `summarize-extract.py` | Extract key user messages from JSONL transcripts |
