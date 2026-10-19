import AppKit
import WebKit

import SharedTheme

/// web view 的导航与脚本回调。
extension MainWindow: WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: - 导航

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        endLoading(webView)
        guard let tab = pool.tab(for: webView) else { return }

        if let started = loadStartedAt.removeValue(forKey: ObjectIdentifier(webView)) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.write(String(format: "firstPaint %@ = %.1fms (pool=%d)",
                                  tab.title, elapsed, pool.residentCount))
        }
        pool.markLoaded(tab, in: webView)
        logContentWidth(webView)
        restoreScrollIfNeeded(in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endLoading(webView)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        endLoading(webView)
    }

    /// 内容进程被系统回收时的兜底：重载它承载的那个标签。
    ///
    /// 不做的话窗口会变成一片空白，而且没有任何提示 —— 接近截断上限的大文档真的会触发。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tabs.first(where: { pool.residentView(for: $0) === webView }) else { return }
        DebugLog.write("webcontent_terminated 重载 \(tab.url.lastPathComponent)")
        load(tab, into: webView, restoreScroll: true)
    }

    private func restoreScrollIfNeeded(in webView: WKWebView) {
        let target = pendingScroll.removeValue(forKey: ObjectIdentifier(webView)) ?? 0
        guard target > 0 else { return }
        webView.evaluateJavaScript("window.scrollTo(0, \(target))")
    }

    // MARK: - 脚本消息

    /// 链接点击（脚本在 `LinkInteraction.script`）：单击复制，⌘ / ⌃ + 单击打开。
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == LinkInteraction.messageName,
              let action = LinkInteraction.action(from: message.body) else { return }

        switch action.kind {
        case .copy:
            LinkInteraction.copyToPasteboard(action.text)
            DebugLog.write("已复制链接 \(action.text)")
            showToast("已复制链接")
        case .open:
            DebugLog.write("打开链接 \(action.text)")
            NSWorkspace.shared.open(action.url)
        }
    }

    /// 兜底：脚本没拦住的导航（中键、键盘回车之类）一律取消并交给系统打开 ——
    /// 否则渲染页会被网页顶掉。CSP 管不住顶层导航。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              LinkInteraction.isExternal(url) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }
}
