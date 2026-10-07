# Spacedown

macOS Markdown 速览：Finder 空格键预览 + 只读多标签查看器。

> **状态：未完成。** 目前只落地了渲染内核（M1 的一部分），
> **没有 App、没有 Quick Look 扩展、没有渲染缓存** —— 空格预览现在用不了。
> 下面「现在能用的」是一个命令行工具，可以先拿它看渲染效果。

---

## 一、现在能用的

### 构建

```bash
cd Spacedown/Packages/Core
swift build -c release --disable-sandbox
```

产物在 `.build/release/Bench`。

### 1. 把任意 Markdown 渲染成 HTML（看观感用）

```bash
.build/release/Bench --file /path/to/README.md --out /tmp/preview.html
open /tmp/preview.html
```

产出的 HTML **单文件自包含**（CSS 内联、明暗双主题），直接拖进浏览器就能看。
这是目前验收「渲染出来好不好看」的唯一途径。

### 2. 跑性能基准

```bash
.build/release/Bench                      # 合成语料 5 档 + 病态输入
.build/release/Bench --iter 500           # 指定每档迭代次数
.build/release/Bench --file X.md          # 对单个真实文件计时
.build/release/Bench --file X.md --print  # 打印渲染出的 HTML 片段
```

当前实测（Apple Silicon）：50KB 渲染 **1.76 ms**，5MB **约 200 ms**，吞吐 25~29 MB/s。
完整数字见 `docs/benchmarks.md`。

---

## 二、做完之后的用法（尚未实现）

```bash
brew install --cask spacedown
```

| 场景 | 操作 |
|---|---|
| **速览** | Finder 里选中 `.md`，按**空格**。第二次按同一文件直接命中缓存 |
| **滚动** | 滚轮 / 触控板 |
| **缩放** | `⌘+` `⌘-` `⌘0`，或双指捏合 |
| **打开为窗口** | 双击文件，或用「打开方式 → Spacedown」 |
| **多标签** | `⌘T` 新建；`⌘⇧[` / `⌘⇧]` 切换；`⌘1`~`⌘9` 直达；`⌘W` 关闭 |
| **自动刷新** | 外部编辑器保存后窗口自动更新，滚动位置保持 |
| **主题** | 跟随系统，切换零延迟（同一份缓存 HTML，不重新渲染） |
| **卸载** | `brew uninstall --zap spacedown`，无残留 |

---

## 三、进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | Spike：UTI 判定、QL 扩展 hello world、webview 冷启实测、键盘事件是否可达 | 🟨 **部分**：UTI ✅ webview 实测 ✅；**R1/R3 需真机** ⬜ |
| M1 | 渲染内核 + 缓存 + 主题 + Bench CLI | 🟨 **部分**：内核 ✅ 主题 ✅ Bench ✅ 缓存 ⬜ |
| M2 | Quick Look 扩展 | ⬜ 未开始 |
| M3 | 主 App 单文档窗口 | ⬜ 未开始 |
| M4 | 多标签 + 文件监听 + 缩放 | ⬜ 未开始 |
| M5 | 打磨与性能回归 | ⬜ 未开始 |
| M6 | 签名公证 + dmg + Homebrew Cask | ⬜ 未开始 |

**M0 必须先做** —— 它要验证三件可能推翻方案的事：

1. Sequoia+ 是否需要在「登录项与扩展 → Quick Look」手动启用扩展（会破坏"装完即用"）
2. `.md` 的 UTI 到底解析成什么（决定扩展能不能匹配上）
3. Quick Look 面板会不会吞掉 `⌘±` 键盘事件

---

## 四、目录

```
Spacedown/
├── Packages/Core/                  SwiftPM 包（仅 macOS .v12，仅 arm64）
│   ├── Sources/CcmarkGfm/          vendored cmark-gfm 0.29.0.gfm.7（34 个 .c）
│   ├── Sources/MarkdownKit/        Data → HTML，约 40 行封装
│   ├── Sources/SharedTheme/        theme.css + HTML 模板拼装
│   └── Sources/Bench/              命令行基准 / 渲染工具
├── docs/技术方案.md                 方案（含性能指标、风险清单、里程碑）
├── docs/benchmarks.md              实测数字与踩坑记录
└── App/ QuickLookExtension/        尚未创建
```

## 五、本机环境注意

- `xcode-select` 当前指向 CommandLineTools，打包 `.appex` 前需要
  `sudo xcode-select -s /Applications/Xcode.app`
- `swift build` 一律加 `--disable-sandbox`，否则 `sandbox-exec: Operation not permitted`
