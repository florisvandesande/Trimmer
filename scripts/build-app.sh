#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build -c release
binary_directory=$(swift build -c release --show-bin-path)
app_directory="$PWD/dist/Trimmer.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/Trimmer" "$app_directory/Contents/MacOS/Trimmer"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$app_directory/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_directory"
echo "Gebouwd: $app_directory"
