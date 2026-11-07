#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
for tool in swift swiftc iconutil codesign; do command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }; done
arch="${ARCH:-$(uname -m)}"
case "$arch" in arm64|x86_64) ;; *) echo 'Unsupported ARCH' >&2; exit 1;; esac
sparkle_dir="$(python3 Tools/fetch_sparkle.py)"
app=dist/GameShelf.app
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p build/module-cache "$app/Contents/MacOS" "$app/Contents/Resources/Tools"
zig_exe="${ZIG:-$(command -v zig || true)}"
[[ -n "$zig_exe" ]] || { echo 'Set ZIG to an official Zig executable to build the Wine window helper.' >&2; exit 1; }
bash Tools/build_wine_window_helper.sh "$zig_exe"
cp build/GameShelfWineWindow.exe "$app/Contents/Resources/Tools/GameShelfWineWindow.exe"
swift -module-cache-path build/module-cache Tools/Icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/GameShelfIcon.icns"
swiftc -swift-version 5 -O -module-cache-path build/module-cache -target "${arch}-apple-macosx15.0" -framework AppKit -framework WebKit -framework NetFS -framework Security -framework Network \
 -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
 Sources/*.swift \
 -o "$app/Contents/MacOS/GameShelf"
for tool in prepare_rgss_dictionary.rb append_rgss3a.py migrate_mz_saves.js migrate_renpy_saves.py shared_web_storage.js; do
 cp "Tools/$tool" "$app/Contents/Resources/Tools/$tool"
done
cp Resources/Updates.json "$app/Contents/Resources/Updates.json"
cp Resources/ManagedWine.json "$app/Contents/Resources/ManagedWine.json"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>GameShelfIcon.icns</string>
<key>CFBundleIdentifier</key><string>local.gameshelf.app</string>
<key>CFBundleName</key><string>GameShelf</string>
<key>CFBundleDisplayName</key><string>GameShelf</string>
<key>CFBundleExecutable</key><string>GameShelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.1</string>
<key>CFBundleVersion</key><string>44</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSNetworkVolumesUsageDescription</key><string>读取您导入的网络卷游戏文件夹。</string>
<key>NSRemovableVolumesUsageDescription</key><string>读取您导入的外置磁盘游戏。</string>
</dict></plist>
PLIST
python3 - <<'PYUPDATES'
import json,plistlib,base64
from pathlib import Path
config=json.loads(Path('Resources/Updates.json').read_text())
assert config['feedURL'].startswith('https://')
assert len(base64.b64decode(config['publicKey'],validate=True))==32
p=Path('dist/GameShelf.app/Contents/Info.plist');info=plistlib.loads(p.read_bytes())
info.update(SUFeedURL=config['feedURL'],SUPublicEDKey=config['publicKey'],SUEnableAutomaticChecks=True,SUAutomaticallyUpdate=False,SUAllowsAutomaticUpdates=False,SUScheduledCheckInterval=14400,SUEnableSystemProfiling=False,SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0)
p.write_bytes(plistlib.dumps(info))
PYUPDATES
mkdir -p "$app/Contents/Resources/Licenses"
cp "$sparkle_dir/LICENSE" "$app/Contents/Resources/Licenses/LICENSE-Sparkle.txt"
for notice in LICENSE LICENSE-rpg-extract.txt LICENSE-WineWindow-toolchain.txt THIRD_PARTY_NOTICES.md; do
 cp "$notice" "$app/Contents/Resources/Licenses/$notice"
done
codesign --force --sign - "$app"
echo "Built $app"
