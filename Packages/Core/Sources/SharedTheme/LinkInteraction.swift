import AppKit
import WebKit

/// 链接的点击语义：**单击复制地址，⌘ / ⌃ + 单击交给系统打开**。
///
/// 逻辑放在注入的 JS 里，而不是原生导航代理：`decidePolicyForNavigationAction`
/// 分不出修饰键，也拿不到"用户只是想复制"这层意图。
///
/// 脚本与消息名由主 App 和 Quick Look 扩展共用，两端语义不会各自漂移。
public enum LinkInteraction {

    /// `WKScriptMessageHandler` 的注册名，必须与脚本里的 `messageHandlers[...]` 一致。
    public static let messageName = "spacedownLinkAction"

    /// 页面内注入的点击拦截脚本。
    ///
    /// 只接管 `http(s)` / `mailto`；站内锚点（`#…`）放行，让页面自己跳。
    public static let script = """
    (function () {
        if (window.__sdLinkBound) { return; }
        window.__sdLinkBound = true;
        function hrefOf(a) {
            var href = a && a.getAttribute ? (a.getAttribute('href') || '') : '';
            return /^(https?:|mailto:)/i.test(href) ? href : null;
        }
        function anchorFrom(e) {
            var el = e.target;
            return (el && el.closest) ? el.closest('a[href]') : null;
        }
        document.addEventListener('click', function (e) {
            var href = hrefOf(anchorFrom(e));
            if (!href) { return; }
            e.preventDefault();
            var open = e.metaKey || e.ctrlKey;
            window.webkit.messageHandlers.\(messageName).postMessage({
                type: open ? 'open' : 'copy', url: href
            });
        }, true);
    })();
    """

    /// 供 `WKWebViewConfiguration` 使用的用户脚本。
    @MainActor
    public static let userScript = WKUserScript(source: script,
                                                injectionTime: .atDocumentEnd,
                                                forMainFrameOnly: true)

    /// 脚本回调解析出的动作。
    public struct Action {
        public enum Kind: String {
            case copy
            case open
        }

        public let kind: Kind
        /// 原始字符串，复制时原样写进剪贴板。
        public let text: String
        public let url: URL
    }

    /// 解析 `WKScriptMessage.body`。无法解析时返回 nil。
    public static func action(from body: Any) -> Action? {
        guard let payload = body as? [String: Any],
              let type = payload["type"] as? String,
              let kind = Action.Kind(rawValue: type),
              let text = payload["url"] as? String,
              let url = URL(string: text) else { return nil }
        return Action(kind: kind, text: text, url: url)
    }

    public static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 只放行这三个 scheme，与 `LinkOpener` 服务侧的白名单保持一致。
    public static func isExternal(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return true
        default: return false
        }
    }
}
