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
// `@preconcurrency` 只对 `QLPreviewingController` 是必需的：它是老的 ObjC 协议、没有隔离标注，
// 而 `NSViewController` 是 main-actor 的 —— Swift 6 严格并发会判定这次 conformance
// 「跨进 main actor」而报错。Quick Look 本来就在主线程调用它，标注只是把这件事写下来。
// ⚠️ `WKNavigationDelegate` / `WKScriptMessageHandler` 不需要它（编译器会警告"no effect"）。
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController,
    WKNavigationDelegate, WKScriptMessageHandler {

    private static let renderer = MarkdownRenderer()

    /// 本类型第一次被访问的时刻（≈ 进程起来之后的最早一段）。
    /// 用来量「扩展进程启动 → 收到 preparePreviewOfFile」这段我们看不到的开销。
    private static let launchedAt = now()

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
    /// 上一次交出去的 HTML —— 内容进程被回收时用它重载（见
    /// `webViewWebContentProcessDidTerminate`）。
    private var lastRenderedHTML: Data?
    /// 是否已经为这次预览重载过一次。只重试一次，避免"重载 → 又崩"死循环。
    private var didRecoverFromTermination = false

    /// 打开外部链接用的 XPC 服务（服务端在 `LinkOpener/`，**不在沙箱里**）。
    ///
    /// 为什么不是直接 `NSWorkspace`：沙箱里调它会让**本进程被 SIGTRAP 杀掉**，
    /// 见 `decidePolicyFor` 上方那张实测表。
    private var linkOpener: LinkOpenerProtocol?
    /// XPC 连接必须自己持有 —— 代理对象不持有连接，放掉它等于把服务断掉。
    private var linkOpenerConnection: NSXPCConnection?
    private static let linkOpenerServiceName = "cn.29dev.Spacedown.LinkOpener"
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
        // ⚠️ **在渲染之前先把内容进程拉起来**：WebContent 的冷启动要一两百毫秒，
        // 而"读文件 + 渲染"那几十毫秒正好可以跟它重叠。这里 load 一个空白页，
        // 真正的 HTML 稍后会顶掉它（同一进程内二次导航很便宜）。
        if web.url == nil {
            web.loadHTMLString("<!doctype html><meta charset='utf-8'><body></body>", baseURL: nil)
        }
        connectLinkOpener()
        // witness：只要这一行落了盘，就说明**我们的扩展确实被拉起来了**。
        Self.diag("view_loaded")
    }

    /// 连上"打开链接"用的 XPC 服务。**失败不影响预览** —— 点链接只会记一条日志。
    private func connectLinkOpener() {
        let connection = NSXPCConnection(serviceName: Self.linkOpenerServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: LinkOpenerProtocol.self)
        connection.resume()
        linkOpenerConnection = connection
        // 异步代理：调用不阻塞。回执在私有队列上回来，用之前自己跳回主队列。
        linkOpener = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async {
                self?.log("link_opener_unavailable \(error.localizedDescription)")
                // ⚠️ 这里也要给提示：连接/调用失败时**回执根本不会来**，
                // 只在 openExternal 里提示的话这种情况是静默的。
                self?.showOpenFailure("XPC 调用失败：" + error.localizedDescription)
            }
        } as? LinkOpenerProtocol

        // 一次无副作用的连通性自检：日志里出现 `link_opener_ping ok=true` 就说明
        // "点链接打不开"不再是 XPC 连接的问题（剩下的只可能是服务侧打开失败）。
        linkOpener?.ping { ok in
            DispatchQueue.main.async {
                Self.logger.notice("link_opener_ping ok=\(ok)")
            }
        }
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
        let sinceLaunch = Self.ms(Self.launchedAt, Self.now())
        Self.diag("prepare", ", \"file\": \"\(url.lastPathComponent)\"")
        Self.logger.notice("prepare file=\(url.lastPathComponent, privacy: .public) since_launch=\(Self.fmt(sinceLaunch), privacy: .public)ms")
        completion = completionHandler
        finished = false
        fileName = url.lastPathComponent
        startedAt = Self.now()
        // 上一次请求的看门狗必须先撤掉：它捕获的 `self` 会再调 finish(nil)，
        // 而 `finished` 刚被重置成 false —— 不撤就会把**这次**请求提前结束。
        watchdog?.cancel()
        watchdog = nil

        // ⚠️ 读文件 + 渲染挪到后台队列。这两步在 512 KB 上限下要几十毫秒，
        // 挂在主线程上会拖住 Quick Look 自己的面板动画 —— 而我们紧接着就要把面板交出去。
        // （同架构的 showmd 也是在 `DispatchQueue.global(qos: .userInitiated)` 上读文件的。）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let rendered = try self.render(url: url)
                DispatchQueue.main.async { self.present(rendered) }
            } catch {
                Self.logger.error("render_failed file=\(self.fileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self.finish(error) }
            }
        }
    }

    /// 把渲染好的 HTML 交给 web view，并**立刻**把面板交还给 Quick Look。
    ///
    /// ## 为什么不再等 `didFinish`（更不等首帧）
    ///
    /// 原来的实现把 completion 一直捏到「`didFinish` + 双 rAF 之后」才交，理由是避免
    /// "空白画面跟面板淡入抢线程"。但真机反馈是"空格预览又慢又卡"，而**同一套架构的
    /// showmd 不慢** —— 读它的扩展源码，差别就在这一行：它在 `loadHTMLString(...)`
    /// 之后**立刻**调 `handler(nil)`，`didFinish` 里只留一条 `NSLog`。
    ///
    /// 观感差别很大：Quick Look 一拿到 completion 就开始淡入面板，**用户马上看到我们这块**
    /// （底色 + 内容随后填进来），而不是盯着系统的占位图、等我们"把首帧都画完"才开门。
    /// 渲染那几十毫秒照旧发生，只是不再挡在门口。
    ///
    /// 代价：极端情况下会先看到很短一段底色。这个取舍是刻意的 —— 见 `waitForFirstPaint`
    /// 现在只负责记录，不再控制交接。
    private func present(_ rendered: Rendered) {
        let html = rendered.html
        htmlBytes = html.count
        readMs = rendered.readMs
        renderMs = rendered.renderMs
        wrapMs = rendered.wrapMs
        lastRenderedHTML = html
        didRecoverFromTermination = false
        // baseURL 只用来解析相对 URL，而我们的 HTML 是单文件自包含的
        // （CSS 内联、CSP `default:none`），所以给个非 file 的 scheme 即可。
        // ⚠️ 别传文件目录：那会走进 WebKit 的沙箱扩展 IPC，实测会死锁（技术方案 §15.2）。
        pendingNavigation = webView.load(html,
                                         mimeType: "text/html",
                                         characterEncodingName: "UTF-8",
                                         baseURL: URL(string: "about:blank")!)
        log("panel_released")
        finish(nil)
        startWatchdog()
    }

    /// 内容迟迟没到就记一笔。**不再参与交接**（面板已经交出去了），只用于诊断。
    private func startWatchdog() {
        let navigation = pendingNavigation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingNavigation === navigation else { return }
            self.log("watchdog_fired_still_loading")
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === pendingNavigation else { return }   // 过期请求的回调，丢掉
        watchdog?.cancel()
        watchdog = nil
        log("load=\(Self.fmt(Self.ms(startedAt, Self.now())))ms")
        Self.diag("did_finish", ", \"ms\": \(Self.fmt(Self.ms(startedAt, Self.now())))")
        logGeometry()
        // 这里的等待**只用于记录**（首帧到底多晚才出来），交接早在 `present()` 里就完成了。
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
            after_didFinish=\(Self.fmt(Self.ms(requestedAt, Self.now())), privacy: .public)ms
            """)
            Self.diag("first_paint", ", \"after_ms\": \(Self.fmt(Self.ms(requestedAt, Self.now())))")
            // ⚠️ 这里**不再**调 finish —— 面板在 `present()` 里就交出去了（那是"看起来快"的关键）。
            // 收尾只做一件事：预建下一个实例，且故意放在这里，
            // 免得"建实例 + 加载空白页"跟**这次**的加载抢资源。
            PreviewWebViewPool.shared.prewarm()
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
            logHostingChain()
        }
    }

    /// 把 Quick Look 给我们的**宿主链**记下来（从我们自己的视图往上走到窗口）。
    ///
    /// 为什么需要它：用户在真机上反馈"App 里很快、空格预览却首帧与滚动都慢" ——
    /// 而两者是同一份 HTML、同一套 CSS、同样的 viewport 承载。那就只剩一种可能：
    /// **QL 给的宿主环境和我们以为的不一样**。最典型的一种是它把我们的视图塞进它自己的
    /// `NSScrollView`，或者把视图撑成整篇高度 —— 那会直接退化成"每帧主线程同步重绘整屏"。
    /// `inner= / scroll=` 只能看出视口高，看不出是谁在撑，所以这里连类名与尺寸一起记。
    private func logHostingChain() {
        var parts: [String] = []
        var node: NSView? = view
        while let current = node, parts.count < 10 {
            let name = String(describing: type(of: current))
            let hint = name.contains("Scroll") ? " ⚠️ScrollView" : ""
            parts.append("\(name)[\(Self.fmt(current.frame.width))x\(Self.fmt(current.frame.height))\(hint)]")
            node = current.superview
        }
        Self.logger.notice("hosting file=\(self.fileName, privacy: .public) \(parts.joined(separator: " ← "), privacy: .public)")
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

    /// 链接点击的回调名 —— 与脚本一起定义在 `SharedTheme` 里，**两端共用同一份**。
    static let linkActionName = SharedTheme.linkActionName

    /// 链接点击脚本（单击复制 / 双击打开）。
    ///
    /// 细节与理由见 `SharedTheme.linkClickScript`：原生导航代理分不出单击/双击，
    /// 所以这段逻辑必须落在注入的 JS 里。
    static let linkScript = WKUserScript(source: SharedTheme.linkClickScript,
                                         injectionTime: .atDocumentEnd,
                                         forMainFrameOnly: true)

    /// 探针的回执。fps 是按**实际帧间隔均值**反推的，不是理论值。
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == Self.linkActionName,
           let dict = message.body as? [String: Any],
           let type = dict["type"] as? String,
           let raw = dict["url"] as? String,
           let url = URL(string: raw) {
            // 单击 = 复制，并给一条**原生**提示（`NSTextField`，不走 WebKit 重绘）。
            switch type {
            case "copy":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(raw, forType: .string)
                log("link_copied")
                showToast("已复制链接")

            case "open":
                log("link_double_clicked")
                openExternal(url)
            default:
                break
            }
            return
        }
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
        fps=\(Self.fmt(fps), privacy: .public) p50=\(Self.fmt(p50), privacy: .public)ms \
        p95=\(Self.fmt(p95), privacy: .public)ms worst=\(Self.fmt(worst), privacy: .public)ms \
        dropped=\(dropped)
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

    /// 拦下预览里的链接点击。
    ///
    /// ## 为什么"必须拦"
    ///
    /// CSP 的 `default-src 'none'` **管不住顶层导航**：不拦的话，点一下链接，
    /// WebKit 会让整个 web view 导航到目标地址 —— 预览被一个网页顶掉，文档就没了。
    /// 所以这个方法存在的首要理由是**堵住这个口子**，其次才是"让链接能打开"。
    ///
    /// ## ⚠️ 这里**不能**直接调 `NSWorkspace`
    ///
    /// 实测（最小探针：同一段代码，加不加 `app-sandbox` 两个版本）：
    ///
    /// | | `NSWorkspace.shared.open(url)` |
    /// |---|---|
    /// | 不沙箱 | 返回 `true`，浏览器打开 |
    /// | **沙箱** | **进程被 SIGTRAP 杀掉（退出码 133）** —— 不是返回 false，是直接死 |
    ///
    /// 所以在沙箱扩展里直接调它 = **点一下链接就把扩展搞崩**。打开链接必须交给
    /// 一个不在沙箱里的独立进程：`LinkOpener.xpc`（同架构的 showmd 叫 LinkOpener、
    /// QLMarkdown 叫 external-launcher，都是同一个理由）。
    ///
    /// 现在的分工：**导航永远拦下来**（预览不会被顶掉）；打开交给 XPC。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto" else {
            // 站内锚点（含被中和成 `#blocked-…` 的那些）与其它形态一律放行：
            // 它们不会把预览带离当前文档。
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openExternal(url)
    }

    /// 把外部链接交给 XPC 服务打开。服务不可用时只记一笔，绝不在本进程里做危险动作。
    private func openExternal(_ url: URL) {
        guard let service = linkOpener else {
            log("link_clicked no_service")
            showOpenFailure("XPC 服务未就绪")
            return
        }
        service.open(url) { [weak self] ok in
            DispatchQueue.main.async {
                self?.log("link_clicked opened=\(ok)")
                if !ok { self?.showOpenFailure("系统拒绝打开") }
            }
        }
    }

    /// 打开失败时给一句**看得见**的反馈。
    ///
    /// 静默失败是最糟的失败模式：用户只看到"点了没反应"，而原因只写在统一日志里 ——
    /// 那玩意儿要开终端才读得到。这里注入一条短暂提示（原生 `evaluateJavaScript`
    /// 不受页面 CSP 限制），并且**把原因编进去**，出问题时用户直接念出来即可。
    private func showOpenFailure(_ reason: String) {
        showToast("无法打开链接：" + reason)
    }

    /// 预览底部弹一条提示。**用原生视图画，不经过 WebKit**。
    ///
    /// 之前是 `evaluateJavaScript` 往页面里塞一个 div。实测 `transport` 只有 **0.4–0.7ms**、
    /// 剪贴板也是亚毫秒，可用户仍觉得"点了要等一下才出来" —— 慢在**注入之后内容进程重绘**那一段。
    /// 提示这种轻反馈没必要走渲染引擎：`NSTextField` + 圆角层直接上屏，路径短得多，
    /// 也不受页面 CSP 影响。
    private func showToast(_ text: String) {
        view.subviews.filter { $0.identifier?.rawValue == Self.toastID }
            .forEach { $0.removeFromSuperview() }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let box = ToastView(frame: NSRect(x: 0, y: 0,
                                          width: label.frame.width + 26,
                                          height: label.frame.height + 15))
        box.identifier = NSUserInterfaceItemIdentifier(Self.toastID)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        box.layer?.cornerRadius = 8
        label.frame.origin = NSPoint(x: 13, y: 7)
        box.addSubview(label)
        box.frame.origin = NSPoint(x: (view.bounds.width - box.frame.width) / 2, y: 20)
        box.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        view.addSubview(box)
        // ⚠️ 别等下一个显示周期：这个面板不一定是 key window，AppKit 可能攒着不刷。
        // 强制同步绘制一次，提示才真的"立刻看见"。
        // ⚠️ **不要在这里强制重画**。试过 `displayIfNeeded()` 和 `display()`：
        // 这个窗口里有一整块 WebKit 图层，同步整窗重画会把主线程占住，
        // 本来是"让提示快出来"，结果反而把它压在重画之后。
        // 交给正常的显示周期就够了 —— 页面滚动实测 53–55 帧，证明这条路是通的。

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                box.animator().alphaValue = 0
            } completionHandler: {
                box.removeFromSuperview()
            }
        }
    }

    private static let toastID = "spacedown.toast"

    /// 只负责显示，**不参与命中测试** —— 否则它会挡住底下 web view 的点击。
    private final class ToastView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    /// WebKit 的内容进程被系统回收时的兜底（同架构的 showmd 也做了这一步）。
    ///
    /// 不做的话表现是**一片空白**：面板早就交出去了、`didFinish` 永远不来，
    /// 用户既看不到内容也看不到错误。大文档（接近 512 KB 上限、几万个节点）时真的会发生。
    ///
    /// 策略：先重载一次；**再被杀就放弃**，改用自己拼的一页说明 ——
    /// 不能让它在"重载 → 又崩"之间无限循环，那比白屏更糟。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !didRecoverFromTermination else {
            // ⚠️ **这里绝对不能再碰 web view**。原来我用 `loadHTMLString(提示页)` 来显示失败，
            // 结果那等于又去拉一个刚被系统杀掉的内容进程 —— 实测变成**每 20 毫秒重启一次的死循环**
            // （日志里 `webcontent_terminated_again` 刷了 299+ 条）。提示必须走不依赖 WebKit 的原生视图。
            Self.logger.error("webcontent_terminated_again file=\(self.fileName, privacy: .public)")
            showNativeNotice()
            return
        }
        didRecoverFromTermination = true
        log("webcontent_terminated_reloading")
        guard let html = lastRenderedHTML else { return }
        pendingNavigation = webView.load(html,
                                         mimeType: "text/html",
                                         characterEncodingName: "UTF-8",
                                         baseURL: URL(string: "about:blank")!)
        startWatchdog()
    }

    /// 兜底提示：**用原生 `NSTextField`，完全不经过 WebKit**。
    ///
    /// 这一条是硬约束：出问题的是渲染引擎本身，再用它去显示错误信息就会变成死循环。
    private func showNativeNotice() {
        guard view.subviews.allSatisfy({ $0.identifier?.rawValue != Self.noticeID }) else { return }
        webView.isHidden = true
        let label = NSTextField(wrappingLabelWithString: """
        这个文件的预览没能完成。

        渲染引擎（WebKit 的内容进程）被系统反复终止，重试也没有成功。
        关掉面板再按一次空格可以再试；用 Spacedown 打开不受这个限制。
        """)
        label.identifier = NSUserInterfaceItemIdentifier(Self.noticeID)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private static let noticeID = "spacedown.failure.notice"


    // MARK: - 内部

    private func log(_ tail: String) {
        Self.logger.notice("""
        preview file=\(self.fileName, privacy: .public) bytes=\(self.htmlBytes) \
        read=\(Self.fmt(self.readMs), privacy: .public)ms \
        render=\(Self.fmt(self.renderMs), privacy: .public)ms \
        wrap=\(Self.fmt(self.wrapMs), privacy: .public)ms \(tail, privacy: .public) \
        total=\(Self.fmt(Self.ms(self.startedAt, Self.now())), privacy: .public)ms
        """)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        let handler = completion
        completion = nil
        handler?(error)
    }

    private static func fmt(_ ms: Double) -> String { String(format: "%.2f", ms) }

    /// 临时诊断：把一行 JSON 追加到磁盘上的两个候选位置。
    ///
    /// 为什么放着 `os_log` 还要写文件：这台机器上 `log show` / `ps` / `pluginkit` 全被权限挡住，
    /// 拿不到档案就看不了。Quick Look 主进程会把扩展进程关进沙箱，**这两个路径不一定可写** ——
    /// 写没写成、写到哪一路，本身就是这次要测的一件事。
    ///
    /// ⚠️ **只在 Debug 构建里存在**。它是取证工具，不该跟着发行版出去：
    /// 会往 `/tmp` 明文写文件名，而 os_log 那条链路本来就够用。
    private static func diag(_ kind: String, _ extra: String = "") {
        #if DEBUG
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
        #endif
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func ms(_ a: UInt64, _ b: UInt64) -> Double {
        Double(b - a) / 1_000_000.0
    }

    /// 渲染结果 + 三段耗时。
    ///
    /// ⚠️ 耗时**随结果一起返回**，而不是由渲染方写进属性：渲染跑在后台队列上，
    /// 写属性会让主线程读到半写状态（数据竞争）。属性只在主线程由 `present` 赋值。
    private struct Rendered {
        let html: Data
        let readMs: Double
        let renderMs: Double
        let wrapMs: Double
    }

    /// 读文件 → 截断 → 解析 → 拼完整 HTML。与主 App 走同一条链路。
    ///
    /// ⚠️ 截断必须走 `MarkdownRenderer.documentBytes`，**不要在这里再写一份**。
    /// 那个方法存在的唯一理由就是「扩展与主 App 的截断口径必须一致，否则同一个文件
    /// 两处显示会不一样长」—— 而这里曾经复制过一份（连提示文案都抄了），
    /// 两边只要改一处就会漂。上限也由它统一持有（`defaultMaxBytes`）。
    ///
    /// 本方法**可以在后台队列上调用**（`MarkdownRenderer` 与 `SharedTheme` 都无共享可变状态）。
    private func render(url: URL) throws -> Rendered {
        // ⚠️ 沙箱里必须显式开启安全作用域访问：Quick Look 交给我们的 URL 是 **security-scoped** 的，
        // 不 start 的话 `Data(contentsOf:)` 会直接失败（operation not permitted）。
        // 这是扩展沙箱化（见 `QuickLookPreview.entitlements`）之后**必须**补的一步 ——
        // showmd 也是在同一个位置这么做的。非沙箱运行时它会返回 false，但读取照样正常。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let t0 = Self.now()
        let markdown = try MarkdownRenderer.documentBytes(contentsOf: url)
        let t1 = Self.now()
        let body = Self.renderer.renderHTMLData(markdown)
        let t2 = Self.now()
        let document = SharedTheme.document(body: body)
        let t3 = Self.now()
        return Rendered(html: document,
                        readMs: Self.ms(t0, t1),
                        renderMs: Self.ms(t1, t2),
                        wrapMs: Self.ms(t2, t3))
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
        for name in [PreviewViewController.probeName, PreviewViewController.linkActionName] {
            controller.removeScriptMessageHandler(forName: name)
            controller.add(handler, name: name)
        }
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
            let controller = view.configuration.userContentController
            for name in [PreviewViewController.probeName, PreviewViewController.linkActionName] {
                controller.removeScriptMessageHandler(forName: name)
            }
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
        config.userContentController.addUserScript(PreviewViewController.linkScript)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                             configuration: config)
        // 缩放走 GPU 合成层，不触发重排（主 App 用的是同一招）
        view.allowsMagnification = true
        return view
    }
}
