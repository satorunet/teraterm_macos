#!/bin/bash
# release ビルドして build/Tera Term Mac.app を作る
#   ./scripts/bundle.sh             … この Mac 用 (開発用。速い)
#   ./scripts/bundle.sh --universal … Apple Silicon と Intel の両対応
#   ./scripts/bundle.sh --dmg       … 両対応でビルドし、配布用のインストーラー (DMG) を作って公証まで行う
#                                     DMG にはアプリとアプリケーションフォルダへのリンクが入る
#                                     (アンインストールはインストール後のアプリのメニューから)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.4.1}"
BUILD_NUMBER="1"
BUNDLE_ID="${BUNDLE_ID:-net.satoru.teramac}"
NAME="Tera Term Mac"

UNIVERSAL=0
DMG=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --dmg) UNIVERSAL=1; DMG=1 ;;
        *) echo "知らないオプション: $arg" >&2; exit 1 ;;
    esac
done

if [ "$UNIVERSAL" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINDIR=".build/apple/Products/Release"
else
    swift build -c release
    BINDIR=".build/release"
fi

# Info.plist を書く: plist <出力> <実行ファイル名> <バンドル ID> <表示名> <アイコン名> <追加の XML>
plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundleName</key><string>$4</string>
    <key>CFBundleDisplayName</key><string>$4</string>
    <key>CFBundleIconFile</key><string>$5</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 satorunet. MIT License. https://github.com/satorunet/teraterm_macos</string>
$6
</dict>
</plist>
PLIST
}

APP="build/${NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/TeraMac" "$APP/Contents/MacOS/TeraMac"
# 自動アップデート (Sparkle) の部品を同梱する
mkdir -p "$APP/Contents/Frameworks"
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# ライセンス (アイコンの元の Tera Term の BSD ライセンス表示も含む)
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# 設定の初期値 (TermSettings.initial) に使う本家同梱の TERATERM.INI
cp "../installer/release/TERATERM.INI" "$APP/Contents/Resources/TERATERM.INI"
# Tera Term のテーマの見本 (installer/release/theme) とヘルプ (doc/ja/html。Tera Term と同じ BSD ライセンス: html/about/copyright.html)
UP=".."
ditto "$UP/installer/release/theme" "$APP/Contents/Resources/theme"
mkdir -p "$APP/Contents/Resources/help"
rsync -a --exclude '*.ppt' --exclude '*.drawio' --exclude '*.md' --exclude '.gitignore' \
    "$UP/doc/ja/html/" "$APP/Contents/Resources/help/html/"
# ヘルプ ID → ファイルの対応 (HelpViewer が読む): hhp の [ALIAS] と helpid.h
cp "$UP/doc/ja/teraterm.hhp" "$APP/Contents/Resources/help/teraterm.hhp"
cp "$UP/teraterm/common/helpid.h" "$APP/Contents/Resources/help/helpid.h"
plist "$APP/Contents/Info.plist" TeraMac "$BUNDLE_ID" "$NAME" AppIcon '    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Tera Term マクロ</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleTypeExtensions</key><array><string>ttl</string></array>
            <key>LSHandlerRank</key><string>Owner</string>
        </dict>
    </array>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/satorunet/teraterm_macos/main/macos/appcast.xml</string>
    <key>SUPublicEDKey</key><string>OZ6nZ4BU5/VBISm4VmPh16mCWj7BNw6+yOfTtAhYDH0=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUAllowsAutomaticUpdates</key><false/>'

# 署名: 「Developer ID Application」の証明書があればそれで (なければ ad-hoc)
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
# Sparkle の中身は内側から順に署名する (Sparkle の説明どおり)
SP="$APP/Contents/Frameworks/Sparkle.framework"
if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --timestamp -s "$SIGN_ID" "$SP/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp -s "$SIGN_ID" --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp -s "$SIGN_ID" "$SP/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp -s "$SIGN_ID" "$SP/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp -s "$SIGN_ID" "$SP"
fi
for A in "$APP"; do
    if [ -n "$SIGN_ID" ]; then
        codesign --force --options runtime --timestamp -s "$SIGN_ID" "$A"
        codesign --verify --strict "$A"
    else
        codesign --force --deep -s - "$A" >/dev/null 2>&1 || true
    fi
done
echo "signed: ${SIGN_ID:-ad-hoc}"
echo "built: $(pwd)/$APP"
lipo -archs "$APP/Contents/MacOS/TeraMac" | sed 's/^/arch: /'

if [ "$DMG" = 1 ]; then
    STAGE="build/dmg"
    VOL="${NAME} ${VERSION}"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/.background"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    BG="build/dmg-bg"
    mkdir -p "$BG"
    swift scripts/make_dmg_bg.swift "$BG/bg.png" 1 >/dev/null
    swift scripts/make_dmg_bg.swift "$BG/bg@2x.png" 2 >/dev/null
    tiffutil -cathidpicheck "$BG/bg.png" "$BG/bg@2x.png" -out "$STAGE/.background/bg.tiff" >/dev/null 2>&1
    rm -rf "$BG"

    OUT="build/TeraTermMac-${VERSION}.dmg"
    RW="build/dmg-rw.dmg"
    rm -f "$OUT" "$RW"
    hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
    rm -rf "$STAGE"
    ATTACH=$(hdiutil attach -readwrite -noverify -noautoopen "$RW")
    DEV=$(echo "$ATTACH" | grep -E '^/dev/' | head -1 | awk '{print $1}')
    # 同じ名前のディスクが開いていると「… 1」のような名前で開くので、実際の名前を使う
    MNT=$(echo "$ATTACH" | grep -o '/Volumes/.*' | head -1)
    DISK=$(basename "$MNT")
    sleep 2
    # Finder に窓の大きさ・背景・アイコンの位置を覚えさせる (.DS_Store に残る)。
    # Finder がうまく保存しないことがあるので、保存されたか確かめて、だめならやり直す
    for TRY in 1 2 3; do
    osascript <<APPLESCRIPT || true
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 542}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:bg.tiff"
        set position of item "${NAME}.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    sync
    sleep 1
    # 背景と配置が保存されると .DS_Store は 8KB を超える (保存されないと 6KB ほど)
    DSSIZE=$(stat -f%z "$MNT/.DS_Store" 2>/dev/null || echo 0)
    if [ "$DSSIZE" -gt 8000 ]; then break; fi
    echo "DMG の窓の見た目が保存されませんでした (.DS_Store ${DSSIZE} バイト)。やり直します ($TRY)" >&2
    if [ "$TRY" = 3 ]; then echo "DMG の窓の見た目を保存できませんでした" >&2; hdiutil detach "$DEV" >/dev/null; exit 1; fi
    sleep 3
    done
    rm -rf "$MNT/.fseventsd" 2>/dev/null || true
    hdiutil detach "$DEV" >/dev/null
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
    rm -f "$RW"
    if [ -n "$SIGN_ID" ]; then
        codesign --force --timestamp -s "$SIGN_ID" "$OUT"
        PROFILE="${NOTARY_PROFILE:-satoru-notary}"
        if [ "${SKIP_NOTARY:-0}" = 1 ]; then
            echo "公証はとばしました (SKIP_NOTARY=1)"
        elif xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
            xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
            xcrun stapler staple "$OUT"
            spctl -a -t open --context context:primary-signature -v "$OUT" && echo "notarized: OK"
        else
            echo "公証はとばしました (notarytool の保存済み資格情報 '$PROFILE' がない)"
        fi
    fi
    echo "dmg: $(pwd)/$OUT"
fi
