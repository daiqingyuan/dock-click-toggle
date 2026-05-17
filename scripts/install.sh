#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
uid="$(id -u)"
agent_label="local.dock-click-toggle"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
app_path="/Applications/DockClickToggle.app"

"$repo_dir/scripts/build.sh" >/dev/null

/bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
/usr/bin/pkill -x DockClickToggle 2>/dev/null || true

rm -rf "$app_path"
cp -R "$repo_dir/.build/DockClickToggle.app" "$app_path"
/usr/bin/xattr -cr "$app_path" 2>/dev/null || true
/usr/bin/codesign -f -s - --identifier local.dock-click-toggle "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"

escaped_repo_dir="${repo_dir//\\/\\\\}"
escaped_repo_dir="${escaped_repo_dir//&/\\&}"
/usr/bin/sed "s#__REPO_DIR__#$escaped_repo_dir#g" \
    "$repo_dir/packaging/local.dock-click-toggle.plist.template" > "$agent_path"

/bin/launchctl bootstrap "gui/$uid" "$agent_path"

echo "Installed DockClickToggle."
echo "Enable Accessibility and Input Monitoring permissions for DockClickToggle in System Settings."
echo "Status file: /tmp/dock-click-toggle.status"
