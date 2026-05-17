#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/.build/DockClickToggle.app"
iconset_dir="$repo_dir/.build/AppIcon.iconset"

clean_bundle_metadata() {
    /usr/bin/xattr -cr "$app_dir" 2>/dev/null || true
    /usr/bin/find "$app_dir" -exec /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
    /usr/bin/find "$app_dir" -exec /usr/bin/xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
}

rm -rf "$app_dir"
rm -rf "$iconset_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

/usr/bin/swift "$repo_dir/scripts/render-icon.swift" "$iconset_dir"
/usr/bin/iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
cp "$repo_dir/scripts/start-via-terminal.sh" "$app_dir/Contents/Resources/start-via-terminal.sh"
chmod +x "$app_dir/Contents/Resources/start-via-terminal.sh"

/usr/bin/swiftc \
    "$repo_dir/Sources/DockClickToggle/main.swift" \
    -o "$app_dir/Contents/MacOS/DockClickToggle" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics

cp "$repo_dir/packaging/Info.plist" "$app_dir/Contents/Info.plist"

for attempt in 1 2 3; do
    clean_bundle_metadata

    if /usr/bin/codesign -f -s - --identifier local.dock-click-toggle "$app_dir" &&
        /usr/bin/codesign --verify --deep --strict "$app_dir"; then
        break
    fi

    if [[ "$attempt" == "3" ]]; then
        echo "failed to sign $app_dir" >&2
        exit 1
    fi

    sleep 0.2
done

clean_bundle_metadata
/usr/bin/codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
