# Spacedown 基准记录

> 每次里程碑跑一次，数字取代估算。跑法：
> `cd Packages/Core && swift build -c release --disable-sandbox && ./.build/release/Bench`

---

## M0 实测 · WKWebView 成本（**本轮最重要的数字**）

`swift build -c release --disable-sandbox && .build/release/WebViewBench <file.html>`

| 场景 | 11KB HTML | 1.85MB HTML |
|---|---:|---:|
| 冷启动（新 WebContent 进程 + 新 webview + 载入） | **373.6 ms** | 455.6 ms |
| 同一 webview 二次导航 | **10.2 ms** | 436.3 ms |
| 新建第二个 webview（进程已热） | 73.8 ms | 469.8 ms |

（1.85MB HTML 由 1MB Markdown 渲染而来）

### 拆开的成本模型

| 环节 | 耗时 | 占比 |
|---|---:|---:|
| **WebContent 进程 spawn** | **≈ 300 ms** | **80%** |
| 新建 `WKWebView` 实例 | ≈ 64 ms | 17% |
| 导航 + 排版（11KB） | ≈ 10 ms | 3% |

### 三条结论，每条都改了原方案

1. **「解析不是瓶颈」成立，而且比预想更极端。** 11KB 文档解析 0.06ms、排版导航 10ms，
   而进程 spawn 要 300ms —— 差 **4 个数量级**。优化预算 100% 该投在进程/webview 复用上。
2. **冷启动 373ms 已超原定 P2 硬上限（300ms）。** 视图型扩展（方案 B）的首次预览不达标。
   → **M2 必须先做数据型（方案 A）的 spike 对比**：它不建 webview，交给 QL 自己的渲染器，
   QL 服务常驻，很可能省掉这 300ms。这是"性能最重要"下的正确顺序。
3. **复用 webview 的收益远大于缓存。** 二次导航 10ms vs 新建 webview 74ms，差 7 倍。
   → 主 App 的 LRU 池从"默认 3"上调，且**淘汰时不要销毁实例**。

### 大文件：真正的成本在排版，不是解析

排版耗时 ≈ **236 ms / MB(HTML)**，而 HTML 约为 Markdown 的 1.85 倍 →
**排版 ≈ 437 ms × (Markdown MB数)**。

| Markdown | 排版 | 原方案阈值 | 修正后 |
|---|---:|---|---|
| 100KB | 44 ms | 正常 | 正常 |
| 500KB | 218 ms | 正常 | **正常（上限）** |
| 1MB | 437 ms | 正常 | ❌ 超 P3 目标 400ms |
| 2MB | 874 ms | 降级 | ❌ |

**原方案的「1~4MB 跳过图片内联与高亮」是错的** —— 成本是整篇排版，跳过这些不解决。
唯一有效的缓解是**截断文档**。阈值改为：≤500KB 正常；>500KB 截断预览 + 提示。

## 第 2 次 · 2026-10-07 · M1 收尾（开启 UNSAFE + tagfilter + 危险链接过滤之后）

**环境**：macOS 27.0.1 (26A434) · Apple Silicon arm64 · Swift 6.4 · `-c release`
**构建**：`-O3 -mcpu=apple-m1`（仅 arm64，不做 universal2）
**被测**：`MarkdownKit.MarkdownRenderer.renderHTML(_:)` —— 只含 `Data → cmark → HTML 字符串`，**不含 WKWebView 载入**。

| case | 输入 | min | p50 | p95 | p99 | 吞吐 |
|---|---|---:|---:|---:|---:|---:|
| 1KB | 2 KB | 0.059 | 0.064 | 0.073 | 0.076 | 25.1 MB/s |
| 10KB | 11 KB | 0.369 | 0.373 | 0.377 | 0.395 | 28.3 MB/s |
| 50KB | 50 KB | 1.742 | **1.757** | 1.818 | 1.843 | 28.0 MB/s |
| 500KB | 502 KB | 18.342 | 18.834 | 19.182 | 19.491 | 26.0 MB/s |
| 5MB | 5.0 MB | 194.006 | **199.670** | 202.367 | 204.125 | 25.1 MB/s |
| pathological | 335 KB | 27.201 | 29.207 | 29.483 | 29.527 | 11.2 MB/s |

> pathological = 2000 层嵌套引用 + 2 万个未闭合 `[a](b` + 3 万个未闭合 `*强调`。

**结论：开启裸 HTML 支持 + 三层安全防护后，性能没有变化**（与第 1 次相比在噪声内）。
安全加固的代价是 **0**，这条要记住——不要为了"保险"把开关关回去。

### 本次踩的三个坑（都是实测才发现的）

1. ❌ **`String.range(of:options:.caseInsensitive)` 在大字符串上只有约 4.5 MB/s。**
   用它扫描渲染结果找危险 scheme，直接把 50KB 从 1.65ms 打到 **33ms**、吞吐 28 → **1.5 MB/s**（20 倍回归）。
   改成手写字节级扫描后完全恢复。**别再用 `range(of:)` 扫大字符串**。
2. ❌ **把 `cmark_node_get_url()` 的返回值 `free()` 会 double free。**
   它返回的是 arena 分配的串（`cmark_chunk_to_cstr(NODE_MEM(node), …)`），所有权在 arena。
   这也是我最后放弃"AST 走查"方案的原因之一。
3. ❌ **tagfilter 挂在 parser 上不生效，必须传给 `cmark_render_html()`。**
   `html.c` 里过滤走的是 `renderer->filter_extensions`，来自 render 的第三个参数。
   只 attach 到 parser 而 render 传 `nil` → 裸 `<script>` 原样输出。

---

## 第 1 次 · 2026-10-07 · M1 骨架完成

**构建**：`-c release`（未加 `-mcpu`）

| case | 输入 | min | p50 | p95 | p99 | 吞吐 |
|---|---|---:|---:|---:|---:|---:|
| 1KB | 2 KB | 0.070 | 0.087 | 0.132 | 0.136 | 18.6 MB/s |
| 10KB | 11 KB | 0.346 | 0.365 | 0.421 | 0.448 | 28.9 MB/s |
| 50KB | 50 KB | 1.677 | 1.725 | 1.835 | 1.935 | 28.5 MB/s |
| 500KB | 502 KB | 17.996 | 18.215 | 18.688 | 19.440 | 26.9 MB/s |
| 5MB | 5.0 MB | 192.603 | 200.491 | 201.627 | 201.766 | 25.0 MB/s |
| pathological | 335 KB | 27.850 | 28.923 | 29.579 | 29.701 | 11.3 MB/s |

### 结论

1. **实测吞吐 25~29 MB/s，不是方案初稿估的 ≥60 MB/s。** 门槛已改为 ≥25 MB/s。
   这个偏差不推翻"解析不是瓶颈"的判断——50KB 解析 1.7ms，对上 WKWebView 的 40~250ms 仍是 <5%。
2. **大文件上解析开始变贵，缓存价值随之放大。** 5MB 冷解析约 200ms，已与 webview 同量级；
   命中缓存后归零。缓存对大文件的收益远大于小文件。
3. **无指数级退化。** 病态输入比正常文档慢约 2.7×/字节（11 vs 28 MB/s），是线性劣化。
   cmark 的 AFL 结论在真实数据上成立，不需要自己加递归深度限制。

### `-O3 -mcpu=apple-m1` 的收益

只支持 M 系列后加的（不做 universal2 才敢加，SwiftPM 的 cSettings 无法按架构分支）：

| case | 加之前 | 加之后 | 变化 |
|---|---:|---:|---:|
| 50KB | 1.725 ms | 1.653 ms | −4% |
| 5MB | 199.3 ms | 193.2 ms | −3% |
| pathological | 31.6 ms | 29.4 ms | −7% |

稳定 3~4%，不大但白拿，留着。

### 固定开销（推断被实测否掉过一次）

1KB 档 p50 = 0.087ms，10KB = 0.357ms——**数据量 10 倍、耗时只涨 4 倍** → 约 **0.04ms 固定成本**。
我一度以为它来自每次 4 次 `cmark_find_syntax_extension` 字符串查表，于是缓存了指针：
**1KB p50 0.087 → 0.086ms，零收益**。真来源是 `cmark_parser_new` 的 arena 分配。
0.04ms 对上 webview 的 40~250ms 毫无意义，不值得追。

---

## 渲染正确性 / 安全性（第 2 次验证，UNSAFE 开启后）

| 输入 | 输出 | 结论 |
|---|---|---|
| GFM 表格（含对齐） | `<table>` + `<th align="right">` | ✅ |
| 任务列表 | `<input type="checkbox" disabled />` | ✅ |
| `~~删除线~~` | `<del>` | ✅ |
| 代码块带语言 | `<pre><code class="language-swift">` | ✅ |
| `<kbd>⌘</kbd>` | `<kbd>⌘</kbd>` | ✅ **开启 UNSAFE 后才保留** |
| 裸 `<script>` | `&lt;script&gt;`（转义） | ✅ tagfilter 拦下 |
| `[x](javascript:alert(1))` | `<a href="#blocked-alert(1)">` | ✅ 我们的过滤 |
| `www.example.com` | `<a href="http://…">` | ✅ autolink |

> ⚠️ **修正第一次记录的结论。** 我原先写"安全性默认就有，不需要额外做"——那是在
> `CMARK_OPT_DEFAULT` 下测的，而默认行为会把**所有**裸 HTML 替换成 `<!-- raw HTML omitted -->`。
> 真实 README 顶部的徽章行（`<p align="center">` + `<img>`）、`<details>`、`<kbd>`、`<br>`
> 会整片消失，预览看起来像坏了。
>
> 现在改成 **开启 `CMARK_OPT_UNSAFE` + tagfilter 渲染列表 + 危险链接过滤 + CSP** 四层，
> 保真度和安全性都要，且实测零性能代价。详见 `Sources/MarkdownKit/MarkdownRenderer.swift` 的注释。
