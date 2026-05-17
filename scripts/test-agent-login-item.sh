#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
uid="$(id -u)"
agent_label="local.dock-click-toggle"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
disabled_agent_path="$agent_path.disabled"
install_dir="${INSTALL_DIR:-/Applications}"
app_path="$install_dir/DockClickToggle.app"
binary_path="$app_path/Contents/MacOS/DockClickToggle"
login_item_app_path="$app_path/Contents/Library/LoginItems/DockClickToggleAgent.app"
login_item_binary_path="$login_item_app_path/Contents/MacOS/DockClickToggleAgent"
support_dir="$HOME/Library/Application Support/DockClickToggle"
status_file="$support_dir/status.json"

mode="prepare"

usage() {
    cat <<'EOF'
Usage: ./scripts/test-agent-login-item.sh [options]

Prepares a real SMAppService.loginItem(identifier:) test for the bundled
DockClickToggleAgent.app helper. The same-session open probe is intentionally
not used as a pass/fail gate.

Default behavior:
  1. Disable and rename the normal Terminal-based LaunchAgent plist.
  2. Stop any currently running DockClickToggle / DockClickToggleAgent process.
  3. Register Contents/Library/LoginItems/DockClickToggleAgent.app.
  4. Verify agentLoginItemStatus=enabled.
  5. Exit 0 and ask you to log out / log in.

Options:
  --prepare-login-test  Same as the default behavior.
  --restore             Unregister the helper login item and restore the normal
                        Terminal-based LaunchAgent.
  --status              Print current main-app and helper login item statuses.
  --help                Show this help.

Use INSTALL_DIR=/path/to/install-dir if DockClickToggle.app is not installed
in /Applications.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --prepare-login-test)
            mode="prepare"
            ;;
        --restore)
            mode="restore"
            ;;
        --status)
            mode="status"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

log() {
    printf '==> %s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

plist_value() {
    local key="$1"
    [[ -f "$status_file" ]] || return 1
    /usr/bin/plutil -extract "$key" raw -o - "$status_file" 2>/dev/null
}

running_pids() {
    {
        /usr/bin/pgrep -x DockClickToggle 2>/dev/null || true
        /usr/bin/pgrep -x DockClickToggleAgent 2>/dev/null || true
    } | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//'
}

pid_is_running() {
    local pid="$1"
    local pids
    pids="$(running_pids || true)"
    [[ " $pids " == *" $pid "* ]]
}

status_age_seconds() {
    local updated_unix="$1"
    if [[ "$updated_unix" == <-> ]]; then
        printf '%s' "$(( $(/bin/date +%s) - updated_unix ))"
    else
        printf 'unknown'
    fi
}

is_status_ok() {
    [[ -f "$status_file" ]] || return 1

    local state event_tap status_pid updated_unix age
    state="$(plist_value state || echo unknown)"
    event_tap="$(plist_value eventTapCreated || echo unknown)"
    status_pid="$(plist_value pid || echo unknown)"
    updated_unix="$(plist_value lastUpdatedUnix || echo unknown)"
    age="$(status_age_seconds "$updated_unix")"

    [[ "$state" == "OK" ]] || return 1
    [[ "$event_tap" == "true" ]] || return 1
    [[ "$status_pid" == <-> ]] || return 1
    [[ "$age" == <-> ]] || return 1
    [[ "$age" -le 120 ]] || return 1
    pid_is_running "$status_pid"
}

wait_for_ok() {
    local timeout="$1"
    local deadline="$(( $(/bin/date +%s) + timeout ))"

    while [[ "$(/bin/date +%s)" -le "$deadline" ]]; do
        if is_status_ok; then
            return 0
        fi
        sleep 1
    done

    return 1
}

main_login_item_status() {
    "$binary_path" --login-item-status
}

agent_login_item_status() {
    "$binary_path" --agent-login-item-status
}

agent_login_item_status_value() {
    agent_login_item_status | /usr/bin/sed 's/^agentLoginItemStatus=//'
}

agent_permission_status() {
    printf 'manualHelperPermissionStatusContext=current-shell-not-login-item\n'
    "$login_item_binary_path" --permission-status
}

request_agent_permissions() {
    "$login_item_binary_path" --request-permissions
}

register_agent_login_item() {
    "$binary_path" --register-agent-login-item
}

unregister_agent_login_item() {
    "$binary_path" --unregister-agent-login-item
}

unregister_main_login_item() {
    "$binary_path" --unregister-login-item
}

disable_terminal_launcher() {
    log "Disabling normal Terminal-based LaunchAgent"
    /bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
    /bin/launchctl bootout "gui/$uid" "$agent_path" 2>/dev/null || true

    if [[ -f "$agent_path" && -f "$disabled_agent_path" ]]; then
        fail "Both $agent_path and $disabled_agent_path exist. Run --restore or resolve them manually first."
    fi

    if [[ -f "$agent_path" ]]; then
        mv "$agent_path" "$disabled_agent_path"
        log "Moved LaunchAgent plist to $disabled_agent_path"
    elif [[ -f "$disabled_agent_path" ]]; then
        log "LaunchAgent plist is already disabled at $disabled_agent_path"
    else
        log "No normal LaunchAgent plist found to disable"
    fi
}

restore_terminal_launcher() {
    log "Restoring normal Terminal-based LaunchAgent"
    /bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
    /bin/launchctl bootout "gui/$uid" "$agent_path" 2>/dev/null || true

    if [[ -f "$disabled_agent_path" ]]; then
        if [[ -f "$agent_path" ]]; then
            fail "Cannot restore because both $agent_path and $disabled_agent_path exist."
        fi
        mv "$disabled_agent_path" "$agent_path"
        log "Moved LaunchAgent plist back to $agent_path"
    fi

    if [[ -f "$agent_path" ]]; then
        /bin/launchctl bootstrap "gui/$uid" "$agent_path" 2>/dev/null || true
        /bin/launchctl kickstart -k "gui/$uid/$agent_label" 2>/dev/null || true
        if wait_for_ok 20; then
            log "Normal launcher restored and status is OK"
        else
            log "Normal launcher restored, but status did not reach OK within 20s"
        fi
    else
        log "Normal LaunchAgent plist not found: $agent_path"
    fi
}

print_current_diagnose() {
    "$repo_dir/scripts/diagnose.sh" --json || true
}

[[ -d "$app_path" ]] || fail "Missing $app_path. Run ./scripts/install.sh first, or pass INSTALL_DIR."
[[ -x "$binary_path" ]] || fail "Missing executable: $binary_path"
[[ -d "$login_item_app_path" ]] || fail "Missing helper app: $login_item_app_path. Run ./scripts/install.sh first."
[[ -x "$login_item_binary_path" ]] || fail "Missing helper executable: $login_item_binary_path"

case "$mode" in
    status)
        main_login_item_status
        agent_login_item_status
        agent_permission_status
        ;;

    restore)
        log "Unregistering helper login item"
        unregister_agent_login_item || true
        log "Unregistering main-app login item"
        unregister_main_login_item || true
        /usr/bin/pkill -x DockClickToggleAgent 2>/dev/null || true
        /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
        sleep 2
        restore_terminal_launcher
        print_current_diagnose
        ;;

    prepare)
        log "Preparing real helper LoginItem test"
        disable_terminal_launcher
        unregister_main_login_item || true
        /usr/bin/pkill -x DockClickToggleAgent 2>/dev/null || true
        /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
        sleep 2
        rm -f "$status_file"

        log "Registering bundled DockClickToggleAgent.app"
        register_agent_login_item
        item_status="$(agent_login_item_status_value)"
        printf 'agentLoginItemStatus=%s\n' "$item_status"
        [[ "$item_status" == "enabled" ]] || fail "Expected agentLoginItemStatus=enabled, got $item_status"

        cat <<EOF

Helper LoginItem register: success
agent login item status: enabled
same-session probe: skipped

The normal Terminal LaunchAgent has been disabled by moving:

  $agent_path

to:

  $disabled_agent_path

Next step:
1. Log out and log back in, or reboot and log in.
2. Wait about 20 seconds.
3. Run:

   cd "$repo_dir"
   ./scripts/diagnose.sh --json

Expected success:
- "status": "OK"
- "eventTapCreated": true
- "accessibilityTrusted": true
- "inputMonitoringGranted": true
- "processRunning": true

If the login test starts the helper but reports missing permissions, grant
"Dock Click Toggle Agent" in Accessibility and Input Monitoring. You can try
to ask macOS for the helper-specific prompts with:

   "$login_item_binary_path" --request-permissions

Note: helper permission checks run manually from Terminal are only a clue.
The real proof is the status written by the helper after log out / log in,
because macOS may evaluate privacy trust differently for a login item than
for a helper binary launched from the current shell.

If the login test fails, restore the normal Terminal-based launcher:

   cd "$repo_dir"
   ./scripts/test-agent-login-item.sh --restore

EOF
        ;;
esac
