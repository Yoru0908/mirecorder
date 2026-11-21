#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output=${BUILD_DIR:-"$root/build"}
identity=${CODESIGN_IDENTITY:--}
app="$output/mirecorder.app"

mkdir -p -- "$output"
staging=$(mktemp -d "$output/.mirecorder.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/mirecorder.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$root/Info.plist" "$bundle/Contents/Info.plist"

xcrun swiftc -parse-as-library -O -module-name Mirecorder \
    -target "$(uname -m)-apple-macosx15.0" \
    "$root/main.swift" "$root/ContentView.swift" "$root/RecordEngine.swift" \
    "$root/AudioMixer.swift" "$root/Trimmer.swift" \
    -o "$bundle/Contents/MacOS/mirecorder"

codesign --force --sign "$identity" "$bundle"
codesign --verify "$bundle"
ditto "$bundle" "$app"
codesign --verify "$app"
printf 'Built %s\n' "$app"
