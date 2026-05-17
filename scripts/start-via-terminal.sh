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
    [[ -f "$status_file" ]] && /usr/bin/grep -q '"state"[[:space:]]*:[[:space:]]*"OK"' "$status_file"
}

if /usr/bin/pgrep -qx DockClickToggle; then
    if is_healthy; then
        exit 0
    fi

    /usr/bin/pkill -x DockClickToggle 2>/dev/null || true
    sleep 1
fi

if [[ ! -x "$binary_path" ]]; then
    echo "DockClickToggle binary not found: $binary_path" >&2
    exit 1
fi

/usr/bin/osascript - "$binary_path" "$out_log" "$err_log" <<'APPLESCRIPT'
on run argv
set binaryPath to item 1 of argv
set outLog to item 2 of argv
set errLog to item 3 of argv

tell application "Terminal"
    do script "nohup " & quoted form of binaryPath & " > " & quoted form of outLog & " 2> " & quoted form of errLog & " & exit"
end tell
end run
APPLESCRIPT
