# Lidless

A free, open source app that keeps your laptop awake while agents, builds or downloads run, including with the lid closed.

macOS: a native Swift and SwiftUI menu bar app. Windows: a small tray app (see [Windows](#windows)). No account, no license key, no network access.

## Features

- **Three session modes.** Timer (presets from 15 min to 8 h, or any length up to 24 h), Until a time of day, or Unlimited. Add 15 minutes to a running timer.
- **Closed-lid mode.** Close the MacBook and it keeps working. You choose how long it may run while closed: 30 min, 1, 2, 4 or 8 hours, or the whole session. When the limit is reached, the Mac goes to sleep.
- **Power rules.** Require a charger, or run on battery and stop at a cutoff you pick (10 to 80 %).
- **Safety in a root daemon.** Charger, battery, thermal pressure, the closed-lid limit and contact with the app are checked every 2 seconds by a small launchd daemon. If the app crashes or freezes, normal sleep comes back within 30 seconds. If the Mac loses power mid-session, the original setting is restored at the next boot.
- **Time left in the menu bar**, optional.
- **Keep the display on**, optional.
- **URL scheme for scripts and agents:**

  ```sh
  open -g "lidless://start?minutes=90"         # timer
  open -g "lidless://start?minutes=90&lid=1"   # timer with closed-lid mode for this session
  open -g "lidless://start"                    # unlimited
  open -g "lidless://extend?minutes=30"
  open -g "lidless://stop"
  open "lidless://show"                        # open the panel as a window
  ```

  If the menu bar is crowded and the icon hides behind the notch, open Lidless again from Spotlight or Finder and the same panel appears as a window.

## Claude Code

Turn on **Keep awake while Claude Code works**. Lidless adds four hooks to `~/.claude/settings.json` (your other settings stay as they are, and the original file is copied to `settings.json.lidless-backup` the first time):

| Hook | Effect |
| --- | --- |
| `UserPromptSubmit` | an agent starts working: start a session if none is running |
| `PostToolUse` | still working: refresh, at most once every 5 minutes |
| `Stop`, `SessionEnd` | the agent finished: end the session once no other Claude Code session is working |

Several Claude Code sessions can work at once; the Mac stays awake until the last one finishes. A session that goes silent for 2 hours is dropped. A session you started by hand is never ended by an agent. Closed-lid mode and the power rules apply to agent sessions too, so you can close the lid and let the agent finish.

## Install

Requirements: macOS 13 or later, Xcode (for `swift build`).

```sh
git clone https://github.com/IskakovDamir/lidless.git
cd lidless
bash script/build.sh
```

The script compiles a release build, bundles `Lidless.app`, signs it ad-hoc, copies it to `/Applications` and launches it. Output goes to `build.log`.

To use closed-lid mode, turn on **Keep running with the lid closed** in the menu and press **Install helper**. macOS asks for your admin password once.

## How it works

| Part | Role |
| --- | --- |
| `Lidless` (app) | Menu bar UI, session timing, IOKit power assertions (`PreventUserIdleSystemSleep`, optionally `PreventUserIdleDisplaySleep`), open-lid power rules. |
| `lidlessd` (root daemon) | Applies and restores `pmset -a disablesleep` for closed-lid sessions and enforces every closed-lid safety rule. |
| `LidlessCore` | Shared models and the pure decision logic, covered by unit tests. |

An open-lid session only needs a power assertion, which any app can hold. Keeping a Mac awake with the lid closed requires the system-wide `disablesleep` setting, which only root can change. Most apps do this with an `SMAppService` privileged helper, which only works when the app is signed with a paid Apple Developer certificate. Lidless uses a plain launchd daemon instead, installed once through the standard admin password prompt, so it works with a free ad-hoc build.

The app and the daemon talk through two files in `/Library/Application Support/Lidless`:

- `client/lease.json`, written by the app every 5 seconds during a closed-lid session. The directory belongs to your user only; the daemon ignores a lease owned by anyone else, a symlink, or anything older than 30 seconds.
- `status.json`, written by the daemon, so the app can show **Ready to close the lid** or why protection stopped.

Before changing the setting, the daemon writes the previous value to a root-only journal and syncs it to disk. It puts that value back when the session ends, a rule fails, the app goes quiet, the daemon is stopped, or at the next boot. A safety stop is final for that session: plugging the charger back in does not silently re-arm it.

## Checks

```sh
bash script/verify.sh          # unit tests, open-lid session, closed-lid session
bash script/verify.sh --crash  # also kills the app mid-session and checks that sleep is restored
```

Each check prints PASS or FAIL; the run ends with `VERIFY OK` or `VERIFY FAILED` and is saved to `verify.log`.

## Uninstall

Press **Remove closed-lid helper** in the menu (or run `sudo bash Resources/uninstall-helper.sh`), then quit the app and delete `/Applications/Lidless.app`.

## Safety notes

A closed MacBook running on battery gets warm. Use a hard, ventilated surface, not a bag. Test a short session on your own Mac before leaving one unattended.

## Windows

`windows/` holds a tray app for Windows 10 and 11 with the same features: Timer, Until and Unlimited sessions, closed-lid mode with a closed-lid time limit, Require charger, End on low battery, Keep the display on, Start with Windows, the `lidless://` URL scheme and the Claude Code hooks.

It is a single `Lidless.exe` built on .NET Framework 4.8, which every Windows 10 and 11 install already has. Download it from the [releases](../../releases) or build it:

```sh
bash script/build-windows.sh      # from macOS or Linux, needs the .NET 8 SDK
dotnet build windows/src -c Release   # on Windows
```

How it maps to Windows:

- Keeping awake uses `SetThreadExecutionState`, visible in `powercfg /requests`.
- Closed-lid mode sets "When I close the lid" to "Do nothing" on the active power plan for the session. The previous values are journaled in `HKCU\Software\Lidless\Journal` first and restored when the session ends, by a watchdog process if the app dies, and at the next start after a crash or power loss.
- The lid state comes from `GUID_LIDSWITCH_STATE_CHANGE`; when the closed-lid limit or a power rule ends a session with the lid shut, the PC is put to sleep.
- Windows has no public thermal API, so the thermal guard is macOS only.

The Windows version is built and unit-tested in CI but has not yet been tested by hand on real hardware. Reports are welcome.

## Credits

Inspired by [WakeBee](https://www.wakebee.app). Lidless is an independent implementation and shares no code with it.

## License

MIT
