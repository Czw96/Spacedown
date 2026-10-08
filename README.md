# Spacedown

macOS Markdown 速览：Finder 空格键预览 + 只读多标签查看器。

> **状态（2026-10-08）：主 App 多标签已可用；Quick Look 扩展已改视图型，待真机验收滚动。**
>
> 已经能编出完整 `Spacedown.app`（内含 Quick Look 扩展），装到了 `/Applications`。
> 但**扩展会不会被系统调用、按空格出来的是渲染页还是纯文本**在本环境验证不了
> （`qlmanage` / `pluginkit` 被沙箱与 TCC 拦），**必须你在 Finder 里按一次空格**。
> 验收方法见第三节。

---

## 一、构建与安装

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
           -derivedDataPath build/DerivedData \
           build
```

产物：`build/DerivedData/Build/Products/Release/Spacedown.app`

### 3. 安装到 /Applications 并让系统重新发现扩展

```bash
pgrep -f "Spacedown.app/Contents/MacOS" | xargs -r kill
rm -rf /Applications/Spacedown.app
cp -R build/DerivedData/Build/Products/Release/Spacedown.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -R -f /Applications/Spacedown.app
qlmanage -r
pluginkit -a /Applications/Spacedown.app/Contents/PlugIns/QuickLookPreview.appex
```

⚠️ 先 `kill` 再替换：进程还在跑的时候 `rm -rf` 它的 bundle，会让它进入半死不活的状态
（`osascript -e 'quit app …'` 也退不掉）。

⚠️ 目前是 **ad-hoc 签名**（本机没有任何 codesigning identity）。正式分发要做
Developer ID + Hardened Runtime + 公证，见 `docs/技术方案.md §9`。

---

## 二、主 App：只读多标签查看器

AppKit 实现（不是 SwiftUI —— 见 `docs/技术方案.md §7.1`）。一个窗口装所有文件，多标签切换。

| 能力 | 实现 |
|---|---|
| 多标签 | 自绘标签栏，38px，`NSVisualEffectView(.windowBackground)` 材质；当前标签底色微抬 + 顶部 2px 强调色条 |
| 标签切换 | **LRU `WKWebView` 池**，容量 5 + 备用 2，淘汰不销毁 → 池内切换 ≈ 0ms |
| 启动预热 | App 一起动就建好一个 webview，省掉首次打开要付的 ~370ms |
| 只读 | HTML 天然不可编辑 + `default-src 'none'` 的 CSP；可以选中复制 |
| 外部修改 | `DispatchSource` 监听 + 120ms 去抖 + `lstat` 四元组比对，没变就不重渲染 |
| 缩放 | `webView.magnification`（GPU 合成层缩放，不触发重排），每个标签各自记 |

### 快捷键

| 动作 | 快捷键 |
|---|---|
| 打开文件… | <kbd>⌘</kbd> <kbd>O</kbd> |
| 关闭标签（只剩一个时关窗口） | <kbd>⌘</kbd> <kbd>W</kbd> |
| 重新载入 | <kbd>⌘</kbd> <kbd>R</kbd> |
| 下一个 / 上一个标签 | <kbd>⌃</kbd> <kbd>⇥</kbd> / <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>⇥</kbd> |
| 同上的第二入口 | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>]</kbd> / <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>[</kbd> |
| 跳到第 N 个标签 | <kbd>⌘</kbd> <kbd>1</kbd> … <kbd>⌘</kbd> <kbd>9</kbd> |
| 放大 / 缩小 / 实际大小 | <kbd>⌘</kbd> <kbd>+</kbd> / <kbd>⌘</kbd> <kbd>−</kbd> / <kbd>⌘</kbd> <kbd>0</kbd> |
| 在 Finder 中显示 | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>R</kbd> |
| 用默认编辑器打开 | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>E</kbd> |

空白标签栏双击 = 新建标签（打开文件面板）。

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
| M6 | 签名公证 + dmg + Homebrew Cask | ⬜ |

---

## 七、目录

```
Spacedown/
├── Spacedown.xcodeproj/          Xcode 工程（由 scripts/gen_project.py 生成）
├── Spacedown/                    主 App target
│   ├── AppIcon.icns              App 图标（源与生成脚本在 design/logo/）
│   ├── AppDelegate.swift         入口、open 事件分发
│   ├── MainWindow.swift          多标签窗口、交通灯对齐、布局自检
│   ├── TabBar.swift              自绘标签栏 + 右侧缩放/动作
│   ├── WebViewPool.swift         LRU webview 池 + 启动预热
│   ├── DocumentTab.swift         标签模型（滚动位置 / 缩放）
│   ├── FileWatcher.swift         外部修改监听（去抖 + lstat 四元组）
│   ├── MainMenu.swift            代码构建主菜单
│   ├── Palette.swift             主题色在 AppKit 侧的镜像
│   ├── SettingsWindow.swift      设置窗（⌘,）：Logo + 打开方式；没开文件时也是启动窗
│   └── DebugLog.swift            /tmp 文件日志
├── QuickLookPreview/             Quick Look 扩展 target（视图型）
│   ├── PreviewViewController.swift  QLPreviewingController + 自建 viewport 尺寸 WKWebView + 实例复用
│   └── Info.plist                扩展声明（⚠️ 故意没有 QLIsDataBasedPreview，见文件内注释）
├── Packages/Core/                SwiftPM 包（仅 macOS ≥13，仅 arm64）
│   ├── Sources/CcmarkGfm/        vendored cmark-gfm 0.29.0.gfm.7
│   ├── Sources/MarkdownKit/      Data → HTML
│   ├── Sources/SharedTheme/      theme.css + HTML 模板拼装
│   ├── Sources/Bench/            命令行基准 / 渲染工具
│   ├── Sources/ScrollBench/      滚动成本基准（重排 / 重绘）与 CSS 变体对比
│   ├── Sources/WebViewBench/     M0 的 WKWebView 成本实测工具
│   └── XcodeSupport/CcmarkGfm/   Xcode 用的 module.modulemap
├── design/logo/                  Logo 源：spacedown-icon.svg + build_logo.py（改几何/配色都改这里再重跑）
├── scripts/gen_project.py        工程生成器
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
