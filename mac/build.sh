#!/bin/zsh
# Builds the macOS app from ../index.html
#   ./build.sh             -> /Applications/<name>.app
#   ./build.sh --snapshot  -> build/<name>.app (debug build for testing, separate app data)
set -euo pipefail
cd "${0:A:h}"
name="$(plutil -extract CFBundleName raw Info.plist)"
exe="$(plutil -extract CFBundleExecutable raw Info.plist)"
app="/Applications/$name.app"
flags=()
if [[ "${1:-}" == "--snapshot" ]]; then app="$PWD/build/$name.app"; flags=(-D SNAPSHOT); fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O $flags main.swift -o "$app/Contents/MacOS/$exe"
cp Info.plist "$app/Contents/"
[[ -n "$flags" ]] && plutil -replace CFBundleIdentifier -string "$(plutil -extract CFBundleIdentifier raw Info.plist).debug" "$app/Contents/Info.plist"
cp ../index.html AppIcon.icns "$app/Contents/Resources/"
for f in *.wav(N); do cp "$f" "$app/Contents/Resources/"; done
codesign --force --sign - "$app"
echo "built: $app"
