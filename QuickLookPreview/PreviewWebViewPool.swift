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
        for name in Self.messageNames {
            controller.removeScriptMessageHandler(forName: name)
            controller.add(handler, name: name)
        }
        return view
    }

    /// 所有脚本消息名集中一处：注册与注销必须用同一份清单，漏一个就是强引用泄漏。
    ///
    /// 滚动探针只在 Debug 里存在（见 `makeView`）：取证工具不该跟着发行版出去。
    private static let messageNames: [String] = {
        var names = [LinkInteraction.messageName, OpenInAppInteraction.messageName]
        #if DEBUG
        names.insert(ScrollProbe.messageName, at: 0)
        #endif
        return names
    }()

    /// 面板退场后延迟回收，避免抽走正在显示的那一份。
    func recycleLater(_ view: WKWebView) {
        let generation = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.token == generation, self.idle == nil else { return }

            view.stopLoading()
            view.removeFromSuperview()

            // 摘掉对旧控制器的强引用，否则每个用过的控制器都会跟着实例活到最后
            let controller = view.configuration.userContentController
            for name in Self.messageNames {
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

    /// 键盘缩放（⌘+/⌘−/⌘0）的区间。**上限 3 倍**：再大就只剩几个字，翻页比读更费劲。
    static let magnificationRange: ClosedRange<CGFloat> = 1.0...3.0

    private static func makeView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 滚动帧率探针是取证用的：发行版里每次滚动都要跑一段 rAF 采样、写一条日志，
        // 对用户是纯开销，所以只在 Debug 构建里注入。
        #if DEBUG
        configuration.userContentController.addUserScript(ScrollProbe.script)
        #endif
        configuration.userContentController.addUserScript(LinkInteraction.userScript)
        configuration.userContentController.addUserScript(OpenInAppInteraction.userScript)

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                             configuration: configuration)
        view.underPageBackgroundColor = Palette.pageBackground
        // 预览面板的缩放（捏合与 ⌘+/⌘−）走 `magnification`，即视觉放大：面板宽度用户
        // 自己可以拖，不需要像主 App 那样靠 `pageZoom` 重排来避免横向滚动条。
        // `WKWebView` 没有 min/maxMagnification（那是 NSScrollView 的），捏合的上限只能
        // 交给 WebKit；键盘缩放的区间由 `magnificationRange` 自己兜。
        view.allowsMagnification = true
        return view
    }
}
