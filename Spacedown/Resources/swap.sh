#!/bin/sh
# Spacedown 换包脚本。
#
# 由 App 在「立即更新」的最后一步启动，**必须等 App 退出之后**才能动手 ——
# 进程正在运行的 bundle 被替换会进入半死不活的状态。所以第一步是等进程消失。
#
# 参数：APP <当前 App 路径>  NEW <解压出来的新 App>  WORK <临时目录>  LOG <日志文件>
#
# 交换用两次 rename（同卷内原子）：先把新包 ditto 到 <App>.updating，再
# <App> → <App>.old、.updating → <App>。任何一步失败都把 .old 挪回去，
# 最坏情况是"没更新成功，但旧版本还在"。
#
# 不写 `set -e`：每一步失败都要走自己的回滚分支，而不是直接退出留下半成品。

APP="$1"
NEW="$2"
WORK="$3"
LOG="$4"

exec >>"$LOG" 2>&1
echo "=== $(date) 开始换包"
echo "APP=$APP"
echo "NEW=$NEW"

if [ ! -d "$NEW" ]; then
    echo "新包不存在，放弃"
    exit 1
fi

# 等旧进程退出：最多 20 秒，之后强行走（总比什么都不做强）
i=0
while pgrep -f "$APP/Contents/MacOS/Spacedown" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
    sleep 0.2
    i=$((i + 1))
done
echo "旧进程已退出（等待 $i 轮）"

# 1. 落到同卷的临时名（跨卷 rename 会退化成拷贝，先 ditto 保证下一步是原子 rename）
rm -rf "$APP.updating"
if ! ditto "$NEW" "$APP.updating"; then
    echo "落盘失败，放弃（旧版本未动）"
    rm -rf "$APP.updating"
    open "$APP"
    exit 1
fi

# 2. 两次 rename 完成交换
rm -rf "$APP.old"
if ! mv "$APP" "$APP.old"; then
    echo "旧包改名失败（权限？），放弃"
    rm -rf "$APP.updating"
    open "$APP"
    exit 1
fi
if ! mv "$APP.updating" "$APP"; then
    echo "交换失败，回滚"
    mv "$APP.old" "$APP"
    rm -rf "$APP.updating"
    open "$APP"
    exit 1
fi

xattr -dr com.apple.quarantine "$APP" 2>/dev/null

# 3. 能启动才算成功；起不来就回滚
if open "$APP"; then
    echo "更新完成，清理备份"
    rm -rf "$APP.old"
else
    echo "启动失败，回滚"
    rm -rf "$APP"
    mv "$APP.old" "$APP"
    open "$APP"
fi

rm -rf "$WORK"
echo "=== $(date) 结束"
