#!/bin/bash
# Spacedown 卸载脚本。
# 由 App 复制到临时目录后执行，参数依次是：App 路径、App 的 pid、用户主目录。
#
# App 退出前已经删掉了自己的 bundle（运行中的进程持有已 unlink 的 inode，不受影响），
# 这里负责它做不到的部分：偏好、缓存、系统登记。逐项删除 —— 不按前缀扫目录。
set -u

APP="$1"
PID="$2"
HOME_DIR="$3"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 等 App 退出；最多 3 秒。等太久会让用户以为"卸载没反应"
for _ in $(seq 1 30); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
done

# 注销空格预览扩展与 App 自身（卸载场景下反登记才是对的）
/usr/bin/pluginkit -e ignore -i cn.29dev.Spacedown.QuickLookPreview >/dev/null 2>&1
"$LSREGISTER" -u "$APP" >/dev/null 2>&1
/usr/bin/qlmanage -r >/dev/null 2>&1
/usr/bin/qlmanage -r cache >/dev/null 2>&1

# 正常情况下这里已经不存在（App 已自删）；保留作为兜底
rm -rf "$APP"

/usr/bin/defaults delete cn.29dev.Spacedown >/dev/null 2>&1
rm -f  "$HOME_DIR/Library/Preferences/cn.29dev.Spacedown.plist"
rm -rf "$HOME_DIR/Library/Saved Application State/cn.29dev.Spacedown.savedState"
rm -rf "$HOME_DIR/Library/Caches/cn.29dev.Spacedown"
rm -rf "$HOME_DIR/Library/HTTPStorages/cn.29dev.Spacedown"
rm -f  /tmp/spacedown-debug.log

# QL 扩展的沙箱容器由 containermanagerd 托管，普通进程删它会被拒（Operation not permitted），
# 系统还可能在删掉后立刻重建一个只含元数据的空壳。尽力删一次，失败就算了。
rm -rf "$HOME_DIR/Library/Containers/cn.29dev.Spacedown.QuickLookPreview" 2>/dev/null

rm -f "$0"
