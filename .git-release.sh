# shellcheck shell=bash
# Release configuration for `git release` / `grel` / `gemini-release`.
# Sourced from the repository root before the target version is known.

APP_NAME="VoiceBoy"
VERSION_FILE="VERSION"

TEST_CMD="./scripts/test.sh"

# The tool writes the new version to VERSION before running BUILD_CMD.
# - Unset VERSION/BUILD_NUMBER so scripts/config.sh re-reads them from disk.
# - Run build.sh explicitly: build_dmg.sh reuses an existing .app, which would
#   still carry the previous version.
# - Copy the versioned DMG to a stable name, since RELEASE_ASSETS is evaluated
#   before the target version is known.
BUILD_CMD='env -u VERSION -u BUILD_NUMBER bash -c '\''
set -Eeuo pipefail
./scripts/build.sh
./scripts/build_dmg.sh
cp "build/VoiceBoy-$(tr -d "[:space:]" < VERSION).dmg" build/VoiceBoy.dmg
'\'''

RELEASE_ASSETS=("build/VoiceBoy.dmg")
