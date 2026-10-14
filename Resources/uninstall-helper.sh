#!/bin/bash
# Removes the Lidless closed-lid daemon and puts the sleep setting back. Runs as root.
set -uo pipefail

LABEL="dev.iskakov.lidless.daemon"
BINARY="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT="/Library/Application Support/Lidless"
JOURNAL="$SUPPORT/journal.json"

[[ "$(id -u)" == "0" ]] || { echo "must run as root" >&2; exit 1; }

# The daemon restores the sleep setting itself when it receives SIGTERM.
launchctl bootout "system/$LABEL" 2>/dev/null || true
sleep 1

# Belt and braces: if a journal survived, apply the value it recorded.
if [[ -f "$JOURNAL" ]]; then
  PREVIOUS="$(/usr/bin/plutil -extract previousSleepDisabled raw -o - "$JOURNAL" 2>/dev/null || echo false)"
  if [[ "$PREVIOUS" == "true" ]]; then pmset -a disablesleep 1; else pmset -a disablesleep 0; fi
fi

rm -f "$PLIST" "$BINARY"
rm -rf "$SUPPORT"
echo "lidlessd removed"
