#!/bin/bash
# Claude Code hook for Lidless. Installed into ~/.claude/settings.json by the app.
#   claude-hook.sh hold      UserPromptSubmit: the agent started working
#   claude-hook.sh refresh   PostToolUse: still working (touches its file at most every 5 minutes)
#   claude-hook.sh release   Stop / SessionEnd: the agent finished
# Each working session is one empty file in ~/Library/Application Support/Lidless/agents.
# Lidless watches that folder. Prints nothing and always exits 0, so it never blocks Claude Code.

ACTION="${1:-hold}"
INPUT="$(cat 2>/dev/null)"
ID="$(printf '%s' "$INPUT" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,64\}\)".*/\1/p' | head -1)"
[ -n "$ID" ] || ID="claude"
DIR="$HOME/Library/Application Support/Lidless/agents"
FILE="$DIR/$ID"

case "$ACTION" in
  hold)
    mkdir -p "$DIR" 2>/dev/null
    touch "$FILE" 2>/dev/null
    # Start Lidless if it is not running. By name, so no URL routing is involved.
    /usr/bin/pgrep -xq Lidless || /usr/bin/open -g -a Lidless >/dev/null 2>&1
    ;;
  refresh)
    # Never recreates a released hold: only refreshes a file that exists.
    if [ -f "$FILE" ] && [ -z "$(/usr/bin/find "$FILE" -mmin -5 2>/dev/null)" ]; then
      touch "$FILE" 2>/dev/null
    fi
    ;;
  release)
    rm -f "$FILE" 2>/dev/null
    ;;
esac
exit 0
