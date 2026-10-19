import AppKit
import WebKit
import SharedTheme

/// LRU `WKWebView` 池 —— 本项目性能方案的核心（docs/技术方案.md §7.2）。
///
/// 三个候选的 M0 实测数字：
///
/// | 方案 | 切换成本 | 内存 |
/// |---|---|---|
/// | 每标签一个 webview | ~0 ms | 20 标签 ≈ 400~800 MB |
/// | 单 webview 换文档 | 30~80 ms | 恒定 |
/// | **LRU 池** | 命中 ≈ 0 ms，池外 ≈ 74 ms | 恒定上界 |
///
/// 另一条实测结论决定了"淘汰不销毁"：**新建 webview 74ms，复用已有实例导航只要 10ms**。
/// 所以淘汰时只把实例摘下来放备用区 —— 销毁后要用就得付 74ms 重建费，
/// 而一个空 webview 常驻的成本远低于此。
///
/// 容量 5 + 备用 2 = 最多 7 个常驻。按实测 ~30 MB/个算 ≈ 210 MB，压在 §1.1 里 P9 的 250 MB 目标内。
///
/// ⚠️ 池子只负责"哪个 webview 服务哪个标签"，**不负责载入内容**。
/// 调用方拿到 `needsLoad == true` 的实例时要自己 `load()`。
@MainActor
final class WebViewPool {

    /// 池容量。M0 实测后从"默认 3"上调到 5。
    ///
    /// ⚠️ **每个 `WKWebView` 都独占一个 WebContent 渲染进程**，不是共享的。
    /// `WKProcessPool.h` 的原文：*"Each web view is given its own web content process
    /// until an implementation-defined process limit is reached; after that, web views
    /// with the same process pool end up sharing web content processes."*
    /// 而且自 macOS 12 起 `WKProcessPool` 已弃用（"不再有任何效果"），
    /// 共享 `WKWebViewConfiguration` 也换不来进程复用 —— 实测 3 个标签就是 3 个进程。
    ///
    /// 所以**池容量同时也是渲染进程数的上界**：5 + 备用 2 = 最多 7 个 WebContent。
    /// 这正是 §1.1 里 P9（20 标签 ≤ 250MB）能成立的原因 —— 标签再多，
    /// 活着的 webview 也只有 7 个。反过来，一旦把"淘汰不销毁"改成"每标签一个"，
    /// 20 标签就是 20 个进程、600MB 起。
    static let capacity = 5

    /// 备用区容量。超出就真的丢一个 —— 备用区不能无限长，否则 20 标签照样吃 600 MB。
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

    /// webview → 它里面此刻装的是哪个标签的内容。
    ///
    /// 这是判断"取到的实例是不是热的"的唯一依据。不能把这个状态记在标签上：
    /// 实例可能被 A 用到一半、进备用区、再被 B 拿走，此时 A 上记的"我载过了"就是过期信息。
    private var contentOwner: [ObjectIdentifier: ObjectIdentifier] = [:]

    private let delegate: WKNavigationDelegate

    /// 文件被拖到某个 webview 上时回调（由 `MainWindow` 接管）。
    var onDropFiles: (([URL]) -> Void)?

    init(delegate: WKNavigationDelegate) {
        self.delegate = delegate
    }

    // MARK: - 预热

    /// 先建一个 webview 并导航到空白文档。
    ///
    /// 这笔钱本来要在用户打开第一个文件时付：WebContent 进程 spawn ≈ 300ms、
    /// 新建 webview 实例 ≈ 74ms（M0 实测）。放到启动阶段做，等于白赚 ——
    /// 见 docs/技术方案.md §6.1 的三招。
    ///
    /// 预热出来的实例进备用区，`contentOwner` 里没有它，所以第一个标签拿到的
    /// `needsLoad` 一定是 true，不会把这段空白页当成内容。
    func prewarm() {
        guard spare.isEmpty, slots.isEmpty else { return }
        let view = makeView()
        view.loadHTMLString("<!doctype html><meta charset='utf-8'><body></body>", baseURL: nil)
        spare.append(view)
    }

    // MARK: - 取用

    /// 取这个标签的 webview。
    ///
    /// `needsLoad == true` 表示拿到的实例里没有这个标签的内容，调用方要 `load()`。
    func acquire(_ tab: DocumentTab) -> (view: WKWebView, needsLoad: Bool) {
        if let slot = slots.first(where: { $0.tab === tab }) {
            touch(slot)
            return (slot.view, contentOwner[ObjectIdentifier(slot.view)] != ObjectIdentifier(tab))
        }

        let view = spare.popLast() ?? makeView()
        // 实例是复用的，缩放不会自己回到 1
        view.pageZoom = tab.zoom

        slots.append(Slot(view: view, tab: tab))
        evictOverflow()
        return (view, contentOwner[ObjectIdentifier(view)] != ObjectIdentifier(tab))
    }

    /// 内容载入完成后登记归属，下次取到时候才知道是热的。
    func markLoaded(_ tab: DocumentTab, in view: WKWebView) {
        contentOwner[ObjectIdentifier(view)] = ObjectIdentifier(tab)
    }

    /// 不用 touch 地查实例（给"文件变了要重载"这种旁路用）
    func residentView(for tab: DocumentTab) -> WKWebView? {
        slots.first { $0.tab === tab }?.view
    }

    /// 让池里所有实例"忘记"自己装的是哪份内容 —— 下次取用时一律重新载入。
    ///
    /// 给**渲染期参数**变化用的（目前是版心宽度）：同一个文件也要重渲染，
    /// 光把当前标签刷了不够，否则切到别的标签会看到旧参数渲染出来的内容。
    func invalidateContent() {
        contentOwner.removeAll()
    }

    /// 池内常驻实例数 = 当前活着的 WebContent 渲染进程数（每个 webview 独占一个）。
    var residentCount: Int { slots.count }

    /// 反查：这个 webview 现在服务哪个标签。`WKNavigationDelegate` 的回调只有 webview。
    func tab(for view: WKWebView) -> DocumentTab? {
        slots.first { $0.view === view }?.tab
    }

    // MARK: - 回收

    /// 标签关掉了：实例退回备用区（**不销毁**）。
    func retire(_ tab: DocumentTab) {
        guard let index = slots.firstIndex(where: { $0.tab === tab }) else { return }
        pushSpare(slots.remove(at: index).view)
    }

    /// 离开一个标签前把滚动位置存回模型。实例被淘汰时也会调。
    ///
    /// ⚠️ 这次读是**异步**的，而调用方紧接着就会回收/复用这个实例
    /// （`retire` / `evictOverflow` 都会把它丢进备用区）。等 JS 回执回来时，
    /// 实例可能已经被别的标签 `acquire` 并载入了新内容 —— 那时读到的 `scrollY`
    /// 是**别人**的位置，写进这个模型就是串台。所以回执必须验身份。
    ///
    /// 判据不能写成 `contentOwner[view] == tab`：被回收的实例 `contentOwner` 已被清空，
    /// 但**里面的内容还没被换掉**，那份读数依然是对的 —— 一刀切会把该存的丢掉。
    /// 真正要挡的只有「实例已经属于另一个标签」。
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
        case .none:                     return true        // 已回收、内容未换：读数仍有效
        case .some(let owner):          return owner == ObjectIdentifier(tab)
        }
    }

    // MARK: - 内部

    private func touch(_ slot: Slot) {
        guard let index = slots.firstIndex(where: { $0 === slot }) else { return }
        slots.append(slots.remove(at: index))
    }

    /// 池子满了就从最久未用的开始淘汰。刚 append 的那个在末尾，永远不会是被淘汰的那个。
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
            // 真的丢掉的这个要把文档清空，不然它带着内容吃内存
            dropped.stopLoading()
            dropped.loadHTMLString("", baseURL: nil)
        }
    }

    /// 建实例并接上拖放回调 —— 两处创建点（预热 / 取用）都走它，
    /// 免得漏掉一处导致"有的 webview 能收拖放、有的不能"。
    private func makeView() -> SpacedownWebView {
        let view = Self.makeBareView(delegate: delegate)
        view.onDropFiles = { [weak self] urls in self?.onDropFiles?(urls) }
        return view
    }

    private static func makeBareView(delegate: WKNavigationDelegate) -> SpacedownWebView {
        // 用 SpacedownWebView 而不是裸 WKWebView：它拦下文件拖放并交给我们（见 MainWindow.swift）
        let config = WKWebViewConfiguration()
        // 链接的点击语义（单击复制 / 双击打开）：脚本定义在 SharedTheme，**与 QL 扩展共用一份**。
        config.userContentController.addUserScript(WKUserScript(source: SharedTheme.linkClickScript,
                                                                injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true))
        // 谁当处理器由调用方决定（MainWindow）；不是处理器就只注入脚本、不注册回调。
        if let handler = delegate as? WKScriptMessageHandler {
            config.userContentController.add(handler, name: SharedTheme.linkActionName)
        }
        let view = SpacedownWebView(frame: .zero, configuration: config)
        // ⚠️ **不要开 `allowsMagnification`**：那是纯视觉放大（不重排），一放大就压出横向滚动条。
        // 缩放由 `pageZoom` 负责（会重排），见 `MainWindow.setZoom`。
        view.navigationDelegate = delegate
        // 文档加载完成前 WebKit 默认刷白，深色模式下会很刺眼
        view.underPageBackgroundColor = Palette.pageBackground
        return view
    }
}
