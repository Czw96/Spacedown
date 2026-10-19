#!/bin/bash
# 打包发布：Release 构建 → （可选）Developer ID 签名 + 公证 → dmg / zip → Cask → （可选）GitHub Release。
#
# 用法：
#   scripts/release.sh                          # 版本取 gen_project.py 的 MARKETING_VERSION
#   scripts/release.sh --version 1.1.0
#   scripts/release.sh --version 1.1.0 --publish
#
# 公开发布前必须先有 Developer ID 证书，并把公证凭据存进钥匙串：
#   xcrun notarytool store-credentials spacedown \
#     --apple-id <Apple ID> --team-id <Team ID> --password <App 专用密码>
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=spacedown scripts/release.sh --version 1.1.0 --publish
#
# 不带 SIGN_IDENTITY 时产物是 ad-hoc 签名：能装能用，但下载后首次打开会被 Gatekeeper 拦。
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Spacedown"
REPO="Czw96/Spacedown"                      # 源码仓库（私有）
RELEASE_REPO="Czw96/Spacedown-releases"    # 公开的二进制发布仓库（Cask 从这里下载）
OUT="Distribution/build"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"

VERSION=""
PUBLISH=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --publish) PUBLISH=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：$1"; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    VERSION=$(python3 -c '
import re, pathlib
s = pathlib.Path("scripts/gen_project.py").read_text()
print(re.search(r"\"MARKETING_VERSION\": \"([^\"]+)\"", s).group(1))
')
fi
BUILD_NUMBER=$(date +%Y%m%d%H%M)
DMG="$OUT/$APP_NAME-$VERSION.dmg"
ZIP="$OUT/$APP_NAME-$VERSION.zip"
CASK="$OUT/spacedown.rb"

echo "==> 版本 $VERSION ($BUILD_NUMBER)"

# 工程是生成的：先重跑，避免 pbxproj 落后于源码目录
python3 scripts/gen_project.py

echo "==> 构建"
xcodebuild -project Spacedown.xcodeproj -scheme Spacedown -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    clean build >/tmp/spacedown-release-build.log 2>&1 \
    || { tail -30 /tmp/spacedown-release-build.log; exit 1; }
grep -E "BUILD (SUCCEEDED|FAILED)" /tmp/spacedown-release-build.log | tail -1

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$BUILT_VERSION" == "$VERSION" ]] \
    || { echo "版本不一致：产物是 $BUILT_VERSION，期望 $VERSION"; exit 1; }

# 签名：从里往外（先内层 framework / xpc / appex，最后才是 App），否则外层封条会被内层改动破坏
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> Developer ID 签名：$SIGN_IDENTITY"
    sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$1"; }

    APPEX="$APP/Contents/PlugIns/QuickLookPreview.appex"
    for framework in "$APP/Contents/Frameworks/"*.framework; do sign "$framework"; done
    for framework in "$APPEX/Contents/Frameworks/"*.framework; do sign "$framework"; done
    sign "$APPEX/Contents/XPCServices/LinkOpener.xpc"
    sign "$APPEX"
    sign "$APP"

    codesign --verify --deep --strict --verbose=2 "$APP"
else
    echo "⚠️ 未提供 SIGN_IDENTITY：维持 ad-hoc 签名（Gatekeeper 会拦下载后的首次打开）"
fi

# 公证：先公证 App（zip 承载），staple 后再打 dmg —— 这样离线首次启动也能通过
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "公证需要 Developer ID 签名"; exit 1; }
    echo "==> 公证"
    NOTARY_ZIP="$OUT/notarize.zip"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$NOTARY_ZIP"
    spctl -a -vvv -t exec "$APP" || true
fi

echo "==> 打包"
rm -rf "$OUT"
mkdir -p "$OUT"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'TXT'
把 Spacedown 拖到左边的「应用程序」文件夹即可。

首次打开：
- 已公证的版本：直接双击。
- 未公证的版本（内测）：在「应用程序」里右键 Spacedown → 打开 → 再点「打开」。
  仍然被拦的话，在终端执行：
      xattr -dr com.apple.quarantine /Applications/Spacedown.app

空格预览：
1. 先启动一次 Spacedown（系统才会登记它的快速查看扩展）。
2. 菜单「显示 → 接管 Markdown 空格预览」，等几秒生效。
TXT

hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SHA_DMG=$(shasum -a 256 "$DMG" | awk '{print $1}')
SHA_ZIP=$(shasum -a 256 "$ZIP" | awk '{print $1}')

# Homebrew Cask：自建 tap 用（Czw96/homebrew-spacedown 的 Casks/spacedown.rb）
cat > "$CASK" <<RUBY
cask "spacedown" do
  version "$VERSION"
  sha256 "$SHA_DMG"

  url "https://github.com/$RELEASE_REPO/releases/download/v#{version}/Spacedown-#{version}.dmg"
  name "Spacedown"
  desc "Markdown Quick Look preview and read-only multi-tab viewer"
  homepage "https://github.com/$REPO"

  depends_on macos: :ventura

  app "Spacedown.app"

  zap trash: [
    "/tmp/spacedown-debug.log",
    "~/Library/Caches/cn.29dev.Spacedown",
    "~/Library/Containers/cn.29dev.Spacedown.QuickLookPreview",
    "~/Library/HTTPStorages/cn.29dev.Spacedown",
    "~/Library/Preferences/cn.29dev.Spacedown.plist",
    "~/Library/Saved Application State/cn.29dev.Spacedown.savedState",
  ]
end
RUBY

echo ""
echo "==> 产物"
printf "  %-42s %8s  %s\n" "$DMG" "$(du -h "$DMG" | cut -f1)" "$SHA_DMG"
printf "  %-42s %8s  %s\n" "$ZIP" "$(du -h "$ZIP" | cut -f1)" "$SHA_ZIP"
printf "  %-42s\n" "${CASK}（Homebrew Cask，放到 tap 的 Casks/ 下）"

if [[ $PUBLISH -eq 1 ]]; then
    command -v gh >/dev/null || { echo "发布需要 gh（brew install gh）"; exit 1; }
    echo "==> 发布 GitHub Release v$VERSION（仓库：$RELEASE_REPO）"
    NOTES=$(mktemp)
    cat > "$NOTES" <<TXT
macOS 13+ / Apple Silicon。源码仓库为私有，这里只放构建产物。

**安装**
1. 下载 dmg，双击挂载，把 Spacedown 拖进「应用程序」
2. 首次打开：右键 → 打开（当前为 ad-hoc 签名、未公证）
3. 启动一次后，菜单「显示 → 接管 Markdown 空格预览」

**Homebrew**
brew tap czw96/spacedown && brew install --cask spacedown
TXT
    gh release create "v$VERSION" "$DMG" "$ZIP" \
        --repo "$RELEASE_REPO" \
        --title "$APP_NAME $VERSION" \
        --notes-file "$NOTES"
    rm -f "$NOTES"
    echo "已发布：https://github.com/$RELEASE_REPO/releases/tag/v$VERSION"
else
    echo ""
    echo "发布：scripts/release.sh --version $VERSION --publish"
fi
