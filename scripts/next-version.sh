#!/bin/zsh
# Prints "version=<next version>" for a release.
# Usage: scripts/next-version.sh "<existing release tags, one per line>"
# The next version keeps Info.plist's major.minor and takes a patch one above the highest released
# patch for that major.minor, but never below Info.plist's patch. With no release yet, it is
# Info.plist's version (e.g. 0.0.1).
set -euo pipefail
cd "$(dirname "$0")/.."

base=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
prefix=${base%.*}
patch=${base##*.}
for tag in ${(f)1}; do
    [[ $tag == v$prefix.<-> ]] || continue
    released=${tag##*.}
    (( released + 1 > patch )) && patch=$(( released + 1 ))
done
echo "version=$prefix.$patch"
