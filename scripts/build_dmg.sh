#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

source "${script_dir}/config.sh"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME,,}"
mkdir -p "$cache_dir"

build_dir="build"
app_bundle="${build_dir}/${APP_NAME}.app"
dmg_name="${APP_NAME}-${VERSION}.dmg"
dmg_path="${build_dir}/${dmg_name}"
tmp_dmg="${build_dir}/tmp_rw.dmg"

if [[ ! -d "$app_bundle" ]]; then
    printf '%s\n' "Application bundle not found. Building ${APP_NAME}..."
    "${script_dir}/build.sh"
fi

# Detach any existing mounted volumes with this name
hdi_info_file="${cache_dir}/hdiutil_info.tmp"
hdiutil info >"$hdi_info_file" 2>/dev/null || true
if [[ -f "$hdi_info_file" ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ (/Volumes/${APP_NAME}( [0-9]+)?)[[:space:]]*$ ]]; then
            hdiutil detach "${BASH_REMATCH[1]}" -force >/dev/null 2>&1 || true
        fi
    done <"$hdi_info_file"
    rm -f "$hdi_info_file"
fi

printf '%s\n' "Creating styled DMG package for ${APP_NAME} v${VERSION}..."
rm -rf "${build_dir}/dmg_root" "$tmp_dmg" "$dmg_path"
mkdir -p "${build_dir}/dmg_root/.background"

if [[ -f "Resources/dmg_background.png" ]]; then
    cp "Resources/dmg_background.png" "${build_dir}/dmg_root/.background/background.png"
    if [[ -f "Resources/dmg_background@2x.png" ]]; then
        tiffutil -cathidpicheck "Resources/dmg_background.png" "Resources/dmg_background@2x.png" -out "${build_dir}/dmg_root/.background/background.tiff" >/dev/null 2>&1 || cp "Resources/dmg_background.png" "${build_dir}/dmg_root/.background/background.tiff"
    else
        cp "Resources/dmg_background.png" "${build_dir}/dmg_root/.background/background.tiff"
    fi
fi

cp -R "$app_bundle" "${build_dir}/dmg_root/"
ln -s /Applications "${build_dir}/dmg_root/Applications"

hdiutil create -volname "${APP_NAME}" -srcfolder "${build_dir}/dmg_root" -format UDRW -ov "$tmp_dmg" >/dev/null

attach_file="${cache_dir}/hdiutil_attach.tmp"
hdiutil attach -readwrite -noverify -noautoopen "$tmp_dmg" >"$attach_file" 2>/dev/null

mount_point=""
while IFS= read -r line; do
    if [[ "$line" =~ (/Volumes/${APP_NAME}( [0-9]+)?)[[:space:]]*$ ]]; then
        mount_point="${BASH_REMATCH[1]}"
        break
    fi
done <"$attach_file"
rm -f "$attach_file"

if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
    printf '%s\n' "Error: Failed to identify disk image mount point" >&2
    exit 1
fi

osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {300, 120, 960, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        if exists file ".background:background.tiff" then
            set background picture of theViewOptions to file ".background:background.tiff"
        end if
        set position of item "${APP_NAME}.app" of container window to {180, 200}
        set position of item "Applications" of container window to {480, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$mount_point" >/dev/null 2>&1 || hdiutil detach -force "$mount_point" >/dev/null 2>&1

hdiutil convert "$tmp_dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$dmg_path" >/dev/null
rm -rf "${build_dir}/dmg_root" "$tmp_dmg"

printf '%s\n' "✅ DMG created successfully: ${dmg_path}"
