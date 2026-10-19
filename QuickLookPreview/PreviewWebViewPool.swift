import AppKit
import WebKit

import SharedTheme

/// Quick Look 扩展的 `WKWebView` 复用池（容量 1）。
///
/// 新建一个 `WKWebView` 约 60~75ms，而 Quick Look 常常连续预览多个文件
/// （在 Finder 里用方向键一路按过去），把实例留着复用能从关键路径上拿掉这一笔。
///
/// ⚠️ 回收要延迟：面板还在做退场动画时就把实例抽走，旧面板会闪。
@MainActor
final class PreviewWebViewPool {

    static let shared = PreviewWebViewPool()

    private var idle: WKWebView?
    private var token = 0

    /// 只有确认过回收会被调用，预热才有意义：Quick Look 面板不是常规的视图呈现，
    /// `viewWillDisappear` 不保证会来。不来则预热出来的实例永远没人取用。
    private var recyclingObserved = false

    /// 取一个实例：优先复用，没有就新建。
    ///
    /// `WKUserScript` 在建实例时就注入了（每个文档加载完自动生效），但**回调对象**
    /// 必须每次预览重新登记 —— 回执要发给当前控制器，旧的可能已经释放，
    /// 而 `userContentController` 对 handler 是强引用，留着就是泄漏 + 串台。
    func take(handler: WKScriptMessageHandler) -> WKWebView {
        token &+= 1

        let view: WKWebView
        if let idle {
            self.idle = nil
            view = idle
        } else {
            view = Self.makeView()
        }

        let controller = view.configuration.userContentController
        for name in [ScrollProbe.messageName, LinkInteraction.messageName] {
            controller.removeScriptMessageHandler(forName: name)
            controller.add(handler, name: name)
        }
        return view
    }

    /// 面板退场后延迟回收，避免抽走正在显示的那一份。
    func recycleLater(_ view: WKWebView) {
        let generation = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.token == generation, self.idle == nil else { return }

            view.stopLoading()
            view.removeFromSuperview()

            // 摘掉对旧控制器的强引用，否则每个用过的控制器都会跟着实例活到最后
            let controller = view.configuration.userContentController
            for name in [ScrollProbe.messageName, LinkInteraction.messageName] {
                controller.removeScriptMessageHandler(forName: name)
            }

            WebViewDocument.loadBlankPage(into: view)
            self.idle = view
            self.recyclingObserved = true
        }
    }

    /// 为"上一位还在回收延迟里、下一位已经来了"这种连按空格的情况备一份。
    /// 调用点在首帧之后，属于非关键路径；未确认回收可达之前不动手。
    func prewarm() {
        guard recyclingObserved, idle == nil else { return }
        let view = Self.makeView()
        WebViewDocument.loadBlankPage(into: view)
        idle = view
    }

    private static func makeView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(ScrollProbe.script)
        configuration.userContentController.addUserScript(LinkInteraction.userScript)

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                             configuration: configuration)
        view.underPageBackgroundColor = Palette.pageBackground
        // 扩展里没有别的缩放入口，所以这里保留捏合缩放（视觉放大）。
        // 主 App 不用它：那里会压出横向滚动条，见 MainWindow.setZoom。
        view.allowsMagnification = true
        return view
    }
}
