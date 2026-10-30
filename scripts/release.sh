#!/bin/bash
# 打包发布：Release 构建 → （可选）Developer ID 签名 + 公证 → dmg / zip → Cask → （可选）发 Release / 更新 tap。
#
# 用法：
#   scripts/release.sh                                  # 版本取 gen_project.py 的 MARKETING_VERSION
#   scripts/release.sh --version 1.1.0                  # 指定版本
#   scripts/release.sh --version 1.1.0 --publish        # 同时发 GitHub Release（到 tap 仓库）
#   scripts/release.sh --version 1.1.0 --update-tap     # 同时把 Cask 提交进 tap 仓库
#   scripts/release.sh --version 1.1.0 --skip-build --update-tap   # 只重推现有 Cask，不重新构建
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
RELEASE_REPO="Czw96/homebrew-spacedown"     # tap 仓库：Cask 与产物放一起
OUT="Distribution/build"
# 构建目录必须放在 Spotlight 不索引的地方（实测：~/Library/Caches 与 /tmp 不被索引，
# 仓库内与 ~/Library/Developer 都会被索引）。否则搜 Spacedown.app 会同时命中
# "已安装的"和"构建产物"，看起来像卸载没生效。
DERIVED="${DERIVED_PATH:-$HOME/Library/Caches/Spacedown/DerivedData}"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"

VERSION=""
PUBLISH=0
UPDATE_TAP=0
SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --publish) PUBLISH=1; shift ;;
        --update-tap) UPDATE_TAP=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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

DMG="$OUT/$APP_NAME-$VERSION.dmg"
ZIP="$OUT/$APP_NAME-$VERSION.zip"
CASK="$OUT/spacedown.rb"

echo "==> 版本 $VERSION"

# ---------------------------------------------------------------- 构建与打包

if [[ $SKIP_BUILD -eq 0 ]]; then
    BUILD_NUMBER=$(date +%Y%m%d%H%M)

    # 工程是生成的：先重跑，避免 pbxproj 落后于源码目录
    python3 scripts/gen_project.py

    echo "==> 构建"
    # 构建产物落在仓库里，Spotlight 会把它当成"又一个 Spacedown.app"；标记目录不索引
    mkdir -p build && touch build/.metadata_never_index
    xcodebuild -project Spacedown.xcodeproj -scheme Spacedown -configuration Release \
        -derivedDataPath "$DERIVED" \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        clean build >/tmp/spacedown-release-build.log 2>&1 \
        || { tail -30 /tmp/spacedown-release-build.log; exit 1; }
    grep -E "BUILD (SUCCEEDED|FAILED)" /tmp/spacedown-release-build.log | tail -1

    BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
    [[ "$BUILT_VERSION" == "$VERSION" ]] \
        || { echo "版本不一致：产物是 ${BUILT_VERSION}，期望 $VERSION"; exit 1; }

    # 签名：从里往外（先内层 framework / xpc / appex，最后才是 App），否则外层封条会被内层改动破坏
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        echo "==> Developer ID 签名：$SIGN_IDENTITY"
        sign() { codesign --force --timestamp --options runtime \
            --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$1"; }

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

    # 优先用 dmgbuild 生成带 Finder 布局的 dmg（背景/图标坐标/窗口大小都会写进
    # .DS_Store）；没装依赖时回退普通 hdiutil，功能一致只是不好看
    DMG_PY="${DMG_PYTHON:-python3}"
    if "$DMG_PY" -c 'import dmgbuild, PIL' >/dev/null 2>&1; then
        "$DMG_PY" scripts/make_dmg.py \
            --app "$APP" --out "$DMG" --version "$VERSION" \
            --icon Spacedown/Resources/AppIcon.icns
    else
        echo "    提示：未安装 dmgbuild/pillow，回退普通 dmg（pip install dmgbuild pillow 可启用美化布局）"
        STAGE=$(mktemp -d)
        cp -R "$APP" "$STAGE/"
        ln -s /Applications "$STAGE/Applications"
        cat > "$STAGE/安装说明.txt" <<'TXT'
把 Spacedown 拖到左边的「应用程序」文件夹即可。

首次打开（未公证版本）：
- 双击后若提示「Apple 无法验证 Spacedown.app」，点「完成」；
- 打开 系统设置 → 隐私与安全性 → 拉到底部，点「仍要打开」，输入密码/Touch ID；
- 或在终端执行：xattr -dr com.apple.quarantine /Applications/Spacedown.app

（macOS 15 起，「右键 → 打开」不再能绕过这个提示。）
TXT

        hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
        rm -rf "$STAGE"
    fi

    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    SHA_DMG=$(shasum -a 256 "$DMG" | awk '{print $1}')
    SHA_ZIP=$(shasum -a 256 "$ZIP" | awk '{print $1}')

    # Homebrew Cask：version 与 sha256 直接填好，省掉手抄
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
else
    echo "==> 跳过构建，复用 $CASK"
    [[ -f "$CASK" ]] || { echo "找不到 $CASK —— --skip-build 需要先成功打包过一次"; exit 1; }
    [[ -f "$DMG" ]] || { echo "找不到 $DMG —— --skip-build 时 dmg 必须还在"; exit 1; }
fi

# ---------------------------------------------------------------- 更新包签名

# 应用内自动更新要求 zip 带 Ed25519 签名（App 里烘焙了对应公钥，见
# Spacedown/Support/UpdateSigning.swift）。私钥在仓库外，没有就跳过：
# 别人 clone 也能打包，只是这个包不能自动更新，用户走手动下载。
SIGNATURE="$ZIP.sig"
if [[ -f "$HOME/.spacedown-signing/update-signing.key" ]]; then
    echo "==> 签名更新包"
    swift scripts/sign_update.swift --sign "$ZIP"
else
    echo "⚠️  没有更新签名私钥（~/.spacedown-signing/update-signing.key），跳过签名"
    rm -f "$SIGNATURE"
fi

# ---------------------------------------------------------------- 发布

if [[ $PUBLISH -eq 1 ]]; then
    command -v gh >/dev/null || { echo "发布需要 gh（brew install gh）"; exit 1; }
    echo "==> 发布 GitHub Release v${VERSION}（仓库：${RELEASE_REPO}）"
    NOTES=$(mktemp)
    cat > "$NOTES" <<TXT
macOS 13+ / Apple Silicon。源码仓库为私有，这里只放构建产物。

**安装**
1. 下载 dmg，双击挂载，把 Spacedown 拖进「应用程序」
2. 首次打开：按提示去「系统设置 → 隐私与安全性 → 仍要打开」（未公证版本）
3. 启动一次后，菜单「显示 → 接管 Markdown 空格预览」

**Homebrew**
brew tap czw96/spacedown
brew trust czw96/spacedown   # 第三方 tap 首次需要显式信任
brew install --cask spacedown
TXT
    gh release create "v$VERSION" "$DMG" "$ZIP" ${SIGNATURE:+"$SIGNATURE"} \
        --repo "$RELEASE_REPO" \
        --title "$APP_NAME $VERSION" \
        --notes-file "$NOTES"
    rm -f "$NOTES"
    echo "已发布：https://github.com/$RELEASE_REPO/releases/tag/v$VERSION"
fi

if [[ $UPDATE_TAP -eq 1 ]]; then
    echo "==> 更新 tap：$RELEASE_REPO"
    TAP_WORK="${TAP_DIR:-}"
    TAP_TEMP=""
    if [[ -z "$TAP_WORK" ]]; then
        TAP_TEMP=$(mktemp -d)
        TAP_WORK="$TAP_TEMP/homebrew-spacedown"
        gh repo clone "$RELEASE_REPO" "$TAP_WORK" -- --quiet >/dev/null
    else
        # 本地 tap 可能分支不匹配（比如克隆自空仓库），拉取失败不该挡住发布
        git -C "$TAP_WORK" pull --quiet --ff-only \
            || echo "    ⚠️ 拉取失败，按本地内容继续"
    fi

    cp "$CASK" "$TAP_WORK/Casks/spacedown.rb"
    if [[ -n "$(git -C "$TAP_WORK" status --porcelain -- Casks/spacedown.rb)" ]]; then
        git -C "$TAP_WORK" add Casks/spacedown.rb
        git -C "$TAP_WORK" commit --quiet -m "spacedown $VERSION"
        git -C "$TAP_WORK" push --quiet
        echo "    已推送 Cask（${VERSION}）"
    else
        echo "    Cask 无变化，跳过提交"
    fi

    if [[ -n "$TAP_TEMP" ]]; then
        rm -rf "$TAP_TEMP"
    fi
fi

# ---------------------------------------------------------------- 清理登记

# xcodebuild 会把构建目录那份 App 也登记进 LaunchServices。两份副本会让 pkd 拿不准
# 该用哪个 Quick Look 扩展（实测会退回别家扩展，空格预览直接失效）。打包完就注销它。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/"
LSREGISTER+="LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    echo "==> 已注销构建目录的登记（避免与 /Applications 形成两份副本）"
fi

# ---------------------------------------------------------------- 汇总

echo ""
echo "==> 产物"
printf "  %-42s %8s  %s\n" "$DMG" "$(du -h "$DMG" | cut -f1)" "$(shasum -a 256 "$DMG" | awk '{print $1}')"
printf "  %-42s %8s  %s\n" "$ZIP" "$(du -h "$ZIP" | cut -f1)" "$(shasum -a 256 "$ZIP" | awk '{print $1}')"
printf "  %-42s\n" "${CASK}（Homebrew Cask）"

if [[ $PUBLISH -eq 0 && $UPDATE_TAP -eq 0 ]]; then
    echo ""
    echo "发布：scripts/release.sh --version $VERSION --publish --update-tap"
fi
