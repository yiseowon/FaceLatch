#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="dist/FaceLatch.app"
identity="${FACELATCH_SIGNING_IDENTITY:--}"
model="${FACELATCH_MODEL_PATH:-$PWD/ArcFace.mlpackage}"
stage="$(mktemp -d "${TMPDIR:-/tmp}/facelatch.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/FaceLatch.app"
mkdir -p "$bundle/Contents/"{MacOS,Resources}
cp Info.plist "$bundle/Contents/"
cp LICENSE "$bundle/Contents/Resources/Glance-LICENSE.txt"
if [[ -d "$model" ]]; then
    cp Sources/CompileModel.swift.txt "$stage/CompileModel.swift"
    swift "$stage/CompileModel.swift" "$model" "$bundle/Contents/Resources/ArcFace.mlmodelc"
elif [[ -n "${FACELATCH_MODEL_PATH:-}" ]]; then
    echo "Model package not found: $model" >&2
    exit 1
else
    echo "Building motion preview only. Add ArcFace.mlpackage to enable face recognition."
fi
swiftc -swift-version 5 -O Sources/*.swift -o "$bundle/Contents/MacOS/FaceLatch"
codesign --force --timestamp=none --sign "$identity" "$bundle"
codesign --verify --strict "$bundle"
mkdir -p dist
# Remove any model left over from a previous build.
rm -rf -- "$app"
ditto "$bundle" "$app"
codesign --verify --strict "$app"
