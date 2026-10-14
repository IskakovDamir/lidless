# Lidless

Keeps a laptop awake while agents, builds or downloads run, including with the lid closed. macOS app in Swift (repo root), Windows tray app in C# (`windows/`). MIT, public on GitHub.

## Layout

| Path | What |
| --- | --- |
| `Sources/LidlessCore` | Shared Swift models (lease, daemon status, journal), pure rules (`ClosedLidRules`, `SessionPowerRules`), IOKit readers, safe JSON file IO. Unit tested. |
| `Sources/lidlessd` | Root launchd daemon. Applies and restores `pmset -a disablesleep` for closed-lid sessions and enforces every closed-lid safety rule. |
| `Sources/Lidless` | Menu bar app: `AppModel` (sessions, timers, power rules, agent holds, URL scheme), `StatusItemController` (icon, popover, window fallback), `Views/PopoverView`, `ClosedLidClient` (lease/status files, helper installer), `ClaudeCodeIntegration` (hooks in ~/.claude/settings.json). |
| `Resources/` | `Info.plist`, `install-helper.sh` / `uninstall-helper.sh` (run as root via the admin prompt), `claude-hook.sh`. |
| `Tests/LidlessCoreTests` | XCTest for the Swift rules. |
| `windows/src` | .NET Framework 4.8 WinForms tray app. `TrayApp` (menu + session logic), `Power` (SetThreadExecutionState, lid action with journal), `LidWatcher`, `Ipc` (named pipe), `ClaudeHooks` + `MiniJson`, `Program` (entry: app, URL, `hook`, `--watchdog`). |
| `windows/tests` | xunit (net8.0) for `Rules`, `MiniJson`, `ClaudeHooks`. |
| `script/` | `build.sh` (build, sign ad-hoc, install to /Applications, launch; log in build.log), `verify.sh` (end-to-end PASS/FAIL, log in verify.log), `build-windows.sh`, `make-icon.swift`. |

## Commands

```sh
bash script/build.sh                 # mac: build + install + launch. Must end with BUILD OK
bash script/verify.sh --crash        # mac: end-to-end checks. Must end with VERIFY OK (lid open, charger on)
swift test                           # mac unit tests
bash script/build-windows.sh         # windows exe + tests from macOS. Must end with BUILD OK (needs .NET 8 SDK)
```

Build products live in `~/Library/Caches/lidless-build`, never in the repo (the repo may sit on an exFAT drive, where `._` files break codesign).

## Invariants that must never break

1. Every path that disables sleep journals the previous value first (daemon: `/Library/Application Support/Lidless/journal.json`, root 0600, fsynced; Windows: `HKCU\Software\Lidless\Journal`) and restores it on: session end, any safety stop, lost contact with the app (lease older than 30 s), daemon SIGTERM, next daemon start, next app start (Windows), watchdog (Windows).
2. A safety stop is final for that session. A returning charger never re-arms it.
3. The daemon trusts nothing from the app beyond the lease file, owned by the configured uid, regular file, no symlinks, under 8 KB, validated by `ClosedLidRules.validate`.
4. Hooks print nothing and always exit 0. Claude Code injects UserPromptSubmit stdout into the conversation.
5. Installing Claude Code hooks only adds or removes entries containing the marker (`claude-hook.sh` on mac, `Lidless.exe` on Windows). Other user settings and hooks stay untouched.
6. When protection stops with the lid closed for a safety reason or session end, the machine is put to sleep (`pmset sleepnow`, `SetSuspendState`).

When a change touches any of these, add or update a unit test in LidlessCore or windows/tests and a check in `script/verify.sh`.

## How to work here

- Measure first, then fix: reproduce with `verify.sh` or a log, name the cause, then change code.
- Done means the scripts say so: `BUILD OK` and `VERIFY OK` on mac, `BUILD OK` from `build-windows.sh` and green CI for Windows. Paste the final lines as evidence. Verbal confirmation is not evidence.
- There is no Windows machine. Windows code is checked by the unit tests, `build-windows.sh` and GitHub Actions (`.github/workflows/ci.yml`, including a hook smoke test). Keep Windows logic in testable pure classes where possible.
- Swift: tools 5.9, Swift 5 mode, macOS 13 minimum. App types are `@MainActor`; hop from Timer/NotificationCenter closures with `MainActor.assumeIsolated`.
- C#: net48 with `LangVersion latest`. No records, init, Index/Range or other APIs missing from .NET Framework.
- UI copy is English, sentence case, short. No decorative capsules or heavy rounding around labels.
- The closed-lid daemon is only re-copied when the user presses Update helper in the app; after changing `Sources/lidlessd` mention that.

## Git

- Small atomic commits, message prefix by area: `core:`, `daemon:`, `app:`, `claude:`, `windows:`, `build:`, `test:`, `docs:`, `ci:`, `fix:`.
- Commit and push to main as soon as a step is finished and its check passes.
- Never add Co-Authored-By, Claude-Session or "Generated with Claude Code" lines to commits or PRs.
- Release: tag `vX.Y.Z` and push the tag; CI attaches `Lidless-macos.zip` and `Lidless.exe` to the GitHub release. Bump the version in `Resources/Info.plist`, `Sources/LidlessCore/Models.swift` (`LidlessVersion`), `windows/src/Lidless.csproj`, `windows/src/Program.cs` (`App.Version`) and `windows/src/app.manifest` together.
