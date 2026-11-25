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

## 为什么用它

macOS 自带的空格预览把 `.md` 当纯文本看：等宽字体、`#` 原样显示、表格散成一堆竖线。

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

## 用起来

| 动作 | 快捷键 |
|---|---|
| 打开文件 | <kbd>⌘</kbd><kbd>O</kbd> |
| 关闭标签 | <kbd>⌘</kbd><kbd>W</kbd> |
| 跳到第 N 个标签 | <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd> |
| 放大 / 缩小 / 实际大小 | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| 版心加宽 / 收窄 / 铺满 | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>=</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>0</kbd> |
| 查找 | <kbd>⌘</kbd><kbd>F</kbd> |
| 在 Finder 中显示 | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd> |

## 已知限制

- 只有 Apple Silicon（没有 Intel 版）。
- 只读：不支持编辑和保存。

## 许可

[MIT](LICENSE)。渲染内核 [cmark-gfm](https://github.com/github/cmark-gfm) 为 BSD-2-Clause。

> 本项目的代码由 AI 编码助手（WorkBuddy）生成。
