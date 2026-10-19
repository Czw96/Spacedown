import WebKit

/// 渲染结果的装载入口：空白页、baseURL、统一的 `load` 调用。
///
/// baseURL 必须是**非 file** URL。WebKit 收到 file URL 的 baseURL 会去申请
/// "可读这个目录"的沙箱扩展（`assumeReadAccessToBaseURL`），那是一条可能阻塞主线程的 IPC；
/// 而文档是单文件自包含的（CSS 内联、图片 base64、CSP `default-src 'none'`），
/// 不需要任何文件访问权。相对 URL 已被 CSP 全部挡掉，所以 baseURL 唯一的用途
/// —— 解析相对地址 —— 在这里也用不上。
@MainActor
public enum WebViewDocument {

    /// 预热 web view 内容的空白页。有正文（而不是 `about:blank`）才能把
    /// WebContent 进程拉起来，后续同进程内的二次导航很便宜。
    public static let blankPageHTML = "<!doctype html><meta charset='utf-8'><body></body>"

    public static let baseURL = URL(string: "about:blank")!

    @discardableResult
    public static func load(_ html: Data, into view: WKWebView) -> WKNavigation? {
        view.load(html, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: baseURL)
    }

    public static func loadBlankPage(into view: WKWebView) {
        view.loadHTMLString(blankPageHTML, baseURL: nil)
    }
}
