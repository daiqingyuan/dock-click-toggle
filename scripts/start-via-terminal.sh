#!/bin/zsh
set -eu

if /usr/bin/pgrep -qx DockClickToggle; then
    exit 0
fi

/usr/bin/osascript <<'APPLESCRIPT'
tell application "Terminal"
    do script "nohup /Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle >/tmp/dock-click-toggle.out.log 2>/tmp/dock-click-toggle.err.log & exit"
end tell

delay 1

try
    tell application "Terminal" to set visible to false
end try
APPLESCRIPT

