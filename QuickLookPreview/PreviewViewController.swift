import AppKit
import QuickLookUI
import WebKit
import os

import MarkdownKit
import SharedTheme

/// 视图型（`QLPreviewingController`）Quick Look 预览扩展。
///
/// ## 为什么从数据型换成视图型
///
/// 原来用的是数据型（`QLPreviewProvider` + `QLPreviewReply(dataOfContentType: .html)`）：
/// 我们把渲染好的 HTML 交出去，**由系统自己去排版显示**。省下的那点东西是
/// WebContent 进程的启动，但代价是**我们对 web view 一无所知** ——
/// 它多大、怎么滚、会不会被按整篇高度撑开，全都不归我们管。
///
/// 2026-10-08 实测把这件事定死了（工具：`Packages/Core/Sources/ScrollBench/`，
/// 归因与完整数据见 `docs/性能分析.md §6`）：
///
/// | HTML | 节点 / 文档高 | 滚动帧率 |
/// |---|---:|---:|
/// | 66KB | 1.5k / 27k px | 60.0 fps，0 漏帧 |
/// | 306KB | 10k / 172k px | 60.0 fps，0 漏帧 |
/// | 828KB | 28k / 471k px | 60.0 fps，0 漏帧（9000 px/s 猛甩） |
///
/// 也就是说：**WebKit 在「viewport 尺寸的 web view」里画这些文档毫无压力** ——
/// 每帧只重画一屏，成本与文档总长无关。用户感受到的「滚动卡」不是内容造成的，
/// 只能来自「谁在承载这份 HTML」。所以这里自己建 web view、自己定尺寸：
///
/// 1. **web view 永远是面板尺寸（viewport），绝不按整篇高度撑开** —— 这是关键；
///    它让滚动走 WebKit 的滚动线程 + 分块，而不是主线程同步重绘整屏。
/// 2. 顺带拿回控制权与可观测性（能埋点、能定背景色、能复用实例）。
/// 3. 实例可复用 + 预览结束后预建下一个 → 进程活着时省掉约 74ms 的实例创建。
///
/// ## 已经排除掉的方向（别再回头试）
///
/// - **CSS 微调无效**：去掉 `text-rendering: optimizeLegibility`、表格改
///   `border-collapse: separate`、去掉 `:has()`、去掉自定义滚动条…… 实测全在噪声里。
///   上面那张 60fps 的表就是**用现有 CSS（含 `::-webkit-scrollbar`）跑出来的**。
/// - **`content-visibility: auto` 是负收益**：文档高度虚高 5 倍（滚动条会跳），
///   还把成本从「平均」挪成「滚动那一刻的 14ms 尖峰」。
/// - **PDF 载体不划算**：同一份文档渲成矢量 PDF 要 485ms / 1.1MB（66KB 文档）
///   到 749ms / 1.56MB（306KB 文档），对「按空格扫一眼」来说太贵。
/// - **`contentSize` 不是开关**：官方文档写明它只是给加载占位 UI 的尺寸提示。
///
/// ## 埋点为什么改成 `os_log`
///
/// 旧实现用 `try?` 往 `~/Library/Logs/Spacedown/` 和 `/tmp` 写文件 —— **全都静默失败**：
/// Quick Look 主进程会把扩展进程关进沙箱，这两个路径都不可写（所以那个 `timing.log`
/// 从来没出现过，README 早期那套「连按两次空格看 pid」的验收方法因此一直无效）。
/// 统一日志在沙箱里可用：
///
/// ```bash
/// log stream --predicate 'subsystem == "cn.29dev.Spacedown"' --style compact
/// ```
// `@preconcurrency` 是必需的：`QLPreviewingController` 是老的 ObjC 协议，没有隔离标注，
// 而 `NSViewController` 是 main-actor 的 —— Swift 6 严格并发会判定这次 conformance
// 「跨进 main actor」而报错。Quick Look 本来就在主线程调用它，标注只是把这件事写下来。
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController,
    @preconcurrency WKNavigationDelegate, @preconcurrency WKScriptMessageHandler {

    /// 超过这个体积就截断。
    ///
    /// 天花板不是解析而是 WebKit 排版（约 236 ms/MB HTML），所以「大文件先截断」
    /// 是唯一有效的缓解手段 —— 见 docs/技术方案.md §3。
    private static let maxBytes = 512 * 1024

    private static let renderer = MarkdownRenderer()

    private static let logger = Logger(subsystem: "cn.29dev.Spacedown", category: "quicklook")

    /// 滚动探针的回调名。JS 里用 `window.webkit.messageHandlers.scrollProbe.postMessage(...)`。
    static let probeName = "scrollProbe"

    // MARK: - 一次预览的状态

    private var webView: WKWebView!
    private var fileName = ""
    private var htmlBytes = 0
    private var startedAt: UInt64 = 0
    private var readMs = 0.0
    private var renderMs = 0.0
    private var wrapMs = 0.0
    private var finished = false
    private var completion: ((Error?) -> Void)?
    private var watchdog: DispatchWorkItem?
    /// 当前这次请求对应的导航对象。
    ///
    /// Quick Look 可以**在旧请求还没加载完时就用同一个控制器发新请求**（在 Finder 里
    /// 用方向键一路按过去就会这样）。此时旧请求的 `didFinish` 会晚于新请求到达 ——
    /// 不认身份的话，它会把**新请求**提前标记成"已完成"，面板就停在上一份内容上。
    /// 认 `WKNavigation` 的对象身份即可：`load()` 返回的就是回调里给的那个。
    private var pendingNavigation: WKNavigation?

    // MARK: - 视图

    override func loadView() {
        // ⚠️ 这里的尺寸不重要（Quick Look 会按面板重设），但 **frame 不能是零**：
        // WKWebView 在零尺寸下不排版。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.pageBackground.cgColor

        let web = PreviewWebViewPool.shared.take(handler: self)
        web.navigationDelegate = self
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        web.underPageBackgroundColor = Self.pageBackground
        container.addSubview(web)

        webView = web
        view = container
        // witness：只要这一行落了盘，就说明**我们的扩展确实被拉起来了**。
        Self.diag("view_loaded")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        PreviewWebViewPool.shared.recycleLater(webView)
    }

    /// 无内容时的底色，避免深色模式下加载前闪白。
    private static var pageBackground: NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1)   // = theme.css 的深色 --bg
            : .white
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        _ = view                     // 强制走 loadView，确保 webView 已就位
        Self.diag("prepare", ", \"file\": \"\(url.lastPathComponent)\"")
        completion = completionHandler
        finished = false
        fileName = url.lastPathComponent
        startedAt = Self.now()
        // 上一次请求的看门狗必须先撤掉：它捕获的 `self` 会再调 finish(nil)，
        // 而 `finished` 刚被重置成 false —— 不撤就会把**这次**请求提前结束。
        watchdog?.cancel()
        watchdog = nil

        let html: Data
        do {
            html = try render(url: url)
        } catch {
            Self.logger.error("render_failed file=\(self.fileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            finish(error)
            return
        }

        htmlBytes = html.count
        // baseURL 只用来解析相对 URL，而我们的 HTML 是单文件自包含的
        // （CSS 内联、CSP `default-src 'none'`），所以给个非 file 的 scheme 即可。
        // ⚠️ 别传文件目录：那会走进 WebKit 的沙箱扩展 IPC，实测会死锁（技术方案 §15.2）。
        pendingNavigation = webView.load(html,
                                         mimeType: "text/html",
                                         characterEncodingName: "UTF-8",
                                         baseURL: URL(string: "about:blank")!)

        // 看门狗：万一 didFinish 不来（解析失败 / WebKit 卡住），也不能让面板一直转圈。
        let navigation = pendingNavigation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingNavigation === navigation else { return }
            self.log("watchdog_fired")
            self.finish(nil)
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === pendingNavigation else { return }   // 过期请求的回调，丢掉
        log("load=\(Self.fmt(Self.ms(startedAt, Self.now())))ms")
        Self.diag("did_finish", ", \"ms\": \(Self.fmt(Self.ms(startedAt, Self.now())))")
        logGeometry()
        // ⚠️ 不能在这里直接 finish：`didFinish` 只代表"导航完成"，不代表**画出来了**。
        waitForFirstPaint()
    }

    /// 等第一帧真正画完，再把 judgement 交给 Quick Look。
    ///
    /// `WKNavigationDelegate.didFinish` 的语义是"主资源加载完成"，WebKit 此刻可能还没排完
    /// 第一次绘制。而一旦调了 completionHandler，面板就开始淡入 —— 那前面的几帧是
    /// 空白（或半截内容）跟淡入动画抢线程，观感就是"出来那一刻卡一下"。
    ///
    /// 双 rAF 是判断"已上屏"的最小手段：第一个回调处于这一帧绘制**之前**，第二个回调
    /// 意味着前一帧已经提交给合成器。代价只有一到两帧（实测期望 ~17~33ms）。
    private func waitForFirstPaint() {
        let requestedAt = Self.now()
        let navigation = pendingNavigation
        webView.evaluateJavaScript("""
        new Promise(function (resolve) {
            requestAnimationFrame(function () {
                requestAnimationFrame(function () { resolve(1); });
            });
        })
        """) { [weak self] _, _ in
            guard let self, self.pendingNavigation === navigation else { return }
            Self.logger.notice("""
            first_paint file=\(self.fileName, privacy: .public) \
            after_didFinish=\(Self.fmt(Self.ms(requestedAt, Self.now())))ms
            """)
            Self.diag("first_paint", ", \"after_ms\": \(Self.fmt(Self.ms(requestedAt, Self.now())))")
            self.finish(nil)
        }
    }

    /// 「是不是没加载完」这个问题的答案：量一下排版结果的高度和视口高度的比值。
    ///
    /// 滚动路线的分岔点全在这里：
    /// - `innerHeight ≈ panel 高度`（几百 px）→ 是 viewport 模式，滚动走 WebKit 滚动线程；
    /// - `innerHeight ≈ scrollHeight`（几万 px）→ 视图被按整篇高度撑开了，
    ///   每帧是主线程同步重绘整屏 —— 那时候再怎么调 CSS 都没用。
    private func logGeometry() {
        let viewSize = view.frame.size
        let webSize = webView.frame.size
        webView.evaluateJavaScript("""
        (function () {
            var d = document.documentElement;
            return {
                scrollHeight: d.scrollHeight,
                innerHeight: window.innerHeight,
                devicePixelRatio: window.devicePixelRatio,
                nodes: document.getElementsByTagName('*').length
            };
        })()
        """) { [weak self] result, error in
            guard let self else { return }
            guard let dict = result as? [String: Any],
                  let scrollHeight = dict["scrollHeight"] as? Double,
                  let innerHeight = dict["innerHeight"] as? Double else {
                Self.logger.notice("geometry_probe_failed file=\(self.fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                return
            }
            let nodes = dict["nodes"] as? Int ?? 0
            let dpr = Self.fmt(dict["devicePixelRatio"] as? Double ?? 0)
            // 取值同时落盘：取证时不依赖能不能读到日志
            Self.diag("geometry", """
            , "inner_h": \(Self.fmt(innerHeight)), "scroll_h": \(Self.fmt(scrollHeight)), \
            "nodes": \(nodes), "dpr": \(dpr)
            """)
            Self.logger.notice("""
            geometry file=\(self.fileName, privacy: .public) \
            view=\(Self.fmt(viewSize.width))x\(Self.fmt(viewSize.height)) \
            web=\(Self.fmt(webSize.width))x\(Self.fmt(webSize.height)) \
            inner=\(Self.fmt(innerHeight))px scroll=\(Self.fmt(scrollHeight))px \
            nodes=\(nodes) dpr=\(dpr, privacy: .public)
            """)
        }
    }

    // MARK: - 滚动探针

    /// 注入到页面里的帧率探针：**被动**的，只在真的发生滚动时采一段。
    ///
    /// 为什么不能"主动"滚一段来量：面板已经显示了，程序化的滚动用户看得见。
    /// 所以挂在 `scroll` 事件上 —— 用户自己滚的那一瞬间才开始记帧间隔，
    /// 停下来 180ms 就出一份统计。既不打扰视线，也测的正是用户感受到的那条路径。
    static let probeScript = WKUserScript(source: """
    (function () {
        var frames = [], raf = 0, idle = 0, last = 0, running = false;
        function tick(ts) {
            if (last) { frames.push(ts - last); }
            last = ts;
            if (frames.length < 900) { raf = requestAnimationFrame(tick); }
        }
        function stop() {
            running = false;
            if (raf) { cancelAnimationFrame(raf); raf = 0; }
            var n = frames.length;
            if (n < 4) { return; }                       // 太短的一段没有统计意义
            var sorted = frames.slice().sort(function (a, b) { return a - b; });
            var sum = 0;
            for (var i = 0; i < n; i++) { sum += frames[i]; }
            window.webkit.messageHandlers.\(probeName).postMessage({
                count: n,
                mean: sum / n,
                p50: sorted[Math.floor(n * 0.5)],
                p95: sorted[Math.floor(n * 0.95)],
                worst: sorted[n - 1],
                // 超过一个 vsync 周期的都算"漏帧"（60Hz 下 >17ms）
                dropped: frames.filter(function (d) { return d > 17.0; }).length
            });
            frames = []; last = 0;
        }
        window.addEventListener('scroll', function () {
            if (!running) { running = true; frames = []; last = 0; raf = requestAnimationFrame(tick); }
            if (idle) { clearTimeout(idle); }
            idle = setTimeout(stop, 180);
        }, { passive: true });
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    /// 探针的回执。fps 是按**实际帧间隔均值**反推的，不是理论值。
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.probeName,
              let dict = message.body as? [String: Any],
              let count = dict["count"] as? Int else { return }
        let p50 = dict["p50"] as? Double ?? 0
        let p95 = dict["p95"] as? Double ?? 0
        let worst = dict["worst"] as? Double ?? 0
        let dropped = dict["dropped"] as? Int ?? 0
        let mean = dict["mean"] as? Double ?? 0
        let fps = mean > 0 ? 1000.0 / mean : 0
        Self.diag("scroll_probe", """
        , "frames": \(count), "fps": \(Self.fmt(fps)), "p50": \(Self.fmt(p50)), \
        "p95": \(Self.fmt(p95)), "worst": \(Self.fmt(worst)), "dropped": \(dropped)
        """)
        Self.logger.notice("""
        scroll_probe file=\(self.fileName, privacy: .public) frames=\(count) \
        fps=\(Self.fmt(fps)) p50=\(Self.fmt(p50))ms p95=\(Self.fmt(p95))ms \
        worst=\(Self.fmt(worst))ms dropped=\(dropped)
        """)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === pendingNavigation else { return }
        log("load_failed error=\(error.localizedDescription)")
        finish(nil)   // 面板已经能显示了，别把它变成错误页
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === pendingNavigation else { return }
        log("load_failed_provisional error=\(error.localizedDescription)")
        finish(nil)
    }

    // MARK: - 内部

    private func log(_ tail: String) {
        Self.logger.notice("""
        preview file=\(self.fileName, privacy: .public) bytes=\(self.htmlBytes) \
        read=\(Self.fmt(self.readMs))ms render=\(Self.fmt(self.renderMs))ms \
        wrap=\(Self.fmt(self.wrapMs))ms \(tail, privacy: .public) \
        total=\(Self.fmt(Self.ms(self.startedAt, Self.now())))ms
        """)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        let handler = completion
        completion = nil
        // 交给 Quick Look 之后预建下一个实例：把 74ms 的实例创建挪出关键路径。
        PreviewWebViewPool.shared.prewarm()
        handler?(error)
    }

    private static func fmt(_ ms: Double) -> String { String(format: "%.2f", ms) }

    /// 临时诊断：把一行 JSON 追加到磁盘上的两个候选位置。
    ///
    /// 为什么放着 `os_log` 还要写文件：这台机器上 `log show` / `ps` / `pluginkit` 全被权限挡住，
    /// 拿不到档案就看不了。Quick Look 主进程会把扩展进程关进沙箱，**这两个路径不一定可写** ——
    /// 写没写成、写到哪一路，本身就是这次要测的一件事。
    /// TODO(诊断用): 取证结束就删掉，正式版本只走 os_log。
    private static func diag(_ kind: String, _ extra: String = "") {
        let line = """
        {"ts":\(Self.now() / 1_000_000), "kind":"\(kind)", "pid":\(ProcessInfo.processInfo.processIdentifier)\(extra)}
        """
        let data = Data((line + "\n").utf8)
        let paths = [
            "/tmp/spacedown-ql-diag.jsonl",
            NSHomeDirectory() + "/Library/Logs/Spacedown/diag.jsonl",
        ]
        for path in paths {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func ms(_ a: UInt64, _ b: UInt64) -> Double {
        Double(b - a) / 1_000_000.0
    }

    /// 读文件 → 截断 → 解析 → 拼完整 HTML。与主 App 走同一条链路。
    private func render(url: URL) throws -> Data {
        let t0 = Self.now()
        var data = try Data(contentsOf: url, options: .mappedIfSafe)
        let t1 = Self.now()
        if data.count > Self.maxBytes {
            data = Self.truncated(data, limit: Self.maxBytes)
        }
        let body = Self.renderer.renderHTMLData(data)
        let t2 = Self.now()
        let document = SharedTheme.document(body: body)
        let t3 = Self.now()

        readMs = Self.ms(t0, t1)
        renderMs = Self.ms(t1, t2)
        wrapMs = Self.ms(t2, t3)
        return document
    }

    /// 尽量切在换行上，避免把一个 markdown 块结构切成半截。
    private static func truncated(_ data: Data, limit: Int) -> Data {
        var slice = data.prefix(limit)
        if let newline = slice.lastIndex(of: 0x0A) {
            slice = slice[..<newline]
        }
        var out = Data("\n\n> 文件过大，已截断显示前 \(limit / 1024) KB\n".utf8)
        out.append(slice)
        return out
    }
}

/// `WKWebView` 复用池（容量 1）。
///
/// 为什么值得做：新建一个 `WKWebView` 实测约 64~74ms。Quick Look 常常是连续预览
/// 好几个文件（方向键一路按过去），把实例留着复用就能把这一笔从关键路径上拿掉。
///
/// ⚠️ 回收要**延迟**：面板还在做退场动画时就把实例抽走，会让旧面板闪。
/// 所以 `recycleLater` 等 0.5 秒，并且用一个 token 确认它没被 reused。
@MainActor
final class PreviewWebViewPool {

    static let shared = PreviewWebViewPool()

    private var idle: WKWebView?
    private var token = 0

    /// 只有**确认过回收会被调用**，预热才有意义。
    ///
    /// Quick Look 面板不是常规的视图呈现，`viewWillDisappear` 不保证会来。如果它不来，
    /// 预热出来的实例永远不会被取用 —— 那就是每次预览白花 74ms 和一份内存。
    /// 所以先观察一次回收再启用预热。
    private var recyclingObserved = false

    /// 取一个实例：优先复用，没有就新建。
    ///
    /// `WKUserScript` 在建实例时就注入了（每个文档加载完自动生效），但**回调对象**
    /// 必须每次预览重新登记 —— 回执要发给当前这个控制器，而旧的那个可能已经释放了，
    /// `userContentController` 对 handler 是强引用，留着就是泄漏 + 串台。
    func take(handler: WKScriptMessageHandler) -> WKWebView {
        token &+= 1
        let view: WKWebView
        if let idle {
            self.idle = nil
            view = idle
        } else {
            view = Self.makeView()
        }
        let controller = view.configuration.userContentController
        controller.removeScriptMessageHandler(forName: PreviewViewController.probeName)
        controller.add(handler, name: PreviewViewController.probeName)
        return view
    }

    /// 面板退场后延迟回收，避免抽走正在显示的那一份。
    func recycleLater(_ view: WKWebView) {
        let generation = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.token == generation, self.idle == nil else { return }
            view.stopLoading()
            view.removeFromSuperview()
            // 断掉对旧控制器的强引用：`userContentController` 的 handler 是强持有，
            // 不摘的话每个被前缀览用过的控制器都会跟着实例活到最后。
            view.configuration.userContentController
                .removeScriptMessageHandler(forName: PreviewViewController.probeName)
            view.loadHTMLString("<!doctype html><meta charset='utf-8'><body></body>", baseURL: nil)
            self.idle = view
            self.recyclingObserved = true
        }
    }

    /// 预热：给「上一位还在回收延迟里、下一位已经来了」这种连按空格的情况备一份。
    /// 调用点在 `finish()` 之后，属于非关键路径。未确认回收可达之前不动手。
    func prewarm() {
        guard recyclingObserved, idle == nil else { return }
        let view = Self.makeView()
        view.loadHTMLString("<!doctype html><meta charset='utf-8'><body></body>", baseURL: nil)
        idle = view
    }

    private static func makeView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // 探针在文档加载完那一刻生效，之后每次导航都会自动跑一遍。
        config.userContentController.addUserScript(PreviewViewController.probeScript)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                             configuration: config)
        // 缩放走 GPU 合成层，不触发重排（主 App 用的是同一招）
        view.allowsMagnification = true
        return view
    }
}
