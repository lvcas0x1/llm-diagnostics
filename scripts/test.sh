#!/bin/zsh
# Unit and integration tests (Swift Testing). Command Line Tools keep the Testing macro plugin
# outside the default plugin search path, so pass it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
