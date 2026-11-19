import AppKit
import WebKit

/// 预览片段末尾的「加载更多」按钮。
///
/// 空格预览只渲染前 64 KB（按完整块切，见 `MarkdownDocument.previewBytes`）；
/// 要看全文就把文件交给主 App（它本来就是全量加载），预览扩展不再自己渲染全量 HTML。
/// 扩展是沙箱进程，点按钮只能发一条消息，由控制器转给不在沙箱里的 `LinkOpener.xpc`。
///
/// 与链接共用 `WKScriptMessageHandler` 机制但**单独一个消息名**，语义不同；
/// 两端只有 QL 注册它。
///
/// 为什么是注入脚本委托而不是 `onclick`：CSP 是 `default-src 'none'`，
/// 没有 `script-src`，内联事件处理器会被挡死；`WKUserScript` 由原生注入，不受 CSP 管。
public enum OpenInAppInteraction {

    public static let messageName = "spacedownOpenInApp"
    /// 按钮的 CSS class。别用 `data-*`：危险 URL 过滤器的属性扫描表里含 `data`。
    public static let buttonClass = "sd-open-in-app"

    public static let script = """
    (function () {
        if (window.__sdOpenInAppBound) { return; }
        window.__sdOpenInAppBound = true;
        document.addEventListener('click', function (e) {
            var el = e.target;
            var button = (el && el.closest) ? el.closest('.\(buttonClass)') : null;
            if (!button) { return; }
            e.preventDefault();
            // 记下原文案，原生回执后能原样恢复；文案只在 HTML 里写一次。
            if (!window.__sdOpenInAppLabel) { window.__sdOpenInAppLabel = button.textContent; }
            button.disabled = true;
            button.textContent = '正在打开…';
            window.webkit.messageHandlers.\(messageName).postMessage({ type: 'openInApp' });
        }, true);
    })();
    """

    /// XPC 回执后解禁按钮（成功时允许再点一次，失败时允许重试）。
    public static let restoreScript = """
    (function () {
        var b = document.querySelector('.\(buttonClass)');
        if (b) {
            b.disabled = false;
            if (window.__sdOpenInAppLabel) { b.textContent = window.__sdOpenInAppLabel; }
        }
    })();
    """

    @MainActor
    public static let userScript = WKUserScript(source: script,
                                                injectionTime: .atDocumentEnd,
                                                forMainFrameOnly: true)
}

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

    /// 这些 scheme 一律不许导航：它们要么执行脚本，要么把页面顶成一份内嵌文档。
    ///
    /// 顶层导航不在 CSP `default-src` 的管辖范围内（`form-action` 只管表单提交），
    /// 所以必须在导航代理里显式拦掉，不能指望 CSP。
    public static func isBlocked(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "javascript", "vbscript", "data": return true
        default: return false
        }
    }
}
