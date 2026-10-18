#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

source "${script_dir}/config.sh"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME,,}"
mkdir -p "$cache_dir"

sdk_file="${cache_dir}/sdk_path.tmp"
xcrun --show-sdk-path >"$sdk_file" 2>/dev/null
if [[ ! -s "$sdk_file" ]]; then
    rm -f "$sdk_file"
    printf '%s\n' "Error: Failed to obtain SDK path from xcrun" >&2
    exit 1
fi
IFS= read -r sdk_path <"$sdk_file"
rm -f "$sdk_file"

# Ensure whisper.cpp submodule is initialized and checked out
if [[ ! -f "${project_dir}/deps/whisper.cpp/CMakeLists.txt" ]]; then
    printf '%s\n' "==> Initializing whisper.cpp dependency submodule..."
    git -C "${project_dir}" submodule update --init --recursive
fi

# Ensure whisper static library is ready
whisper_lib="${project_dir}/deps/whisper.cpp/build-static/libwhisper_all.a"
if [[ ! -f "$whisper_lib" ]]; then
    printf '%s\n' "==> Static whisper library missing; compiling now..."
    mkdir -p "${project_dir}/deps/whisper.cpp/build-static"
    cmake -S "${project_dir}/deps/whisper.cpp" -B "${project_dir}/deps/whisper.cpp/build-static" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DGGML_METAL=OFF \
        -DGGML_BLAS_DEFAULT=ON
    cmake --build "${project_dir}/deps/whisper.cpp/build-static" --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    libtool -static -o "$whisper_lib" \
        "${project_dir}/deps/whisper.cpp/build-static/src/libwhisper.a" \
        "${project_dir}/deps/whisper.cpp/build-static/src/libparakeet.a" \
        "${project_dir}/deps/whisper.cpp/build-static/ggml/src/libggml.a" \
        "${project_dir}/deps/whisper.cpp/build-static/ggml/src/libggml-base.a" \
        "${project_dir}/deps/whisper.cpp/build-static/ggml/src/libggml-cpu.a" \
        "${project_dir}/deps/whisper.cpp/build-static/ggml/src/ggml-blas/libggml-blas.a"
fi

# Increment and track build number
build_num_file="${project_dir}/BUILD_NUMBER"
if [[ -f "$build_num_file" ]]; then
    current_build="$(cat "$build_num_file")"
    current_build="${current_build//[[:space:]]/}"
    if [[ "$current_build" =~ ^[0-9]+$ ]]; then
        build_number=$((current_build + 1))
    else
        build_number=1
    fi
else
    build_number=1
fi
printf '%s\n' "$build_number" >"$build_num_file"
export BUILD_NUMBER="$build_number"

build_dir="build"
app_name="${APP_NAME}"
bundle_id="${BUNDLE_ID}"
app_dir="${build_dir}/${app_name}.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

mkdir -p "$macos_dir" "$resources_dir"

if [[ -f "VERSION" ]]; then
    cp "VERSION" "${resources_dir}/VERSION"
fi
printf '%s\n' "$build_number" >"${resources_dir}/BUILD_NUMBER"

if [[ -d "Resources" ]]; then
    cp -R Resources/. "${resources_dir}/"
fi

sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find Sources/App -type f -name "*.swift" | sort)

printf '%s\n' "Compiling ${app_name} v${VERSION} (Build ${BUILD_NUMBER}) (${#sources[@]} source files)..."
swiftc -sdk "$sdk_path" \
    -O \
    -whole-module-optimization \
    -Xlinker -dead_strip \
    -import-objc-header Sources/BridgingHeader.h \
    -I deps/whisper.cpp/include \
    -I deps/whisper.cpp/ggml/include \
    -Xlinker "$whisper_lib" \
    -lc++ \
    -framework Accelerate \
    -framework Metal \
    -framework MetalKit \
    -framework Foundation \
    -framework AVFoundation \
    -framework Cocoa \
    -framework Carbon \
    "${sources[@]}" \
    -o "${macos_dir}/${app_name}"

# Also symlink CLI binary directly in build/ for easy terminal invocation
ln -sf "${app_name}.app/Contents/MacOS/${app_name}" "${build_dir}/${app_name}"

printf '%s\n' "Generating ${app_name} Info.plist..."
cat <<EOF >"${contents_dir}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${app_name}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>LSUIElement</key>
    <${LS_UI_ELEMENT}/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceBoy needs access to your microphone for real-time live voice transcription.</string>
    <key>NSHumanReadableCopyright</key>
    <string>${COPYRIGHT}</string>
</dict>
</plist>
EOF

printf '%s\n' "Signing ${app_name} bundle..."
codesign --force --deep --sign - --requirements "=designated => identifier \"${bundle_id}\"" "$app_dir"

printf '%s\n' "Refreshing macOS LaunchServices cache..."
touch "$app_dir"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$app_dir" >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

printf '%s\n' "✅ Build complete:"
printf '%s\n' "   - App Bundle: ${app_dir}"
printf '%s\n' "   - CLI Tool:   ${build_dir}/${app_name}"
