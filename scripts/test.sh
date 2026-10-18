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

# Optional audio file transcription if present
if [[ -f "input.m4a" ]]; then
    printf '%s\n' ""
    printf '%s\n' "==> [Audio Test] Transcribing input.m4a (Native AAC -> 16kHz PCM)..."
    out_m4a="$("$cli_bin" input.m4a --model futo-english-39.bin)"
    echo "$out_m4a"
    if echo "$out_m4a" | grep -qi "movie"; then
        printf '%s\n' "✅ [Audio Test PASSED] Successfully decoded and transcribed input.m4a!"
    else
        printf '%s\n' "❌ [Audio Test FAILED] Transcription for input.m4a did not match." >&2
        exit 1
    fi
fi

printf '%s\n' ""
printf '%s\n' "🎉 All tests passed successfully!"
