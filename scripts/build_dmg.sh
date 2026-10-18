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
for v in /Volumes/"${APP_NAME}"*; do
    if [[ -d "$v" ]]; then
        hdiutil detach "$v" -force >/dev/null 2>&1 || true
    fi
done

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

if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${build_dir}/dmg_root/.VolumeIcon.icns"
fi

cp -R "$app_bundle" "${build_dir}/dmg_root/"
ln -s /Applications "${build_dir}/dmg_root/Applications"

# Calculate required size with headroom for filesystem structures, custom icons, and background
content_kb=$(du -sk "${build_dir}/dmg_root" | awk '{print $1}')
dmg_size_mb=$(((content_kb / 1024) + 80))
if ((dmg_size_mb < 120)); then
    dmg_size_mb=120
fi

hdiutil create -volname "${APP_NAME}" -srcfolder "${build_dir}/dmg_root" -size "${dmg_size_mb}m" -fs HFS+ -format UDRW -ov "$tmp_dmg" >/dev/null

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

mount_name="$(basename "$mount_point")"

mkdir -p "${mount_point}/.background"
if [[ -f "Resources/dmg_background.png" ]]; then
    cp "Resources/dmg_background.png" "${mount_point}/.background/background.png"
    if [[ -f "Resources/dmg_background@2x.png" ]]; then
        tiffutil -cathidpicheck "Resources/dmg_background.png" "Resources/dmg_background@2x.png" -out "${mount_point}/.background/background.tiff" >/dev/null 2>&1 || cp "Resources/dmg_background.png" "${mount_point}/.background/background.tiff"
    else
        cp "Resources/dmg_background.png" "${mount_point}/.background/background.tiff"
    fi
fi

osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    activate
    tell disk "${mount_name}"
        open
        set w to container window
        set current view of w to icon view
        set toolbar visible of w to false
        set statusbar visible of w to false
        delay 0.5
        set bounds of w to {200, 120, 888, 504}
        delay 0.5
        set theViewOptions to the icon view options of w
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        try
            set background picture of theViewOptions to (POSIX file "${mount_point}/.background/background.tiff" as alias)
        on error
            try
                set background picture of theViewOptions to (POSIX file "${mount_point}/.background/background.png" as alias)
            end try
        end try
        set position of item "${APP_NAME}.app" of w to {148, 190}
        set position of item "Applications" of w to {536, 188}
        set the bounds of container window to {200, 120, 888, 504}
        update without registering applications
        delay 2
        close container window
    end tell
end tell
APPLESCRIPT

sleep 2

# Apply custom volume icon AFTER Finder window closes to prevent Finder from stripping dotfiles
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${mount_point}/.VolumeIcon.icns"
    SetFile -c icnC "${mount_point}/.VolumeIcon.icns" >/dev/null 2>&1 || true
    SetFile -a C "$mount_point" >/dev/null 2>&1 || true
    touch "$mount_point"
fi

sync
hdiutil detach "$mount_point" >/dev/null 2>&1 || hdiutil detach -force "$mount_point" >/dev/null 2>&1

hdiutil convert "$tmp_dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$dmg_path" >/dev/null
rm -rf "${build_dir}/dmg_root" "$tmp_dmg"

# Stamp custom app icon onto the .dmg file itself
if [[ -f "Resources/AppIcon.icns" ]]; then
    swift - <<EOF >/dev/null 2>&1 || true
import Cocoa
if let img = NSImage(contentsOfFile: "Resources/AppIcon.icns") {
    NSWorkspace.shared.setIcon(img, forFile: "${dmg_path}", options: [])
}
EOF
fi

printf '%s\n' "✅ DMG created successfully: ${dmg_path}"
