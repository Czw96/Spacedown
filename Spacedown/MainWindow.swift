import AppKit
import UniformTypeIdentifiers
import WebKit

import MarkdownKit
import SharedTheme

/// 只读查看器主窗口 —— 多标签，一个窗口装所有文件。
///
/// 只读是天然保证的：webview 里装的是渲染结果，没有输入控件，
/// HTML 本身还带着 `default-src 'none'` 的 CSP（见 `SharedTheme`）。
///
/// 窗口形态用的是 `fullSizeContentView` + 隐藏标题栏，交通灯和自绘标签栏同一行（§5.3）。
@MainActor
final class MainWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {

    private let window: SpacedownWindow
    private let barBackground = NSVisualEffectView()
    private let tabBar = TabBarView()
    private let webHost = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private let renderer = MarkdownRenderer()
    private let watcher = FileWatcher.shared
    private lazy var pool = WebViewPool(delegate: self)

    private(set) var tabs: [DocumentTab] = []
    private var currentIndex = -1

    /// 载入完成后要还原到的滚动位置，键是 webview 身份
    private var pendingScroll: [ObjectIdentifier: Double] = [:]
    /// 上次对齐交通灯时的窗口高度，避免 resize 里重复做无用功
    private var lastAlignedHeight: CGFloat = 0
    /// 正在淡出的那个 webview，以及淡入的代次号（快速切换时防止误删）
    private var fadingOut: WKWebView?
    private var fadeGeneration = 0
    /// 各 webview 发起 `load` 的时刻，用于量首帧（调试开关打开时才记录）
    private var loadStartedAt: [ObjectIdentifier: UInt64] = [:]

    var onClose: ((MainWindow) -> Void)?

    var currentTab: DocumentTab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }

    override init() {
        DebugLog.write("MainWindow.init")
        window = SpacedownWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Spacedown"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Palette.pageBackground
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        window.onLayout = { [weak self] in self?.alignTrafficLights() }

        buildContent()
        wireTabBar()
        alignTrafficLights()
        // 窗口一建出来就预热 webview：等用户按 ⌘O 再建就要多付 ~370ms
        pool.prewarm()
        refresh()
    }

    // MARK: - 对外

    func show() {
        window.makeKeyAndOrderFront(nil)
        // 上屏前 AppKit 还会跑几轮标题栏布局，init 里那次平移会被冲掉，这里补一次
        alignTrafficLights()
    }

    /// 打开一个文件：已经在标签里就切过去，不叠开。
    func open(_ url: URL) {
        if let index = tabs.firstIndex(where: { $0.url == url }) {
            select(index)
            show()
            return
        }
        tabs.append(DocumentTab(url: url))
        refresh()
        select(tabs.count - 1)
        show()
    }

    // MARK: - 构建

    private func buildContent() {
        guard let content = window.contentView else { return }
        content.wantsLayer = true

        barBackground.material = .windowBackground
        barBackground.blendingMode = .withinWindow
        barBackground.state = .followsWindowActiveState
        content.addSubview(barBackground)
        content.addSubview(tabBar)

        webHost.wantsLayer = true
        content.addSubview(webHost)

        emptyLabel.stringValue = "把 .md 拖进来，或按 ⌘O 打开"
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        content.addSubview(emptyLabel)

        for view in [barBackground, tabBar, webHost, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        let barHeight = TabBarView.height
        NSLayoutConstraint.activate([
            barBackground.topAnchor.constraint(equalTo: content.topAnchor),
            barBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            barBackground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            barBackground.heightAnchor.constraint(equalToConstant: barHeight),

            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: barHeight),

            webHost.topAnchor.constraint(equalTo: content.topAnchor, constant: barHeight),
            webHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),
        ])
    }

    private func wireTabBar() {
        tabBar.onSelect = { [weak self] index in self?.select(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.openDocument(nil) }
        tabBar.onZoomIn = { [weak self] in self?.zoomIn(nil) }
        tabBar.onZoomOut = { [weak self] in self?.zoomOut(nil) }
        tabBar.onZoomReset = { [weak self] in self?.zoomActualSize(nil) }
        tabBar.onRevealInFinder = { [weak self] in self?.revealInFinder(nil) }
        tabBar.onOpenInEditor = { [weak self] in self?.openInDefaultEditor(nil) }
        tabBar.contextMenuProvider = { [weak self] index in self?.tabMenu(for: index) }

        watcher.onChange = { [weak self] url in self?.documentChanged(at: url) }
    }

    /// 交通灯默认按 28pt 的标题栏垂直居中（离窗口顶 14pt），我们是 38pt 的标签栏
    /// （中线离顶 19pt），所以要把它挪下来 5pt。
    ///
    /// ⚠️ 换算**必须在窗口坐标系里做差值**，不能直接按"超视图高度 - 目标中心"的公式写：
    /// 容器的超视图到底是 `NSThemeFrame` 还是标题栏视图，以及它的 `isFlipped`，
    /// 都是 AppKit 的内部实现，换个系统版本就可能变。量当前实际位置、再平移 delta，
    /// 只需要知道超视图的 y 轴朝哪边，这个信息稳定得多。
    ///
    /// 这个换算依赖 `closeButton.superview` 这个内部视图层级，所以整体是"尽力而为"：
    /// 拿不到就什么都不做 —— 标签从 `leadingInset` 起排，本来也不会和交通灯重叠。
    private func alignTrafficLights() {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let close = buttons.first, let host = close.superview else {
            DebugLog.write("alignTrafficLights: 拿不到交通灯")
            return
        }

        // ⚠️ 量的是**按钮**的中线，不是它父视图（`NSTitlebarContainerView`）的中线。
        // 一开始量的是父视图，结果"移了 3pt"却毫无变化 —— 因为 AppKit 随后会把那个容器
        // 摆回它自己的位置，而真正决定观感的是按钮。同理，平移也**只移按钮本身**，
        // 不碰容器：容器是 AppKit 的结构视图，动它容易被打回去，动按钮则所见即所得。
        let delta = (window.frame.height - TabBarView.height / 2)
            - close.convert(close.bounds, to: nil).midY
        guard abs(delta) > 0.5 else {
            lastAlignedHeight = window.frame.height
            return
        }

        // 窗口坐标 y 向上；超视图若翻转，y 向下，平移方向要取反
        let sign: CGFloat = host.isFlipped ? -1 : 1
        var moved = 0
        for button in buttons where button.superview === host {
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: button.frame.minY + sign * delta))
            moved += 1
        }
        lastAlignedHeight = window.frame.height
        DebugLog.write("alignTrafficLights: 移了 \(moved)/\(buttons.count) 个按钮 "
            + "delta=\(fmt(delta)) host=\(type(of: host)) flipped=\(host.isFlipped)")
    }

    // MARK: - 标签

    private func refresh() {
        tabBar.reload(titles: tabs.map(\.title), current: currentIndex)
        emptyLabel.isHidden = !tabs.isEmpty
        if let tab = currentTab {
            window.title = tab.title
            window.representedURL = tab.url
        } else {
            window.title = "Spacedown"
            window.representedURL = nil
        }
        watcher.watch(tabs.map(\.url))
        updateZoomLabel()
        dumpLayout()
    }

    private func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if let old = currentTab, old !== tabs[index] {
            pool.captureScrollY(of: old)
        }
        currentIndex = index
        let tab = tabs[index]

        let (view, needsLoad) = pool.acquire(tab)
        if needsLoad {
            load(tab, into: view, restoreScroll: true)
        } else {
            view.magnification = tab.magnification
        }
        present(view)
        refresh()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        pool.captureScrollY(of: tab)
        pool.retire(tab)
        tabs.remove(at: index)

        if tabs.isEmpty {
            currentIndex = -1
            removeAllWebViews()
            refresh()
            return
        }
        // 关掉当前标签后落到右邻居；关的是最后一个就落到新的最后一个
        let next = min(index, tabs.count - 1)
        currentIndex = -1
        refresh()
        select(next)
    }

    private func closeOthers(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        for tab in tabs where tab !== keep {
            pool.retire(tab)
        }
        removeAllWebViews()
        tabs = [keep]
        currentIndex = -1
        refresh()
        select(0)
    }

    private func tabMenu(for index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "关闭标签", action: #selector(closeCurrentTab(_:)), keyEquivalent: "")
            .target = self
        let others = menu.addItem(
            withTitle: "关闭其他标签", action: #selector(closeOtherTabsFromMenu(_:)), keyEquivalent: "")
        others.target = self
        others.tag = index
        menu.addItem(.separator())
        for (title, selector) in [("在 Finder 中显示", #selector(revealInFinder(_:))),
                                  ("用默认编辑器打开", #selector(openInDefaultEditor(_:)))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    // MARK: - webview

    private func present(_ view: WKWebView) {
        emptyLabel.isHidden = true
        let others = webHost.subviews.compactMap { $0 as? WKWebView }.filter { $0 !== view }

        view.frame = webHost.bounds
        view.autoresizingMask = [.width, .height]

        guard let outgoing = others.first(where: { $0.alphaValue > 0.5 }) ?? others.first else {
            if view.superview !== webHost {
                view.alphaValue = 1
                webHost.addSubview(view)
            }
            return
        }
        for extra in others where extra !== outgoing {
            extra.removeFromSuperview()
        }
        if view.superview !== webHost {
            view.alphaValue = 0
            webHost.addSubview(view)
        }

        // 120ms 交叉淡入（§5.3），不用弹性动画。
        //
        // 收尾**不用** `runAnimationGroup` 的 completionHandler：那个闭包在 Swift 6 里
        // 是非隔离的，碰 alphaValue / removeFromSuperview 会报 actor 隔离警告。
        // 改成主 actor 上的定时收尾 + 代次号防止快速切换时误删。
        let generation = fadeGeneration + 1
        fadeGeneration = generation
        fadingOut = outgoing
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard self.fadeGeneration == generation, let fading = self.fadingOut else { return }
            fading.removeFromSuperview()
            fading.alphaValue = 1
            self.fadingOut = nil
        }
    }

    /// 布局自检：把关键几何写进调试日志。
    ///
    /// 存在的理由很实际：交通灯的位置依赖 AppKit 内部视图层级，而开发机截不了屏
    /// （`screencapture` 被系统权限挡住），只能靠数字确认"按钮中线 = 标签栏中线"。
    private func dumpLayout() {
        guard DebugLog.isEnabled else { return }
        window.layoutIfNeeded()

        DebugLog.write("layout windowHeight=\(fmt(window.frame.height)) "
            + "tabBarHeight=\(fmt(TabBarView.height)) tabs=\(tabs.count) current=\(currentIndex)")
        for (name, type) in [("close", NSWindow.ButtonType.closeButton),
                             ("miniaturize", .miniaturizeButton),
                             ("zoom", .zoomButton)] {
            guard let view = window.standardWindowButton(type) else { continue }
            let rect = view.convert(view.bounds, to: nil)
            DebugLog.write("  \(name) centerFromTop=\(fmt(window.frame.height - rect.midY))")
        }
        let bar = tabBar.convert(tabBar.bounds, to: nil)
        DebugLog.write("  tabBar topFromTop=\(fmt(window.frame.height - bar.maxY)) "
            + "centerFromTop=\(fmt(window.frame.height - bar.midY))")
        if let first = tabBar.debugFirstTabFrame {
            DebugLog.write("  firstTab x=\(fmt(first.minX)) "
                + "topFromTop=\(fmt(window.frame.height - first.maxY)) "
                + "size=\(fmt(first.width))x\(fmt(first.height))")
        }
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func removeAllWebViews() {
        for view in webHost.subviews.compactMap({ $0 as? WKWebView }) {
            view.removeFromSuperview()
        }
    }

    private func load(_ tab: DocumentTab, into view: WKWebView, restoreScroll: Bool) {
        pendingScroll[ObjectIdentifier(view)] = restoreScroll ? tab.scrollY : 0
        loadStartedAt[ObjectIdentifier(view)] = DispatchTime.now().uptimeNanoseconds
        view.magnification = tab.magnification
        do {
            let markdown = try MarkdownRenderer.documentBytes(contentsOf: tab.url)
            let html = SharedTheme.document(body: renderer.renderHTMLData(markdown))
            view.load(
                html,
                mimeType: "text/html",
                characterEncodingName: "UTF-8",
                baseURL: Self.selfContainedBaseURL
            )
        } catch {
            view.loadHTMLString(Self.failureHTML(error), baseURL: nil)
        }
        // 标记归属要等导航真正开始；`didFinish` 里还会再确认一次
        pool.markLoaded(tab, in: view)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = pool.tab(for: webView) else { return }
        if let started = loadStartedAt.removeValue(forKey: ObjectIdentifier(webView)) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.write(String(
                format: "firstPaint %@ = %.1fms (pool=%d)",
                tab.title, elapsed, pool.residentCount))
        }
        pool.markLoaded(tab, in: webView)
        let target = pendingScroll.removeValue(forKey: ObjectIdentifier(webView)) ?? 0
        guard target > 0 else { return }
        webView.evaluateJavaScript("window.scrollTo(0, \(target))")
    }

    // MARK: - 文件变化

    private func documentChanged(at url: URL) {
        guard let tab = tabs.first(where: { $0.url == url }),
              let view = pool.residentView(for: tab) else {
            // 实例不在池里，下次切回来时池子会重新 load
            return
        }
        load(tab, into: view, restoreScroll: true)
    }

    // MARK: - 缩放

    private func setMagnification(_ value: CGFloat) {
        guard let tab = currentTab,
              let view = pool.residentView(for: tab) else { return }
        let clamped = min(max(value, 0.25), 5.0)
        view.magnification = clamped
        // 挪动窗口大小不会自动回到 1，但标签模型必须记住，否则切走再回来会串
        tab.magnification = clamped
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        let percent = Int((currentTab?.magnification ?? 1) * 100)
        tabBar.setZoomPercent(percent)
    }

    // MARK: - 菜单动作

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let markdown = UTType("net.daringfireball.markdown") {
            panel.allowedContentTypes = [markdown]
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        // 只剩一个标签时 ⌘W 关窗口 —— 和浏览器一致，不然"关到最后一步还得再按一次"
        if currentIndex >= 0 && tabs.count > 1 {
            closeTab(at: currentIndex)
        } else {
            window.performClose(sender)
        }
    }

    @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        closeOthers(keeping: sender.tag)
    }

    @objc func nextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((currentIndex + 1) % tabs.count)
    }

    @objc func previousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((currentIndex - 1 + tabs.count) % tabs.count)
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        select(sender.tag - 1)
    }

    @objc func zoomIn(_ sender: Any?) {
        setMagnification((currentTab?.magnification ?? 1) * 1.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        setMagnification((currentTab?.magnification ?? 1) / 1.1)
    }

    @objc func zoomActualSize(_ sender: Any?) {
        setMagnification(1)
    }

    @objc func reloadDocument(_ sender: Any?) {
        guard let tab = currentTab, let view = pool.residentView(for: tab) else { return }
        load(tab, into: view, restoreScroll: true)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = currentTab?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInDefaultEditor(_ sender: Any?) {
        guard let url = currentTab?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) {
        // 交通灯是从窗口顶往下量的；窗口一改高，换算结果就过期了
        guard abs(window.frame.height - lastAlignedHeight) > 0.5 else { return }
        alignTrafficLights()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        alignTrafficLights()
        dumpLayout()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        alignTrafficLights()
    }

    /// 给自包含文档用的占位 baseURL。
    ///
    /// ⚠️ **绝不能传文件所在目录**。WebKit 拿到 file URL 的 baseURL 会走
    /// `WebProcessProxy::assumeReadAccessToBaseURL` → `SandboxExtension::createHandle`
    /// → `_sandbox_extension_issue` 去申请"能读这个目录"的沙箱扩展。实测这条路会死锁：
    ///
    /// ```
    /// 主线程   : loadData → assumeReadAccessToBaseURL → _sandbox_extension_issue → __mac_syscall  [阻塞]
    /// 后台线程 : SQLiteDatabase::open → initializeSQLiteIfNecessary
    ///            → callOnMainThreadAndWait → __psynch_cvwait                                    [等主线程]
    /// ```
    ///
    /// 而我们的 HTML 是**单文件自包含**的（CSS 内联、图片是 base64、CSP 就写着
    /// `default-src 'none'; img-src data:`），根本不需要任何文件访问权。
    /// WebKit 源码里那个函数第一句就是 `if (!url.isLocalFile()) { done(); return; }`，
    /// 所以换个非 file 的 scheme 就能整段绕开 —— 既躲开死锁，又省一次沙箱 IPC。
    ///
    /// baseURL 的唯一作用是解析相对 URL，而相对 URL 已经被 CSP 全部挡掉了。
    private static let selfContainedBaseURL = URL(string: "about:blank")!

    private static func failureHTML(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return "<meta charset='utf-8'><p style='font:14px system-ui'>打不开这个文件：\(message)</p>"
    }
}

/// 带布局钩子的 `NSWindow`。
///
/// 存在的唯一理由：**交通灯的位置自愈**。
///
/// 交通灯默认按 28~32pt 的标题栏垂直居中，而我们的标签栏是 38pt，要把按钮往下挪 3pt。
/// 问题是 AppKit 会在若干时机（窗口上屏、成为 key、改尺寸、切全屏…）重新布局标题栏，
/// 每次都把我们挪过的按钮**摆回原位**。
///
/// 光靠在 `windowDidBecomeKey` / `windowDidResize` 里补是补不干净的 —— 实测同一时刻
/// 能同时读到 19.0 和 16.0 两种状态，说明还有没覆盖到的时机。挂到 `layoutIfNeeded()`
/// 上就变成自愈：**无论 AppKit 什么时候重排，排完立刻再对齐一次**。
///
/// 不会死循环：`alignTrafficLights()` 里比对目标位置，已经对齐（Δ ≤ 0.5pt）就直接返回。
final class SpacedownWindow: NSWindow {

    var onLayout: (() -> Void)?

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        onLayout?()
    }
}
