#!/bin/zsh
set -eu

uid="$(id -u)"
agent_label="local.dock-click-toggle"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
install_dir="${INSTALL_DIR:-/Applications}"
app_path="$install_dir/DockClickToggle.app"
support_dir="$HOME/Library/Application Support/DockClickToggle"
log_dir="$HOME/Library/Logs/DockClickToggle"

/bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
/usr/bin/pkill -x DockClickToggle 2>/dev/null || true
rm -f "$agent_path"
rm -rf "$app_path"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$support_dir" "$log_dir"
    rm -f /tmp/dock-click-toggle.status /tmp/dock-click-toggle.out.log /tmp/dock-click-toggle.err.log
fi

echo "Uninstalled DockClickToggle."
