import AppKit
import WebKit

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
        let view = Self.makeView(delegate: delegate)
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

        let view = spare.popLast() ?? Self.makeView(delegate: delegate)
        // 实例是复用的，缩放不会自己回到 1
        view.magnification = tab.magnification

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
    func captureScrollY(of tab: DocumentTab) {
        guard let view = residentView(for: tab) else { return }
        Task { @MainActor in
            if let raw = try? await view.evaluateJavaScript("window.scrollY") {
                tab.scrollY = (raw as? NSNumber)?.doubleValue ?? 0
            }
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

    private static func makeView(delegate: WKNavigationDelegate) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.allowsMagnification = true
        view.navigationDelegate = delegate
        // 文档加载完成前 WebKit 默认刷白，深色模式下会很刺眼
        view.underPageBackgroundColor = Palette.pageBackground
        return view
    }
}
