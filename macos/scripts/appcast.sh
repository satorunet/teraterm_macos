#!/bin/bash
# 自動アップデート (Sparkle) の appcast.xml を書く
#   ./scripts/appcast.sh <版> <DMG のパス> [リリースノートのファイル (.md か .html)]
# リリースノートを渡すと、更新の画面に「更新内容」として出る。.md は GitHub Releases に書いたものをそのまま渡せばよい
# DMG に秘密鍵 (~/.config/teramac/sparkle_ed25519_private.txt) で署名し、macos/appcast.xml を最新の版 1 つにして書き直す。
# appcast.xml を GitHub の main に push すると、アプリが新しい版に気づく (SUFeedURL)。
# DMG は GitHub Releases の v<版> に TeraTermMac-<版>.dmg として上げておくこと。
set -euo pipefail
cd "$(dirname "$0")/.."

VER="$1"
DMG="$2"
NOTES="${3:-}"
SIGN_UPDATE="${SIGN_UPDATE:-tools/sparkle/sign_update}"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update がありません: $SIGN_UPDATE (Sparkle のリリースの bin/ から置く)" >&2; exit 1; }
[ -f "$DMG" ] || { echo "DMG がありません: $DMG" >&2; exit 1; }

# 署名の秘密鍵はファイルから読む (キーチェーンを使わないので、許可を求める画面は出ない)
KEY="${SPARKLE_KEY:-$HOME/.config/teramac/sparkle_ed25519_private.txt}"
[ -f "$KEY" ] || { echo "署名の鍵がありません: $KEY" >&2; exit 1; }
# 出力例: sparkle:edSignature="..." length="12345"
SIG=$("$SIGN_UPDATE" --ed-key-file "$KEY" "$DMG")
URL="https://github.com/satorunet/teraterm_macos/releases/download/v${VER}/TeraTermMac-${VER}.dmg"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
DESC=""
if [ -n "$NOTES" ]; then
    [ -f "$NOTES" ] || { echo "リリースノートがありません: $NOTES" >&2; exit 1; }
    case "$NOTES" in
        *.md) DESC=$(python3 scripts/notes2html.py "$NOTES") ;;
        *) DESC=$(cat "$NOTES") ;;
    esac
fi

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Tera Term Mac</title>
    <link>https://github.com/satorunet/teraterm_macos</link>
    <language>ja</language>
    <item>
      <title>Tera Term Mac ${VER}</title>
      <pubDate>${DATE}</pubDate>
      <sparkle:version>${VER}</sparkle:version>
      <sparkle:shortVersionString>${VER}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/satorunet/teraterm_macos/releases/tag/v${VER}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[${DESC}]]></description>
      <enclosure url="${URL}" ${SIG} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "appcast: $(pwd)/appcast.xml (v${VER})"
