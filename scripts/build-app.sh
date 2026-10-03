#!/bin/zsh
# Build LLMUsageBar.app into ./build (Command Line Tools are sufficient; Xcode is not required).
#
# Optional environment:
#   APP_VERSION   CFBundleShortVersionString (default: the value in Resources/Info.plist)
#   BUILD_NUMBER  CFBundleVersion (default: the value in Resources/Info.plist)
# Builds for the architecture of the Mac it runs on.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/LLMUsageBar"

app="build/LLMUsageBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/LLMUsageBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
[[ -n "${APP_VERSION:-}" ]] && plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$app/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
# Ad-hoc signature: not a Developer ID signature, and not notarized.
codesign --force --sign - "$app"

echo "Built $app ($(lipo -archs "$app/Contents/MacOS/LLMUsageBar"))"
