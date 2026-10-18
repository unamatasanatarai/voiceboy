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

# Test 1: WAV transcription with FUTO English-39
printf '%s\n' ""
printf '%s\n' "==> [Test 1] Transcribing input.wav with futo-english-39.bin..."
out_wav="$("$cli_bin" input.wav --model futo-english-39.bin)"
echo "$out_wav"

if echo "$out_wav" | grep -qi "movie"; then
    printf '%s\n' "✅ [Test 1 PASSED] Successfully transcribed input.wav!"
else
    printf '%s\n' "❌ [Test 1 FAILED] Transcription did not contain expected text." >&2
    exit 1
fi

# Test 2: M4A transcription (Verifying native AVFoundation decoding without ffmpeg)
printf '%s\n' ""
printf '%s\n' "==> [Test 2] Transcribing input.m4a (Native AAC -> 16kHz PCM)..."
out_m4a="$("$cli_bin" input.m4a --model futo-english-39.bin)"
echo "$out_m4a"

if echo "$out_m4a" | grep -qi "movie"; then
    printf '%s\n' "✅ [Test 2 PASSED] Successfully decoded and transcribed input.m4a!"
else
    printf '%s\n' "❌ [Test 2 FAILED] Transcription for input.m4a did not match." >&2
    exit 1
fi

printf '%s\n' ""
printf '%s\n' "🎉 All tests passed successfully!"
