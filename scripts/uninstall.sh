#!/bin/zsh
set -eu

uid="$(id -u)"
agent_label="local.dock-click-toggle"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"

/bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
/usr/bin/pkill -x DockClickToggle 2>/dev/null || true
rm -f "$agent_path"
rm -rf /Applications/DockClickToggle.app

echo "Uninstalled DockClickToggle."

