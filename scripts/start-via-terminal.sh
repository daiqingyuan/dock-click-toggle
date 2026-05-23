#!/bin/zsh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_path="${DOCK_CLICK_TOGGLE_APP_PATH:-}"

if [[ -z "$app_path" && "$script_dir" == */Contents/Resources ]]; then
    app_path="$(cd "$script_dir/../.." && pwd)"
fi

if [[ -z "$app_path" ]]; then
    app_path="/Applications/DockClickToggle.app"
fi

binary_path="$app_path/Contents/MacOS/DockClickToggle"
support_dir="$HOME/Library/Application Support/DockClickToggle"
log_dir="$HOME/Library/Logs/DockClickToggle"
status_file="$support_dir/status.json"
out_log="$log_dir/out.log"
err_log="$log_dir/err.log"

mkdir -p "$support_dir" "$log_dir"

is_healthy() {
    local pid="$1"
    local state status_pid last_updated now age

    [[ -f "$status_file" ]] || return 1

    state="$(/usr/bin/plutil -extract state raw -o - "$status_file" 2>/dev/null || true)"
    [[ "$state" == "OK" ]] || return 1

    status_pid="$(/usr/bin/plutil -extract pid raw -o - "$status_file" 2>/dev/null || true)"
    [[ "$status_pid" == "$pid" ]] || return 1

    last_updated="$(/usr/bin/plutil -extract lastUpdatedUnix raw -o - "$status_file" 2>/dev/null || true)"
    [[ "$last_updated" == <-> ]] || return 1

    now="$(/bin/date +%s)"
    age=$((now - last_updated))
    (( age >= 0 && age <= 120 ))
}

pid="$(/usr/bin/pgrep -x DockClickToggle | /usr/bin/head -n 1 || true)"

if [[ -n "$pid" ]]; then
    if is_healthy "$pid"; then
        exit 0
    fi

    /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
    sleep 1
fi

if [[ ! -x "$binary_path" ]]; then
    echo "DockClickToggle binary not found: $binary_path" >&2
    exit 1
fi

terminal_was_running=false
if /usr/bin/pgrep -x Terminal >/dev/null 2>&1; then
    terminal_was_running=true
fi

/usr/bin/osascript - "$binary_path" "$out_log" "$err_log" "$terminal_was_running" <<'APPLESCRIPT'
on run argv
set binaryPath to item 1 of argv
set outLog to item 2 of argv
set errLog to item 3 of argv
set terminalWasRunning to item 4 of argv is "true"
set shouldKillTerminal to false

tell application "Terminal"
    set launchCommand to "nohup " & quoted form of binaryPath & " > " & quoted form of outLog & " 2> " & quoted form of errLog & " < /dev/null & disown >/dev/null 2>&1; exit"
    set launchTab to do script launchCommand
    set custom title of launchTab to "DockClickToggle Launcher"

    repeat with attempt from 1 to 50
        try
            if busy of launchTab is false then exit repeat
        on error
            exit repeat
        end try
        delay 0.1
    end repeat

    delay 0.5

    repeat with terminalWindow in (windows as list)
        try
            if custom title of selected tab of terminalWindow is "DockClickToggle Launcher" then
                close terminalWindow saving no
            end if
        end try
    end repeat

    if terminalWasRunning is false then
        set shouldKillTerminal to true
    end if
end tell

if shouldKillTerminal then
    do shell script "/usr/bin/killall Terminal >/dev/null 2>&1 || true"
end if
end run
APPLESCRIPT
