#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
uid="$(id -u)"
agent_label="local.dock-click-toggle"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
install_dir="${INSTALL_DIR:-/Applications}"

default_local_sign_identity="DockClickToggle Local Code Signing"
if [[ -n "${SIGN_IDENTITY+x}" ]]; then
    sign_identity="$SIGN_IDENTITY"
elif /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    /usr/bin/grep -F "\"$default_local_sign_identity\"" >/dev/null; then
    sign_identity="$default_local_sign_identity"
else
    sign_identity="-"
fi

app_path="$install_dir/DockClickToggle.app"
support_dir="$HOME/Library/Application Support/DockClickToggle"
log_dir="$HOME/Library/Logs/DockClickToggle"
start_script="$app_path/Contents/Resources/start-via-terminal.sh"
out_log="$log_dir/out.log"
err_log="$log_dir/err.log"

"$repo_dir/scripts/build.sh" >/dev/null

/bin/launchctl bootout "gui/$uid/$agent_label" 2>/dev/null || true
/usr/bin/pkill -x DockClickToggle 2>/dev/null || true
rm -f "$support_dir/status.json" /tmp/dock-click-toggle.status /tmp/dock-click-toggle.out.log /tmp/dock-click-toggle.err.log

mkdir -p "$install_dir" "$HOME/Library/LaunchAgents" "$support_dir" "$log_dir"
rm -rf "$app_path"
cp -R "$repo_dir/.build/DockClickToggle.app" "$app_path"
/usr/bin/xattr -cr "$app_path" 2>/dev/null || true
/usr/bin/codesign -f --sign "$sign_identity" --identifier local.dock-click-toggle "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"

cp "$repo_dir/packaging/local.dock-click-toggle.plist.template" "$agent_path"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $start_script" "$agent_path"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath $err_log" "$agent_path"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath $out_log" "$agent_path"

/usr/bin/plutil -lint "$agent_path"
/bin/launchctl bootstrap "gui/$uid" "$agent_path"

echo "Installed DockClickToggle."
echo "Signing identity: $sign_identity"
echo "Enable Accessibility and Input Monitoring permissions for DockClickToggle in System Settings."
echo "To request permission prompts manually: $app_path/Contents/MacOS/DockClickToggle --request-permissions"
echo "Status file: $support_dir/status.json"
