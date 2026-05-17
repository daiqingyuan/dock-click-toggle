#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
uid="$(id -u)"
agent_label="local.dock-click-toggle"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
install_dir="${INSTALL_DIR:-/Applications}"
app_path="$install_dir/DockClickToggle.app"
binary_path="$app_path/Contents/MacOS/DockClickToggle"
support_dir="$HOME/Library/Application Support/DockClickToggle"
status_file="$support_dir/status.json"

prepare_login_test=false
restore=false
status_only=false
timeout_seconds=30

usage() {
    cat <<'EOF'
Usage: ./scripts/test-smappservice-login-item.sh [options]

Experiments with SMAppService.mainApp as a login item. This does not replace
the normal Terminal-based LaunchAgent unless you explicitly prepare a real
login test.

Options:
  --status              Print the current SMAppService main-app login status.
  --prepare-login-test  Register DockClickToggle as a main-app login item,
                        disable the normal LaunchAgent, stop the app, and
                        leave the machine ready for a log out / log in test.
  --restore             Unregister the SMAppService login item and restore the
                        normal Terminal-based LaunchAgent.
  --timeout N           Seconds to wait for the immediate open probe. Default: 30.
  --help                Show this help.

Default mode registers the main-app login item, runs a same-session open probe,
then unregisters it and restores the normal LaunchAgent before exiting.

Use INSTALL_DIR=/path/to/install-dir if DockClickToggle.app is not installed
in /Applications.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --prepare-login-test)
            prepare_login_test=true
            ;;
        --restore)
            restore=true
            ;;
        --status)
            status_only=true
            ;;
        --timeout)
            shift
            timeout_seconds="${1:?missing timeout value}"
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
    /usr/bin/pgrep -x DockClickToggle 2>/dev/null | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//'
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

login_item_status() {
    "$binary_path" --login-item-status
}

register_login_item() {
    "$binary_path" --register-login-item
}

unregister_login_item() {
    "$binary_path" --unregister-login-item
}

restore_normal_launcher() {
    log "Restoring normal Terminal-based LaunchAgent"
    /bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
    if [[ -f "$agent_path" ]]; then
        /bin/launchctl bootstrap "gui/$uid" "$agent_path" 2>/dev/null || true
        /bin/launchctl kickstart -k "gui/$uid/$agent_label" 2>/dev/null || true
        if wait_for_ok 20; then
            log "Normal launcher restored"
        else
            log "Normal launcher did not reach OK within 20s"
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

if [[ "$status_only" == true ]]; then
    login_item_status
    exit 0
fi

if [[ "$restore" == true ]]; then
    log "Unregistering SMAppService main-app login item"
    unregister_login_item || true
    /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
    sleep 2
    restore_normal_launcher
    print_current_diagnose
    exit 0
fi

if [[ "$prepare_login_test" == true ]]; then
    log "Preparing real SMAppService login test"
    /bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
    /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
    rm -f "$status_file"

    log "Registering main app as SMAppService login item"
    register_login_item
    login_item_status

    cat <<EOF

The normal LaunchAgent is now disabled, and DockClickToggle is registered
as an SMAppService main-app login item.

To complete the real test:
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

To restore the normal Terminal-based launcher:

   cd "$repo_dir"
   ./scripts/test-smappservice-login-item.sh --restore

EOF
    exit 0
fi

cleanup_started=false
cleanup() {
    local exit_code="$?"
    trap - EXIT INT TERM

    if [[ "$cleanup_started" == true ]]; then
        exit "$exit_code"
    fi
    cleanup_started=true

    log "Cleaning up SMAppService experiment"
    unregister_login_item || true
    /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
    sleep 2
    restore_normal_launcher
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

log "Disabling normal LaunchAgent for safe same-session experiment"
/bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
/usr/bin/pkill -x DockClickToggle 2>/dev/null || true
sleep 2
rm -f "$status_file"

log "Registering main app as SMAppService login item"
register_login_item
login_item_status

log "Running same-session open probe. This is not a substitute for a real log out / log in test."
/usr/bin/open -gj "$app_path"

if wait_for_ok "$timeout_seconds"; then
    log "Same-session SMAppService probe reached OK"
    print_current_diagnose
else
    print_current_diagnose
    fail "Same-session SMAppService probe did not reach OK within ${timeout_seconds}s"
fi

log "SMAppService same-session experiment completed"
