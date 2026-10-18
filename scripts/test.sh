#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

source "${script_dir}/config.sh"

cli_bin="build/${APP_NAME}"
if [[ ! -x "$cli_bin" ]]; then
    printf '%s\n' "==> App binary not found. Building now..."
    "${script_dir}/build.sh"
fi

printf '%s\n' "=================================================="
printf '%s\n' "VoiceBoy Test Suite: Verification & Benchmarks"
printf '%s\n' "=================================================="

# Test 1: CLI binary execution & help output
printf '%s\n' ""
printf '%s\n' "==> [Test 1] Verifying CLI help output..."
help_out="$("$cli_bin" --help)"
if echo "$help_out" | grep -qi "VoiceBoy"; then
    printf '%s\n' "✅ [Test 1 PASSED] CLI help verified."
else
    printf '%s\n' "❌ [Test 1 FAILED] CLI help did not match expected output." >&2
    exit 1
fi

# Test 2: Model catalog listing & FUTO model availability
printf '%s\n' ""
printf '%s\n' "==> [Test 2] Verifying FUTO model catalog and status..."
models_out="$("$cli_bin" --list-models)"
if echo "$models_out" | grep -qi "Available FUTO Voice Input Models"; then
    printf '%s\n' "✅ [Test 2 PASSED] Model catalog listing verified."
else
    printf '%s\n' "❌ [Test 2 FAILED] Failed to list FUTO models." >&2
    exit 1
fi

# Test 3: Application bundle structure
printf '%s\n' ""
printf '%s\n' "==> [Test 3] Verifying macOS application bundle..."
app_bundle="build/${APP_NAME}.app"
if [[ -d "$app_bundle" && -f "${app_bundle}/Contents/Info.plist" ]]; then
    printf '%s\n' "✅ [Test 3 PASSED] App bundle and Info.plist verified."
else
    printf '%s\n' "❌ [Test 3 FAILED] Application bundle missing or incomplete." >&2
    exit 1
fi

# Test 4: Native Swift unit & adversarial test suite
printf '%s\n' ""
printf '%s\n' "==> [Test 4] Compiling and running native Swift test suite..."
test_sources=()
while IFS= read -r file; do
    if [[ "$file" != "Sources/App/Main.swift" ]]; then
        test_sources+=("$file")
    fi
done < <(find Sources/App -type f -name "*.swift" | sort)
test_sources+=("Tests/VoiceBoyTests.swift")

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME,,}"
sdk_file="${cache_dir}/sdk_path.tmp"
xcrun --show-sdk-path >"$sdk_file" 2>/dev/null
IFS= read -r sdk_path <"$sdk_file"
rm -f "$sdk_file"

whisper_lib="${project_dir}/deps/whisper.cpp/build-static/libwhisper_all.a"

swiftc -sdk "$sdk_path" \
    -O \
    -whole-module-optimization \
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
    "${test_sources[@]}" \
    -o "build/VoiceBoyTests"

./build/VoiceBoyTests

printf '%s\n' ""
printf '%s\n' "🎉 All tests passed successfully!"
