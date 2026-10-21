# Spacedown

macOS Markdown 速览：Finder 空格键预览 + 只读多标签查看器。
**平台：macOS 13+ · Apple Silicon**（App target 与 `Package.swift` 的口径已统一为 13.0）。

> **状态（2026-10-19）**
>
> | 部分 | 状态 |
> |---|---|
> | 主 App（双击打开、多标签、版心、缩放） | ✅ **已验收**（三份真实文档首帧 147–202 ms） |
> | Quick Look 扩展（渲染、提示块、兜底） | ✅ 被选中时正常（实测 `load=314 ms`，无内容进程反复终止） |
> | 空格预览的**选中权** | ⚠️ **未定** —— 本机 WPS 的 `WPSQuickLook` 认领了同样的 markdown 类型，系统可能选它 |
> | 预览里点链接 | ⚠️ 代码就位（`LinkOpener.xpc`），**缺一次人工点击验收** |
>
> 打包产物：`Distribution/build/Spacedown-1.0.dmg` / `.zip`（ad-hoc 签名，仅供本机/内测）。

---

## 安装（用户）

两种方式，装出来是同一个 App —— 都用 tap 仓库（`Czw96/homebrew-spacedown`）Release 里那份 dmg。
源码仓库保持私有；Cask 与产物放在同一个公开仓库，少一个要同步的地方。

### 方式一：Homebrew Cask（可升级、可干净卸载）

```bash
brew tap czw96/spacedown
brew trust czw96/spacedown        # 第三方 tap 需要显式信任（Homebrew 的安全机制，一次性）
brew install --cask spacedown
```

> 当前是 ad-hoc 签名（未公证），首次打开仍会被 Gatekeeper 拦一次，见下面的「首次打开」。
> （新版 Homebrew 已移除 `--no-quarantine` 选项，只能安装后清一次 `com.apple.quarantine`。）

```bash
brew upgrade --cask spacedown            # 升级
brew uninstall --cask --zap spacedown    # 卸载：偏好、QL 沙箱容器、缓存一并清掉
```

### 方式二：直接下载 dmg

1. 打开 [Releases](https://github.com/Czw96/homebrew-spacedown/releases)，下载 `Spacedown-<版本>.dmg`
2. 双击挂载，把 `Spacedown` 拖进「应用程序」
3. 首次打开：已公证的版本直接双击；未公证版本按下面的「首次打开」处理

### 首次启动后（两种方式都要做一次）

1. **先启动一次 Spacedown** —— 系统只在宿主 App 运行过之后才登记它的 Quick Look 扩展
2. 菜单「**显示 → 接管 Markdown 空格预览**」，等几秒（后台跑 `pluginkit` 选举）
3. 想让双击 `.md` 也用它：<kbd>⌘</kbd><kbd>,</kbd> 打开设置 → 「设为 .md 默认打开方式」

> ⚠️ 未公证版本首次打开会被 Gatekeeper 拦（提示「Apple 无法验证…」）：
> 点「完成」→ **系统设置 → 隐私与安全性** → 拉到底 →「仍要打开」→ 输入密码。
> 或者终端执行 `xattr -dr com.apple.quarantine /Applications/Spacedown.app`。
> macOS 15 起**「右键 → 打开」已不再有效**。
> 正式对外发布需要 Developer ID 证书 + 公证（见「六、打包与发布」），
> 官方 `homebrew-cask` 也只收已公证的 App，未公证之前走上面的自建 tap。

## 一、从源码构建（开发）

### 1. 生成 / 更新 Xcode 工程

`project.pbxproj` 由脚本生成（手写容易漏 UUID 引用）。**加了源码文件就重跑一次**：

```bash
python3 scripts/gen_project.py        # 需要 Python 3.10+（用了 `str | None`）
```

### 2. 构建

```bash
xcodebuild -project Spacedown.xcodeproj \
           -scheme Spacedown \
           -configuration Release \
           -derivedDataPath ~/Library/Caches/Spacedown/DerivedData \
           build
```

产物：`~/Library/Caches/Spacedown/DerivedData/Build/Products/Release/Spacedown.app`

### 3. 安装到 /Applications 并让系统重新发现扩展

```bash
pgrep -f "Spacedown.app/Contents/MacOS" | xargs -r kill
rm -rf /Applications/Spacedown.app
cp -R ~/Library/Caches/Spacedown/DerivedData/Build/Products/Release/Spacedown.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -R -f /Applications/Spacedown.app
qlmanage -r
pluginkit -a /Applications/Spacedown.app/Contents/PlugIns/QuickLookPreview.appex
```

### 4. ⚠️ 两个"静默失效"的坑（都踩过，先查这两条）

**① 扩展必须沙箱化，否则系统静默不加载它。**

`QuickLookPreview.appex` 必须带 `com.apple.security.app-sandbox`（权限在
`QuickLookPreview/QuickLookPreview.entitlements`，由 `gen_project.py` 挂到 appex 目标上）。
不带的后果不是报错，而是**静默失效**：扩展永远不会被拉起、`os_log` 里一行都没有、
系统设置的扩展面板里也看不到它 —— 然后系统退回去用**别家**已注册的扩展，
按空格看到的是别人的预览（本机是 WPS 的「金山文档」，又慢又卡）。

这条能自查，不用按空格：

```bash
codesign -d --entitlements - /Applications/Spacedown.app/Contents/PlugIns/QuickLookPreview.appex
```

必须看到 `com.apple.security.app-sandbox = true`。

**② WPS 会抢 markdown 的空格预览。** 它的 `WPSQuickLook.appex` 认领了**同样 8 个 markdown 类型**
（含 `net.daringfireball.markdown`，与我们同一个 UTI）。两个都注册时系统只挑一个，实测挑中了 WPS。
把不想要的那个关掉即可（用户级、可逆；只影响 markdown，docx/xlsx 仍走系统 `Office.qlgenerator`）：

```bash
pluginkit -e ignore -i com.kingsoft.wpsoffice.mac.WPSQuickLook
pluginkit -e use    -i cn.29dev.Spacedown.QuickLookPreview
```

⚠️ **面板右上角那行「通过 Spacedown 打开」说明不了任何问题** —— 它标的是**默认打开程序**
（Finder 对所有文件都这么标），不是预览提供者。**唯一可靠的判据是看扩展自己的日志**：

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "cn.29dev.Spacedown"' --style compact
```

按几次空格之后再跑：**有 `panel_released` / `load=` / `geometry` / `hosting` = 我们的扩展真的接手了**；
**一行都没有 = 它压根没被加载**（回去查 ①）。
（⚠️ 必须写全路径 `/usr/bin/log`：zsh 有个同名内置命令会抢它。）

⚠️ 先 `kill` 再替换：进程还在跑的时候 `rm -rf` 它的 bundle，会让它进入半死不活的状态
（`osascript -e 'quit app …'` 也退不掉）。

⚠️ 目前是 **ad-hoc 签名**（本机没有任何 codesigning identity）。正式分发要做
Developer ID + Hardened Runtime + 公证，见 `docs/技术方案.md §9`。

### 5. 🚨 本地调试专属的坑：**构建目录的那份 App 会被登记成第二个扩展**

产物在 `~/Library/Caches/Spacedown/DerivedData/...`。`xcodebuild` 跑过之后，LaunchServices 里
**同一个 `pluginIdentifier` 会有两条记录**：一条指向构建目录、一条指向 `/Applications`，
UUID 不同 —— 系统于是在两者之间拿不准，**静默退回用别家扩展**（本机是 WPS）。

判据（`lsregister -dump` 里数 block，必须是 **1** 条）：

```bash
lsregister -dump | grep -c "cn.29dev.Spacedown.QuickLookPreview.*pluginIdentifier"   # 不靠谱
# 用这个：数 path 里带 QuickLookPreview.appex 且同一个 pluginIdentifier 的记录
```

修法 —— **每次构建完、装完都做一遍**：

```bash
lsregister -u "$HOME/Library/Caches/Spacedown/DerivedData/Build/Products/Release/Spacedown.app"
```
⚠️ 注销/重登记之后 **pkd 要过几十秒才重新发现**（日志里会先出现
`LaunchServices observer: Uninstalled plugins`）。这段时间按空格会用别家扩展 ——
**别在这几十秒里下结论**。

### 6. 打包与发布

```bash
scripts/release.sh                                    # 只打包，版本取 MARKETING_VERSION
scripts/release.sh --version 1.1.0                    # 指定版本
scripts/release.sh --version 1.1.0 --publish --update-tap   # 一条命令发完
scripts/release.sh --version 1.1.0 --skip-build --update-tap  # 只重推 Cask
```

dmg 的窗口布局由 `scripts/make_dmg.py` 生成（`pip install dmgbuild pillow`）；
没装这两个依赖时脚本会自动回退成普通 `hdiutil` dmg —— 功能一样，只是没有背景/图标摆位。

脚本做四件事：Release 全量构建 →（可选）Developer ID 重签 + 公证 → 出 `dmg` / `zip`
（dmg 里含 App、`/Applications` 软链与安装说明）→ 生成 `Distribution/build/spacedown.rb`
（Homebrew Cask，version 与 sha256 已填好）。

`--publish` 上传到 **`Czw96/homebrew-spacedown`** 的 Release（tap 仓库，公开），
`--update-tap` 顺手把 Cask 提交进该仓库（默认临时 clone 后推送；设 `TAP_DIR`
可复用本地克隆，省一次下载）。源码仓库保持私有，Cask 的 `url` 指向 tap 仓库，
用户下载、`brew install` 都不需要任何账号。

`--skip-build` 跳过构建，直接复用 `Distribution/build/` 里已有的 dmg 与 Cask ——
用于只改 Cask（比如换下载地址）或补推 tap 的场景。

**正式发布**还需要一台有 Developer ID 证书的机器，并把公证凭据存进钥匙串：

```bash
xcrun notarytool store-credentials spacedown \
  --apple-id <Apple ID> --team-id <Team ID> --password <App 专用密码>

SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=spacedown \
scripts/release.sh --version 1.1.0 --publish
```

不带 `SIGN_IDENTITY` 时产物是 **ad-hoc 签名**：本机可用，别人下载后首次打开会被
Gatekeeper 拦（右键 → 打开，或 `xattr -dr com.apple.quarantine`）。

**Cask 发布**：把生成的 `spacedown.rb` 推到 `Czw96/homebrew-spacedown` 仓库的
`Casks/spacedown.rb`；用户即可 `brew install --cask czw96/spacedown/spacedown`。
官方 `homebrew-cask` 要求 App 已公证，满足后再提 PR。

---

## 二、主 App：只读多标签查看器

AppKit 实现（不是 SwiftUI —— 见 `docs/技术方案.md §7.1`）。一个窗口装所有文件，多标签切换。

| 能力 | 实现 |
|---|---|
| 多标签 | 自绘标签栏，38px，`NSVisualEffectView(.windowBackground)` 材质；当前标签底色微抬 + 顶部 2px 强调色条 |
| 标签切换 | **LRU `WKWebView` 池**，容量 5 + 备用 2，淘汰不销毁 → 池内切换 ≈ 0ms |
| 启动预热 | App 一起动就建好一个 webview，省掉首次打开要付的 ~370ms |
| 拖放打开 | `.md` 拖到窗口任意位置都能开（空白处与已打开的文档上都能接） |
| 打开反馈 | 首帧超过 120ms 才起转菊花 —— 快速加载不会闪一下 |
| 只读 | HTML 天然不可编辑 + `default-src 'none'` 的 CSP；可以选中复制 |
| 外部修改 | `DispatchSource` 监听 + 120ms 去抖 + `lstat` 四元组比对，没变就不重渲染；文件被删掉再重建会自动换源重挂 |
| 缩放 | `webView.pageZoom`（**会重排**，所以放大不出横向滚动条），每个标签各自记 |
| 宽表格 | 渲染期给 `<table>` 套 `overflow-x: auto` 容器，窄面板里横着滚而不是撑破版心 |
| 版心宽度 | 「显示 → 版心宽度」，默认铺满，可收到 40%~100%；⌥⌘= / ⌥⌘− / ⌥⌘0，设置会记住 |
| 检查更新 | 启动 5 秒后自动查（24 小时一次），也可手动「Spacedown → 检查更新…」 |

### 快捷键

| 动作 | 快捷键 |
|---|---|
| 打开文件… | <kbd>⌘</kbd> <kbd>O</kbd> |
| 关闭标签（只剩一个时关窗口） | <kbd>⌘</kbd> <kbd>W</kbd> |
| 重新载入 | <kbd>⌘</kbd> <kbd>R</kbd> |
| 下一个 / 上一个标签 | <kbd>⌃</kbd> <kbd>⇥</kbd> / <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>⇥</kbd> |
| 同上的第二入口 | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>]</kbd> / <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>[</kbd> |
| 跳到第 N 个标签 | <kbd>⌘</kbd> <kbd>1</kbd> … <kbd>⌘</kbd> <kbd>9</kbd>（<kbd>⌘9</kbd> 固定是**最后一个**） |
| 放大 / 缩小 / 实际大小 | <kbd>⌘</kbd> <kbd>+</kbd> / <kbd>⌘</kbd> <kbd>−</kbd> / <kbd>⌘</kbd> <kbd>0</kbd> |
| 版心加宽 / 收窄 / 铺满 | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>=</kbd> / <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>−</kbd> / <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>0</kbd> |
| 在 Finder 中显示 | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>R</kbd> |
| 用默认编辑器打开 | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>E</kbd> |

> 缩放那三条：**<kbd>⌘=</kbd> 也管用**（等价于 ⇧<kbd>⌘=</kbd>，也就是大家心里的「⌘+」）。
> 物理键盘上并没有单独的 `+` 键，所以菜单匹配不能写成 `"+"` —— 见 `MainMenu.hiddenAlias` 的注释，
> 那里有一张实测表格。
>
> 版心那三条：**默认铺满**（`--measure: 100%`），范围 40%~100%、每次 10%。
> 入口在 **「显示 → 版心宽度」**（菜单里那一行会显示当前值，打开菜单时刷新）。
> ⌥⌘= / ⌥⌘− / ⌥⌘0 随时可用，不用打开菜单。
> **空格预览读不到这个设置** —— 扩展与 App 的 bundle id 不同、也没有 App Group，
> 所以 QL 面板固定按铺满渲染。

空白标签栏双击 = 新建标签（打开文件面板）；把 `.md` 拖到窗口任意位置也会打开。
工具栏右侧只有缩放（`−` / 百分比 / `+`）；「在 Finder 中显示」「用默认编辑器打开」只在「文件」菜单里。

### ⚠️ 为什么双击 `.md` 打开的不是渲染视图

因为 **`.md` 的默认打开方式不是 Spacedown**。本机实测：

```
LSHandlerContentType => net.daringfireball.markdown
LSHandlerRoleAll     => com.microsoft.vscode      ← 就是这条
```

`LSHandlerRank` 我们设的是 **Alternate** —— **不抢**你现有编辑器的默认打开方式（§7.4）。
所以要让双击生效，二选一：

1. 打开 Spacedown（双击 App 图标，或菜单「Spacedown → **设置…**」<kbd>⌘</kbd><kbd>,</kbd>）
   → 在「打开方式」那张卡片上点「**设为默认打开方式**」
2. 或 Finder 里右键 `.md` → 显示简介 → 打开方式 → 选 Spacedown → 「更改全部」

> **这里有个死锁要说清楚**：默认打开方式被别人占着时，双击 `.md` 根本不会启动 Spacedown，
> 你也就永远看不到那个按钮。所以设置窗的卡片会**明确显示现在是谁在接管**
> （值那一行就是当前接管的 App 名）。

**但空格预览不受影响** —— 它走 Quick Look 扩展，和默认打开方式是两回事。

---

## 三、现在需要你做的验收（2 个动作）

在 Finder 里随便选中一个 `.md` 文件，**按空格**，告诉我两件事：

1. **出来的是渲染后的页面，还是一堆 `#` `**` 的纯文本？**
   → 判断扩展有没有被系统启用（风险 R1）
2. **滚动跟不跟手**（尤其是 100KB 以上的大文件、以及猛甩一下）

> 扩展已从**数据型**改成**视图型**（自建 viewport 尺寸的 `WKWebView`）——
> 原因与实测数据见 `docs/性能分析.md §6`。**改了扩展的形态就必须重装**（第一节的
> 3 个步骤），否则系统跑的还是旧的那份。

样例文件在 **桌面 → `Spacedown 示例`**：

| 文件 | 看什么 |
|---|---|
| `01 README 风格.md` | 裸 HTML 有没有被吃掉（徽章行 / `<details>` / `<kbd>`）、表格、任务列表 |
| `02 性能实测.md` | 长表格数字列对齐、代码块 |
| `03 排版细节.md` | **专门用来挑毛病**：行宽 / 行高 / 字号 / 留白 / 颜色 |

顺带请再看一眼埋点（输出到统一日志，不再写文件）：

```bash
log stream --predicate 'subsystem == "cn.29dev.Spacedown"' --style compact
```

每次按空格会打一行 `preview file=… bytes=… read=…ms render=…ms wrap=…ms load=…ms total=…ms`。
连续预览同一个文件两次、看两次的耗时差，就知道扩展进程和 webview 有没有被复用。

---

## 四、渲染内核：命令行也能看（不依赖扩展）

```bash
cd Packages/Core
swift build -c release --disable-sandbox
.build/release/Bench --file /path/to/README.md --out /tmp/preview.html
open /tmp/preview.html
```

产出的 HTML **单文件自包含**（CSS 内联、明暗双主题），拖进浏览器即可。
这是验收「渲染出来好不好看」最直接的途径，也用来判断扩展是不是真的在工作
——两边看到的效果应当一致。

### 性能基准

```bash
.build/release/Bench                      # 合成语料 5 档 + 病态输入
.build/release/Bench --iter 500           # 指定每档迭代次数
.build/release/Bench --file X.md          # 对单个真实文件计时
```

实测（Apple Silicon）：50KB 渲染 **1.76 ms**，5MB **约 200 ms**，吞吐 25~29 MB/s。
完整数字见 `docs/benchmarks.md`，**归因与优化决策见 `docs/性能分析.md`**。

> 一句话：我们自己只占 ~1ms，慢的全在 WebKit。所以优化全部投在
> "WebContent 进程预热 + webview 实例复用"上，而不是解析或缓存。
>
> ⚠️ 上面这句只管**首帧**。**滚动是另一笔账**（每帧重绘），预热与池化对它无效 —— 见 §四之下的滚动基准。

### 滚动基准

```bash
.build/release/ScrollBench --file /path/to/preview.html            # 全部 CSS 变体
.build/release/ScrollBench --file X.html --only baseline,cv        # 只跑指定变体
.build/release/ScrollBench --file X.html --raf 3000 --step 150     # 连续滚动帧率（150px/帧 ≈ 猛甩）
.build/release/ScrollBench --file X.html --pdf /tmp/out.pdf        # 试渲矢量 PDF（原型，见 §6.5）
```

三件能力：**滚一步的同步重排**、**强制重绘一屏**、**连续滚动帧率**（rAF 帧间隔直方图），
并在 10 个 CSS 变体之间横向对比。结论（含"别再调 CSS"这条）见 `docs/性能分析.md §6`。

⚠️ 连续滚动那一项对**可见性**敏感：页面被判 hidden 时 rAF 会被节流成 1Hz 左右，
量出来是「max 4627ms」这种假数字。工具靠「跑 `NSApplication.run()` + runloop 定时器」
保证窗口真的可见；看数前先确认输出里有 `[页面可见性] visible`。


---

## 五、调试

主 App 里看不到 stderr（双击启动），`log show` 又被沙箱挡。所以用一个文件日志开关：

```bash
defaults write cn.29dev.Spacedown DebugLayout -bool true   # 打开
# …复现问题…
cat /tmp/spacedown-debug.log                               # 看
defaults delete cn.29dev.Spacedown DebugLayout             # 关掉
```

打开后会记录：启动回调顺序、`application(_:open:)` 收到几个 URL、主窗口是否创建、
以及**几何自检**（交通灯中线 vs 标签栏中线 —— 截不了屏时只能靠数字确认对齐）。

⚠️ 开关走 `UserDefaults` 而不是环境变量：**`open --env` 送进去的变量到不了 App 进程**（实测）。

---

## 六、进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | Spike：UTI 判定、QL 扩展跑通、webview 冷启实测、键盘事件是否可达 | 🟨 代码完成；**R1 / R3 待真机** ⬜ |
| M1 | 渲染内核 + 主题 + Bench CLI | ✅ 内核 / 主题 / Bench；**缓存决定不做**（收益 ≈ 0，见性能分析 §2.4） |
| M2 | Quick Look 扩展做完整 | 🟨 **已由数据型改为视图型**（自建 viewport 尺寸 WKWebView + 实例复用 + `os_log` 埋点），已安装，待真机验收滚动 |
| M3 | 主 App | ✅ **多标签 + LRU 池 + 主菜单 + 文件监听 + 缩放（2026-10-08）** |
| M4 | 打磨 | 🟨 布局自检 ✅；图片内联 ⬜（现在相对路径图片是坏图） |
| M5 | 性能回归 | 🟨 滚动口径已建（`ScrollBench`）+ 归因见 `docs/性能分析.md §6`；按渲染规模截断 ⬜ |
| M6 | 签名公证 + dmg + Homebrew Cask | 🟨 dmg / Cask 已可生成（`scripts/release.sh`）；**签名 + 公证待 Developer ID** |

---

## 七、目录

```
Spacedown/
├── Spacedown.xcodeproj/          Xcode 工程（由 scripts/gen_project.py 生成）
├── Spacedown/                    主 App target
│   ├── App/                      入口（SpacedownMain）、AppDelegate、主菜单
│   ├── Window/                   主窗口与动作/WebKit/自检（MainWindow+*.swift）、标签栏、标签模型、窗口子类
│   ├── Content/                  LRU web view 池、拖放落点、SpacedownWebView
│   ├── Document/                 markdown 文件类型判定、文件监听、版心偏好
│   ├── Settings/                 设置窗、悬停按钮、卸载
│   ├── Support/                  调试日志、命令行调用、空格预览接管与诊断
│   └── Resources/                Info.plist、AppIcon.icns、uninstall.sh
├── QuickLookPreview/             Quick Look 扩展 target（视图型）
│   ├── PreviewViewController.swift   QLPreviewingController：交接、导航、链接、兜底
│   ├── PreviewDocument.swift         读文件 → 截断 → 渲染 → 拼文档
│   ├── PreviewWebViewPool.swift      实例复用（容量 1）
│   ├── ScrollProbe.swift             滚动帧率探针
│   ├── PreviewDiagnostics.swift      os_log 与 Debug 取证
│   └── Resources/                    Info.plist、entitlements
├── LinkOpener/                   XPC 服务：替沙箱里的扩展打开外部链接
├── Packages/Core/                SwiftPM 包（仅 macOS ≥13，仅 arm64）
│   ├── Sources/CcmarkGfm/        vendored cmark-gfm 0.29.0.gfm.7
│   ├── Sources/MarkdownKit/      文档装载（截断）、cmark 渲染、危险 scheme 中和
│   ├── Sources/SharedTheme/      主题与 HTML 外壳、文档后处理、链接语义、色板、Toast
│   ├── Sources/DevTools/         Bench / ScrollBench / WebViewBench
│   └── XcodeSupport/CcmarkGfm/   Xcode 用的 module.modulemap
├── design/logo/                  Logo 源：spacedown-icon.svg + build_logo.py（改几何/配色都改这里再重跑）
├── scripts/                      gen_project.py（工程生成）、release.sh（打包发布）
├── docs/技术方案.md               方案（性能指标、风险清单、里程碑）
├── docs/benchmarks.md            实测数字与踩坑记录
└── docs/性能分析.md              耗时归因、"换技术栈"的结论、优化清单
```

## 八、环境注意

- `xcode-select` 必须指向 `/Applications/Xcode.app`（打包 `.appex` 需要完整 SDK/签名链路）
- `swift build` 一律加 `--disable-sandbox`，否则 `sandbox-exec: Operation not permitted`
- Xcode 工程**不引用** SwiftPM 包（本机沙箱下 manifest 编译过不去），源码由原生 target
  直接编译；原因与替代方案见 `docs/技术方案.md §14`
- 本机 `screencapture` 被系统权限挡住 → UI 改动没法截屏验证，只能靠 `DebugLayout` 的几何数字
- 构建产物必须放在 **Spotlight 不索引**的位置。实测：`~/Library/Caches` 与 `/tmp` 不被索引，
  仓库内与 `~/Library/Developer` 都会被索引。现在用 `~/Library/Caches/Spacedown/DerivedData`。
  否则搜 `Spacedown.app` 会同时命中构建产物，看起来像"卸载没生效"。
  注意：目录里放 `.metadata_never_index` **不管用**，那只对卷根有效
