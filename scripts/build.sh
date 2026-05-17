#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/.build/DockClickToggle.app"
iconset_dir="$repo_dir/.build/AppIcon.iconset"

rm -rf "$app_dir"
rm -rf "$iconset_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

/usr/bin/swift "$repo_dir/scripts/render-icon.swift" "$iconset_dir"
/usr/bin/iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"

/usr/bin/swiftc \
    "$repo_dir/Sources/DockClickToggle/main.swift" \
    -o "$app_dir/Contents/MacOS/DockClickToggle" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics

cp "$repo_dir/packaging/Info.plist" "$app_dir/Contents/Info.plist"

/usr/bin/xattr -cr "$app_dir" 2>/dev/null || true
/usr/bin/codesign -f -s - --identifier local.dock-click-toggle "$app_dir"

echo "$app_dir"
