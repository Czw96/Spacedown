import AppKit
import WebKit

import MarkdownKit
import SharedTheme

/// 只读查看器主窗口 —— 一个窗口装所有标签。
///
/// 只读是结构上保证的：web view 里只有渲染结果，没有输入控件，HTML 还带着
/// `default-src 'none'` 的 CSP。
///
/// 窗口形态是 `fullSizeContentView` + 隐藏标题栏，交通灯与自绘标签栏同一行。
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {

    let window: SpacedownWindow
    let tabBar = TabBarView()
    lazy var pool = WebViewPool(delegate: self)
    private(set) var tabs: [DocumentTab] = []
    private(set) var currentIndex = -1

    /// 内容宿主的圆角与四周留白。
    private static let cardRadius: CGFloat = 10
    private static let cardInset: CGFloat = 8

    private let barBackground = NSView()
    /// 内容宿主。用 `DropTargetView` 而不是裸 `NSView`：空窗口时的拖放落点就是它。
    /// 非 private：`MainWindow+Find.swift` 要把查找条浮在它上面。
    let webHost = DropTargetView()
    /// 空状态：图标 + 一句话 + 快捷键提示。
    private let emptyState = NSStackView()
    private let spinner = NSProgressIndicator()
    /// 查找条（浮在内容卡片右上角）。同样是跨文件使用，故不设 private。
    let findBar = FindBar()

    private let renderer = MarkdownRenderer()
    private let watcher = FileWatcher.shared

    /// 载入完成后要还原的滚动位置，键是 web view 身份。
    var pendingScroll: [ObjectIdentifier: Double] = [:]
    /// 各 web view 发起 `load` 的时刻，用于量首帧（调试开关打开时才记录）。
    var loadStartedAt: [ObjectIdentifier: UInt64] = [:]
    /// 正在加载的 web view，决定菊花该不该转。
    private var loadingView: WKWebView?
    /// 延迟起转的定时器；加载够快就取消掉，避免闪一下。
    private var spinnerWork: DispatchWorkItem?

    /// 正在淡出的那个 web view，以及淡入的代次号（快速切换时防止误删）。
    private var fadingOut: WKWebView?
    private var fadeGeneration = 0

    /// 上次对齐交通灯时的窗口高度，避免 resize 里重复做无用功。
    private var lastAlignedHeight: CGFloat = 0

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
        window.backgroundColor = Palette.chromeBackground
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        window.onLayout = { [weak self] in self?.alignTrafficLights() }

        buildContent()
        wireTabBar()
        wireFindBar()
        alignTrafficLights()
        // 窗口一建出来就预热 web view：等用户按 ⌘O 再建要多付一次 WebContent 启动
        pool.prewarm()
        refresh()
    }

    // MARK: - 对外

    func show() {
        window.makeKeyAndOrderFront(nil)
        // 上屏前 AppKit 还会跑几轮标题栏布局，init 里那次平移会被冲掉，这里补一次
        alignTrafficLights()
    }

    /// 打开文件：已经在标签里就切过去，不叠开。
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

        barBackground.wantsLayer = true
        barBackground.layer?.backgroundColor = Palette.chromeBackground.cgColor
        content.addSubview(barBackground)
        content.addSubview(tabBar)

        // 「内容是一张纸」：圆角 + 裁掉溢出（web view 会被一起裁圆）
        webHost.wantsLayer = true
        webHost.layer?.cornerRadius = Self.cardRadius
        webHost.layer?.masksToBounds = true
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

            // 一圈 8pt 的窗口底色，卡片就"浮"起来了
            webHost.topAnchor.constraint(equalTo: content.topAnchor, constant: barHeight),
            webHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.cardInset),
            webHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.cardInset),
            webHost.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.cardInset),

            emptyState.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: webHost.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: webHost.centerYAnchor),
        ])
    }

    /// 空状态：给一块空白一个明确的下一步。
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

        // 池子造的每个 web view 都要能把拖进来的文件交回窗口
        pool.onDropFiles = { [weak self] urls in self?.openDroppedFiles(urls) }
        watcher.onChange = { [weak self] url in self?.documentChanged(at: url) }
    }

    /// 拖放落点只认认识的文件 —— 拖进来一个 `.zip` 不该平白开个标签。
    /// 打开面板是另一回事：那里是用户逐个点选的明确指定，不做二次过滤。
    private func openDroppedFiles(_ urls: [URL]) {
        for url in urls where MarkdownFileType.isSupported(url) {
            open(url)
        }
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

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if let previous = currentTab, previous !== tabs[index] {
            pool.captureScrollY(of: previous)
        }
        currentIndex = index

        let tab = tabs[index]
        let (view, needsLoad) = pool.acquire(tab)
        if needsLoad {
            load(tab, into: view, restoreScroll: true)
        }
        present(view)
        refresh()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        pool.captureScrollY(of: tab)
        pool.retire(tab)
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            currentIndex = -1
            removeAllWebViews()
            refresh()
            return
        }
        // 关掉当前标签后落到右邻居；关的是最后一个就落到新的最后一个
        let next = min(index, tabs.count - 1)
        currentIndex = -1
        select(next)
    }

    func closeOthers(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let kept = tabs[index]
        for tab in tabs where tab !== kept {
            pool.retire(tab)
        }
        removeAllWebViews()
        tabs = [kept]
        currentIndex = -1
        select(0)
    }

    private func tabMenu(for index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let menu = NSMenu()

        // 右键点中的标签未必是当前标签，所以用 tag 记住它
        let close = menu.addItem(withTitle: "关闭标签",
                                 action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.tag = index

        let others = menu.addItem(withTitle: "关闭其他标签",
                                  action: #selector(closeOtherTabsFromMenu(_:)), keyEquivalent: "")
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

    // MARK: - 呈现

    private func present(_ view: WKWebView) {
        emptyState.isHidden = true
        // 查找条属于"上一个文档"：换标签就收起来，免得对着新内容还显示旧关键词
        findBar.dismiss()

        let others = webHost.subviews.compactMap { $0 as? WKWebView }.filter { $0 !== view }
        view.frame = webHost.bounds
        view.autoresizingMask = [.width, .height]

        guard let outgoing = others.first(where: { $0.alphaValue > 0.5 }) ?? others.first else {
            if view.superview !== webHost {
                view.alphaValue = 1
                webHost.addSubview(view)
            }
            focusForCopy(view)
            return
        }
        for extra in others where extra !== outgoing {
            extra.removeFromSuperview()
        }
        if view.superview !== webHost {
            view.alphaValue = 0
            webHost.addSubview(view)
        }
        focusForCopy(view)

        // 120ms 交叉淡入。收尾不用 runAnimationGroup 的 completionHandler
        // （它在 Swift 6 里是非隔离的，碰 alphaValue 会报隔离告警），
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
            if self.fadeGeneration == generation, let fading = self.fadingOut {
                self.fadingOut = nil
                fading.removeFromSuperview()
                fading.alphaValue = 1
            }
            // 连切时上一代的任务会被代次号挡掉，「每代只收一个」就会漏下已经淡到
            // 全透明的 web view —— 它们看不见，但还在视图树里参与命中测试。
            for other in self.webHost.subviews.compactMap({ $0 as? WKWebView })
            where other !== view && other.alphaValue <= 0.01 {
                other.removeFromSuperview()
                other.alphaValue = 1
            }
        }
    }

    /// 把第一响应者交给 web view。
    ///
    /// 「编辑 → 复制 / 全选」是不设 target 的菜单项，靠响应链找到 `copy:` / `selectAll:`；
    /// 第一响应者不是 web view 时（比如刚点过标签栏），这两个快捷键会落空。
    private func focusForCopy(_ view: WKWebView) {
        view.window?.makeFirstResponder(view)
    }

    private func removeAllWebViews() {
        endLoading()
        for view in webHost.subviews.compactMap({ $0 as? WKWebView }) {
            view.removeFromSuperview()
        }
    }

    // MARK: - 载入

    func load(_ tab: DocumentTab, into view: WKWebView, restoreScroll: Bool) {
        pendingScroll[ObjectIdentifier(view)] = restoreScroll ? tab.scrollY : 0
        loadStartedAt[ObjectIdentifier(view)] = DispatchTime.now().uptimeNanoseconds
        view.pageZoom = tab.zoom
        beginLoading(view)

        do {
            let markdown = try MarkdownDocument.bytes(contentsOf: tab.url)
            let body = renderer.renderHTMLData(markdown)
            let html = SharedTheme.document(
                body: body,
                measurePercent: MeasureSettings.percent,
                baseDirectory: tab.url.deletingLastPathComponent()
            )
            logRender(markdown: markdown, html: html)
            WebViewDocument.load(html, into: view)
        } catch {
            view.loadHTMLString(Self.failureHTML(error), baseURL: nil)
        }

        // 导航还没跑完就先记上归属：否则用户在加载途中切回来，`acquire` 会判成
        // 「没载过」而重复 load。`didFinish` 里那次是确认，不是首次登记。
        pool.markLoaded(tab, in: view)
    }

    /// 大文件被截到多少、渲染出多大 —— 光看源文件大小看不出来。
    private func logRender(markdown: Data, html: Data) {
        guard DebugLog.isEnabled else { return }
        // 判据只能看正文有没有那条提示（它被拼在最前面）：截断会切在换行上，
        // 结果略小于上限，拿字节数跟上限比会误判。
        let truncated = markdown.prefix(64).range(of: Data("已截断显示前".utf8)) != nil
        DebugLog.write("  render 解析输入=\(markdown.count / 1024)KB"
            + " 截断=\(truncated ? "是" : "否") HTML=\(html.count / 1024)KB")
    }

    private static func failureHTML(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return "<meta charset='utf-8'><p style='font:14px system-ui'>打不开这个文件：\(message)</p>"
    }

    // MARK: - 文件变化

    private func documentChanged(at url: URL) {
        guard let tab = tabs.first(where: { $0.url == url }),
              let view = pool.residentView(for: tab) else { return }
        load(tab, into: view, restoreScroll: true)
    }

    // MARK: - 加载指示

    /// 首帧通常只有几十毫秒，立刻显示菊花反而会"闪一下"。
    /// 所以推迟 120ms 起转，并认住是哪个实例：期间已经切走就不转。
    func beginLoading(_ view: WKWebView) {
        loadingView = view
        spinnerWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.loadingView === view else { return }
            self.spinner.startAnimation(nil)
        }
        spinnerWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// 带实例时只认自己那一次加载：后台标签的重载不该把前台刚起转的菊花停掉。
    func endLoading(_ view: WKWebView? = nil) {
        if let view, loadingView !== view { return }
        spinnerWork?.cancel()
        spinnerWork = nil
        loadingView = nil
        spinner.stopAnimation(nil)
    }

    // MARK: - 交通灯

    /// 交通灯默认按 28pt 的标题栏垂直居中（离窗口顶 14pt），标签栏是 38pt
    /// （中线离顶 19pt），所以要把它挪下来。
    ///
    /// 换算必须在窗口坐标系里做差值，而不是按"超视图高度 − 目标中心"套公式：
    /// 容器的超视图到底是 `NSThemeFrame` 还是标题栏视图、以及它是否翻转，
    /// 都是 AppKit 的内部实现。量当前位置、再平移 delta，只需要知道超视图的 y 轴朝向。
    ///
    /// 这一步依赖 `closeButton.superview` 这个内部层级，所以整体是"尽力而为"：
    /// 拿不到就什么都不做 —— 标签从 `leadingInset` 起排，本来也不会与交通灯重叠。
    private func alignTrafficLights() {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let close = buttons.first, let host = close.superview else {
            DebugLog.write("alignTrafficLights: 拿不到交通灯")
            return
        }

        // 量的是按钮中线，不是父容器中线：AppKit 随后会把容器摆回自己的位置，
        // 而真正决定观感的是按钮。平移也只移按钮本身。
        let delta = (window.frame.height - TabBarView.height / 2)
            - close.convert(close.bounds, to: nil).midY
        guard abs(delta) > 0.5 else {
            lastAlignedHeight = window.frame.height
            return
        }

        // 窗口坐标 y 向上；超视图若翻转，平移方向要取反
        let sign: CGFloat = host.isFlipped ? -1 : 1
        var moved = 0
        for button in buttons where button.superview === host {
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: button.frame.minY + sign * delta))
            moved += 1
        }
        lastAlignedHeight = window.frame.height
        DebugLog.write("alignTrafficLights: 移了 \(moved)/\(buttons.count) 个按钮 "
            + "delta=\(logNumber(delta)) host=\(type(of: host)) flipped=\(host.isFlipped)")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) {
        // 交通灯是从窗口顶往下量的，窗口一改高，换算结果就过期了
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
}
