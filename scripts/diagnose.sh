#!/bin/zsh
set -u

agent_label="local.dock-click-toggle"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
default_app_path="/Applications/DockClickToggle.app"
custom_app_path="${INSTALL_DIR:-}"
app_path="${custom_app_path:+$custom_app_path/DockClickToggle.app}"
app_path="${app_path:-$default_app_path}"
binary_path="$app_path/Contents/MacOS/DockClickToggle"
launcher_path="$app_path/Contents/Resources/start-via-terminal.sh"
support_dir="$HOME/Library/Application Support/DockClickToggle"
log_dir="$HOME/Library/Logs/DockClickToggle"
status_file="$support_dir/status.json"
err_log="$log_dir/err.log"

print_kv() {
    printf '%-28s %s\n' "$1:" "$2"
}

print_header() {
    printf '\n== %s ==\n' "$1"
}

exists_text() {
    [[ -e "$1" ]] && echo "yes" || echo "no"
}

executable_text() {
    [[ -x "$1" ]] && echo "yes" || echo "no"
}

print_header "DockClickToggle Diagnose"
print_kv "App path" "$app_path"
print_kv "App exists" "$(exists_text "$app_path")"
print_kv "Binary exists" "$(exists_text "$binary_path")"
print_kv "Binary executable" "$(executable_text "$binary_path")"
print_kv "Launcher exists" "$(exists_text "$launcher_path")"
print_kv "Launcher executable" "$(executable_text "$launcher_path")"

print_header "LaunchAgent"
print_kv "Plist path" "$agent_path"
print_kv "Plist exists" "$(exists_text "$agent_path")"
if [[ -f "$agent_path" ]]; then
    lint_output="$(/usr/bin/plutil -lint "$agent_path" 2>&1)"
    lint_status=$?
    print_kv "Plist lint" "$lint_output"
    print_kv "Plist lint exit" "$lint_status"
else
    print_kv "Plist lint" "skipped"
fi

launch_output="$(/bin/launchctl print "gui/$(id -u)/$agent_label" 2>&1)"
launch_status=$?
print_kv "LaunchAgent loaded" "$([[ $launch_status -eq 0 ]] && echo yes || echo no)"
if [[ $launch_status -eq 0 ]]; then
    echo "$launch_output" | /usr/bin/grep -E 'state =|runs =|last exit code|run interval|program =|path =' || true
else
    echo "$launch_output"
fi

print_header "Process"
running_pids="$(/usr/bin/pgrep -x DockClickToggle | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//')"
print_kv "Running pids" "${running_pids:-none}"

print_header "Status"
print_kv "Status path" "$status_file"
print_kv "Status exists" "$(exists_text "$status_file")"
if [[ -f "$status_file" ]]; then
    state="$(/usr/bin/plutil -extract state raw -o - "$status_file" 2>/dev/null || echo unknown)"
    status_pid="$(/usr/bin/plutil -extract pid raw -o - "$status_file" 2>/dev/null || echo unknown)"
    updated_unix="$(/usr/bin/plutil -extract lastUpdatedUnix raw -o - "$status_file" 2>/dev/null || echo unknown)"
    updated_at="$(/usr/bin/plutil -extract lastUpdatedAt raw -o - "$status_file" 2>/dev/null || echo unknown)"
    accessibility="$(/usr/bin/plutil -extract accessibilityTrusted raw -o - "$status_file" 2>/dev/null || echo unknown)"
    input_monitoring="$(/usr/bin/plutil -extract inputMonitoringGranted raw -o - "$status_file" 2>/dev/null || echo unknown)"
    event_tap="$(/usr/bin/plutil -extract eventTapCreated raw -o - "$status_file" 2>/dev/null || echo unknown)"
    last_error="$(/usr/bin/plutil -extract lastError raw -o - "$status_file" 2>/dev/null || true)"
    now="$(/bin/date +%s)"

    print_kv "State" "$state"
    print_kv "Status pid" "$status_pid"
    print_kv "Updated at" "$updated_at"
    if [[ "$updated_unix" == <-> ]]; then
        print_kv "Status age seconds" "$((now - updated_unix))"
    else
        print_kv "Status age seconds" "unknown"
    fi
    print_kv "Accessibility trusted" "$accessibility"
    print_kv "Input monitoring" "$input_monitoring"
    print_kv "Event tap created" "$event_tap"
    print_kv "Last error" "${last_error:-none}"

    if [[ -n "$running_pids" && "$status_pid" != "unknown" ]]; then
        case " $running_pids " in
            *" $status_pid "*) print_kv "PID match" "yes" ;;
            *) print_kv "PID match" "no" ;;
        esac
    else
        print_kv "PID match" "unknown"
    fi
else
    print_kv "State" "unknown"
fi

print_header "Recent Error Log"
print_kv "Error log path" "$err_log"
if [[ -f "$err_log" ]]; then
    /usr/bin/tail -30 "$err_log"
else
    echo "No error log found."
fi

