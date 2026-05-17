#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
uid="$(id -u)"
main_label="local.dock-click-toggle"
test_label="local.dock-click-toggle.open-test"
main_agent_path="$HOME/Library/LaunchAgents/$main_label.plist"
test_agent_path="$HOME/Library/LaunchAgents/$test_label.plist"
install_dir="${INSTALL_DIR:-/Applications}"
app_path="$install_dir/DockClickToggle.app"
support_dir="$HOME/Library/Application Support/DockClickToggle"
log_dir="$HOME/Library/Logs/DockClickToggle"
status_file="$support_dir/status.json"
out_log="$log_dir/open-test.out.log"
err_log="$log_dir/open-test.err.log"

manual=false
restart_test=false
timeout_seconds=30
restart_timeout_seconds=80

usage() {
    cat <<'EOF'
Usage: ./scripts/test-open-launcher.sh [options]

Temporarily tests launching DockClickToggle with:

    /usr/bin/open -gj /Applications/DockClickToggle.app

The script disables the normal Terminal-based LaunchAgent during the test,
uses a separate local.dock-click-toggle.open-test LaunchAgent, then restores
the normal LaunchAgent before exiting.

Options:
  --manual          Pause after open -gj reaches OK so you can click Dock icons.
  --restart-test    Kill DockClickToggle and wait for the open-test LaunchAgent
                    StartInterval to relaunch it.
  --timeout N       Seconds to wait for the first OK status. Default: 30.
  --help            Show this help.

Use INSTALL_DIR=/path/to/install-dir if DockClickToggle.app is not installed
in /Applications.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --manual)
            manual=true
            ;;
        --restart-test)
            restart_test=true
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

xml_escape() {
    printf '%s' "$1" | /usr/bin/perl -pe 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g'
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

    while [[ "$(date +%s)" -le "$deadline" ]]; do
        if is_status_ok; then
            return 0
        fi
        sleep 1
    done

    return 1
}

print_status_summary() {
    local state status_pid updated_unix age event_tap last_error
    state="$(plist_value state || echo unknown)"
    status_pid="$(plist_value pid || echo unknown)"
    updated_unix="$(plist_value lastUpdatedUnix || echo unknown)"
    age="$(status_age_seconds "$updated_unix")"
    event_tap="$(plist_value eventTapCreated || echo unknown)"
    last_error="$(plist_value lastError || true)"

    printf 'state=%s pid=%s age=%s eventTapCreated=%s lastError=%s\n' \
        "$state" "$status_pid" "$age" "$event_tap" "${last_error:-none}"
}

print_open_test_debug() {
    log "Open-test LaunchAgent details"
    /bin/launchctl print "gui/$uid/$test_label" 2>&1 |
        /usr/bin/grep -E 'state =|runs =|last exit code|run interval|program =|path =' || true

    log "Open-test stderr log"
    if [[ -f "$err_log" ]]; then
        /usr/bin/tail -30 "$err_log"
    else
        echo "No open-test stderr log found."
    fi
}

main_was_loaded=false
if /bin/launchctl print "gui/$uid/$main_label" >/dev/null 2>&1; then
    main_was_loaded=true
fi

cleanup_started=false
cleanup() {
    local exit_code="$?"
    trap - EXIT INT TERM

    if [[ "$cleanup_started" == true ]]; then
        exit "$exit_code"
    fi
    cleanup_started=true

    log "Cleaning up open-test launcher"
    /bin/launchctl bootout "gui/$uid/$test_label" 2>/dev/null || true
    rm -f "$test_agent_path"

    /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
    sleep 2

    if [[ "$main_was_loaded" == true && -f "$main_agent_path" ]]; then
        log "Restoring normal Terminal-based launcher"
        /bin/launchctl bootstrap "gui/$uid" "$main_agent_path" 2>/dev/null || true
        /bin/launchctl kickstart -k "gui/$uid/$main_label" 2>/dev/null || true
        if wait_for_ok 20; then
            log "Normal launcher restored: $(print_status_summary)"
        else
            log "Normal launcher restore did not reach OK within 20s"
        fi
    else
        log "Normal launcher was not loaded before the test; leaving it unloaded"
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

[[ -d "$app_path" ]] || fail "Missing $app_path. Run ./scripts/install.sh first, or pass INSTALL_DIR."
[[ -x "$app_path/Contents/MacOS/DockClickToggle" ]] || fail "Missing executable in $app_path."

mkdir -p "$HOME/Library/LaunchAgents" "$support_dir" "$log_dir"

log "Disabling normal launcher and current DockClickToggle process"
/bin/launchctl bootout "gui/$uid/$test_label" 2>/dev/null || true
rm -f "$test_agent_path"
/bin/launchctl bootout "gui/$uid/$main_label" 2>/dev/null || true
/usr/bin/pkill -x DockClickToggle 2>/dev/null || true
sleep 2
rm -f "$status_file"

cat > "$test_agent_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$test_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-gj</string>
        <string>$(xml_escape "$app_path")</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$out_log")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$err_log")</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$test_agent_path"

log "Bootstrapping open-test launcher: $test_label"
/bin/launchctl bootstrap "gui/$uid" "$test_agent_path"
/bin/launchctl kickstart -k "gui/$uid/$test_label" 2>/dev/null || true

log "Waiting for open -gj launched app to report OK"
if ! wait_for_ok "$timeout_seconds"; then
    print_open_test_debug
    log "Normal diagnose output follows; LaunchAgent fields refer to $main_label, not $test_label"
    "$repo_dir/scripts/diagnose.sh" --json || true
    fail "open -gj did not reach healthy OK status within ${timeout_seconds}s"
fi

log "open -gj reached OK: $(print_status_summary)"
"$repo_dir/scripts/diagnose.sh" --json

if [[ "$restart_test" == true ]]; then
    old_pid="$(plist_value pid || echo unknown)"
    log "Killing DockClickToggle to test open-test StartInterval recovery"
    /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
    sleep 3

    if ! wait_for_ok "$restart_timeout_seconds"; then
        print_open_test_debug
        log "Normal diagnose output follows; LaunchAgent fields refer to $main_label, not $test_label"
        "$repo_dir/scripts/diagnose.sh" --json || true
        fail "open-test launcher did not recover to OK within ${restart_timeout_seconds}s"
    fi

    new_pid="$(plist_value pid || echo unknown)"
    log "open-test recovery reached OK: oldPid=$old_pid newPid=$new_pid $(print_status_summary)"
fi

if [[ "$manual" == true ]]; then
    cat <<'EOF'

Open-test launcher is active now.

Manual check:
1. Make any normal app frontmost.
2. Click that app's Dock icon.
3. Confirm its visible windows minimize.
4. Click the same Dock icon again and confirm Dock restores it normally.

Press Return here to restore the normal Terminal-based launcher.
EOF
    read -r _
fi

log "Open launcher experiment completed"
