import WebKit

/// 预览页里的链接导航策略 —— 主 App 与 Quick Look 扩展共用同一套判定。
///
/// 两端的差别只有"谁来打开外链"：主 App 直接调 `NSWorkspace`，扩展必须走不在沙箱里的
/// `LinkOpener.xpc`。而"该不该放行"这件事必须一致，否则同一份文档在两处的行为会不一样，
/// 所以判定收在这里，两端只留各自的动作。
@MainActor
public enum LinkPolicy {

    public enum Decision {
        /// 放行。页内锚点（含被中和成 `#blocked-…` 的地址）与其它非链接导航都走这里。
        case allow
        /// 拦下但不打开：危险 scheme 没有任何"打开"的语义。
        case block
        /// 拦下并交给系统打开。
        case openExternally(URL)
    }

    public static func decision(for action: WKNavigationAction) -> Decision {
        // 只处理"用户点了链接"。脚本导航、表单提交、回退前进不归这里管
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        if LinkInteraction.isExternal(url) { return .openExternally(url) }
        if LinkInteraction.isBlocked(url) { return .block }
        return .allow
    }

    /// 把判定直接落到 `decisionHandler`：外链拦下后交给 `open`。
    ///
    /// 两端都只需要写"谁去打开"这一件不同的事，其余判定与回调顺序保持一致。
    public static func decide(_ action: WKNavigationAction,
                              using handler: @escaping @MainActor (WKNavigationActionPolicy) -> Void,
                              open: (URL) -> Void) {
        switch decision(for: action) {
        case .allow:
            handler(.allow)
        case .block:
            handler(.cancel)
        case .openExternally(let url):
            handler(.cancel)
            open(url)
        }
    }
}
