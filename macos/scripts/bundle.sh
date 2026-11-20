#!/bin/bash
# release ビルドして build/Tera Term Mac.app を作る
#   ./scripts/bundle.sh             … この Mac 用
#   ./scripts/bundle.sh --universal … Apple Silicon と Intel の両対応
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUNDLE_ID="${BUNDLE_ID:-net.satoru.teramac}"

if [ "${1:-}" = "--universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/TeraMac"
else
    swift build -c release
    BIN=".build/release/TeraMac"
fi

APP="build/Tera Term Mac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TeraMac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TeraMac</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Tera Term Mac</string>
    <key>CFBundleDisplayName</key><string>Tera Term Mac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Based on Tera Term (BSD License)</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Tera Term マクロ</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleTypeExtensions</key><array><string>ttl</string></array>
            <key>LSHandlerRank</key><string>Owner</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
    echo "signed: $SIGN_ID"
else
    codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
    echo "signed: ad-hoc"
fi
echo "built: $(pwd)/$APP"
