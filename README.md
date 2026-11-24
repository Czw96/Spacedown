<div align="center">
  <img src="icon.png" width="120" alt="Spacedown 图标">
  <h1>Spacedown</h1>
  <p><b>在 Finder 里按一下空格，Markdown 就是排版好的样子。</b><br>
  原生渲染 · Quick Look 扩展 · 只读多标签查看器</p>

  <p>
    <b>简体中文</b> ｜ <a href="README.en.md">English</a>
  </p>

  <p>
    macOS 13+ · Apple Silicon · MIT ·
    <a href="https://github.com/Czw96/homebrew-spacedown/releases/latest">v1.0.22</a> ·
    AI 生成代码
  </p>
</div>

![Spacedown 渲染 Markdown 的样子](preview-light.png)

> [!NOTE]
> **本项目由 AI 编码助手实现**（代码、文档、设计脚本、发版脚本），人类负责需求、方案取舍与真机验收。
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
| **扫一眼就够** | 空格预览只渲染前 64 KB（按**完整内容块**切，不会切断表格或代码块），片段末尾给「加载更多」交给主 App |
| **多标签** | 自绘标签栏，`WKWebView` LRU 池（5 + 备用 2），池内切换约 0 ms；上限 10 个 |
| **跟手** | 启动即预热一份 webview，首个文件首帧约 100 ms（冷启 370 ms 的账挪到启动期） |
| **只读但可复制** | CSP `default-src 'none'`，HTML 天然不可编辑；选中、⌘C、⌘A 正常 |
| **外改自动刷新** | `DispatchSource` 监听 + 120 ms 去抖 + inode/size/mtime 比对；删掉再重建也能重挂源 |
| **明暗自适应** | 跟随系统外观，空格预览与主窗口共用同一套 CSS |
| **版心可调** | 默认铺满，可收到 40%，⌥⌘= / ⌥⌘− / ⌥⌘0 |
| **缩放** | ⌘+ / ⌘− / ⌘0，25%–500%，走 `pageZoom`（重排版，不产生横向滚动条） |
| **查找** | ⌘F 浮出查找条，走 WebKit 原生 `find`，不注入 JS |
| **链接** | 单击复制地址，⌘/⌃ + 单击用默认浏览器打开（跨沙箱走 XPC） |
| **自更新** | Ed25519 自签校验 + 换包脚本，没有 Developer ID 也能安全升级 |

![深色外观](preview-dark.png)

## 安装

要求 **macOS 13 Ventura 或更新**、**Apple Silicon**（只出 arm64）。

```bash
brew tap czw96/spacedown
brew trust czw96/spacedown            # 第三方 tap 首次需要显式信任
brew install --cask spacedown

brew upgrade --cask spacedown         # 升级
brew uninstall --cask --zap spacedown # 卸载：偏好、沙箱容器、缓存一并清掉
```

也可以从 [最新 Release](https://github.com/Czw96/homebrew-spacedown/releases/latest) 下 `.dmg`，
拖进「应用程序」。

装完还有两件事，各一次：

1. **首次打开会被 Gatekeeper 拦**（本项目没有 Apple Developer ID）：去
   **系统设置 → 隐私与安全性 → 仍要打开**。
2. **启动一次后，点菜单「显示 → 接管 Markdown 空格预览」**。不点这一步，空格看到的还是源码。

细节（`xattr` 清 quarantine、为什么接管必须手动点、失败怎么查）见
[`docs/构建与发布.md`](docs/构建与发布.md)。

## 用起来

| 动作 | 快捷键 |
|---|---|
| 打开文件… | <kbd>⌘</kbd><kbd>O</kbd> |
| 关闭标签 / 窗口 | <kbd>⌘</kbd><kbd>W</kbd> |
| 重新载入 | <kbd>⌘</kbd><kbd>R</kbd> |
| 下一个 / 上一个标签 | <kbd>⌃</kbd><kbd>⇥</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⇥</kbd> |
| 跳到第 N 个标签 | <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd>（<kbd>⌘9</kbd> 固定是最后一个） |
| 放大 / 缩小 / 实际大小 | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| 版心加宽 / 收窄 / 铺满 | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>=</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>0</kbd> |
| 在 Finder 中显示 | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd> |
| 用默认编辑器打开 | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 查找 / 下一个 / 上一个 | <kbd>⌘</kbd><kbd>F</kbd> / <kbd>⌘</kbd><kbd>G</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> |

- 把 `.md` 拖到窗口任意位置都能打开；双击空白标签栏 = 新建标签。
- 空格预览里 **⌘+ / ⌘− / ⌘0 也能缩放**（视觉放大，最大 3 倍，捏合手势同一套）。
- 版心设置只对主 App 生效：扩展读不到主 App 偏好，空格预览固定按铺满渲染。

## 已知限制

- **只有 arm64**，没做 universal2，Intel Mac 用不了。
- **没有 Developer ID**：首次打开被 Gatekeeper 拦，也进不了官方 `homebrew-cask`。
- **只读**：不支持编辑、保存。这是设计选择。
- **预览上限 64 KB**：超过按完整块截断并给「加载更多」。主 App 不设上限。
- **远程图片不加载**：CSP 只允许 `img-src data:`，这是刻意不联网。GitHub 上常见的 shields
  徽章在预览里直接不显示，也不留空框。
- **空格预览读不到子目录图片**：系统只给被预览文件本身的读权限，`docs/img/x.png` 这类图在空格里
  出不来（主 App 正常）。
- **Release 资产在另一个仓库**：[Czw96/homebrew-spacedown](https://github.com/Czw96/homebrew-spacedown)，
  Cask 也指向那里，所以本仓库的 Releases 页面是空的。
- **不做 iOS / iPadOS**：Quick Look 扩展、`DispatchSource`、AppKit 决定了它只属于 macOS。

## 排错

- **空格显示源码 / 等宽字体**：接管没成功，菜单里再点一次；把别的 Markdown 预览扩展关掉
  （本机是 WPS：`pluginkit -e ignore -i com.kingsoft.wpsoffice.mac.WPSQuickLook`）。
- **改了代码、装了新版却没变化**：构建目录那份 App 被登记成第二个扩展，见 `docs/构建与发布.md`。
- **双击 `.md` 打开的不是渲染视图**：设置里点「设为 .md 默认打开方式」。

想知道到底是谁在渲染，只看日志：

```bash
/usr/bin/log stream --predicate 'subsystem == "cn.29dev.Spacedown"' --style compact
```

有 `preview file=` 才是我们接手了；一行都没有说明扩展根本没被加载。

## 从源码构建

```bash
python3 scripts/gen_project.py      # 工程文件是生成的，加了源码文件就重跑
xcodebuild -project Spacedown.xcodeproj -scheme Spacedown -configuration Release \
           -derivedDataPath ~/Library/Caches/Spacedown/DerivedData build
```

安装、接管、发版、公证、自更新密钥的完整流程见
[`docs/构建与发布.md`](docs/构建与发布.md)——那里面有三个会「静默失效」的坑，先读能省半天。

## 项目结构

```
Spacedown/            主 App（AppKit）
QuickLookPreview/     空格预览扩展（.appex）
LinkOpener/           XPC 服务：替沙箱里的扩展打开链接
Packages/Core/        cmark-gfm + MarkdownKit（渲染/截断）+ SharedTheme（外壳/主题）+ DevTools（基准）
scripts/              gen_project.py / release.sh / sign_update.swift
docs/                 技术方案 / 性能分析 / 代码审查 / 构建与发布
```

| 文档 | 内容 |
|---|---|
| [`docs/技术方案.md`](docs/技术方案.md) | 架构与每个决定的来龙去脉 |
| [`docs/性能分析.md`](docs/性能分析.md) | 时间到底花在哪（结论：99% 在 WebKit） |
| [`docs/代码审查.md`](docs/代码审查.md) | 逐文件审查记录，含未修项与取舍 |
| [`docs/构建与发布.md`](docs/构建与发布.md) | 构建、安装、接管、发版、自更新密钥 |

## 参与

单人维护、AI 生成的代码库——评审外部 PR 的成本比写代码高：

- **Issue 欢迎**：bug、排版怪例、Quick Look 行为差异，附上 macOS 版本与文件样例。
- **PR 请先开 issue**：没讨论过的 PR 可能直接关闭。
- 文档纠错、错别字、翻译改进：直接 PR，不用先问。

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

- [`docs/技术方案.md`](docs/技术方案.md) 每条决定都带「为什么不选另一个」，其中若干条是**人类否决
  AI 初稿**之后改的（典型例子：最初打算做渲染缓存，实测收益 ≈ 0 后砍掉）。
- README 与文档里所有「实测」数字，都来自 `Packages/Core/Sources/DevTools/` 里 AI 写的基准工具，
  可以自己跑一遍复核。
- 注释统一写「为什么」而不是复述代码在做什么——这是 AI 生成代码最容易变噪音的地方，
  本项目刻意往反方向压。

**局限也要说**：AI 生成的代码在边界条件上更依赖实测而不是推理，所以仓库里留了大量一次性取证
工具与踩坑记录（`docs/修复记录-*.md`）。发现行为古怪时，先怀疑那里。

## 许可

[MIT](LICENSE)。渲染内核 [cmark-gfm](https://github.com/github/cmark-gfm) 为 BSD-2-Clause；
图标与视觉由本项目自绘（[`design/logo/build_logo.py`](design/logo/build_logo.py)）。
