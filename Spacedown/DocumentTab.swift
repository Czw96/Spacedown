import AppKit

/// 一个标签。
///
/// 它**不持有 webview** —— 实例归 `WebViewPool` 管。这里只留
/// "实例被淘汰后必须保住的东西"：滚动位置和缩放级别。
/// 池子把 webview 收回去时会先把 `scrollY` 用 JS 读出来存这儿（§7.2）。
@MainActor
final class DocumentTab {

    let url: URL
    var title: String

    /// 上次离开时的滚动位置。回来时 `didFinish` 之后 `scrollTo` 还原。
    var scrollY: Double = 0

    /// 每个标签各自记缩放。webview 是复用的，不记在模型上会串到别的标签。
    var magnification: CGFloat = 1

    init(url: URL) {
        self.url = url
        self.title = url.lastPathComponent
    }
}
