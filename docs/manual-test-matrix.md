# Manual Test Matrix

Use this checklist before changing event handling, Dock hit testing, launch behavior, or Accessibility window logic.

## Environment

Record the environment before testing:

- macOS version:
- Mac model / CPU:
- Dock position: bottom / left / right
- Dock auto-hide: on / off
- Dock magnification: on / off
- Displays: single / external / Dock on secondary display
- Install path: `/Applications` / `~/Applications` / other
- Status before test: `./scripts/diagnose.sh --json`

## Apps To Try

Test a mix of native, browser, Electron, and multi-window apps:

- Finder
- Safari
- Google Chrome
- Terminal
- VS Code or another Electron app
- A JetBrains IDE, if installed
- An app with multiple windows
- An app with only minimized windows
- An app with no visible normal windows
- A full-screen app

## Core Scenarios

| ID | Scenario | Expected Result |
| --- | --- | --- |
| 1 | Click the frontmost app's Dock icon | Visible windows minimize |
| 2 | Click the same Dock icon again while minimized | Dock restores the app normally |
| 3 | Click a non-frontmost app's Dock icon | Native Dock switch behavior, no minimize |
| 4 | Command-click a Dock icon | Native Dock behavior, no minimize |
| 5 | Option-click a Dock icon | Native Dock behavior, no minimize |
| 6 | Control-click a Dock icon | Native menu behavior, no minimize |
| 7 | Shift-click a Dock icon | Native Dock behavior, no minimize |
| 8 | Press on the frontmost Dock icon and drag | Drag is not swallowed by DockClickToggle |
| 9 | Mouse down on one Dock icon, move, mouse up elsewhere | No accidental minimize |
| 10 | Rapidly click the same Dock icon several times | No stuck pending click or repeated unwanted minimize |
| 11 | Click while an app is launching | No crash, no stuck `RECOVERING` or `FAIL` state |
| 12 | Trigger LaunchAgent restart with `launchctl kickstart -k gui/$(id -u)/local.dock-click-toggle` | Status returns to `OK` |
| 13 | Kill the process and wait up to 60 seconds | LaunchAgent restarts it, status returns to `OK` |

## Status And Logs

After each test group, run:

```bash
./scripts/diagnose.sh
./scripts/diagnose.sh --json
tail -80 "$HOME/Library/Logs/DockClickToggle/err.log"
```

Healthy baseline:

- `status` / `State` is `OK`
- `eventTapCreated` is `true`
- `accessibilityTrusted` is `true`
- `inputMonitoringGranted` is `true`
- `PID match` is `yes`
- Status age is under 120 seconds

## Regression Notes

When a scenario fails, capture:

- The app tested
- Dock position and auto-hide setting
- Whether the app had multiple, minimized, hidden, or full-screen windows
- `./scripts/diagnose.sh --json` output
- The last 80 lines of `~/Library/Logs/DockClickToggle/err.log`
