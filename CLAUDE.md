# Multiplex — Claude Code Session Manager

## Project overview

Multiplex is a tmux-based session manager for Claude Code. It uses Claude Code hooks to track session lifecycle events and display them in a real-time TUI dashboard. All scripts are bash except `summarize-extract.py` (Python 3).

## Architecture

### State management

Session state lives in `sessions/*.json` (one file per Claude session, keyed by session ID).

`writer.sh` is the core state writer — called by every Claude Code hook. It uses **atomic read-modify-write with flock** to prevent race conditions. The key design principle: **status is always derived, never set directly**.

The internal `turn` field tracks state (`waiting`, `thinking`, `tool`, `done`, `idle`), and `waiting_for_permission` is a boolean flag. The displayed `status` is derived via:
```
if waiting_for_permission → "waiting"
elif turn == "done" or "idle" → "done"
elif turn == "waiting" → "waiting"
else → "active"
```

### Event flow

Claude Code hooks → `writer.sh <event>` → atomic JSON update → `mpx` reads JSON files on 1s loop

Events: `session_start`, `session_end`, `status_line`, `tool_use`, `post_tool_use`, `post_tool_use_failure`, `permission_request`, `user_prompt`, `notification`, `stop`, `subagent_start`, `subagent_stop`

### Display ordering

Sessions are sorted by: status priority (`active`/`waiting` = 0, `done` = 1, `inactive` = 2), then by `created_at` timestamp. This ordering is shared by `mpx`, `mpx-switch`, and `mpx-kill`.

### Session visibility

The tmux pane is the primary authority for whether a session is displayed. The dashboard validates that the pane exists AND belongs to the expected tmux session (pane IDs can be reused after tmux server restarts). Sessions without pane info are cleaned up when their process is dead and they exceed `INACTIVE_TIMEOUT` (60s). Sessions with dead panes are cleaned up after `STALE_REMOVE` (600s).

### Summaries

Event-driven: `writer.sh stop` → spawns `mpx-summarize-one` in background → `summarize-extract.py` extracts user messages → ollama generates summary → written back to session JSON. File-size caching prevents redundant summarization. `mpx-summarize` is a legacy polling daemon (60s interval), largely superseded.

## Key files

- `writer.sh` — Core state machine. All session state mutations go through here.
- `mpx` — TUI dashboard. Read-only (except cleanup of stale/ghost sessions).
- `tmpx` — Workspace launcher. Creates 3-pane tmux layout.
- `mpx-switch` — Session switcher for tmux keybindings. Mirrors mpx's sort order.
- `mpx-kill` — Kill current session, switch to next.
- `mpx-summarize-one` — Event-driven single-session summarizer.
- `mpx-summarize` — Legacy polling summarizer (superseded by mpx-summarize-one).
- `summarize-extract.py` — Extracts first + last 2 user messages from JSONL, ~500 char limit.

## Session JSON schema (v2)

```json
{
  "session_id": "string",
  "project": "string (basename of cwd)",
  "cwd": "string",
  "model": "string",
  "context_pct": "number",
  "status": "active|waiting|done|inactive (derived)",
  "turn": "waiting|thinking|tool|done|idle (internal)",
  "waiting_for_permission": "boolean",
  "last_update": "unix timestamp",
  "created_at": "unix timestamp",
  "pid": "number",
  "tmux_pane": "string",
  "tmux_session": "string",
  "tmux_window": "string",
  "activity": "string",
  "summary": "string",
  "subagents": "object {agent_id: {type, activity}}",
  "schema_version": 2
}
```

## Conventions

- All JSON updates must be atomic (flock + write to .tmp + mv).
- Never set `.status` directly in event handlers — always set `.turn` and/or `.waiting_for_permission` and let `DERIVE_STATUS` compute it.
- `session_end` is the one exception that sets status directly to "inactive" (terminal state, no further derivation needed).
- Tool activity descriptions should be short and human-readable (e.g., "Reading foo.js", "$ git status").
- Interactive tools (`AskUserQuestion`, `EnterPlanMode`, `ExitPlanMode`) set `waiting_for_permission = true` immediately in the `tool_use` handler.
- The `SESSIONS_DIR` path is hardcoded to `$HOME/workplace/multiplex/sessions` across all scripts.

## Dependencies

- `bash` 4.0+, `jq`, `tmux`, `python3`
- `ollama` (optional, for summaries)
- `curl` (for ollama API calls)
- `flock` (from util-linux, for atomic updates)

## Environment variables

- `MPX_SUMMARY_MODEL` — ollama model (default: `qwen2.5:3b`)
- `MPX_OLLAMA_URL` — ollama endpoint (default: `http://localhost:11434`)
