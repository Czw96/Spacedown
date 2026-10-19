import AppKit
import QuickLookUI
import WebKit

import SharedTheme

/// 视图型（`QLPreviewingController`）Quick Look 预览扩展。
///
/// 自己做 web view 而不是把 HTML 交给系统排版（数据型 `QLPreviewProvider`），
/// 因为关键在**尺寸**：web view 必须是面板尺寸（viewport），绝不能按整篇高度撑开。
/// 只有 viewport 模式下滚动才走 WebKit 的滚动线程与分块；被撑成整篇高度时，
/// 每帧都是主线程同步重绘整屏，文档一长就卡，且调 CSS 无法挽回。
///
/// 顺带拿回了控制权与可观测性：背景色、实例复用、几何与帧率埋点。
// 仅 `QLPreviewingController` 需要 `@preconcurrency`：它是老的 ObjC 协议、没有隔离标注，
// 而 `NSViewController` 是 main-actor 的。Quick Look 本来就在主线程调用它。
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController,
    WKNavigationDelegate, WKScriptMessageHandler {

    /// 一次预览的耗时统计。
    private struct Measurements {
        var bytes = 0
        var read = 0.0
        var render = 0.0
        var wrap = 0.0
    }

    private var webView: WKWebView!
    private var fileName = ""
    private var measurements = Measurements()
    private var startedAt: UInt64 = 0
    private var finished = false
    private var completion: ((Error?) -> Void)?
    private var watchdog: DispatchWorkItem?

    /// 上一次交出去的 HTML —— 内容进程被回收时用它重载。
    private var lastRenderedHTML: Data?
    /// 是否已经为这次预览重载过一次。只重试一次，避免"重载 → 又崩"死循环。
    private var didRecoverFromTermination = false

    /// 打开外部链接用的 XPC 服务（服务端在 `LinkOpener/`，不在沙箱里）。
    private var linkOpener: LinkOpenerProtocol?
    /// XPC 连接必须自己持有 —— 代理对象不持有连接。
    private var linkOpenerConnection: NSXPCConnection?

    /// Quick Look 可以在旧请求还没加载完时用同一个控制器发新请求（方向键一路按过去）。
    /// 旧请求的 `didFinish` 会晚于新请求到达，认 `WKNavigation` 身份才能把它丢掉。
    private var pendingNavigation: WKNavigation?

    // MARK: - 视图

    override func loadView() {
        // 这里的尺寸不重要（Quick Look 会按面板重设），但 frame 不能是零：
        // WKWebView 在零尺寸下不排版。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.pageBackground.cgColor

        let web = PreviewWebViewPool.shared.take(handler: self)
        web.navigationDelegate = self
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)

        webView = web
        view = container

        // 先拉内容进程：WebContent 冷启动要一两百毫秒，正好与"读文件 + 渲染"重叠
        if web.url == nil {
            WebViewDocument.loadBlankPage(into: web)
        }
        connectLinkOpener()
        PreviewDiagnostics.record("view_loaded")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        PreviewWebViewPool.shared.recycleLater(webView)
    }

    /// 连上"打开链接"用的 XPC 服务。失败不影响预览 —— 点链接时才会记日志并提示。
    private func connectLinkOpener() {
        let connection = NSXPCConnection(serviceName: LinkOpenerEndpoint.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: LinkOpenerProtocol.self)
        connection.resume()
        linkOpenerConnection = connection

        // 异步代理：调用不阻塞，回执在私有队列上回来，用之前自己跳回主队列
        linkOpener = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async {
                PreviewDiagnostics.logger.error("link_opener_unavailable \(error.localizedDescription, privacy: .public)")
                // 连接失败时回执根本不会来，所以这里也要提示
                self?.showToast("无法打开链接：" + error.localizedDescription)
            }
        } as? LinkOpenerProtocol

        // 无副作用的连通性自检：日志里 `link_opener_ping ok=true` 说明连接是通的
        linkOpener?.ping { ok in
            DispatchQueue.main.async {
                PreviewDiagnostics.logger.notice("link_opener_ping ok=\(ok)")
            }
        }
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        _ = view                     // 强制走 loadView，确保 webView 已就位
        let sinceLaunch = PreviewDiagnostics.milliseconds(
            from: PreviewDiagnostics.launchedAt, to: PreviewDiagnostics.now()
        )
        PreviewDiagnostics.record("prepare", ", \"file\": \"\(url.lastPathComponent)\"")
        PreviewDiagnostics.logger.notice(
            "prepare file=\(url.lastPathComponent, privacy: .public) since_launch=\(PreviewDiagnostics.formatted(sinceLaunch), privacy: .public)ms"
        )

        completion = completionHandler
        finished = false
        fileName = url.lastPathComponent
        startedAt = PreviewDiagnostics.now()

        // 上一次请求的看门狗必须先撤掉：它捕获的 `self` 会再调 finish(nil)，
        // 而 `finished` 刚被重置成 false —— 不撤就会把这次请求提前结束。
        watchdog?.cancel()
        watchdog = nil

        // 读文件 + 渲染在 512 KB 上限下要几十毫秒，挂在主线程会拖住面板动画
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let document = try PreviewDocument.load(at: url)
                DispatchQueue.main.async { self?.present(document) }
            } catch {
                PreviewDiagnostics.logger.error(
                    "render_failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                DispatchQueue.main.async { self?.finish(error) }
            }
        }
    }

    /// 把渲染好的 HTML 交给 web view，并**立刻**把面板交还给 Quick Look。
    ///
    /// 不等 `didFinish`（更不等首帧）：Quick Look 一拿到 completion 就开始淡入面板，
    /// 用户马上看到我们这块内容，而不是盯着系统占位图等我们"把首帧画完"。
    /// 代价是极端情况下先看到很短一段底色 —— 这个取舍是刻意的。
    private func present(_ document: PreviewDocument) {
        lastRenderedHTML = document.html
        didRecoverFromTermination = false

        measurements = Measurements(
            bytes: document.html.count,
            read: document.readMs,
            render: document.renderMs,
            wrap: document.wrapMs
        )

        pendingNavigation = WebViewDocument.load(document.html, into: webView)
        log("panel_released")
        finish(nil)
        startWatchdog()
    }

    /// 内容迟迟没到就记一笔。不参与交接（面板已经交出去了），只用于诊断。
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
        guard navigation === pendingNavigation else { return }   // 过期请求的回调
        watchdog?.cancel()
        watchdog = nil

        let elapsed = PreviewDiagnostics.milliseconds(
            from: startedAt, to: PreviewDiagnostics.now()
        )
        log("load=\(PreviewDiagnostics.formatted(elapsed))ms")
        PreviewDiagnostics.record("did_finish", ", \"ms\": \(PreviewDiagnostics.formatted(elapsed))")
        logGeometry()
        waitForFirstPaint()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === pendingNavigation else { return }
        log("load_failed error=\(error.localizedDescription)")
        finish(nil)   // 面板已经能显示了，别把它变成错误页
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard navigation === pendingNavigation else { return }
        log("load_failed_provisional error=\(error.localizedDescription)")
        finish(nil)
    }

    /// 内容进程被系统回收时的兜底。
    ///
    /// 不做的话表现是一片空白：面板早就交出去了、`didFinish` 永远不来。
    /// 策略是先重载一次，**再被杀就放弃**，改用自己的原生一页说明 ——
    /// 不能在"重载 → 又崩"之间无限循环。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !didRecoverFromTermination else {
            // 这里绝对不能再碰 web view：那等于又去拉一个刚被杀掉的内容进程，
            // 会变成"每 20ms 重启一次"的死循环。
            PreviewDiagnostics.logger.error("webcontent_terminated_again file=\(self.fileName, privacy: .public)")
            showNativeNotice()
            return
        }
        didRecoverFromTermination = true
        log("webcontent_terminated_reloading")

        guard let html = lastRenderedHTML else { return }
        pendingNavigation = WebViewDocument.load(html, into: webView)
        startWatchdog()
    }

    // MARK: - 链接

    /// 拦下预览里的链接点击。
    ///
    /// 首要理由是堵住顶层导航：CSP 的 `default-src 'none'` 管不住它，
    /// 不拦的话点一下链接，整个 web view 就导航走，预览被网页顶掉。
    ///
    /// ⚠️ 这里不能直接调 `NSWorkspace`：沙箱里调它会让本进程被 SIGTRAP 杀掉。
    /// 打开链接必须交给不在沙箱里的 `LinkOpener.xpc`。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              LinkInteraction.isExternal(url) else {
            // 站内锚点（含被中和成 `#blocked-…` 的）与其它形态放行：不会把预览带离文档
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openExternal(url)
    }

    private func openExternal(_ url: URL) {
        guard let service = linkOpener else {
            log("link_clicked no_service")
            showToast("无法打开链接：XPC 服务未就绪")
            return
        }
        service.open(url) { [weak self] ok in
            DispatchQueue.main.async {
                PreviewDiagnostics.logger.notice("link_clicked opened=\(ok)")
                if !ok {
                    self?.showToast("无法打开链接：系统拒绝打开")
                }
            }
        }
    }

    // MARK: - 脚本消息

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == LinkInteraction.messageName {
            handleLink(message.body)
        } else if message.name == ScrollProbe.messageName {
            handleProbe(message.body)
        }
    }

    private func handleLink(_ body: Any) {
        guard let action = LinkInteraction.action(from: body) else { return }
        switch action.kind {
        case .copy:
            LinkInteraction.copyToPasteboard(action.text)
            log("link_copied")
            showToast("已复制链接")
        case .open:
            log("link_opened")
            openExternal(action.url)
        }
    }

    private func handleProbe(_ body: Any) {
        guard let sample = ScrollProbe.Sample(body: body) else { return }

        PreviewDiagnostics.record("scroll_probe", """
        , "frames": \(sample.frames), "fps": \(PreviewDiagnostics.formatted(sample.fps)), \
        "p50": \(PreviewDiagnostics.formatted(sample.p50)), \
        "p95": \(PreviewDiagnostics.formatted(sample.p95)), \
        "worst": \(PreviewDiagnostics.formatted(sample.worst)), "dropped": \(sample.dropped)
        """)
        PreviewDiagnostics.logger.notice("""
        scroll_probe file=\(self.fileName, privacy: .public) frames=\(sample.frames) \
        fps=\(PreviewDiagnostics.formatted(sample.fps), privacy: .public) \
        p50=\(PreviewDiagnostics.formatted(sample.p50), privacy: .public)ms \
        p95=\(PreviewDiagnostics.formatted(sample.p95), privacy: .public)ms \
        worst=\(PreviewDiagnostics.formatted(sample.worst), privacy: .public)ms \
        dropped=\(sample.dropped)
        """)
    }

    // MARK: - 诊断

    /// 等第一帧真正画完再记一笔（**只用于记录**，交接早已完成）。
    ///
    /// `didFinish` 的语义只是"主资源加载完成"，WebKit 此刻可能还没排完第一次绘制。
    /// 双 rAF 是判断"已上屏"的最小手段：第二个回调意味着前一帧已提交给合成器。
    private func waitForFirstPaint() {
        let requestedAt = PreviewDiagnostics.now()
        let navigation = pendingNavigation
        webView.evaluateJavaScript("""
        new Promise(function (resolve) {
            requestAnimationFrame(function () {
                requestAnimationFrame(function () { resolve(1); });
            });
        })
        """) { [weak self] _, _ in
            guard let self, self.pendingNavigation === navigation else { return }
            let elapsed = PreviewDiagnostics.milliseconds(
                from: requestedAt, to: PreviewDiagnostics.now()
            )
            PreviewDiagnostics.logger.notice("""
            first_paint file=\(self.fileName, privacy: .public) \
            after_didFinish=\(PreviewDiagnostics.formatted(elapsed), privacy: .public)ms
            """)
            PreviewDiagnostics.record("first_paint", ", \"after_ms\": \(PreviewDiagnostics.formatted(elapsed))")

            // 预建下一个实例放在这里，免得"建实例 + 加载空白页"跟这次加载抢资源
            PreviewWebViewPool.shared.prewarm()
        }
    }

    /// 量一下排版结果的高度与视口高度的比值 —— 这是判断"是不是 viewport 模式"的依据：
    /// `innerHeight ≈ 面板高度` 说明滚动走 WebKit 滚动线程；
    /// `innerHeight ≈ scrollHeight` 说明视图被整篇撑开，每帧都会主线程重绘整屏。
    private func logGeometry() {
        let viewSize = view.frame.size
        let webSize = webView.frame.size

        webView.evaluateJavaScript("""
        (function () {
            var root = document.documentElement;
            return {
                scrollHeight: root.scrollHeight,
                innerHeight: window.innerHeight,
                devicePixelRatio: window.devicePixelRatio,
                nodes: document.getElementsByTagName('*').length
            };
        })()
        """) { [weak self] result, error in
            guard let self else { return }
            guard let data = result as? [String: Any],
                  let scrollHeight = data["scrollHeight"] as? Double,
                  let innerHeight = data["innerHeight"] as? Double else {
                PreviewDiagnostics.logger.notice(
                    "geometry_probe_failed file=\(self.fileName, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                return
            }
            let nodes = data["nodes"] as? Int ?? 0
            let ratio = PreviewDiagnostics.formatted(data["devicePixelRatio"] as? Double ?? 0)

            PreviewDiagnostics.record("geometry", """
            , "inner_h": \(PreviewDiagnostics.formatted(innerHeight)), \
            "scroll_h": \(PreviewDiagnostics.formatted(scrollHeight)), \
            "nodes": \(nodes), "dpr": \(ratio)
            """)
            PreviewDiagnostics.logger.notice("""
            geometry file=\(self.fileName, privacy: .public) \
            view=\(PreviewDiagnostics.formatted(viewSize.width))x\(PreviewDiagnostics.formatted(viewSize.height)) \
            web=\(PreviewDiagnostics.formatted(webSize.width))x\(PreviewDiagnostics.formatted(webSize.height)) \
            inner=\(PreviewDiagnostics.formatted(innerHeight))px scroll=\(PreviewDiagnostics.formatted(scrollHeight))px \
            nodes=\(nodes) dpr=\(ratio, privacy: .public)
            """)
            self.logHostingChain()
        }
    }

    /// 记录 Quick Look 给的宿主链（从我们的视图往上走到窗口）。
    ///
    /// `inner / scroll` 只能看出视口高度，看不出是谁在撑。若宿主把视图塞进自己的
    /// `NSScrollView` 或撑成整篇高度，滚动就会退化成主线程整屏重绘，
    /// 所以这里连类名与尺寸一起记。
    private func logHostingChain() {
        var parts: [String] = []
        var node: NSView? = view
        while let current = node, parts.count < 10 {
            let name = String(describing: type(of: current))
            let hint = name.contains("Scroll") ? " ⚠️ScrollView" : ""
            parts.append("\(name)[\(PreviewDiagnostics.formatted(current.frame.width))x\(PreviewDiagnostics.formatted(current.frame.height))\(hint)]")
            node = current.superview
        }
        PreviewDiagnostics.logger.notice(
            "hosting file=\(self.fileName, privacy: .public) \(parts.joined(separator: " ← "), privacy: .public)"
        )
    }

    // MARK: - 内部

    private func log(_ tail: String) {
        PreviewDiagnostics.logger.notice("""
        preview file=\(self.fileName, privacy: .public) bytes=\(self.measurements.bytes) \
        read=\(PreviewDiagnostics.formatted(self.measurements.read), privacy: .public)ms \
        render=\(PreviewDiagnostics.formatted(self.measurements.render), privacy: .public)ms \
        wrap=\(PreviewDiagnostics.formatted(self.measurements.wrap), privacy: .public)ms \
        \(tail, privacy: .public) \
        total=\(PreviewDiagnostics.formatted(PreviewDiagnostics.milliseconds(from: self.startedAt, to: PreviewDiagnostics.now())), privacy: .public)ms
        """)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        let handler = completion
        completion = nil
        handler?(error)
    }

    private func showToast(_ text: String) {
        Toast.show(text, in: view, placement: .bottom(inset: 20))
    }

    /// 兜底提示：用原生 `NSTextField`，完全不经过 WebKit ——
    /// 出问题的是渲染引擎本身，再用它去显示错误信息就会变成死循环。
    private func showNativeNotice() {
        let identifier = NSUserInterfaceItemIdentifier("spacedown.failure.notice")
        guard view.subviews.allSatisfy({ $0.identifier != identifier }) else { return }

        webView.isHidden = true
        let label = NSTextField(wrappingLabelWithString: """
        这个文件的预览没能完成。

        渲染引擎（WebKit 的内容进程）被系统反复终止，重试也没有成功。
        关掉面板再按一次空格可以再试；用 Spacedown 打开不受这个限制。
        """)
        label.identifier = identifier
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
}
