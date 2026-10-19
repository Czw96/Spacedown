import AppKit

/// 一个标签。
///
/// 它**不持有 web view** —— 实例归 `WebViewPool` 管。这里只留"实例被回收后必须保住
/// 的东西"：滚动位置与缩放级别。
@MainActor
final class DocumentTab {

    let url: URL
    var title: String

    /// 上次离开时的滚动位置，回到这个标签时在 `didFinish` 之后还原。
    var scrollY: Double = 0

    /// 每个标签各自记缩放：web view 是复用的，不记在模型上会串到别的标签。
    ///
    /// 它对应 `WKWebView.pageZoom`（会重排），不是 `magnification`（只做视觉放大）。
    var zoom: CGFloat = 1

    init(url: URL) {
        self.url = url
        self.title = url.lastPathComponent
    }
}
