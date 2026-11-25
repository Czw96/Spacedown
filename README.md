<div align="center">
  <img src="icon.png" width="112" alt="Spacedown 图标">
  <h1>Spacedown</h1>
  <p><b>在 Finder 里按一下空格，Markdown 就是排版好的样子。</b></p>
  <p>
    <b>简体中文</b> ｜ <a href="README.en.md">English</a>
  </p>
  <p>
    macOS 13+ · Apple Silicon · MIT ·
    <a href="https://github.com/Czw96/Spacedown/releases/latest">v1.0.23</a>
  </p>
</div>

![Spacedown 渲染 Markdown 的样子](preview-light.png)

## 为什么用它

macOS 自带的空格预览把 `.md` 当纯文本看：等宽字体、`#` 原样显示、表格散成一堆竖线。
你只是想扫一眼文档，却不得不打开编辑器。

Spacedown 接管这一步：Finder 里选中 `.md` 按空格，出来的是排版好的正文。双击还能开一个
只读的多标签窗口，同时看几份文档。

## 它好在哪

- **按空格就看** —— 不需要打开任何窗口。
- **排版像 GitHub** —— 表格、任务列表、代码块、`> [!NOTE]` 提示块、删除线，与网页上一致。
- **多标签只读窗口** —— 拖入文件即开，外部改动自动刷新，版心与字号可调。
- **原生且轻** —— Swift + AppKit 写的 3 MB 应用，排版走系统 WebKit 而不是自带浏览器框架，首帧通常一两百毫秒。

## 安装

从 [最新 Release](https://github.com/Czw96/Spacedown/releases/latest) 下载 `.dmg`，双击挂载，
把 Spacedown 拖进「应用程序」。

> [!IMPORTANT]
> 装完还有两步，各一次：**首次打开**在「系统设置 → 隐私与安全性」里允许（应用未公证）；
> **启动一次后**点菜单「显示 → 接管 Markdown 空格预览」。少了第二步，空格看到的还是源码。
>
> 更细的说明（`xattr` 清隔离、接管失败怎么查）见 [`docs/构建与发布.md`](docs/构建与发布.md)。

## 用起来

| 动作 | 快捷键 |
|---|---|
| 打开文件 | <kbd>⌘</kbd><kbd>O</kbd> |
| 关闭标签 | <kbd>⌘</kbd><kbd>W</kbd> |
| 下一个 / 上一个标签 | <kbd>⌃</kbd><kbd>⇥</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⇥</kbd> |
| 跳到第 N 个标签 | <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd> |
| 放大 / 缩小 / 实际大小 | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| 版心加宽 / 收窄 / 铺满 | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>=</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>0</kbd> |
| 查找 | <kbd>⌘</kbd><kbd>F</kbd> |
| 在 Finder 中显示 | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd> |

把 `.md` 拖到窗口任意位置就能打开；双击空白标签栏可以新建。空格预览里同样能 ⌘+ / ⌘− 缩放。

## 已知限制

- 只有 Apple Silicon（没有 Intel 版）。
- 只读：不支持编辑和保存。

## 常见问题

**按空格还是看到源码？** 接管没生效。菜单里再点一次「显示 → 接管 Markdown 空格预览」，
并确认没有别的 Markdown 预览扩展在抢（WPS 会抢）。

**双击 `.md` 打开的不是渲染视图？** 设置里点「设为 .md 默认打开方式」。

**图片显示不出来？** 本地图片要求与文档在同一目录树下；远程图片只加载 `https` 的，
且预览时会向图片服务器发起请求（与浏览器一致）。

## 从源码构建

```bash
python3 scripts/gen_project.py
xcodebuild -project Spacedown.xcodeproj -scheme Spacedown -configuration Release build
```

安装、接管、发版、自更新密钥的完整流程见 [`docs/构建与发布.md`](docs/构建与发布.md)，
架构与取舍见 [`docs/技术方案.md`](docs/技术方案.md)。

## 参与

单人维护。Issue 欢迎（附 macOS 版本与示例文件）；PR 请先开 issue；文档纠错直接提。

## 许可

[MIT](LICENSE)。渲染内核 [cmark-gfm](https://github.com/github/cmark-gfm) 为 BSD-2-Clause。

> 本项目的代码由 AI 编码助手（WorkBuddy）生成，需求、取舍与验收由人类负责。
