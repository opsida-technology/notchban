#!/bin/zsh
# Builds Notchban.app (release) with its icon into ./build and prints the path.
# With NOTARY_PROFILE set (a `xcrun notarytool store-credentials` profile) it signs with the Developer ID,
# notarizes, staples and leaves build/Notchban-<version>.zip for a release; otherwise it signs ad hoc.
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
app=build/Notchban.app
rm -rf "$app" build/icon.iconset
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/icon.iconset
cp "$(swift build -c release --show-bin-path)/notchban" "$app/Contents/MacOS/notchban"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Notchban</string>
<key>CFBundleDisplayName</key><string>Notchban</string>
<key>CFBundleIdentifier</key><string>com.opsidatech.notchban</string>
<key>CFBundleExecutable</key><string>notchban</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-0.1.0}</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>2026 Özgün Kasap</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  codesign --force --sign - "$app" >/dev/null
  echo "$PWD/$app"
  exit
fi
identity=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
codesign --force --options runtime --timestamp --sign "$identity" "$app"
zip=build/Notchban-${VERSION:-0.1.0}.zip
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
# a failed submit leaves a signed but unnotarized app: Gatekeeper must accept it before it ships
spctl -a -vvv -t exec "$app" 2>&1 | tee /dev/stderr | grep -q "source=Notarized Developer ID"
rm "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$PWD/$zip"
