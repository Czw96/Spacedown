#!/bin/bash
# Spacedown 卸载脚本。
# 由 App 复制到临时目录后执行，参数依次是：App 路径、App 的 pid、用户主目录。
# 先等 App 退出，再逐项删除 —— 不按前缀扫目录。
set -u

APP="$1"
PID="$2"
HOME_DIR="$3"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

for _ in $(seq 1 100); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
done

# 注销空格预览扩展与 App 自身（卸载场景下反登记才是对的）
/usr/bin/pluginkit -e ignore -i cn.29dev.Spacedown.QuickLookPreview >/dev/null 2>&1
"$LSREGISTER" -u "$APP" >/dev/null 2>&1
/usr/bin/qlmanage -r >/dev/null 2>&1
/usr/bin/qlmanage -r cache >/dev/null 2>&1

rm -rf "$APP"

/usr/bin/defaults delete cn.29dev.Spacedown >/dev/null 2>&1
rm -f  "$HOME_DIR/Library/Preferences/cn.29dev.Spacedown.plist"
rm -rf "$HOME_DIR/Library/Saved Application State/cn.29dev.Spacedown.savedState"
rm -rf "$HOME_DIR/Library/Containers/cn.29dev.Spacedown.QuickLookPreview"
rm -rf "$HOME_DIR/Library/Caches/cn.29dev.Spacedown"
rm -rf "$HOME_DIR/Library/HTTPStorages/cn.29dev.Spacedown"
rm -f  /tmp/spacedown-debug.log

rm -f "$0"
