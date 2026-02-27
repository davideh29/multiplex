#!/usr/bin/env python3
"""Extract key user messages from a Claude Code session JSONL transcript.

Reads a session JSONL file and outputs a concise text blob suitable for
LLM summarization: first user message (defines the task) + last 2 user
messages (current focus), each truncated to ~200 chars, total ~500 chars.
"""

import json
import sys

NOISE = [
    "[Request interrupted by user for tool use]",
    "[Request interrupted by user]",
]

MAX_PER_MSG = 200
MAX_TOTAL = 500


def extract_text(content):
    """Extract plain text from a message content field (string or list)."""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block["text"].strip())
            elif isinstance(block, str):
                parts.append(block.strip())
        return " ".join(parts)
    return ""


def main():
    if len(sys.argv) != 2:
        print("Usage: summarize-extract.py <path-to-jsonl>", file=sys.stderr)
        sys.exit(1)

    jsonl_path = sys.argv[1]
    user_messages = []

    try:
        with open(jsonl_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if entry.get("type") != "user":
                    continue

                msg = entry.get("message", {})
                if msg.get("role") != "user":
                    continue

                text = extract_text(msg.get("content", ""))
                if not text or text in NOISE:
                    continue

                user_messages.append(text)
    except (OSError, IOError):
        sys.exit(0)

    if not user_messages:
        sys.exit(0)

    # Select: first message + last 2 (deduplicated)
    selected = [user_messages[0]]
    for msg in user_messages[-2:]:
        if msg not in selected:
            selected.append(msg)

    # Truncate each and build output
    output_parts = []
    total = 0
    for msg in selected:
        truncated = msg[:MAX_PER_MSG]
        if len(msg) > MAX_PER_MSG:
            truncated += "..."
        remaining = MAX_TOTAL - total
        if remaining <= 0:
            break
        if len(truncated) > remaining:
            truncated = truncated[:remaining]
        output_parts.append(truncated)
        total += len(truncated)

    print("\n---\n".join(output_parts))


if __name__ == "__main__":
    main()
