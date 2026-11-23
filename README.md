<div align="center">
  <img src="docs/img/icon.png" width="120" alt="Spacedown 图标">
  <h1>Spacedown</h1>
  <p><b>在 Finder 里按一下空格，Markdown 就是排版好的样子。</b><br>
  原生渲染 · Quick Look 扩展 · 只读多标签查看器</p>

  <p>
    <b>简体中文</b> ｜ <a href="README.en.md">English</a>
  </p>

  <p>
    <img alt="platform" src="https://img.shields.io/badge/macOS-13%2B-1a2a4a?style=flat-square">
    <img alt="arch" src="https://img.shields.io/badge/Apple%20Silicon-arm64-1a2a4a?style=flat-square">
    <img alt="version" src="https://img.shields.io/github/v/release/Czw96/homebrew-spacedown?label=version&color=6a3de8&style=flat-square">
    <img alt="license" src="https://img.shields.io/badge/license-MIT-6a3de8?style=flat-square">
    <img alt="AI" src="https://img.shields.io/badge/code-AI%20generated-8a8a8f?style=flat-square">
  </p>
</div>

![Spacedown 渲染 Markdown 的样子](docs/img/preview-light.png)

> [!NOTE]
> **这个项目由 AI 编码助手实现**（代码、文档、设计脚本、发版脚本），人类负责需求、方案取舍与真机验收。
> 边界与可验证的痕迹见 [AI 实现说明](#ai-实现说明)——建议先读那一节，再决定要不要信任它。

## 它解决什么问题

macOS 自带的空格预览把 `.md` 当**纯文本**：等宽字体、`#` 原样显示、表格散成一堆竖线。
你只是想扫一眼文档长什么样，却得打开编辑器。

Spacedown 做两件事：

1. **接管 Markdown 的空格预览**——在 Finder 里选中 `.md` 按空格，出来的是排版好的正文
   （GFM 表格、任务列表、删除线、autolink、代码块、`> [!NOTE]` 提示块、相对路径图片内联）。
2. **给一个只读的多标签查看器**——双击打开、多文件并排、外改即时刷新、版心与缩放随你。

渲染内核是 vendored 的 [cmark-gfm](https://github.com/github/cmark-gfm) 加自写的 HTML 外壳，
**这一层不跑任何 JavaScript**：没有前端框架、没有 JS 版语法高亮、也不联网。

## 特性

| | |
|---|---|
| **空格即看** | Quick Look 扩展，Finder 里按空格直接出渲染结果 |
| **扫一眼就够** | 空格预览只渲染前 64 KB（按**完整内容块**切，不会切断表格或代码块），片段末尾给「加载更多」，把文件交给主 App |
| **多标签** | 自绘标签栏，`WKWebView` LRU 池（5 + 备用 2），池内切换约 0 ms；标签上限 10 |
| **跟手** | App 启动即预热一份 webview，首个文件首帧约 100 ms（冷启 370 ms 的账挪到启动期） |
| **只读但可复制** | CSP `default-src 'none'`，HTML 天然不可编辑；选中、⌘C、⌘A 正常 |
| **外改自动刷新** | `DispatchSource` 监听 + 120 ms 去抖 + inode/size/mtime 比对；文件删掉再重建也能重挂源 |
| **明暗自适应** | 跟随系统外观，空格预览与主窗口共用同一套 CSS |
| **版心可调** | 默认铺满，可收到 40%，⌥⌘= / ⌥⌘− / ⌥⌘0 |
| **缩放** | ⌘+ / ⌘− / ⌘0，25%–500%，走 `pageZoom`（重排版，不产生横向滚动条） |
| **查找** | ⌘F 浮出查找条，走 WebKit 原生 `find`，不注入 JS |
| **链接** | 单击复制地址，⌘/⌃ + 单击用默认浏览器打开（跨沙箱走 XPC） |
| **自更新** | Ed25519 自签校验 + 换包脚本，没有 Developer ID 也能安全升级 |

![深色外观](docs/img/preview-dark.png)

## 安装

要求：**macOS 13 Ventura 或更新**，**Apple Silicon**（只出 arm64，没有 Intel 版）。

### Homebrew（推荐）

```bash
brew tap czw96/spacedown
brew trust czw96/spacedown            # 第三方 tap 首次需要显式信任
brew install --cask spacedown

brew upgrade --cask spacedown         # 升级
brew uninstall --cask --zap spacedown # 卸载：偏好、QL 沙箱容器、缓存一并清掉
```

### 直接下载

到 [最新 Release](https://github.com/Czw96/homebrew-spacedown/releases/latest) 下 `.dmg`，
双击挂载，把 Spacedown 拖进「应用程序」。

### 首次打开（未公证，会被拦一次）

本项目**没有 Apple Developer ID**，产物是 ad-hoc 签名，首次打开会被 Gatekeeper 拦下：

- macOS 15 起「右键 → 打开」已经失效；
- 走 **系统设置 → 隐私与安全性 → 仍要打开**；
- 或终端执行 `xattr -dr com.apple.quarantine /Applications/Spacedown.app`。

### ⚠️ 还有一步：接管空格预览

装完**先启动一次** Spacedown（系统只在宿主 App 运行过之后才登记它的扩展），
再点菜单 **「显示 → 接管 Markdown 空格预览」**，等几秒。

**不点这一下，空格看到的还是源码。** 原因见下一节。

顺便可以在设置里（<kbd>⌘</kbd><kbd>,</kbd>）点「设为 .md 默认打开方式」。

## 用起来

| 动作 | 快捷键 |
|---|---|
| 打开文件… | <kbd>⌘</kbd><kbd>O</kbd> |
| 关闭标签 / 窗口 | <kbd>⌘</kbd><kbd>W</kbd> |
| 重新载入 | <kbd>⌘</kbd><kbd>R</kbd> |
| 下一个 / 上一个标签 | <kbd>⌃</kbd><kbd>⇥</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⇥</kbd> |
| 同上的第二入口 | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>]</kbd> / <kbd>⌘</kbd><kbd>⇧</kbd><kbd>[</kbd> |
| 跳到第 N 个标签 | <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd>（<kbd>⌘9</kbd> 固定是**最后一个**） |
| 放大 / 缩小 / 实际大小 | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| 版心加宽 / 收窄 / 铺满 | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>=</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>0</kbd> |
| 在 Finder 中显示 | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd> |
| 用默认编辑器打开 | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 查找 / 下一个 / 上一个 | <kbd>⌘</kbd><kbd>F</kbd> / <kbd>⌘</kbd><kbd>G</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> |

其他：

- **拖放**：把 `.md` 拖到窗口任意位置都会打开（空白处和已打开的文档上都行）。
- **双击空白标签栏** = 新建标签；标签最多 10 个，到顶会提示而不是静默失败。
- **空格预览里也能缩放**：<kbd>⌘+</kbd> / <kbd>⌘−</kbd> / <kbd>⌘0</kbd>，走视觉放大
  （`magnification`），最大 3 倍，捏合手势是同一套。这里故意不重排版——面板宽度本来就能拖。
- **撞到缩放下限/上限**时工具栏那颗按钮会变灰，按到底不会毫无反应。
- **版心设置只对主 App 生效**：扩展读不到主 App 的偏好（不同 bundle id、也没有 App Group），
  空格预览固定按铺满渲染。

## 为什么必须手动点一次「接管」

macOS 允许同一个文件类型被多个 Quick Look 扩展认领，**由系统挑一个**——本机上 WPS 的扩展
认领了同样 8 个 markdown 类型，实测系统挑中了 WPS。

沙箱里的 App 不能调用 `pluginkit`（TCC 拦死），所以选举必须由一个非沙箱进程来做，
Spacedown 主 App 就是那个进程。菜单里那一次点击会做四步：

1. `lsregister -f` 重新登记 App 与扩展
2. `pluginkit -a` 登记扩展
3. `pluginkit -e use` 选中我们，`-e ignore` 关掉已知竞争者
4. `qlmanage -r` 重建 Quick Look 索引

四步缺一，系统就静默退回内置的纯文本预览（表现：空格显示源码、等宽字体）。
细节与排错见 [`docs/构建与发布.md`](docs/构建与发布.md#接管空格预览的四步选举)。

> [!IMPORTANT]
> 面板右上角那行「通过 Spacedown 打开」说明不了任何问题——它标的是**默认打开程序**，
> 不是预览提供者。唯一可靠的判据是日志里有没有 `preview file=`。

## 从源码构建

```bash
python3 scripts/gen_project.py      # 工程文件是生成的，加了源码文件就重跑

xcodebuild -project Spacedown.xcodeproj -scheme Spacedown -configuration Release \
           -derivedDataPath ~/Library/Caches/Spacedown/DerivedData build

killall Spacedown                   # 先退出再替换，别在运行中 rm 它的 bundle
rm -rf /Applications/Spacedown.app
cp -R ~/Library/Caches/Spacedown/DerivedData/Build/Products/Release/Spacedown.app /Applications/
```

装好之后同样要点一次「显示 → 接管 Markdown 空格预览」。

三个会「静默失效」的坑（扩展没沙箱化、WPS 抢预览、构建目录被登记成第二个扩展），
以及发版、公证、自更新密钥的完整流程，都写在 **[`docs/构建与发布.md`](docs/构建与发布.md)**。
先读那一节，能省掉半天。

只想看渲染效果、不装扩展的话，内核可以直接跑：

```bash
cd Packages/Core && swift build --disable-sandbox
.build/debug/Bench ../某文档.md        # 渲染耗时与 HTML 体积
```

## 已知限制

- **只有 arm64**：没做 universal2，Intel Mac 用不了。
- **没有 Developer ID**：首次打开会被 Gatekeeper 拦（见上），也进不了官方 `homebrew-cask`。
- **空格预览固定铺满**：扩展读不到主 App 的版心设置，也没有 App Group 共享。
- **只读**：不支持编辑、保存。这是设计选择，不是没做完。
- **预览上限 64 KB**：超过就按完整块截断并给「加载更多」（交给主 App 看全文）。主 App 不设上限。
- **Release 资产在另一个仓库**：源码公开前二进制度放在公开的
  [Czw96/homebrew-spacedown](https://github.com/Czw96/homebrew-spacedown)，Cask 也指向那里，
  所以本仓库的 Releases 页面是空的。
- **不打算支持 iOS / iPadOS**：Quick Look 扩展、`DispatchSource`、AppKit 决定了它只属于 macOS。

## 排错

| 症状 | 先查什么 |
|---|---|
| 空格显示源码 / 等宽字体 | 没接管成功。菜单「显示 → 接管 Markdown 空格预览」；再看日志里有没有 `preview file=` |
| 预览被别的 App 抢走 | 本机是 WPS：`pluginkit -e ignore -i com.kingsoft.wpsoffice.mac.WPSQuickLook` |
| 改了代码、装了新版却没变化 | 构建目录那份 App 被登记成第二个扩展，系统在两者之间拿不准；见 `docs/构建与发布.md` |
| 相对路径图片不显示 | 沙箱读不到同目录图片时会静默保留原 `src`；主 App 里正常 |
| 双击 `.md` 打开的不是渲染视图 | 默认打开方式没设；设置里点「设为 .md 默认打开方式」 |

日志都在统一日志里（不写文件）：

```bash
/usr/bin/log stream --predicate 'subsystem == "cn.29dev.Spacedown"' --style compact
```

## 项目结构

```
Spacedown/            主 App（AppKit）：App / Window / Content / Document / Settings / QuickLook / Update
QuickLookPreview/     空格预览扩展（.appex）：视图型，web view 尺寸等于面板尺寸
LinkOpener/           XPC 服务：替沙箱里的扩展打开链接
Packages/Core/
  Sources/CcmarkGfm/  vendored cmark-gfm
  Sources/MarkdownKit/文档装载、块边界截断、渲染、危险 scheme 中和
  Sources/SharedTheme/主题外壳、文档后处理、图片内联、链接语义、色板
  Sources/DevTools/   Bench / WebViewBench / ScrollBench（性能基准，不进 App）
scripts/              gen_project.py（工程生成）、release.sh（打包发布）、sign_update.swift
docs/                 技术方案 / 性能分析 / 代码审查 / 构建与发布 / 基准数据
```

| 文档 | 内容 |
|---|---|
| [`docs/技术方案.md`](docs/技术方案.md) | 正本：架构、性能取舍、每个决定的来龙去脉 |
| [`docs/性能分析.md`](docs/性能分析.md) | 时间到底花在哪（结论：99% 在 WebKit） |
| [`docs/benchmarks.md`](docs/benchmarks.md) | 两轮实测原始数据 |
| [`docs/代码审查.md`](docs/代码审查.md) | 一次逐文件审查记录，含未修项与取舍 |
| [`docs/构建与发布.md`](docs/构建与发布.md) | 构建、安装、接管、发版、自更新密钥 |
| [`docs/样式总览.md`](docs/样式总览.md) | 排版与视觉规则 |

## 参与

这是**单人维护**的项目，也是 AI 生成的代码库——评审外部 PR 的成本比写代码高。所以：

- **Issue 欢迎**：bug、排版怪例、Quick Look 行为差异都有价值，附上 macOS 版本与文件样例。
- **PR 请先开 issue**：没讨论过的 PR 可能直接关闭。不是不尊重，是没时间做跨机器验证。
- 文档纠错、错别字、翻译改进：直接 PR，这类不用先问。

## AI 实现说明

**本项目的代码由 AI 编码助手（WorkBuddy）生成。** 这个声明不是免责套话，把边界说清楚：

| 环节 | 谁做的 |
|---|---|
| 需求、产品判断、真机验收 | 人类（仓库所有者） |
| 技术方案、架构、性能测量与取舍 | AI 提出 → 人类否决或确认 |
| Swift / C 胶水代码、脚本、文档 | AI 生成 |
| 每次提交前的检查与放行 | 人类 |
| 踩坑归档与审查记录 | AI 整理，人类补实测结果 |

可验证的地方：

- [`docs/技术方案.md`](docs/技术方案.md) 每条约都带「为什么不选另一个」，其中若干条是**人类否决
  AI 初稿**之后改的（典型例子：最初打算做渲染缓存，实测收益 ≈ 0 后砍掉）。
- README 与文档里所有「实测」数字，都来自本仓库 `Packages/Core/Sources/DevTools/` 里 AI 写的
  基准工具，可以自己跑一遍复核。
- 注释统一写「为什么」而不是复述代码在做什么——这是 AI 生成代码最容易变噪音的地方，
  本项目刻意往反方向压。

**局限也要说**：AI 生成的代码在边界条件上更依赖实测而不是推理，所以仓库里留了大量一次性
取证工具与踩坑记录（`docs/修复记录-*.md`）。发现行为古怪时，先怀疑那里。

## 许可

[MIT](LICENSE)。渲染内核 [cmark-gfm](https://github.com/github/cmark-gfm) 为 BSD-2-Clause；
图标与视觉由本项目自绘（[`design/logo/build_logo.py`](design/logo/build_logo.py)）。
