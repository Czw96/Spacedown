import AppKit
import WebKit
import SharedTheme

/// LRU `WKWebView` 池。
///
/// 每个 `WKWebView` 独占一个 WebContent 渲染进程，新建一个实例约 60~75ms，
/// 而复用已有实例只需一次导航（约 10ms）。所以池子的策略是「按上限常驻、
/// 淘汰不销毁」：标签再多，活着的渲染进程也只有 `capacity + spareCapacity` 个。
///
/// ⚠️ 池子只负责"哪个 web view 服务哪个标签"，**不负责载入内容**：
/// 调用方拿到 `needsLoad == true` 的实例时要自己 `load()`。
@MainActor
final class WebViewPool {

    /// 池容量，同时也是渲染进程数的上界。
    static let capacity = 5
    /// 备用区容量。超出就真的丢一个 —— 备用区不能无限长。
    static let spareCapacity = 2

    private final class Slot {
        let view: WKWebView
        weak var tab: DocumentTab?

        init(view: WKWebView, tab: DocumentTab) {
            self.view = view
            self.tab = tab
        }
    }

    /// LRU 顺序，最近用过的排最后。
    private var slots: [Slot] = []
    private var spare: [WKWebView] = []

    /// web view → 它此刻装的是哪个标签的内容。
    ///
    /// 这是判断"取到的实例是不是热的"的唯一依据，不能记在标签上：
    /// 实例可能被 A 用到一半、进备用区、再被 B 拿走，那时 A 上的"我载过了"就是过期信息。
    private var contentOwner: [ObjectIdentifier: ObjectIdentifier] = [:]

    /// 池只借用委托，不持有 —— 窗口持有池，池再强持窗口就成环，关窗后两者都不释放。
    private weak var delegate: (any WKNavigationDelegate)?

    /// 文件被拖到某个 web view 上时回调。
    var onDropFiles: (([URL]) -> Void)?

    init(delegate: any WKNavigationDelegate) {
        self.delegate = delegate
    }

    // MARK: - 预热

    /// 先建一个实例并导航到空白页。
    ///
    /// WebContent 进程启动约 300ms、新建实例约 74ms，这笔钱本来要等用户打开第一个
    /// 文件时才付；放到启动阶段做等于白赚。预热实例进备用区、`contentOwner` 里没有它，
    /// 所以第一个标签拿到的 `needsLoad` 一定是 true。
    func prewarm() {
        guard spare.isEmpty, slots.isEmpty else { return }
        let view = makeView()
        WebViewDocument.loadBlankPage(into: view)
        spare.append(view)
    }

    // MARK: - 取用

    /// 取这个标签的 web view。`needsLoad == true` 表示里面没有这个标签的内容。
    func acquire(_ tab: DocumentTab) -> (view: WKWebView, needsLoad: Bool) {
        let view: WKWebView
        if let slot = slots.first(where: { $0.tab === tab }) {
            touch(slot)
            view = slot.view
        } else {
            view = spare.popLast() ?? makeView()
            slots.append(Slot(view: view, tab: tab))
            evictOverflow()
        }
        // 实例是复用的，缩放不会自己回到 1
        view.pageZoom = tab.zoom
        return (view, !holds(view, tab))
    }

    /// 内容载入完成后登记归属，下次取到时才知道是热的。
    func markLoaded(_ tab: DocumentTab, in view: WKWebView) {
        contentOwner[ObjectIdentifier(view)] = ObjectIdentifier(tab)
    }

    /// 不改变 LRU 顺序地查实例（给"文件变了要重载"这类旁路用）。
    func residentView(for tab: DocumentTab) -> WKWebView? {
        slots.first { $0.tab === tab }?.view
    }

    /// 让池里所有实例"忘记"自己装的是哪份内容，下次取用一律重新载入。
    ///
    /// 给渲染期参数变化用的（版心宽度）：只刷新当前标签不够，否则切到别的标签
    /// 会看到用旧参数渲染的内容。
    func invalidateContent() {
        contentOwner.removeAll()
    }

    /// 池内常驻实例数，等于当前活着的渲染进程数。
    var residentCount: Int { slots.count }

    /// 反查：这个 web view 现在服务哪个标签（导航回调里只有 web view）。
    func tab(for view: WKWebView) -> DocumentTab? {
        slots.first { $0.view === view }?.tab
    }

    // MARK: - 回收

    /// 标签关掉了：实例退回备用区，不销毁。
    func retire(_ tab: DocumentTab) {
        guard let index = slots.firstIndex(where: { $0.tab === tab }) else { return }
        pushSpare(slots.remove(at: index).view)
    }

    /// 离开一个标签前把滚动位置存回模型。实例被淘汰时也会调。
    ///
    /// 读取是异步的，而调用方紧接着就会回收/复用这个实例，所以回执必须验身份。
    /// 判据不能写成 `contentOwner[view] == tab`：已回收的实例 `contentOwner` 已被清空，
    /// 但里面的内容还没被换掉，那份读数依然有效 —— 一刀切会把该存的丢掉。
    func captureScrollY(of tab: DocumentTab) {
        guard let view = residentView(for: tab) else { return }
        Task { @MainActor in
            guard let raw = try? await view.evaluateJavaScript("window.scrollY"),
                  self.stillHolds(view, tab) else { return }
            tab.scrollY = (raw as? NSNumber)?.doubleValue ?? 0
        }
    }

    /// 回执回来时，实例里的内容还是不是这个标签的。
    private func stillHolds(_ view: WKWebView, _ tab: DocumentTab) -> Bool {
        switch contentOwner[ObjectIdentifier(view)] {
        case .none: return true                        // 已回收、内容未换：读数仍有效
        case .some(let owner): return owner == ObjectIdentifier(tab)
        }
    }

    /// 实例此刻装的是不是这个标签的内容（判"热"的唯一依据）。
    private func holds(_ view: WKWebView, _ tab: DocumentTab) -> Bool {
        contentOwner[ObjectIdentifier(view)] == ObjectIdentifier(tab)
    }

    // MARK: - 内部

    private func touch(_ slot: Slot) {
        guard let index = slots.firstIndex(where: { $0 === slot }) else { return }
        slots.append(slots.remove(at: index))
    }

    /// 池子满了就从最久未用的开始淘汰。刚 append 的那个在末尾，不会被淘汰。
    private func evictOverflow() {
        while slots.count > Self.capacity {
            let evicted = slots.removeFirst()
            if let tab = evicted.tab {
                captureScrollY(of: tab)
            }
            pushSpare(evicted.view)
        }
    }

    private func pushSpare(_ view: WKWebView) {
        contentOwner.removeValue(forKey: ObjectIdentifier(view))
        slots.removeAll { $0.view === view }
        spare.removeAll { $0 === view }
        spare.append(view)

        while spare.count > Self.spareCapacity {
            let dropped = spare.removeFirst()
            // 真的丢掉的这个要清空文档，否则它带着内容吃内存
            dropped.stopLoading()
            dropped.loadHTMLString("", baseURL: nil)
        }
    }

    /// 建实例并接上拖放回调 —— 两处创建点（预热 / 取用）都走它。
    private func makeView() -> SpacedownWebView {
        let view = Self.makeBareView(delegate: delegate)
        view.onDropFiles = { [weak self] urls in self?.onDropFiles?(urls) }
        return view
    }

    private static func makeBareView(delegate: (any WKNavigationDelegate)?) -> SpacedownWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(LinkInteraction.userScript)
        // 谁当处理器由调用方决定：不是处理器就只注入脚本、不注册回调
        if let handler = delegate as? WKScriptMessageHandler {
            configuration.userContentController.add(handler, name: LinkInteraction.messageName)
        }

        let view = SpacedownWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = delegate
        // 文档加载完成前 WebKit 默认刷白，深色模式下会很刺眼
        view.underPageBackgroundColor = Palette.pageBackground
        // 不要开 `allowsMagnification`：那是纯视觉放大、不重排，一放大就压出横向滚动条。
        // 缩放由 `pageZoom` 负责（见 MainWindow.setZoom）。
        return view
    }
}
