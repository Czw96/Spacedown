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
final class MainWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, NSMenuItemValidation {

    private let window: SpacedownWindow
    private let barBackground = NSVisualEffectView()
    private let tabBar = TabBarView()
    /// 内容宿主。用 `DropTargetView` 而不是裸 `NSView`：空窗口时的拖放落点就是它。
    private let webHost = DropTargetView()
    /// 空状态：图标 + 一句话 + 快捷键提示。比原来那一行灰字有用得多。
    private let emptyState = NSStackView()
    /// 首帧晚于 120ms 才出现（否则快速加载会闪一下反而更差）。
    private let spinner = NSProgressIndicator()

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
    /// 正在加载的 webview（决定转菊花该不该转）
    private var loadingView: WKWebView?
    /// 延迟起转的定时器；加载够快就把它取消掉，避免闪一下
    private var spinnerWork: DispatchWorkItem?

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
        // 空窗口时整块内容区都是拖放落点。有内容时挡住它的是 webview，
        // 那一层由 `SpacedownWebView` 自己接（见文件末尾）。
        webHost.onDropFiles = { [weak self] urls in self?.openDroppedFiles(urls) }
        content.addSubview(webHost)

        buildEmptyState()
        content.addSubview(emptyState)

        spinner.style = .spinning
        spinner.controlSize = .small
        // 停转时自动隐藏，省掉一个手动 isHidden 的同步点
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        for view in [barBackground, tabBar, webHost, emptyState, spinner] {
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

            emptyState.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),
        ])
    }

    /// 空状态：给一块空白一个明确的下一步。
    ///
    /// 原来只有一行 13pt 的灰字，既没告诉用户「你是谁」，也没把最重要的入口顶出来。
    /// 图标用 App 自己的（`AppIcon.icns`），配色沿用系统语义色，不引入新色。
    private func buildEmptyState() {
        let icon = NSImageView()
        icon.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = NSTextField(labelWithString: "还没有打开的文档")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let hint = NSTextField(labelWithString: "把 .md 拖进来，或按 ⌘O 打开")
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.setViews([icon, title, hint], in: .leading)
        emptyState.setCustomSpacing(16, after: icon)
    }

    private func wireTabBar() {
        tabBar.onSelect = { [weak self] index in self?.select(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.openDocument(nil) }
        tabBar.onZoomIn = { [weak self] in self?.zoomIn(nil) }
        tabBar.onZoomOut = { [weak self] in self?.zoomOut(nil) }
        tabBar.onZoomReset = { [weak self] in self?.zoomActualSize(nil) }
        tabBar.contextMenuProvider = { [weak self] index in self?.tabMenu(for: index) }

        // 池子造的每个 webview 都要能把拖进来的文件交回窗口
        pool.onDropFiles = { [weak self] urls in self?.openDroppedFiles(urls) }

        watcher.onChange = { [weak self] url in self?.documentChanged(at: url) }
    }

    /// 拖放落点。只认扩展名认识的文件 —— 拖进来一个 `.zip` 不该平白开个标签。
    ///
    /// （打开面板是另一回事：那里用户是逐个点选的，属于明确指定，不做二次过滤。）
    private func openDroppedFiles(_ urls: [URL]) {
        for url in urls where MarkdownFiles.accepts(url) {
            open(url)
        }
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
        emptyState.isHidden = !tabs.isEmpty
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
            view.pageZoom = tab.zoom
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
        // ⚠️ 必须带 `tag`：右键的标签未必是当前标签，
        // 用 `closeCurrentTab` 会去关**另一个**标签（回落到发送者身上修）。
        let close = menu.addItem(
            withTitle: "关闭标签", action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.tag = index
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
        emptyState.isHidden = true
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
            // 代次对得上才收：对不上说明已经有更新的一次切换在跑，那一个才是它的活
            if self.fadeGeneration == generation, let fading = self.fadingOut {
                self.fadingOut = nil
                fading.removeFromSuperview()
                fading.alphaValue = 1
            }
            // 兜底清扫：连切时上一代的任务会被代次号挡掉，「每代只收一个」就会漏下几层
            // 已经淡到全透明的 webview —— 它们看不见，但还在视图树里参与命中测试。
            for other in self.webHost.subviews.compactMap({ $0 as? WKWebView })
            where other !== view && other.alphaValue <= 0.01 {
                other.removeFromSuperview()
                other.alphaValue = 1
            }
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
        // 缩放三件套必须落在同一条中线上（含数字的 cap 高中线），差一点都看得出来
        for (name, fromTop) in tabBar.debugZoomCentersFromTop ?? [] {
            DebugLog.write("  \(name) centerFromTop=\(fmt(fromTop))")
        }
        dumpMeasureMenu()
    }

    /// 菜单自检：把「显示」里跟版心有关的那几行打出来。
    ///
    /// 存在的理由很具体：用户反馈"没看到版心宽度的设置"，而本机截不了屏 ——
    /// 到底菜单里有没有这几行、标题是什么，只能靠日志给答案。
    private func dumpMeasureMenu() {
        let actions: Set<Selector> = [
            #selector(widenMeasure(_:)), #selector(narrowMeasure(_:)), #selector(resetMeasure(_:)),
        ]
        let found = NSApp.mainMenu?.item(withTitle: "显示")?.submenu?.items.filter { item in
            item.tag == MainMenu.measureInfoTag || (item.action.map(actions.contains) ?? false)
        } ?? []
        DebugLog.write("menu[显示] 版心相关条目 \(found.count) 条")
        for item in found {
            DebugLog.write("  「\(item.title)」 enabled=\(item.isEnabled) state=\(item.state.rawValue)")
        }
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func removeAllWebViews() {
        endLoading()
        for view in webHost.subviews.compactMap({ $0 as? WKWebView }) {
            view.removeFromSuperview()
        }
    }

    private func load(_ tab: DocumentTab, into view: WKWebView, restoreScroll: Bool) {
        pendingScroll[ObjectIdentifier(view)] = restoreScroll ? tab.scrollY : 0
        loadStartedAt[ObjectIdentifier(view)] = DispatchTime.now().uptimeNanoseconds
        view.pageZoom = tab.zoom
        beginLoading(view)
        do {
            let markdown = try MarkdownRenderer.documentBytes(contentsOf: tab.url)
            let html = SharedTheme.document(body: renderer.renderHTMLData(markdown),
                                            measurePercent: MeasureSettings.percent)
            view.load(
                html,
                mimeType: "text/html",
                characterEncodingName: "UTF-8",
                baseURL: Self.selfContainedBaseURL
            )
        } catch {
            view.loadHTMLString(Self.failureHTML(error), baseURL: nil)
        }
        // 导航还没跑完就先记上归属：否则用户在加载途中切回来，`acquire` 会判成
        // 「没载过」而重复 `load()`。`didFinish` 里那次是**确认**，不是首次登记。
        pool.markLoaded(tab, in: view)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        endLoading(webView)
        guard let tab = pool.tab(for: webView) else { return }
        if let started = loadStartedAt.removeValue(forKey: ObjectIdentifier(webView)) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.write(String(
                format: "firstPaint %@ = %.1fms (pool=%d)",
                tab.title, elapsed, pool.residentCount))
        }
        pool.markLoaded(tab, in: webView)
        if DebugLog.isEnabled { logContentWidth(webView) }
        let target = pendingScroll.removeValue(forKey: ObjectIdentifier(webView)) ?? 0
        guard target > 0 else { return }
        webView.evaluateJavaScript("window.scrollTo(0, \(target))")
    }

    /// 版心 / 缩放自检：把「设置值 → 实际宽度 → 要不要横向滚」记进调试日志。
    ///
    /// 本机 `screencapture` 被 TCC 挡住，而这两样都是"看得见"的东西 —— 只能靠数字确认：
    /// - `defaults write cn.29dev.Spacedown MeasurePercent 80` 之后，占比应当约 80%
    /// - 按 ⌘+ 放大之后，**横向滚动那一栏必须还是"无"**（`pageZoom` 会重排；
    ///   老的 `magnification` 是视觉放大，这里会变成"有"）
    private func logContentWidth(_ view: WKWebView) {
        view.evaluateJavaScript("""
        (function () {
            var c = document.querySelector('.content');
            if (!c) { return null; }
            var d = document.documentElement;
            return { content: Math.round(c.getBoundingClientRect().width),
                     viewport: window.innerWidth,
                     layoutW: d.scrollWidth,
                     needsHScroll: d.scrollWidth > window.innerWidth };
        })()
        """) { [weak self] result, _ in
            guard let self, let d = result as? [String: Any],
                  let content = (d["content"] as? NSNumber)?.doubleValue,
                  let viewport = (d["viewport"] as? NSNumber)?.doubleValue,
                  let layout = (d["layoutW"] as? NSNumber)?.doubleValue else { return }
            let needs = (d["needsHScroll"] as? NSNumber)?.boolValue ?? false
            let ratio = viewport > 0 ? content / viewport * 100 : 0
            let tab = self.currentTab
            DebugLog.write("  版心=\(self.fmt(content)) viewport=\(self.fmt(viewport)) "
                + "设置=\(MeasureSettings.percent)% 实际占比=\(self.fmt(ratio))% "
                + "zoom=\(self.fmt(tab?.zoom ?? 1)) 布局宽=\(self.fmt(layout)) "
                + "横向滚动=\(needs ? "有 ← 出问题了" : "无")")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endLoading(webView)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        endLoading(webView)
    }

    // MARK: - 加载指示

    /// 首帧通常只有几十毫秒，立刻显示菊花会「闪一下」——反而更差。
    /// 所以推迟 120ms 起转，并认住是哪个实例：期间已经切走就不转。
    private func beginLoading(_ view: WKWebView) {
        loadingView = view
        spinnerWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.loadingView === view else { return }
            self.spinner.startAnimation(nil)
        }
        spinnerWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func endLoading(_ view: WKWebView? = nil) {
        // 带实例时只认自己那一次加载：后台标签的重载进度不该把前台刚起转的菊花停掉
        if let view, loadingView !== view { return }
        spinnerWork?.cancel()
        spinnerWork = nil
        loadingView = nil
        spinner.stopAnimation(nil)
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

    /// 缩放走 `pageZoom`，**不是 `magnification`**。
    ///
    /// 两者差别就是这个功能能不能用：
    /// - `magnification`：只把画面**视觉**放大，版心宽度（CSS px）纹丝不动 →
    ///   900pt 视口放到 2x，内容还是 889 CSS px，可只有 450 CSS px 看得见 →
    ///   **必然压出横向滚动条**（实测 2x 溢出 439px、4x 溢出 664px）。这就是反馈里那条。
    /// - `pageZoom`：改的是**布局缩放**，视口变窄、内容跟着重排折行 →
    ///   2x 时版心自己缩到 439，4x 缩到 214，实测溢出 −11px（就是滚动条那点宽度），**永远不横向滚**。
    ///
    /// 所以捏合缩放（`allowsMagnification`）也一并关掉了：它属于前者，留着就会重新引入同一个问题，
    /// 而且两套缩放叠加会互相干扰。缩放入口保留 ⌘+ / ⌘− / ⌘0 与工具栏三件套。
    private func setZoom(_ value: CGFloat) {
        guard let tab = currentTab,
              let view = pool.residentView(for: tab) else { return }
        let clamped = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        view.pageZoom = clamped
        // 切换标签时实例是复用的，缩放不会自己回到 1，所以模型必须记住
        tab.zoom = clamped
        updateZoomLabel()
    }

    private static let zoomRange: ClosedRange<CGFloat> = 0.25...5.0

    private func updateZoomLabel() {
        let percent = Int((currentTab?.zoom ?? 1) * 100)
        tabBar.setZoomPercent(percent)
    }

    // MARK: - 菜单动作

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.markdownContentTypes
        // ⚠️ 本机 `.mdown` / `.mkdn` / `.mdx` 等分别被 WPS 与 showmd 认领成了各自的 UTI
        // （技术方案 §6.2），不在白名单里就会被面板灰掉、根本选不中。放开这一层，
        // 用户愿意手选什么就开什么 —— 这里是明确的逐文件指定，不再做二次过滤。
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    /// 打开面板的默认类型过滤。只影响"下拉菜单里默认选中哪类文件"，不影响能否手选。
    private static let markdownContentTypes: [UTType] = {
        let identifiers = [
            "net.daringfireball.markdown",              // 系统给 .md / .markdown
            "public.markdown",                          // 通用 markdown UTI
            "com.kingsoft.wpsoffice.markdown",          // 本机被 WPS 认领的 .mdown / .mkd
        ]
        let types = identifiers.compactMap { UTType($0) }
        // 一个都解析不出来时退回纯文本，别给出一个空过滤（空过滤 = 什么都不让选）
        return types.isEmpty ? [.plainText] : types
    }()

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

    /// 右键菜单里的"关闭标签"：关的是**右键点中的那个**，不是当前标签。
    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        closeTab(at: sender.tag)
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
        // ⌘9 固定跳到**最后一个**（Safari / Chrome 惯例），不是"第 9 个"。
        // 菜单里 1…9 共用同一个 tag 序列，所以 9 单独走一条路。
        select(sender.tag >= 9 ? tabs.count - 1 : sender.tag - 1)
    }

    @objc func zoomIn(_ sender: Any?) {
        setZoom((currentTab?.zoom ?? 1) * 1.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        setZoom((currentTab?.zoom ?? 1) / 1.1)
    }

    @objc func zoomActualSize(_ sender: Any?) {
        setZoom(1)
    }

    // MARK: - 版心宽度

    @objc func widenMeasure(_ sender: Any?) {
        setMeasure(MeasureSettings.percent + MeasureSettings.step)
    }

    @objc func narrowMeasure(_ sender: Any?) {
        setMeasure(MeasureSettings.percent - MeasureSettings.step)
    }

    @objc func resetMeasure(_ sender: Any?) {
        setMeasure(MeasureSettings.full)
    }

    private func setMeasure(_ value: Int) {
        let clamped = MeasureSettings.clamp(value)
        // 已经顶到 40% / 铺满 了就不做无谓的重渲染
        guard clamped != MeasureSettings.percent else { return }
        MeasureSettings.percent = clamped
        applyMeasureChange()
    }

    /// 版心宽度变了：当前标签立刻重渲染，其余实例标记为"内容过期"。
    ///
    /// ⚠️ 这是**渲染期参数**（写进 HTML 的覆盖样式里），不是纯 CSS 变量 ——
    /// 所以不能只改样式了事，必须重新出 HTML。同一份文件也要重来。
    private func applyMeasureChange() {
        // 别的标签下次取用时重新载入 —— 否则会看到"旧参数渲染出来的内容"
        pool.invalidateContent()

        guard let tab = currentTab, let view = pool.residentView(for: tab) else { return }
        // 先把眼下读到哪儿了取回来，重渲染后滚回原处
        view.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            guard let self else { return }
            tab.scrollY = (result as? NSNumber)?.doubleValue ?? 0
            self.load(tab, into: view, restoreScroll: true)
        }
    }

    /// 顶到上/下界时把对应的菜单项灰掉，「版心自适应」顺带用勾表示"当前就是铺满"。
    ///
    /// ⚠️ 对不认识的条目**必须返回 true**：这个方法一旦实现，就接管了整张菜单的启用判定，
    /// 漏掉一条（比如缩放、切标签）会让它莫名其妙变灰。
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(widenMeasure(_:)):
            return MeasureSettings.percent < MeasureSettings.full
        case #selector(narrowMeasure(_:)):
            return MeasureSettings.percent > MeasureSettings.minimum
        case #selector(resetMeasure(_:)):
            let isFull = MeasureSettings.percent == MeasureSettings.full
            item.state = isFull ? .on : .off
            return !isFull
        default:
            return true
        }
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

    /// ⚠️ **必须把 `isReleasedWhenClosed` 关掉，否则关窗时段错误崩溃。**
    ///
    /// 程序化创建的 `NSWindow` 这个标志**默认是 `true`**（实测确认）：关窗时 AppKit
    /// 释放窗口一次，而 `AppDelegate` 还持有一份强引用 —— ARC 之后再释放一次，
    /// 就是典型的"多释放一次"。
    ///
    /// 崩溃现场很有迷惑性：栈上**完全没有我们自己的代码**
    /// （`objc_release` → `AutoreleasePoolPage::releaseUntil` → `NSAutoreleasePool drain`
    /// → `-[NSApplication run]`），地址是垃圾指针，所以从崩溃报告里看不出是这里。
    ///
    /// 复现与验证：写了个同结构的最小程序（`AppDelegate` 持控制器、控制器持窗口、
    /// `windowWillClose` 里把强引用置 nil、`applicationShouldTerminateAfterLastWindowClosed = true`）——
    /// 关窗时 `isReleasedWhenClosed = true` → **退出码 139（SIGSEGV）**；
    /// 改成 `false` → **退出码 0**，干净退出。
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style,
                   backing: backingStoreType, defer: flag)
        isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        onLayout?()
    }
}

/// 「这个文件我们能预览吗」的唯一判据。
///
/// 拖放与打开面板共用它，避免两处白名单各自漂移。
///
/// ⚠️ 刻意按**扩展名**判断而不是 UTI：本机 `.mdown` / `.mkdn` / `.mdx` 分别被 WPS 与
/// showmd 认领成了各自的 UTI（技术方案 §6.2），按 UTI 白名单会把它们整片漏掉，
/// 而我们对内容本身没有额外要求 —— 都是文本，cmark 照渲染。
enum MarkdownFiles {

    private static let extensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdtxt", "mdwn", "mdx", "rmd", "qmd",
    ]

    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return extensions.contains(url.pathExtension.lowercased())
    }
}

/// 版心宽度这个偏好设置的唯一读写口。
///
/// 语义是「**占可用宽度的百分比**」：`full`(100) = 铺满（两侧只留内容区的内边距），
/// 90 = 两侧各留 5%。改动会写进 `UserDefaults`，下次启动还在。
///
/// ⚠️ **Quick Look 扩展读不到它**：App 是 `cn.29dev.Spacedown`、扩展是
/// `cn.29dev.Spacedown.QuickLookPreview`，两个 UserDefaults 域；工程里也没有
/// entitlements / App Group（要真签名 + Team 才能加）。所以空格预览固定按 100%。
enum MeasureSettings {

    private static let key = "MeasurePercent"

    /// 铺满，同时是取值上界。
    static let full = SharedTheme.fullMeasurePercent
    /// 下界。再窄下去标题会频繁折行，反而更难读。
    static let minimum = 40
    /// 每次加宽/收窄的步长，和小步快调的缩放保持同一种手感。
    static let step = 10

    static var percent: Int {
        get { clamp(UserDefaults.standard.object(forKey: key) as? Int ?? full) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: key) }
    }

    static func clamp(_ value: Int) -> Int {
        min(full, max(minimum, value))
    }
}

/// 只认文件拖放的容器视图 —— 空窗口时的拖放落点就是它。
final class DropTargetView: NSView {
    var onDropFiles: (([URL]) -> Void)?

    static let fileTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.fileTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.markdownURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.markdownURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    /// 从拖放板里取出「我们认得的」文件 URL。
    static func markdownURLs(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return objects.filter(MarkdownFiles.accepts)
    }
}

/// 主 App 用的 `WKWebView`：加这一层壳只为拦下文件拖放。
///
/// `WKWebView` 自己对文件拖放有默认行为（直接导航过去，把渲染结果换成裸文本/二进制）。
/// 我们要的是「拖进来 = 开一个新标签」，所以得自己接过来。
final class SpacedownWebView: WKWebView {

    var onDropFiles: (([URL]) -> Void)?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes(DropTargetView.fileTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropTargetView.markdownURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DropTargetView.markdownURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
