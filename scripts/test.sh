#!/bin/zsh
# Unit, integration, and regression tests (Swift Testing).
# Command Line Tools keep the Testing macro plugin outside the default plugin search path, so pass
# it explicitly when it is there; with Xcode (e.g. on CI) no extra flag is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d $plugins ]]; then
    swift test -Xswiftc -plugin-path -Xswiftc $plugins "$@"
else
    swift test "$@"
fi
