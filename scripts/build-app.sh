#!/bin/zsh
# Build LLMUsageBar.app into ./build (Command Line Tools are sufficient; Xcode is not required).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/LLMUsageBar"

app="build/LLMUsageBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/LLMUsageBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "Built $app"
