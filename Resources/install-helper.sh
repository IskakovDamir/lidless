#!/bin/bash
# Installs the Lidless closed-lid daemon. Runs as root (Lidless.app asks for the admin password).
# Usage: install-helper.sh <path to bundled lidlessd> <uid of the app user>
set -euo pipefail

SOURCE="$1"
CLIENT_UID="$2"
LABEL="dev.iskakov.lidless.daemon"
BINARY="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT="/Library/Application Support/Lidless"

[[ "$(id -u)" == "0" ]] || { echo "must run as root" >&2; exit 1; }
[[ "$CLIENT_UID" =~ ^[0-9]+$ && "$CLIENT_UID" != "0" ]] || { echo "invalid uid" >&2; exit 2; }
[[ -x "$SOURCE" ]] || { echo "lidlessd not found at $SOURCE" >&2; exit 3; }

# Stopping an older daemon makes it restore the sleep setting before it exits.
launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p /Library/PrivilegedHelperTools
install -m 0755 -o root -g wheel "$SOURCE" "$BINARY"

mkdir -p "$SUPPORT/client"
chown root:wheel "$SUPPORT"
chmod 0755 "$SUPPORT"
chown "$CLIENT_UID":staff "$SUPPORT/client"
chmod 0700 "$SUPPORT/client"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BINARY</string>
    <string>--uid</string>
    <string>$CLIENT_UID</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/Library/Logs/lidlessd.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

# bootout returns before launchd has fully unloaded the old job, so retry briefly.
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap system "$PLIST" 2>/dev/null; then break; fi
  [[ "$attempt" == "5" ]] && { echo "launchctl bootstrap failed" >&2; exit 4; }
  sleep 1
done
launchctl enable "system/$LABEL" 2>/dev/null || true
echo "lidlessd installed for uid $CLIENT_UID"
