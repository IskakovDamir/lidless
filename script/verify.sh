#!/bin/bash
# End-to-end checks with a pass condition for each. Writes verify.log next to the repo.
# Run with the lid open and the charger connected. Takes about a minute.
#   bash script/verify.sh            unit tests + open-lid + closed-lid (if the helper is installed)
#   bash script/verify.sh --crash    also kills the app mid-session and waits for the daemon to restore sleep
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec > >(tee "$ROOT/verify.log") 2>&1

SUPPORT="/Library/Application Support/Lidless"
PLIST="/Library/LaunchDaemons/dev.iskakov.lidless.daemon.plist"
PASSED=0
FAILED=0

pass() { printf 'PASS  %s\n' "$1"; PASSED=$((PASSED + 1)); }
failc() { printf 'FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }
check() { if eval "$2"; then pass "$1"; else failc "$1"; fi; }

# Capture first, then match: `pmset ... | grep -q` under pipefail returns 141 when grep exits on
# the first match while pmset is still writing, which made every positive check fail.
sleep_disabled() { [[ "$(pmset -g | awk '/SleepDisabled/ {print $2}')" == 1 ]]; }
has_assertion() { [[ "$(pmset -g assertions)" == *"Lidless session"* ]]; }
daemon_state() { /usr/bin/plutil -extract state raw -o - "$SUPPORT/status.json" 2>/dev/null; }
lidless() { open -g "lidless://$1"; }

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1 || true)"
  if [[ -n "$XCODE" ]]; then export DEVELOPER_DIR="$XCODE/Contents/Developer"; fi
fi

echo "== $(date) =="
sw_vers | tr '\n' ' '; echo
pmset -g batt | head -2

echo; echo "== Unit tests =="
TEST_OUT="$(swift test --package-path "$ROOT" --scratch-path "$HOME/Library/Caches/lidless-test" 2>&1)"
TEST_RC=$?
echo "$TEST_OUT" | tail -5
if [[ "$TEST_RC" == "0" ]]; then
  pass "swift test"
elif [[ "$TEST_OUT" == *"no such module 'XCTest'"* ]]; then
  echo "SKIP  swift test (XCTest needs the full Xcode, not only the Command Line Tools)"
else
  failc "swift test"
fi

echo; echo "== Open-lid session =="
pgrep -x Lidless >/dev/null || { open -g /Applications/Lidless.app; sleep 2; }
check "app is running" "pgrep -x Lidless >/dev/null"
BEFORE_SLEEP="$(pmset -g | awk '/SleepDisabled/ {print $2}')"
echo "SleepDisabled before: ${BEFORE_SLEEP:-unset}"

lidless "start?minutes=2&lid=0"
sleep 3
check "assertion held during session" "has_assertion"
check "sleep not disabled without closed-lid mode" "! sleep_disabled"
lidless "stop"
sleep 2
check "assertion released after stop" "! has_assertion"

echo; echo "== Claude Code hook =="
HOOK="/Applications/Lidless.app/Contents/Resources/claude-hook.sh"
echo '{"session_id":"verify-a","hook_event_name":"UserPromptSubmit"}' | /bin/bash "$HOOK" hold
echo '{"session_id":"verify-b","hook_event_name":"UserPromptSubmit"}' | /bin/bash "$HOOK" hold
sleep 3
check "agent hold starts a session" "has_assertion"
echo '{"session_id":"verify-a","hook_event_name":"Stop"}' | /bin/bash "$HOOK" release
sleep 2
check "session stays while another agent works" "has_assertion"
echo '{"session_id":"verify-b","hook_event_name":"Stop"}' | /bin/bash "$HOOK" release
sleep 2
check "session ends when the last agent finishes" "! has_assertion"
check "hook prints nothing" "[[ -z \"\$(echo '{\"session_id\":\"verify-c\"}' | /bin/bash \"$HOOK\" release)\" ]]"

if [[ -f "$PLIST" ]]; then
  echo; echo "== Closed-lid session =="
  check "daemon is running" "pgrep -f dev.iskakov.lidless.daemon >/dev/null"
  lidless "start?minutes=3&lid=1"
  sleep 9
  check "daemon holding" "[[ \"\$(daemon_state)\" == holding ]]"
  check "SleepDisabled=1 during closed-lid session" "sleep_disabled"
  lidless "stop"
  sleep 5
  check "daemon back to idle" "[[ \"\$(daemon_state)\" == idle ]]"
  check "SleepDisabled restored after stop" "! sleep_disabled || [[ \"$BEFORE_SLEEP\" == 1 ]]"
  check "journal removed" "[[ ! -e \"$SUPPORT/journal.json\" ]]"

  if [[ "${1:-}" == "--crash" ]]; then
    echo; echo "== Crash recovery (about 40 s) =="
    lidless "start?minutes=5&lid=1"
    sleep 9
    check "holding before crash" "sleep_disabled"
    pkill -9 -x Lidless
    echo "app killed, waiting for the lease to expire"
    sleep 38
    check "daemon restored sleep after the app died" "! sleep_disabled || [[ \"$BEFORE_SLEEP\" == 1 ]]"
    check "daemon reports stopped" "[[ \"\$(daemon_state)\" == stopped || \"\$(daemon_state)\" == idle ]]"
    open -g /Applications/Lidless.app
    sleep 2
    check "app relaunched and cleared the stale lease" "[[ ! -e \"$SUPPORT/client/lease.json\" ]]"
  fi
else
  echo; echo "(closed-lid helper not installed, skipping closed-lid checks)"
fi

echo; echo "== Result: $PASSED passed, $FAILED failed =="
[[ "$FAILED" == "0" ]] && echo "VERIFY OK" || { echo "VERIFY FAILED"; exit 1; }
