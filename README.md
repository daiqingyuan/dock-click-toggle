# macOS Dock Icon Auto Minimize

DockClickToggle is a small macOS utility that makes the macOS Dock, the bottom app navigation bar, behave more like a Windows taskbar:

- Click the frontmost app's Dock icon to minimize that app's visible windows.
- Click the same Dock icon again while it is minimized to let Dock restore it normally.

It is intentionally tiny, local-only, and dependency-free.

The app includes a custom icon that represents a macOS Dock shelf and a minimize action. The design source is in `assets/icon.svg`, and the build script renders the final `.icns` file automatically.

## Privacy

DockClickToggle does not send data anywhere. It does not use networking, analytics, telemetry, or cloud services.

It needs macOS permissions because of how the feature works:

- Accessibility: read Dock item metadata and minimize app windows.
- Input Monitoring: intercept the mouse down/up pair before Dock reopens the app immediately.

All logic runs locally on the Mac.

## Requirements

- macOS 14 or later
- Swift toolchain available at `/usr/bin/swiftc`
- Accessibility permission
- Input Monitoring permission

## Install

Clone the repo, then run:

```bash
./scripts/install.sh
```

The default install location is `/Applications`. To install somewhere else:

```bash
INSTALL_DIR="$HOME/Applications" ./scripts/install.sh
```

Then enable both permissions in System Settings:

- Privacy & Security > Accessibility > DockClickToggle
- Privacy & Security > Input Monitoring > DockClickToggle

On a clean Mac, the first launch may report `FAIL` until those permissions are granted. After enabling permissions, restart the LaunchAgent:

```bash
launchctl kickstart -k gui/$(id -u)/local.dock-click-toggle
sleep 10
cat "$HOME/Library/Application Support/DockClickToggle/status.json"
```

The installer creates:

- `/Applications/DockClickToggle.app`
- `~/Library/LaunchAgents/local.dock-click-toggle.plist`
- `~/Library/Application Support/DockClickToggle/status.json`
- `~/Library/Logs/DockClickToggle/err.log`
- `~/Library/Logs/DockClickToggle/out.log`

## Why Terminal May Flash At Login

On some recent macOS versions, a LaunchAgent that directly starts a `CGEventTap` process can fail to receive Input Monitoring permission because the process is spawned in a daemon-like context.

The installed LaunchAgent uses `DockClickToggle.app/Contents/Resources/start-via-terminal.sh`, which asks Terminal to start DockClickToggle in the user's interactive session. This makes the event tap work reliably on systems that otherwise report:

```text
failed to create event tap
Grant Input Monitoring permission
```

Terminal may briefly appear at login. That is expected.

## Check Status

```bash
cat "$HOME/Library/Application Support/DockClickToggle/status.json"
pgrep -afil DockClickToggle
launchctl print gui/$(id -u)/local.dock-click-toggle | grep -E 'state =|runs =|last exit code|run interval'
```

Healthy status:

- `status.json` has `"state" : "OK"`
- A `DockClickToggle` process is running
- LaunchAgent shows `run interval = 60 seconds`

The LaunchAgent itself can be `state = not running`; it only checks and starts the utility.

The status file also reports whether Accessibility, Input Monitoring, and the event tap are active.

## Manual Restart

```bash
launchctl kickstart -k gui/$(id -u)/local.dock-click-toggle
sleep 10
cat "$HOME/Library/Application Support/DockClickToggle/status.json"
```

## Build Only

```bash
./scripts/build.sh
```

The built app is written to:

```text
.build/DockClickToggle.app
```

## Uninstall

```bash
./scripts/uninstall.sh
```

The uninstall script removes the LaunchAgent and `/Applications/DockClickToggle.app`. It does not reset macOS privacy permissions.

To remove support files and logs too:

```bash
./scripts/uninstall.sh --purge
```

## Troubleshooting

Read the error log:

```bash
tail -80 "$HOME/Library/Logs/DockClickToggle/err.log"
```

If permissions look enabled but status is still `FAIL`, toggle DockClickToggle off and back on in:

- System Settings > Privacy & Security > Accessibility
- System Settings > Privacy & Security > Input Monitoring

Then restart:

```bash
launchctl kickstart -k gui/$(id -u)/local.dock-click-toggle
```
