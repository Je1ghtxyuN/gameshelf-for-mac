#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app=dist/GameShelf.app
[[ -d "$app" ]] || { echo 'Run ./build.sh first.' >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo 'Invalid app version.' >&2; exit 1; }
arch=$(lipo -archs "$app/Contents/MacOS/GameShelf")
case "$arch" in arm64|x86_64) ;; *) echo 'Package a single architecture at a time.' >&2; exit 1;; esac
name="GameShelf-v${version}-macOS-${arch}"
output="dist/${name}.dmg"
[[ ! -e "$output" ]] || { echo "Already exists: $output" >&2; exit 1; }
codesign --verify --deep --strict "$app"
mkdir -p build dist
staging=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto --norsrc --noextattr --noqtn "$app" "$staging/GameShelf.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname GameShelf -srcfolder "$staging" -fs HFS+ -format UDZO -o "$output"
hdiutil verify "$output"
(
 cd dist
 assets=("${name}.dmg")
 [[ ! -f "${name}.zip" ]] || assets+=("${name}.zip")
 shasum -a 256 "${assets[@]}" > SHA256SUMS.txt.new
 mv SHA256SUMS.txt.new SHA256SUMS.txt
)
echo "Created $output"
