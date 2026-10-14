#!/bin/bash
# Claude Code hook for Lidless. Installed into ~/.claude/settings.json by the app.
#   claude-hook.sh hold      UserPromptSubmit: the agent started working
#   claude-hook.sh refresh   PostToolUse: still working (throttled to once per 5 minutes)
#   claude-hook.sh release   Stop / SessionEnd: the agent finished
# Prints nothing and always exits 0, so it never blocks or adds context to Claude Code.

ACTION="${1:-hold}"
INPUT="$(cat 2>/dev/null)"
ID="$(printf '%s' "$INPUT" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,64\}\)".*/\1/p' | head -1)"
[ -n "$ID" ] || ID="claude"
STAMP="${TMPDIR:-/tmp}/lidless-hook-$ID"

case "$ACTION" in
  hold)
    touch "$STAMP" 2>/dev/null
    /usr/bin/open -g "lidless://hold?id=$ID" >/dev/null 2>&1
    ;;
  refresh)
    if [ -z "$(/usr/bin/find "$STAMP" -mmin -5 2>/dev/null)" ]; then
      touch "$STAMP" 2>/dev/null
      /usr/bin/open -g "lidless://hold?id=$ID" >/dev/null 2>&1
    fi
    ;;
  release)
    rm -f "$STAMP" 2>/dev/null
    /usr/bin/open -g "lidless://release?id=$ID" >/dev/null 2>&1
    ;;
esac
exit 0
