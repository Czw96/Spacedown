import AppKit
import WebKit
import Foundation

// ScrollBench：量化「重绘一整屏」的成本。
//
// 背景：docs/性能分析.md 只算了「首帧」（进程 spawn / 实例创建 / 排版），
// 从没算过「滚动」—— 而滚动卡不卡是另一笔账。本工具就是为了把两件事分开。
//
// 用法：
//   ScrollBench --file <preview.html> [--positions 30] [--only baseline,cv]
//
// 口径：把 HTML 载进真的 WKWebView，沿整篇高度均匀取样 N 个滚动位置，
// 每个位置都「滚过去 → 强制渲染当前视口 → 取快照」并计时。
//
// 为什么用 takeSnapshot 而不是 requestAnimationFrame：
//   rAF 只在页面**可见**时才走，窗口一旦被遮挡 WebKit 就把它挂起，测出来全是 0；
//   而 `afterScreenUpdates: true` 的快照会强制 WebKit 立刻把当前视口画出来 ——
//   这一笔开销就是「重绘一屏」的真实成本，且与窗口是否可见无关。
//
// 为什么这个数字能代表「卡不卡」：
//   - 正常 WKWebView 走滚动线程 + 分块（tiling）：用户滚的时候只需栅格化新露出的那一条，
//     所以即使这个数字偏大，手也不一定卡；
//   - 但 Quick Look 面板是把网页按**整页高度**塞进它自己的 NSScrollView 里，
//     滚动退化成主线程同步重绘整屏 —— 那种情况下，这个数字就是每帧要付的钱，
//     超过 16.7ms（60Hz 预算）就必然掉帧。
//
// ⚠️ 这个工具**测不了连续滚动的帧率**。试过 `requestAnimationFrame`：窗口在
// 「手工泵 runloop、不跑 NSApplication.run()」的情况下，WebKit 自报
// `document.visibilityState === "hidden"`（即使 .floating + orderFrontRegardless
// + activate 也一样），rAF 根本不触发，帧数恒为 0。`--raf` 参数保留着，
// 但别指望它 —— 想测手感只能上真机 + Instruments。
//
// 数字只用于**变体之间横向比较**（快照本身的编码开销所有变体都一样）。

// MARK: - 参数

let args = CommandLine.arguments

func arg(_ flag: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let htmlPath = arg("--file", "")
guard !htmlPath.isEmpty else {
    print("用法: ScrollBench --file <preview.html> [--positions 30] [--only baseline,cv]")
    exit(2)
}
let positionCount = Int(arg("--positions", "40")) ?? 40
/// 连续滚动测试时长（毫秒）。0 = 跳过。
let rafMs = Double(arg("--raf", "0")) ?? 0
/// 连续滚动时每帧滚多少像素。36 ≈ 2160 px/s（正常速度）；150 ≈ 9000 px/s（猛甩一下）。
let scrollStep = Double(arg("--step", "36")) ?? 36

let baseHTML: String
do {
    baseHTML = try String(contentsOfFile: htmlPath, encoding: .utf8)
} catch {
    print("读不到 \(htmlPath)：\(error)")
    exit(1)
}

// MARK: - CSS 变体

struct Variant {
    let name: String
    let note: String
    /// `@Sendable` 是必需的：不然 `variants` 这个顶层 `let` 会被推断成
    /// main-actor 隔离的全局量，从 `runAll()` 里就引用不到（Swift 6 严格并发）。
    /// 这些变体都是无捕获闭包，标 `@Sendable` 没有代价。
    let mutate: @Sendable (String) -> String
}

/// 追加到内联样式表末尾。（`@Sendable` 是因为它被下面那些无捕获的变体闭包引用。）
@Sendable func inject(_ html: String, _ css: String) -> String {
    html.replacingOccurrences(of: "</style>", with: css + "\n</style>")
}

let variants: [Variant] = [
    Variant(name: "baseline", note: "现状") { $0 },

    Variant(name: "cv", note: "视口外内容跳过渲染（作用在 .content 的每个直接子元素上）") { html in
        inject(html, """
        .content > * { content-visibility: auto; contain-intrinsic-size: auto 600px; }
        """)
    },

    Variant(name: "cv-blocks", note: "只对代码块/表格/引用这些重元素跳过渲染") { html in
        inject(html, """
        .content > pre, .content > table, .content > blockquote {
          content-visibility: auto;
          contain-intrinsic-size: auto 220px;
        }
        """)
    },

    Variant(name: "sep", note: "表格 border-collapse: separate") { html in
        inject(html, "\ntable { border-collapse: separate; border-spacing: 0; }")
    },

    Variant(name: "no-trl", note: "去掉 text-rendering: optimizeLegibility") { html in
        html.replacingOccurrences(of: "text-rendering: optimizeLegibility;", with: "")
    },

    Variant(name: "no-color", note: "去掉强制灰阶抗锯齿（-webkit-font-smoothing: antialiased）") { html in
        html.replacingOccurrences(of: "-webkit-font-smoothing: antialiased;", with: "")
    },

    Variant(name: "no-has", note: "把 :has() 换掉（探测选择器开销，语义已破坏）") { html in
        html.replacingOccurrences(of: ":has(", with: ":not(.x-unused ")
    },

    Variant(name: "no-lb", note: "去掉 line-break: strict") { html in
        html.replacingOccurrences(of: "line-break: strict;", with: "")
    },

    Variant(name: "no-shadow", note: "去掉链接下划线过渡（transition 探测）") { html in
        html.replacingOccurrences(of: "transition: text-decoration-color 120ms ease;", with: "")
    },

    Variant(name: "all", note: "cv + sep + 去 trl/字体平滑/line-break") { html in
        var out = html.replacingOccurrences(of: "text-rendering: optimizeLegibility;", with: "")
        out = out.replacingOccurrences(of: "-webkit-font-smoothing: antialiased;", with: "")
        out = out.replacingOccurrences(of: "line-break: strict;", with: "")
        out = inject(out, """
        .content > * { content-visibility: auto; contain-intrinsic-size: auto 600px; }
        table { border-collapse: separate; border-spacing: 0; }
        """)
        return out
    },
]

let only = arg("--only", "")
let selected = only.isEmpty
    ? variants
    : variants.filter { v in only.split(separator: ",").map(String.init).contains(v.name) }

// MARK: - 窗口与 webview

final class Nav: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done = true
        print("  载入失败: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        done = true
        print("  载入失败(provisional): \(error.localizedDescription)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "ScrollBench"
let nav = Nav()
let webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size))
webView.navigationDelegate = nav
window.contentView = webView
// ⚠️ 必须真的「可见」：窗口被遮挡时 WebKit 会把页面标记为不可见，
// requestAnimationFrame 直接不触发（第一版就是这么量出一堆 0 的）。
// 用 floating level + orderFrontRegardless 保证它在最上层，但**不激活 App、不抢焦点**。
window.level = .floating
window.orderFrontRegardless()

// 激活与「让窗口真正可见」在 ScrollBenchApp 里做 —— 必须在 NSApplication.run() 之内，
// 否则 app.isActive 落不了地、页面被判 hidden、rAF 不触发。旧的 --activate 开关已废弃。

@discardableResult
func pump(until: () -> Bool, timeout: TimeInterval = 30) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !until() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
    return until()
}

func sleepRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

final class EvalBox: @unchecked Sendable {
    var value: Any?
    var done = false
}

/// 同步取值的小工具。JS 回调在别的隔离域，用显式 Sendable 盒子搬结果。
///
/// ⚠️ `callAsyncJavaScript` 传进去的是**函数体**，不是表达式 ——
/// 少了 `return` 会安静地返回 undefined（踩过：所有数字都是 0）。
func evalSync(_ js: String) -> Any? {
    let box = EvalBox()
    webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { outcome in
        switch outcome {
        case .success(let v): box.value = v
        case .failure(let e): print("  JS 出错: \(e.localizedDescription)")
        }
        box.done = true
    }
    pump(until: { box.done }, timeout: 30)
    return box.value
}

func number(_ expression: String) -> Double {
    if let n = evalSync("return (\(expression));") as? NSNumber { return n.doubleValue }
    return 0
}

/// 已经是完整函数体（自带 `return`）的用这个，别再套一层 `return (...)`。
func numberBody(_ body: String) -> Double {
    if let n = evalSync(body) as? NSNumber { return n.doubleValue }
    return 0
}

/// 渲染并取快照；返回值是「取一张 1000×800 快照」的毫秒数。
///
/// 关键是 `afterScreenUpdates`：
/// - `false` → 不强制渲染，拿到的是当前已有的内容，开销只有 IPC + 图像编码；
/// - `true`  → 要求 WebKit 先把最新状态画出来，开销 = IPC + 编码 + **真正的绘制**。
///
/// 所以同一位置 `true - false` 就把编码这个常数抵掉了，剩下的才是「重绘一屏」的钱。
func timedSnapshot(afterScreenUpdates: Bool) -> Double {
    let done = EvalBox()
    let config = WKSnapshotConfiguration()
    config.afterScreenUpdates = afterScreenUpdates
    let t0 = DispatchTime.now().uptimeNanoseconds
    webView.takeSnapshot(with: config) { _, _ in done.done = true }
    pump(until: { done.done }, timeout: 30)
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
}

func quantile(_ xs: [Double], _ q: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))
    return s[i]
}

/// 连续滚动的帧间隔直方图。
///
/// ⚠️ 口径要说清楚：这里用**脚本**改 `scrollTop`（每帧 36px），走的是「改滚动位置 →
/// 主线程重排重绘」这条同步路径。真实滚轮在 WKWebView 里走的是滚动线程 + 分块，
/// 主线程再忙也可能不掉帧。所以这个数字是**上界**，用来看「谁在拖后腿」，
/// 不能直接当成用户手感。
///
/// 返回 (frames, p50, p95, max, janky, missed, fps)
func measureScrollFrames(_ durationMs: Double) -> [Double] {
    let raw = evalSync("""
    const el = document.scrollingElement || document.documentElement;
    const max = Math.max(0, el.scrollHeight - window.innerHeight);
    const STEP = \(scrollStep);
    el.scrollTop = 0;
    const frames = [];
    const t0 = await new Promise(r => requestAnimationFrame(r));
    let last = t0;
    await new Promise(resolve => {
      function step(now) {
        frames.push(now - last);
        last = now;
        let y = el.scrollTop + STEP;
        if (y >= max) y = 0;                 // 到底就回顶部继续，保持一直在滚
        el.scrollTop = y;
        if (now - t0 < \(durationMs)) { requestAnimationFrame(step); } else { resolve(); }
      }
      requestAnimationFrame(step);
    });
    const sorted = frames.slice().sort((a, b) => a - b);
    const q = p => sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))];
    let total = 0;
    for (const f of frames) total += f;
    return {
      frames: frames.length,
      p50: q(0.5),
      p95: q(0.95),
      worst: sorted[sorted.length - 1],
      janky: frames.filter(x => x > 33.4).length,
      missed: Math.round(total / 16.667) - frames.length,
      fps: total > 0 ? (frames.length * 1000 / total) : 0,
    };
    """)
    guard let dict = raw as? [String: Any] else { return [] }
    func g(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
    return [g("frames"), g("p50"), g("p95"), g("worst"), g("janky"), g("missed"), g("fps")]
}

// MARK: - PDF 模式
//
// 目的：验证「把同一份 HTML/CSS 渲成矢量 PDF、交给系统 PDF 预览」这条路的
// 生成成本与保真度。分页必须切在**块边界**上（不然会把行/表格切一半）。

/// `createPDF` 是异步的，用盒子搬回来。
func createPDFPage(top: Double, bottom: Double, width: Double) -> Data? {
    let box = EvalBox()
    let config = WKPDFConfiguration()
    config.rect = CGRect(x: 0, y: top, width: width, height: bottom - top)
    webView.createPDF(configuration: config) { outcome in
        switch outcome {
        case .success(let d): box.value = d
        case .failure(let e): print("  createPDF 失败: \(e.localizedDescription)")
        }
        box.done = true
    }
    pump(until: { box.done }, timeout: 120)
    return box.value as? Data
}

/// 取 `window.innerWidth` 与 `.content` 直接子块在文档坐标下的 [top, bottom]。
func measureBlocks() -> (width: Double, height: Double, blocks: [(Double, Double)]) {
    let raw = evalSync("""
    const els = document.querySelectorAll('.content > *');
    const out = [];
    const scrollY = window.scrollY;
    for (const el of els) {
      const r = el.getBoundingClientRect();
      out.push([r.top + scrollY, r.bottom + scrollY]);
    }
    return { width: window.innerWidth, height: document.scrollingElement.scrollHeight, blocks: out };
    """)
    guard let dict = raw as? [String: Any] else { return (0, 0, []) }
    let width = (dict["width"] as? NSNumber)?.doubleValue ?? 0
    let height = (dict["height"] as? NSNumber)?.doubleValue ?? 0
    var blocks: [(Double, Double)] = []
    if let arr = dict["blocks"] as? [[Any]] {
        for pair in arr where pair.count == 2 {
            let top = (pair[0] as? NSNumber)?.doubleValue ?? 0
            let bottom = (pair[1] as? NSNumber)?.doubleValue ?? 0
            blocks.append((top, bottom))
        }
    }
    return (width, height, blocks)
}

/// 把多份单页 PDF 合成一个多页 PDF，每页各带自己的 mediaBox（页高不同）。
func mergePDFPages(_ pages: [(data: Data, size: CGSize)]) -> Data? {
    let out = NSMutableData()
    guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
    var media = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
    for page in pages {
        guard let provider = CGDataProvider(data: page.data as CFData),
              let doc = CGPDFDocument(provider),
              let pdfPage = doc.page(at: 1) else { continue }
        var box = CGRect(origin: .zero, size: page.size)
        let boxData = withUnsafeBytes(of: &box) { Data($0) }
        let info: [String: Any] = [kCGPDFContextMediaBox as String: boxData]
        ctx.beginPDFPage(info as CFDictionary)
        ctx.drawPDFPage(pdfPage)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return out as Data
}

func runPDFMode(out: String, pageHeight: Double) {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scrollbench-pdf.html")
    try? Data(baseHTML.utf8).write(to: tmp)
    nav.done = false
    webView.loadFileURL(tmp, allowingReadAccessTo: URL(fileURLWithPath: NSTemporaryDirectory()))
    guard pump(until: { nav.done }) else { print("载入超时"); exit(1) }
    sleepRunLoop(1.0)

    let tStart = DispatchTime.now().uptimeNanoseconds
    let (width, docHeight, blocks) = measureBlocks()
    let tMeasure = DispatchTime.now().uptimeNanoseconds
    guard width > 0, !blocks.isEmpty else { print("量不到块（width=\(width) blocks=\(blocks.count)）"); exit(1) }

    // 按块边界分页：累加到超过 pageHeight 就从**上一个块的底**收页
    var pages: [(Double, Double)] = []
    var pageTop = blocks[0].0
    var lastBottom = pageTop
    for block in blocks {
        if block.1 - pageTop > pageHeight, lastBottom > pageTop {
            pages.append((pageTop, lastBottom))
            pageTop = block.0
        }
        lastBottom = block.1
    }
    if lastBottom > pageTop { pages.append((pageTop, lastBottom)) }

    var rendered: [(data: Data, size: CGSize)] = []
    var bytes = 0
    for page in pages {
        guard let data = createPDFPage(top: page.0, bottom: page.1, width: width) else { continue }
        rendered.append((data, CGSize(width: width, height: page.1 - page.0)))
        bytes += data.count
    }
    let tPages = DispatchTime.now().uptimeNanoseconds

    guard let merged = mergePDFPages(rendered) else { print("合并失败"); exit(1) }
    let tEnd = DispatchTime.now().uptimeNanoseconds
    try? merged.write(to: URL(fileURLWithPath: out))

    func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000.0 }
    print("PDF 原型")
    print(String(format: "  视口宽 %.0f px   文档高 %.0f px   块数 %d", width, docHeight, blocks.count))
    print(String(format: "  分页 %d 页（上限 %.0f pt/页）", pages.count, pageHeight))
    print(String(format: "  量块 %.1f ms   逐页 createPDF %.1f ms（%.1f ms/页）   合并 %.1f ms",
                 ms(tStart, tMeasure), ms(tMeasure, tPages), ms(tMeasure, tPages) / Double(max(1, pages.count)),
                 ms(tPages, tEnd)))
    print(String(format: "  总耗时 %.1f ms   合并后 %.0f KB（分页原始合计 %.0f KB）",
                 ms(tStart, tEnd), Double(merged.count) / 1024, Double(bytes) / 1024))
    print("  写出 -> \(out)")
}

let pdfOut = arg("--pdf", "")
if !pdfOut.isEmpty {
    runPDFMode(out: pdfOut, pageHeight: Double(arg("--page-height", "12000")) ?? 12000)
    exit(0)
}

// MARK: - 单次测量

struct Row {
    var variant = ""
    var nodes = 0.0
    var height = 0.0
    /// 滚一步的同步重排耗时（p95）
    var layoutP95 = 0.0
    var p50 = 0.0
    var p95 = 0.0
    var worst = 0.0
    var over = 0
    var samples = 0
}

/// 全部测量。必须在 `NSApplication.run()` 之内调用 —— 否则页面会被 WebKit 判为
/// hidden（`app.isActive` 落不了地），`requestAnimationFrame` 永远不触发。
func runAll() {
print("ScrollBench · 一屏重绘成本")
print("文件: \(htmlPath)")
print(String(format: "HTML: %.0f KB   取样点: %d", Double(baseHTML.utf8.count) / 1024, positionCount))
print("")
print(String(format: "%-10@ %7@ %9@ %9@ %8@ %8@ %8@ %8@",
             "variant" as NSString, "nodes" as NSString, "height" as NSString, "layout95" as NSString,
             "p50" as NSString, "p95" as NSString, "max" as NSString, ">16.7" as NSString))
print(String(repeating: "-", count: 78))

var rows: [Row] = []

for v in selected {
    let html = v.mutate(baseHTML)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scrollbench-\(v.name).html")
    try? Data(html.utf8).write(to: tmp)

    nav.done = false
    webView.loadFileURL(tmp, allowingReadAccessTo: URL(fileURLWithPath: NSTemporaryDirectory()))
    guard pump(until: { nav.done }) else {
        print(String(format: "%-10@ 载入超时", v.name as NSString))
        continue
    }
    sleepRunLoop(1.0)   // 等字体加载 + 首次全量排版落定

    var row = Row(variant: v.name)
    row.nodes = number("document.querySelectorAll('*').length")
    row.height = number("(document.scrollingElement || document.documentElement).scrollHeight")
    let viewport = number("window.innerHeight")

    if rafMs > 0, let vs = evalSync("return document.visibilityState + '|hidden=' + document.hidden;") as? String {
        print("  [页面可见性] \(vs)")
    }

    // 沿整篇高度均匀取样；每个点先取缓存帧、再强制重绘，两者相减
    let maxY = max(0, row.height - viewport)
    var samples: [Double] = []
    var layouts: [Double] = []
    for i in 0..<positionCount {
        let y = maxY * Double(i) / Double(max(1, positionCount - 1))

        // 布局成本：改 scrollTop 后读一个布局属性，强制同步重排一次
        let layoutMs = numberBody("""
        const el = document.scrollingElement || document.documentElement;
        const a = performance.now();
        el.scrollTop = \(y);
        void document.body.offsetHeight;
        return performance.now() - a;
        """)
        layouts.append(layoutMs)

        let cached = timedSnapshot(afterScreenUpdates: false)
        let forced = timedSnapshot(afterScreenUpdates: true)
        samples.append(max(0, forced - cached))
    }

    row.samples = samples.count
    row.p50 = quantile(samples, 0.50)
    row.p95 = quantile(samples, 0.95)
    row.worst = quantile(samples, 1.0)
    row.over = samples.filter { $0 > 16.7 }.count
    row.layoutP95 = quantile(layouts, 0.95)
    rows.append(row)

    print(String(format: "%-10@ %7.0f %9.0f px %8.1fms %7.1fms %7.1fms %7.1fms %5d/%d",
                 v.name as NSString, row.nodes, row.height, row.layoutP95,
                 row.p50, row.p95, row.worst, row.over, row.samples))

    if rafMs > 0 {
        let f = measureScrollFrames(rafMs)
        if f.count == 7, f[0] > 0 {
            print(String(format: "%-10@ %7.0f 帧  p50 %5.1fms  p95 %5.1fms  max %6.1fms  >33ms %5.0f  漏帧 %5.0f  %5.1f fps",
                         "  滚动" as NSString, f[0], f[1], f[2], f[3], f[4], f[5], f[6]))
        } else {
            print("  滚动     rAF 未触发（窗口不可见？加 --activate 再跑）")
        }
    }
}

print("")
print("layout95 = 滚一步的同步重排耗时（改 scrollTop 后强制读布局属性）")
print("p50/95   = 「强制重绘一屏」减「取缓存帧」，编码开销已抵掉，剩下的就是绘制成本")
print(">16.7    = 超过 60Hz 一帧预算的取样点数 / 总点数（这些位置必掉帧）")
print("")
for v in selected {
    print(String(format: "  %-10@ %@", v.name as NSString, v.note as NSString))
}
}

// MARK: - 启动

/// 注意顺序：**先让 `NSApplication.run()` 真正跑起来**，再在事件循环里做测量。
/// 不这样做的失败模式很隐蔽 —— 页面被 WebKit 判为 hidden，rAF 静默不触发。
final class ScrollBenchApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 用 runloop 定时器而不是 DispatchQueue：runAll() 内部会嵌套泵 runloop，
        // 从「定时器回调」里嵌套是标准做法（模态循环就是这么干的）；
        // 而从主队列 block 里嵌套会让里面的 runloop 跑不动（实测 load 直接超时）。
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            runAll()
            exit(0)
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

let benchApp = ScrollBenchApp()
app.delegate = benchApp
app.run()
