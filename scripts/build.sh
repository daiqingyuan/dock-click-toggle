#!/bin/zsh
set -eu

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/.build/DockClickToggle.app"
agent_dir="$app_dir/Contents/Library/LoginItems/DockClickToggleAgent.app"
iconset_dir="$repo_dir/.build/AppIcon.iconset"

default_local_sign_identity="DockClickToggle Local Code Signing"
if [[ -n "${SIGN_IDENTITY+x}" ]]; then
    sign_identity="$SIGN_IDENTITY"
elif /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    /usr/bin/grep -F "\"$default_local_sign_identity\"" >/dev/null; then
    sign_identity="$default_local_sign_identity"
else
    sign_identity="-"
fi

clean_bundle_metadata() {
    /usr/bin/xattr -cr "$app_dir" 2>/dev/null || true
    /usr/bin/find "$app_dir" -exec /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
    /usr/bin/find "$app_dir" -exec /usr/bin/xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
}

verify_bundle() {
    for verify_attempt in 1 2 3 4 5; do
        clean_bundle_metadata
        if /usr/bin/codesign --verify --deep --strict "$app_dir" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done

    /usr/bin/codesign --verify --deep --strict "$app_dir"
}

verify_target() {
    local target="$1"
    for verify_attempt in 1 2 3 4 5; do
        clean_bundle_metadata
        if /usr/bin/codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done

    /usr/bin/codesign --verify --deep --strict "$target"
}

sign_target() {
    local target="$1"
    local identifier="$2"

    for attempt in 1 2 3; do
        clean_bundle_metadata

        if [[ "$attempt" == "3" ]]; then
            if /usr/bin/codesign -f --sign "$sign_identity" --identifier "$identifier" "$target" &&
                verify_target "$target"; then
                return 0
            fi
        else
            if /usr/bin/codesign -f --sign "$sign_identity" --identifier "$identifier" "$target" >/dev/null 2>&1 &&
                verify_target "$target"; then
                return 0
            fi
        fi

        if [[ "$attempt" == "3" ]]; then
            echo "failed to sign $target" >&2
            exit 1
        fi

        sleep 0.2
    done
}

rm -rf "$app_dir"
rm -rf "$iconset_dir"
mkdir -p \
    "$app_dir/Contents/MacOS" \
    "$app_dir/Contents/Resources" \
    "$agent_dir/Contents/MacOS" \
    "$agent_dir/Contents/Resources"

/usr/bin/swift "$repo_dir/scripts/render-icon.swift" "$iconset_dir"
/usr/bin/iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
cp "$app_dir/Contents/Resources/AppIcon.icns" "$agent_dir/Contents/Resources/AppIcon.icns"
cp "$repo_dir/scripts/start-via-terminal.sh" "$app_dir/Contents/Resources/start-via-terminal.sh"
chmod +x "$app_dir/Contents/Resources/start-via-terminal.sh"

/usr/bin/swiftc \
    "$repo_dir/Sources/DockClickToggle/main.swift" \
    -o "$app_dir/Contents/MacOS/DockClickToggle" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ServiceManagement

/usr/bin/swiftc \
    -D DOCK_CLICK_TOGGLE_AGENT \
    "$repo_dir/Sources/DockClickToggle/main.swift" \
    -o "$agent_dir/Contents/MacOS/DockClickToggleAgent" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ServiceManagement

cp "$repo_dir/packaging/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/packaging/AgentInfo.plist" "$agent_dir/Contents/Info.plist"

sign_target "$agent_dir" "local.dock-click-toggle.agent"
sign_target "$app_dir" "local.dock-click-toggle"

verify_bundle
clean_bundle_metadata

echo "$app_dir"
