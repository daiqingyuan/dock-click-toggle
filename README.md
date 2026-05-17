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

The background launcher does not open permission prompts automatically. If you want macOS to show the permission prompts, run:

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --request-permissions
```

To check the current permission state without opening prompts:

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --permission-status
```

On a clean Mac, the first launch reports `FAIL` until those permissions are granted. After enabling permissions, restart the LaunchAgent:

```bash
launchctl kickstart -k gui/$(id -u)/local.dock-click-toggle
sleep 10
cat "$HOME/Library/Application Support/DockClickToggle/status.json"
```

By default, the installer creates:

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

## Experimental Open Launcher Test

There is an experimental test script for checking whether `open -gj DockClickToggle.app` can replace the Terminal launcher on a given Mac:

```bash
./scripts/test-open-launcher.sh
```

The script temporarily disables the normal LaunchAgent, creates a separate `local.dock-click-toggle.open-test` LaunchAgent, waits for `status.json` to report `OK`, then restores the normal Terminal-based launcher.

For a real Dock click check, run:

```bash
./scripts/test-open-launcher.sh --manual
```

For recovery testing through the experimental LaunchAgent's `StartInterval`:

```bash
./scripts/test-open-launcher.sh --restart-test
```

This script is intentionally only a test harness. The default installed launcher still uses Terminal until `open -gj` is proven reliable across more macOS setups.

If the test reports `accessibilityTrusted: false`, `inputMonitoringGranted: false`, or `event_tap_create_failed`, keep the Terminal launcher. That means the `open -gj` LaunchAgent path did not inherit the permission context needed for the event tap.

## Experimental SMAppService Login Item Test

DockClickToggle also includes experimental `SMAppService.mainApp` commands:

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --login-item-status
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --register-login-item
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --unregister-login-item
```

Use the wrapper script for safer testing:

```bash
./scripts/test-smappservice-login-item.sh
```

Default mode prepares a real log out / log in test:

- disables the normal Terminal-based LaunchAgent
- renames `~/Library/LaunchAgents/local.dock-click-toggle.plist` to `~/Library/LaunchAgents/local.dock-click-toggle.plist.disabled`
- stops the current DockClickToggle process
- registers the app as an `SMAppService.mainApp` login item
- verifies `loginItemStatus=enabled`

It intentionally skips the same-session `open` probe. The probe is not a pass/fail gate because the real question is whether macOS starts the app correctly during the next login session.

After running the script, log out / log in and then run:

```bash
./scripts/diagnose.sh --json
```

If the login test fails, or if you want to return to the normal Terminal-based launcher:

```bash
./scripts/test-smappservice-login-item.sh --restore
```

This is intentionally experimental. On the current test machine, `SMAppService.mainApp` successfully registers as a login item, but the real log out / log in test still starts DockClickToggle without Accessibility and Input Monitoring trust. This remained true after switching from ad-hoc signing to the local stable signing identity. The result is `event_tap_create_failed`, so `SMAppService.mainApp` should not replace the Terminal launcher yet.

Notes:

- `loginItemStatus=enabled` means macOS accepted the app as a login item.
- `loginItemStatus=notRegistered` or `loginItemStatus=notFound` means there is no active `SMAppService` registration.
- The same-session open probe is intentionally ignored; the real proof is the log out / log in test.
- If the real login test reports `accessibilityTrusted: false`, `inputMonitoringGranted: false`, and `event_tap_create_failed`, restore the Terminal launcher. The next practical experiment is a dedicated LoginItem helper app, with Developer ID signing reserved for formal distribution testing.

## Experimental LoginItem Agent Test

The app bundle also contains a dedicated helper login item:

```text
/Applications/DockClickToggle.app
└── Contents/Library/LoginItems/DockClickToggleAgent.app
```

The main app can register and inspect that helper with:

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --agent-login-item-status
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --register-agent-login-item
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --unregister-agent-login-item
```

Use the wrapper script for the real log out / log in test:

```bash
./scripts/test-agent-login-item.sh
```

The script disables the normal Terminal-based LaunchAgent, registers `DockClickToggleAgent.app`, verifies `agentLoginItemStatus=enabled`, and stops there. It intentionally does not run a same-session probe. After logging out and back in, run:

```bash
./scripts/diagnose.sh --json
```

If the test fails or you want to return to the stable launcher:

```bash
./scripts/test-agent-login-item.sh --restore
```

Because the helper has its own bundle id, macOS may require separate permissions for `Dock Click Toggle Agent`. Check or request the helper-specific permission state with:

```bash
/Applications/DockClickToggle.app/Contents/Library/LoginItems/DockClickToggleAgent.app/Contents/MacOS/DockClickToggleAgent --permission-status
/Applications/DockClickToggle.app/Contents/Library/LoginItems/DockClickToggleAgent.app/Contents/MacOS/DockClickToggleAgent --request-permissions
```

## Check Status

```bash
cat "$HOME/Library/Application Support/DockClickToggle/status.json"
pgrep -afil DockClickToggle
launchctl print gui/$(id -u)/local.dock-click-toggle | grep -E 'state =|runs =|last exit code|run interval'
```

Healthy status:

- `status.json` has `"state" : "OK"`
- A `DockClickToggle` or `DockClickToggleAgent` process is running
- LaunchAgent shows `run interval = 60 seconds`

The LaunchAgent itself can be `state = not running`; it only checks and starts the utility.

The status file also reports whether Accessibility, Input Monitoring, and the event tap are active.

Possible status states:

- `STARTING`: the app is launching and checking permissions without prompting.
- `OK`: the event tap is active.
- `RECOVERING`: the event tap was disabled and is being re-enabled.
- `FAIL`: startup or event tap creation failed.
- `STOPPED`: the app received a termination signal and shut down cleanly.

DockClickToggle refreshes this file every 30 seconds. The launcher treats an `OK` status as stale if it is older than 120 seconds or if the recorded `pid` does not match the running process.

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

The build also embeds the experimental helper at:

```text
.build/DockClickToggle.app/Contents/Library/LoginItems/DockClickToggleAgent.app
```

## Local Stable Signing

For local development, create a stable self-signed code signing identity:

```bash
./scripts/create-local-signing-identity.sh
```

This creates a local identity named:

```text
DockClickToggle Local Code Signing
```

After it exists, `scripts/build.sh` and `scripts/install.sh` automatically use it. Without that identity, the scripts fall back to ad-hoc signing.

To force a specific signing identity:

```bash
SIGN_IDENTITY="DockClickToggle Local Code Signing" ./scripts/install.sh
```

To force ad-hoc signing:

```bash
SIGN_IDENTITY=- ./scripts/install.sh
```

Stable local signing is useful for testing macOS privacy permissions because TCC is sensitive to the app's code identity. On the current test machine, local stable signing did not make `SMAppService.mainApp` login startup inherit Accessibility or Input Monitoring trust. It is not a substitute for Developer ID signing and notarization when distributing to other people.

## Uninstall

```bash
./scripts/uninstall.sh
```

The uninstall script removes the LaunchAgent and the installed app from `INSTALL_DIR`, which defaults to `/Applications`. It does not reset macOS privacy permissions.

To remove support files and logs too:

```bash
./scripts/uninstall.sh --purge
```

If you installed to a custom directory, pass the same `INSTALL_DIR` when uninstalling:

```bash
INSTALL_DIR="$HOME/Applications" ./scripts/uninstall.sh --purge
```

## Known Limitations

- The current login launcher uses Terminal to start the app in an interactive user session. Terminal may briefly open during login or restart.
- Dragging the current frontmost app's Dock icon may not behave exactly like the native Dock because DockClickToggle consumes the initial mouse-down event for eligible clicks.
- Some apps with unusual Accessibility window metadata may not minimize every window exactly like a native Dock action.

## Troubleshooting

Start with the diagnose script:

```bash
./scripts/diagnose.sh
```

For issue reports or automation, use JSON output:

```bash
./scripts/diagnose.sh --json
```

If you installed to a custom directory, pass the same `INSTALL_DIR`:

```bash
INSTALL_DIR="$HOME/Applications" ./scripts/diagnose.sh
```

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

## Manual Testing

Most DockClickToggle behavior depends on macOS Dock and Accessibility behavior, so manual testing matters more than unit tests for the core event tap path. See [docs/manual-test-matrix.md](docs/manual-test-matrix.md).
